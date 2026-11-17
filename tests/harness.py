# Concurrency and correctness suite for the stock ledger.
#
# Runs against a REAL PostgreSQL with many parallel connections (no mocks). It TRUNCATES
# tables, so only point it at a throwaway database; scripts/run_tests.sh builds one.
#   PG_DSN="host=... dbname=ledger_test user=... password=..." python3 tests/harness.py
import os, psycopg2, threading, uuid, time, statistics, sys, json, random, datetime

DSN = os.environ.get("PG_DSN", "host=127.0.0.1 dbname=ledger_test user=postgres password=pw")
TODAY = datetime.date.today()
def d(days): return (TODAY + datetime.timedelta(days=days)).isoformat()

def conn_as(uid):
    c = psycopg2.connect(DSN); c.autocommit = True
    cur = c.cursor()
    cur.execute("set role authenticated")
    cur.execute("select set_config('request.jwt.claim.sub', %s, false)", (str(uid),))
    return c

a = psycopg2.connect(DSN); a.autocommit = True; ac = a.cursor()
ac.execute("truncate sales, sale_items, sale_item_batches, stock_movements, product_batches, "
           "sale_counters, products, users, auth.users restart identity cascade")
CASHIER, PHARM = uuid.uuid4(), uuid.uuid4()
for uid, name, role in [(CASHIER, 'Cash', 'CASHIER'), (PHARM, 'Pharm', 'PHARMACIST')]:
    ac.execute("insert into auth.users values (%s)", (str(uid),))
    ac.execute("insert into users(id,name,email,role) values (%s,%s,%s,%s)", (str(uid), name, name + '@x.com', role))

BN = [0]
def mkbatch(pid, qty, expiry=None, number=None):
    """Create a batch with opening stock the way a migration would: batch + OPENING movement."""
    BN[0] += 1
    ac.execute('insert into product_batches("productId","batchNumber","expiryDate") values (%s,%s,%s) returning id',
               (pid, number or f'B{BN[0]}', expiry))
    bid = ac.fetchone()[0]
    if qty:
        ac.execute('insert into stock_movements("productId","batchId",type,quantity,reason) values (%s,%s,%s,%s,%s)',
                   (pid, bid, 'OPENING', qty, 'test'))
    return bid

def mkprod(name, price, stock=0, expiry=None, batches=None):
    ac.execute('insert into products(name,"sellingPrice") values (%s,%s) returning id', (name, price))
    pid = ac.fetchone()[0]
    if batches:
        for qty, exp in batches: mkbatch(pid, qty, exp)
    elif stock:
        mkbatch(pid, stock, expiry)
    return pid

def stock(pid):
    ac.execute('select "stockQuantity" from products where id=%s', (pid,)); return ac.fetchone()[0]
def bq(bid):
    ac.execute('select "quantityOnHand" from product_batches where id=%s', (bid,)); return ac.fetchone()[0]
def batches_of(pid):
    ac.execute('select id from product_batches where "productId"=%s order by "expiryDate" nulls last, id', (pid,))
    return [r[0] for r in ac.fetchall()]

def call(c, sql, params):
    cur = c.cursor()
    try:
        cur.execute(sql, params); return ('ok', cur.fetchone()[0] if cur.description else None)
    except psycopg2.Error as e:
        return ('err', e.pgerror.split('\n')[0].replace('ERROR:  ', ''))

def sale(c, items, key=None, discount=0, pm='CASH'):
    return call(c, "select create_sale(%s::jsonb, %s::payment_method, %s, null, %s)", (json.dumps(items), pm, discount, key))
def void(c, sid, reason='t'):
    return call(c, "select void_sale(%s, %s)", (sid, reason))
def receive(c, pid, qty, batch, expiry=None, key=None, cost=None):
    return call(c, "select receive_stock(%s,%s,%s,%s,%s,null,null,%s)", (str(pid), qty, batch, expiry, cost, key))
def adjust(c, bid, delta, typ, reason=None, key=None):
    return call(c, "select adjust_stock(%s,%s,%s::movement_type,%s,%s)", (str(bid), delta, typ, reason, key))
def integrity():
    ac.execute("select kind, id, expected, actual from verify_stock_integrity()"); return ac.fetchall()

def run_parallel(fns):
    res = [None] * len(fns); lat = [0] * len(fns)
    def w(i):
        t = time.perf_counter(); res[i] = fns[i](); lat[i] = (time.perf_counter() - t) * 1000
    ts = [threading.Thread(target=w, args=(i,)) for i in range(len(fns))]
    [t.start() for t in ts]; [t.join() for t in ts]
    return res, lat

fails = 0; passes = 0
def check(name, cond, detail=''):
    global fails, passes
    print(('PASS' if cond else 'FAIL'), '-', name, detail)
    if cond: passes += 1
    else: fails += 1

pitems = lambda pid, q=1, **kw: [{'productId': str(pid), 'quantity': q, **kw}]
cashiers = [conn_as(CASHIER) for _ in range(40)]
pharms = [conn_as(PHARM) for _ in range(12)]
cc = cashiers[0]; pc = pharms[0]

print('\n--- 1. No oversell across batches (300 parallel sales, 100 units in 3 batches)')
p1 = mkprod('Paracetamol', 5.0, batches=[(40, d(30)), (30, d(90)), (30, None)])
fns = [(lambda i=i: sale(cashiers[i % 40], pitems(p1), key=f'k1-{i}')) for i in range(300)]
res, lat = run_parallel(fns)
ok = [r for r in res if r[0] == 'ok']; err = [r for r in res if r[0] == 'err']
check('exactly 100 sales succeed', len(ok) == 100, f'ok={len(ok)} err={len(err)}')
check('rest rejected with INSUFFICIENT_STOCK', all(e[1].startswith('INSUFFICIENT_STOCK') for e in err), str({e[1] for e in err}))
check('product stock exactly 0 and every batch exactly 0', stock(p1) == 0 and all(bq(b) == 0 for b in batches_of(p1)))
ac.execute('select count(*), count(distinct "saleNumber") from sales'); c, dd = ac.fetchone()
check('sale numbers unique', c == dd == 100, f'{c}/{dd}')
ac.execute("select count(*) from stock_movements where type='SALE'"); check('one SALE ledger row per allocation', ac.fetchone()[0] == 100)
check('integrity check clean', integrity() == [], str(integrity()))
lo = sorted(lat); print(f'   (not a benchmark) 300 threads/40 conns: p50={statistics.median(lo):.0f}ms p95={lo[int(.95*len(lo))]:.0f}ms')

print('\n--- 2. FEFO allocation')
pf = mkprod('Amoxicillin', 12.0)
bA = mkbatch(pf, 5, d(30)); bB = mkbatch(pf, 5, d(10)); bC = mkbatch(pf, 5, None); bD = mkbatch(pf, 5, d(-1))
r = sale(cc, pitems(pf, 7))
check('sale of 7 ok', r[0] == 'ok', str(r))
check('took soonest expiry first: B emptied, A gave 2, C and expired D untouched', (bq(bB), bq(bA), bq(bC), bq(bD)) == (0, 3, 5, 5), str((bq(bB), bq(bA), bq(bC), bq(bD))))
allocs = r[1]['saleItems'][0]['batches']
check('receipt shows batches used', sum(x['quantity'] for x in allocs) == 7 and len(allocs) == 2, str(allocs))
r2 = sale(cc, pitems(pf, 9))
check('asking 9 with 8 sellable (+5 expired) -> INSUFFICIENT_STOCK|...|8 (expired not counted)', r2[0] == 'err' and r2[1].endswith('|8'), str(r2))
r3 = sale(cc, pitems(pf, 8)); check('selling the remaining 8 works, expired batch still untouched', r3[0] == 'ok' and bq(bD) == 5)
r4 = sale(cc, pitems(pf, 1)); check('only expired stock left -> PRODUCT_EXPIRED', r4[0] == 'err' and r4[1].startswith('PRODUCT_EXPIRED'), str(r4))
ac.execute("select count(*) from stock_movements where \"productId\"=%s and \"batchId\"=%s and type='SALE'", (pf, bD)); check('expired batch has zero SALE movements', ac.fetchone()[0] == 0)

print('\n--- 3. Void returns stock to the SAME batches, once')
pv = mkprod('Vitamin C', 2.0)
v1 = mkbatch(pv, 3, d(20)); v2 = mkbatch(pv, 10, d(200))
r = sale(cc, pitems(pv, 5)); sid = r[1]['id']
check('multi-batch sale split 3 + 2', (bq(v1), bq(v2)) == (0, 8), str((bq(v1), bq(v2))))
res, _ = run_parallel([(lambda i=i: void(pharms[i], sid)) for i in range(10)])
oks = [x for x in res if x[0] == 'ok']
check('exactly one of 10 concurrent voids succeeds', len(oks) == 1, f'ok={len(oks)}')
check('others rejected SALE_NOT_VOIDABLE', all(x[1].startswith('SALE_NOT_VOIDABLE') for x in res if x[0] == 'err'))
check('stock restored to the same batches (3 and 10)', (bq(v1), bq(v2)) == (3, 10) and stock(pv) == 13, str((bq(v1), bq(v2))))
ac.execute("select count(*) from stock_movements where type='SALE_VOID' and \"saleId\"=%s", (sid,)); check('one SALE_VOID row per batch (2)', ac.fetchone()[0] == 2)
check('cashier cannot void', void(cc, sid)[1].startswith('FORBIDDEN'))
check('void unknown sale -> SALE_NOT_FOUND', 'SALE_NOT_FOUND' in void(pc, str(uuid.uuid4()))[1])

print('\n--- 4. Idempotency, server-side price, validation')
pi = mkprod('Ibuprofen', 8.0, stock=50)
res, _ = run_parallel([(lambda i=i: sale(cashiers[i % 40], pitems(pi, 3), key='same-key')) for i in range(25)])
oks = [r for r in res if r[0] == 'ok']; ids = {r[1]['id'] for r in oks}
check('25 parallel retries: all succeed, ONE sale, stock 47', len(oks) == 25 and len(ids) == 1 and stock(pi) == 47, f'ids={len(ids)} stock={stock(pi)}')
check('exactly one reports replayed=false', sum(1 for r in oks if r[1]['replayed'] is False) == 1)
r = sale(pc, pitems(pi, 1), key='same-key'); check('key scoped per user (other user gets a NEW sale)', r[0] == 'ok' and r[1]['id'] not in ids and stock(pi) == 46)
r = sale(cc, pitems(pi, 2, unitPrice=0.01)); check('client price ignored (total 16.00)', r[0] == 'ok' and float(r[1]['total']) == 16.0)
check('cashier sale deducts stock', stock(pi) == 44, str(stock(pi)))
for name, items, disc, exp in [
    ('empty cart', [], 0, 'EMPTY_CART'), ('qty 0', pitems(pi, 0), 0, 'INVALID_QUANTITY'),
    ('negative qty', pitems(pi, -5), 0, 'INVALID_QUANTITY'), ('unknown product', pitems(uuid.uuid4()), 0, 'PRODUCT_NOT_FOUND'),
    ('garbage productId', [{'productId': 'nope', 'quantity': 1}], 0, 'INVALID_ITEMS'),
    ('discount > subtotal', pitems(pi, 1), 999, 'INVALID_DISCOUNT'), ('negative discount', pitems(pi, 1), -1, 'INVALID_DISCOUNT'),
    ('line discount > line total', pitems(pi, 1, discount=50), 0, 'INVALID_DISCOUNT'), ('over-stock', pitems(pi, 99), 0, 'INSUFFICIENT_STOCK')]:
    r = sale(cc, items, discount=disc); check(f'reject: {name}', r[0] == 'err' and r[1].startswith(exp), r[1] if r[0] == 'err' else 'accepted!')
check('rejections changed no stock', stock(pi) == 44)
r = sale(cc, pitems(pi, 3) + pitems(pi, 4)); check('duplicate lines merged (7), stock 44->37', r[0] == 'ok' and stock(pi) == 37 and len(r[1]['saleItems']) == 1)
cur = cc.cursor()
try: cur.execute("insert into sales(\"saleNumber\",subtotal,total) values ('HACK',0,0)"); direct = 'allowed'
except psycopg2.Error: direct = 'blocked'
check('direct INSERT into sales blocked', direct == 'blocked')
anon = psycopg2.connect(DSN); anon.autocommit = True; ca = anon.cursor(); ca.execute("set role anon")
for fn in ["select create_sale('[]'::jsonb)", "select receive_stock(null,1,'x')", "select verify_stock_integrity()"]:
    try: ca.execute(fn); res_ = 'allowed'
    except psycopg2.Error: res_ = 'blocked'
    check(f'anon cannot run {fn.split("(")[0][7:]}', res_ == 'blocked')

print('\n--- 5. Ledger cannot be bypassed or rewritten')
pb = mkprod('Guarded', 3.0, stock=10)
def attempt(c, sql, params=()):
    cur = c.cursor()
    try: cur.execute(sql, params); return 'allowed'
    except psycopg2.Error as e: return e.pgerror.split('\n')[0].replace('ERROR:  ', '')
check('pharmacist cannot UPDATE products.stockQuantity', 'STOCK_LEDGER_ONLY' in attempt(pc, 'update products set "stockQuantity"=999 where id=%s', (pb,)) and stock(pb) == 10)
check('pharmacist CAN edit product details (price)', attempt(pc, 'update products set "sellingPrice"=4 where id=%s', (pb,)) == 'allowed')
check('API user cannot INSERT a product with stock', 'STOCK_LEDGER_ONLY' in attempt(pc, 'insert into products(name,"sellingPrice","stockQuantity") values (\'x\',1,5)'))
check('API user cannot INSERT/UPDATE batches directly', attempt(pc, 'update product_batches set "quantityOnHand"=999') != 'allowed' and attempt(pc, 'insert into product_batches("productId","batchNumber") values (%s,\'X\')', (pb,)) != 'allowed')
check('API user cannot write the ledger directly', attempt(pc, "insert into stock_movements(\"productId\",\"batchId\",type,quantity) values (%s,%s,'RECEIPT',5)", (pb, batches_of(pb)[0])) != 'allowed')
check('UPDATE of a ledger row refused (even as superuser)', 'LEDGER_IMMUTABLE' in attempt(ac.connection, 'update stock_movements set quantity=quantity+1'))
check('DELETE of a ledger row refused (even as superuser)', 'LEDGER_IMMUTABLE' in attempt(ac.connection, 'delete from stock_movements'))
cur = cc.cursor(); cur.execute('select count(*) from stock_movements'); check('cashier sees 0 ledger rows', cur.fetchone()[0] == 0)
cur = pc.cursor(); cur.execute('select count(*) from stock_movements'); check('pharmacist sees ledger rows', cur.fetchone()[0] > 0)
check('sign rule: SALE with positive quantity rejected by constraint', 'chk_movement_sign' in attempt(ac.connection, "insert into stock_movements(\"productId\",\"batchId\",type,quantity) values (%s,%s,'SALE',5)", (pb, batches_of(pb)[0])))
check('batch must belong to the product (composite FK)', 'foreign key' in attempt(ac.connection, "insert into stock_movements(\"productId\",\"batchId\",type,quantity) values (%s,%s,'RECEIPT',5)", (p1, batches_of(pb)[0])).lower())

print('\n--- 6. receive_stock')
pr = mkprod('Receivable', 10.0)
check('cashier cannot receive', receive(cc, pr, 10, 'R1', d(100))[1].startswith('FORBIDDEN'))
for name, args, exp in [('qty 0', (pr, 0, 'R1', d(100)), 'INVALID_QUANTITY'), ('blank batch no.', (pr, 5, '  ', d(100)), 'INVALID_BATCH'),
                        ('already-expired batch', (pr, 5, 'R1', d(-3)), 'EXPIRED_BATCH'), ('unknown product', (uuid.uuid4(), 5, 'R1', d(100)), 'PRODUCT_NOT_FOUND')]:
    r = receive(pc, *args); check(f'reject: {name}', r[0] == 'err' and r[1].startswith(exp), str(r))
r = receive(pc, pr, 20, 'R1', d(100), cost=6.5); check('receive creates batch R1 (20)', r[0] == 'ok' and r[1]['quantityOnHand'] == 20 and stock(pr) == 20, str(r))
r = receive(pc, pr, 5, 'R1', d(100)); check('same batch number tops up (25)', r[0] == 'ok' and r[1]['quantityOnHand'] == 25 and stock(pr) == 25)
r = receive(pc, pr, 5, 'R1', d(150)); check('same batch number, different expiry -> BATCH_EXPIRY_MISMATCH', r[0] == 'err' and r[1].startswith('BATCH_EXPIRY_MISMATCH'))
res, _ = run_parallel([(lambda i=i: receive(pharms[i % 12], pr, 7, 'R2', d(60), key='recv-1')) for i in range(10)])
ac.execute("select count(*) from stock_movements where \"idempotencyKey\" is not null and type='RECEIPT'")
r2q = ac.execute('select "quantityOnHand" from product_batches where "productId"=%s and "batchNumber"=%s', (pr, 'R2')) or ac.fetchone()
check('double-submitted receipt (10 parallel, same key) adds stock once', all(x[0] == 'ok' for x in res) and r2q[0] == 7 and stock(pr) == 32, f'R2={r2q[0]} stock={stock(pr)}')

print('\n--- 7. adjust_stock')
pa = mkprod('Adjustable', 4.0); ba = mkbatch(pa, 10, d(50))
check('cashier cannot adjust', adjust(cc, ba, -1, 'DAMAGE')[1].startswith('FORBIDDEN'))
check('DAMAGE must be negative', adjust(pc, ba, 3, 'DAMAGE')[1].startswith('INVALID_QUANTITY'))
check('RECEIPT is not an adjust type', adjust(pc, ba, -1, 'RECEIPT')[1].startswith('INVALID_TYPE'))
check('CORRECTION requires a reason', adjust(pc, ba, -1, 'CORRECTION')[1].startswith('REASON_REQUIRED'))
check('cannot remove more than on hand', adjust(pc, ba, -11, 'DAMAGE')[1].startswith('INSUFFICIENT_STOCK'))
check('unknown batch', adjust(pc, uuid.uuid4(), -1, 'DAMAGE')[1].startswith('BATCH_NOT_FOUND'))
r = adjust(pc, ba, -4, 'DAMAGE', 'dropped'); check('damage -4 -> 6', r[0] == 'ok' and bq(ba) == 6 and stock(pa) == 6)
r = adjust(pc, ba, 3, 'CORRECTION', 'recount found 3 more'); check('correction +3 -> 9', r[0] == 'ok' and bq(ba) == 9)
r = adjust(pc, ba, -9, 'EXPIRY_WRITEOFF', 'expired'); check('write-off to 0', r[0] == 'ok' and bq(ba) == 0 and stock(pa) == 0)
bb = mkbatch(pa, 100, d(50))
res, _ = run_parallel([(lambda i=i: adjust(pharms[i % 12], bb, -1, 'DAMAGE', None, key='adj-1')) for i in range(10)])
check('double-submitted adjustment (same key) applies once', all(x[0] == 'ok' for x in res) and bq(bb) == 99, str(bq(bb)))
res, _ = run_parallel([(lambda i=i: adjust(pharms[i % 12], bb, -1, 'DAMAGE', None, key=f'adj-x{i}')) for i in range(120)])
check('120 concurrent single-unit write-offs on 99 units: exactly 99 succeed, batch never negative', sum(1 for x in res if x[0] == 'ok') == 99 and bq(bb) == 0, str(bq(bb)))

print('\n--- 8. Lock ordering: opposite-order multi-product carts, multi-batch, no deadlocks')
pa1 = mkprod('A', 1, batches=[(300, d(20)), (300, d(40)), (400, None)]); pa2 = mkprod('B', 1, batches=[(500, d(15)), (500, d(80))])
def cart(i):
    items = pitems(pa1, 2) + pitems(pa2, 3)
    if i % 2: items.reverse()
    return sale(cashiers[i % 40], items)
res, _ = run_parallel([(lambda i=i: cart(i)) for i in range(250)])
check('250 opposite-order carts all succeed', all(r[0] == 'ok' for r in res), str({r[1] for r in res if r[0] == 'err'}))
check('stock A=500, B=250', stock(pa1) == 500 and stock(pa2) == 250, f'{stock(pa1)} {stock(pa2)}')

print('\n--- 9. Atomicity')
pg_, pbad = mkprod('Good', 1, stock=10), mkprod('Bad', 1)
ac.execute('select count(*) from sales'); before = ac.fetchone()[0]
r = sale(cc, pitems(pg_, 2) + pitems(pbad, 1))
ac.execute('select count(*) from sales'); after = ac.fetchone()[0]
check('failed cart leaves no sale, no stock change', r[0] == 'err' and before == after and stock(pg_) == 10)
ac.execute("select count(*) from sale_counters where day=(now() at time zone 'Africa/Accra')::date and last_number=(select count(*) from sales)")
check('sale numbers gapless', ac.fetchone()[0] == 1)

print('\n--- 10. Randomised stress: mixed carts, receipts, damage and voids, all concurrent')
random.seed(7)
sp = [mkprod(f'S{i}', 2.0 + i, batches=[(random.randint(20, 60), d(random.choice([10, 25, 60, 400]))) for _ in range(random.randint(1, 3))]) for i in range(8)]
initial = {p: stock(p) for p in sp}
recv_total = {p: 0 for p in sp}; sold_ids = []; lock = threading.Lock()
def rnd_cart(i):
    items = []
    for p in random.sample(sp, random.randint(1, 3)): items += pitems(p, random.randint(1, 4))
    r = sale(cashiers[i % 40], items)
    if r[0] == 'ok':
        with lock: sold_ids.append(r[1]['id'])
    return r
def rnd_recv(i):
    p = random.choice(sp); n = random.randint(1, 10)
    r = receive(pharms[i % 12], p, n, f'NEW{i}', d(random.choice([30, 90, 500])))
    if r[0] == 'ok':
        with lock: recv_total[p] += n
    return r
def rnd_void(i):
    with lock: sid = random.choice(sold_ids) if sold_ids else None
    return void(pharms[i % 12], sid) if sid else ('ok', None)
tasks = [(rnd_cart, i) for i in range(260)] + [(rnd_recv, i) for i in range(30)] + [(rnd_void, i) for i in range(50)]
random.shuffle(tasks)
res, _ = run_parallel([(lambda f=f, i=i: f(i)) for f, i in tasks])
unexpected = {r[1] for r in res if r[0] == 'err' and not r[1].startswith(('INSUFFICIENT_STOCK', 'SALE_NOT_VOIDABLE', 'PRODUCT_EXPIRED'))}
check('no unexpected errors (deadlocks, constraint violations...)', not unexpected, str(unexpected))
check('integrity: ledger == batch balances == product caches', integrity() == [], str(integrity()[:3]))
ac.execute('select count(*) from product_batches where "quantityOnHand" < 0'); check('no negative batch', ac.fetchone()[0] == 0)
ok_conserved = True
for p in sp:
    ac.execute("select coalesce(sum(si.quantity),0) from sale_items si join sales s on s.id=si.\"saleId\" where si.\"productId\"=%s and s.status='COMPLETED'", (p,))
    sold = ac.fetchone()[0]
    if initial[p] + recv_total[p] != stock(p) + sold: ok_conserved = False; print('   mismatch', p, initial[p], recv_total[p], stock(p), sold)
check('conservation: initial + received == on hand + sold (completed sales), every product', ok_conserved)
ac.execute("select count(*) from stock_movements m join sales s on s.id=m.\"saleId\" where m.type='SALE' and s.status='COMPLETED' and -m.quantity <> (select coalesce(sum(sib.quantity),0) from sale_item_batches sib join sale_items si on si.id=sib.\"saleItemId\" where si.\"saleId\"=s.id and sib.\"batchId\"=m.\"batchId\")")
check('every SALE movement matches its sale_item_batches allocation', ac.fetchone()[0] == 0)

print('\n--- 11. Integrity check detects tampering')
tp = mkprod('Tamper', 1, stock=10)
ac.execute('update products set "stockQuantity"="stockQuantity"+5 where id=%s', (tp,))   # superuser bypass
bad = integrity(); check('product cache drift detected', any(k == 'product' and i == tp for k, i, _, _ in bad), str(bad))
ac.execute('update products set "stockQuantity"="stockQuantity"-5 where id=%s', (tp,))
check('clean again after repair', integrity() == [])
check('verify_stock_integrity forbidden for cashier', (lambda r: r[0] == 'err' and 'FORBIDDEN' in r[1])(call(cc, 'select verify_stock_integrity()', ())))
ac.execute('select count(*) from expiring_batches'); check('expiring_batches view returns near-expiry stock', ac.fetchone()[0] > 0)

print(f'\n{"FAILED" if fails else "ALL PASSED"}  ({passes} passed, {fails} failed)')
sys.exit(1 if fails else 0)
