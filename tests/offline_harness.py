# Offline-selling suite (ADR 0003): submit_offline_sale, shortfalls, resolve_shortfall,
# void_sale with shortfalls, and the sale-line invariant in verify_stock_integrity().
#
# Runs against a REAL PostgreSQL with parallel connections. TRUNCATES tables: throwaway DB only.
#   PG_DSN="host=... dbname=ledger_test user=... password=..." python3 tests/offline_harness.py
import os, psycopg2, threading, uuid, time, sys, json, random, datetime

DSN = os.environ.get("PG_DSN", "host=127.0.0.1 dbname=ledger_test user=postgres password=pw")
TODAY = datetime.date.today()
def d(days): return (TODAY + datetime.timedelta(days=days)).isoformat()

def conn_as(uid):
    c = psycopg2.connect(DSN); c.autocommit = True
    cur = c.cursor(); cur.execute("set role authenticated")
    if uid is not None:
        cur.execute("select set_config('request.jwt.claim.sub', %s, false)", (str(uid),))
    return c

a = psycopg2.connect(DSN); a.autocommit = True; ac = a.cursor()
ac.execute("truncate sales, sale_items, sale_item_batches, stock_movements, product_batches, "
           "sale_counters, sale_shortfalls, sale_flags, devices, products, users, auth.users "
           "restart identity cascade")
CASHIER, PHARM, PHARM2 = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
for uid, name, role in [(CASHIER, 'Cash', 'CASHIER'), (PHARM, 'Pharm', 'PHARMACIST'), (PHARM2, 'Pharm2', 'PHARMACIST')]:
    ac.execute("insert into auth.users values (%s)", (str(uid),))
    ac.execute("insert into users(id,name,email,role) values (%s,%s,%s,%s)", (str(uid), name, name + '@x.com', role))

BN = [0]
def mkbatch(pid, qty, expiry=None):
    BN[0] += 1
    ac.execute('insert into product_batches("productId","batchNumber","expiryDate") values (%s,%s,%s) returning id',
               (pid, f'B{BN[0]}', expiry))
    bid = ac.fetchone()[0]
    if qty:
        ac.execute('insert into stock_movements("productId","batchId",type,quantity,reason) values (%s,%s,%s,%s,%s)',
                   (pid, bid, 'OPENING', qty, 'test'))
    return bid
def mkprod(name, price=5.0, batches=()):
    ac.execute('insert into products(name,"sellingPrice") values (%s,%s) returning id', (name, price))
    pid = ac.fetchone()[0]
    return pid, [mkbatch(pid, q, e) for q, e in batches]
def qone(sql, params=()):
    ac.execute(sql, params); r = ac.fetchone(); return r[0] if r else None
def stock(pid): return qone('select "stockQuantity" from products where id=%s', (pid,))
def bq(bid): return qone('select "quantityOnHand" from product_batches where id=%s', (bid,))

def call(c, sql, params):
    cur = c.cursor()
    try:
        cur.execute(sql, params); return ('ok', cur.fetchone()[0] if cur.description else None)
    except psycopg2.Error as e:
        return ('err', e.pgerror.split('\n')[0].replace('ERROR:  ', ''))

def new_device(name='till'):
    ac.execute('insert into devices(name) values (%s) returning id', (name,)); return ac.fetchone()[0]
def offline(c, dev, cid, items, off_s=0, pm='CASH', discount=0, receipt=None):
    """off_s = seconds from the server's now() that the device says the sale happened."""
    return call(c, "select submit_offline_sale(%s,%s, now() + (%s * interval '1 second'), %s::jsonb, "
                   "%s::payment_method, %s, null, %s)", (str(dev), str(cid), off_s, json.dumps(items), pm, discount, receipt))
def line(pid, qty, price=5.0, **kw): return {'productId': str(pid), 'quantity': qty, 'unitPrice': price, **kw}
def resolve(c, sfid, action, batch=None, reason=None):
    return call(c, "select resolve_shortfall(%s,%s,%s,%s)", (str(sfid), action, str(batch) if batch else None, reason))
def online(c, items, key=None):
    return call(c, "select create_sale(%s::jsonb,'CASH',0,null,%s)", (json.dumps(items), key))
def void(c, sid, why='t'): return call(c, "select void_sale(%s,%s)", (str(sid), why))
def integrity():
    ac.execute("select kind, id, expected, actual from verify_stock_integrity()"); return ac.fetchall()
def sf_of(sale_json): return sale_json['shortfalls']
def flags_of(sale_json): return {f['code'] for f in sale_json['flags']}

def run_parallel(fns):
    res = [None] * len(fns)
    def w(i): res[i] = fns[i]()
    ts = [threading.Thread(target=w, args=(i,)) for i in range(len(fns))]
    [t.start() for t in ts]; [t.join() for t in ts]
    return res

fails = 0; passes = 0
def check(name, cond, detail=''):
    global fails, passes
    print(('PASS' if cond else 'FAIL'), '-', name, detail)
    if cond: passes += 1
    else: fails += 1

cash = [conn_as(CASHIER) for _ in range(30)]; cc = cash[0]
pharm = [conn_as(PHARM) for _ in range(10)]; pc = pharm[0]
pc2 = conn_as(PHARM2)

print('\n--- 1. Idempotency: duplicates, replays and parallel retries')
dev = new_device()
p, (b,) = mkprod('Idem', 5.0, [(50, d(60))])
cid = uuid.uuid4()
res = run_parallel([(lambda i=i: offline(cash[i % 30], dev, cid, [line(p, 3)])) for i in range(20)])
oks = [r for r in res if r[0] == 'ok']; ids = {r[1]['id'] for r in oks}
check('20 parallel submissions of one sale: all succeed, ONE sale', len(oks) == 20 and len(ids) == 1, f'ids={len(ids)}')
check('stock moved once (50 -> 47)', stock(p) == 47, str(stock(p)))
check('exactly one reports replayed=false', sum(1 for r in oks if r[1]['replayed'] is False) == 1)
r = offline(cc, dev, cid, [line(p, 99)])
check('a later replay returns the ORIGINAL sale even if the payload differs', r[0] == 'ok' and r[1]['replayed'] and r[1]['id'] in ids and stock(p) == 47)
dev2 = new_device('till 2')
r = offline(cc, dev2, cid, [line(p, 1)])
check('the same client sale id on ANOTHER device is a different sale', r[0] == 'ok' and r[1]['id'] not in ids and stock(p) == 46)
r = offline(cc, dev, uuid.uuid4(), [line(p, 2)], receipt='OFF-T1-0007')
check('device receipt number kept; server assigns its own sale number', r[0] == 'ok' and r[1]['saleNumber'].startswith('POS-')
      and qone('select "clientReceiptNumber" from sales where id=%s', (r[1]['id'],)) == 'OFF-T1-0007')
row = qone("select source::text || '|' || (\"occurredAt\" is not null)::text || '|' || (\"receivedAt\" is not null)::text from sales where id=%s", (r[1]['id'],))
check('source OFFLINE, occurredAt and receivedAt both stored', row == 'OFFLINE|true|true', row)
r = online(cc, [{'productId': str(p), 'quantity': 1}])
row = qone("select source::text || '|' || coalesce(\"deviceId\"::text,'none') from sales where id=%s", (r[1]['id'],))
check('online sales are untouched: source ONLINE, no device', row == 'ONLINE|none', row)

print('\n--- 2. Order does not matter (same sales, forward vs reverse)')
random.seed(11)
qtys = [random.randint(1, 4) for _ in range(25)]
assert sum(qtys) <= 100
pA, bA = mkprod('OrderA', 5.0, [(30, d(10)), (40, d(60)), (30, None)])
pB, bB = mkprod('OrderB', 5.0, [(30, d(10)), (40, d(60)), (30, None)])
dF, dR = new_device('fwd'), new_device('rev')
for i, q in enumerate(qtys): assert offline(cc, dF, uuid.uuid4(), [line(pA, q)])[0] == 'ok'
for q in reversed(qtys): assert offline(cc, dR, uuid.uuid4(), [line(pB, q)])[0] == 'ok'
fa, fb = [bq(x) for x in bA], [bq(x) for x in bB]
check('per-batch stock identical in both orders', fa == fb and stock(pA) == stock(pB) == 100 - sum(qtys), f'{fa} vs {fb}')

print('\n--- 3. A shortage becomes a recorded shortfall')
dev = new_device()
p, (b,) = mkprod('Short', 5.0, [(3, d(30))])
r = offline(cc, dev, uuid.uuid4(), [line(p, 5)])
sale3 = r[1]
check('sale of 5 with 3 in stock is ACCEPTED (COMPLETED)', r[0] == 'ok' and sale3['status'] == 'COMPLETED', str(r)[:90])
check('3 allocated, one OPEN shortfall of 2', sum(x['quantity'] for x in sale3['saleItems'][0]['batches']) == 3
      and [(s['quantity'], s['status']) for s in sf_of(sale3)] == [(2, 'OPEN')], str(sf_of(sale3)))
check('stock is 0 and never negative', stock(p) == 0 and bq(b) == 0)
check('the sale line still says 5 (what the customer bought)', qone('select quantity from sale_items where "saleId"=%s', (sale3['id'],)) == 5)
check('integrity clean (the line invariant holds)', integrity() == [], str(integrity()))
sf3 = sf_of(sale3)[0]['id']

print('\n--- 4. Only expired stock left: everything becomes a shortfall')
p4, (b4,) = mkprod('Expired', 5.0, [(5, d(-2))])
r = offline(cc, dev, uuid.uuid4(), [line(p4, 2)])
check('accepted; the expired batch is untouched; the whole line is a shortfall',
      r[0] == 'ok' and bq(b4) == 5 and [(s['quantity'], s['status']) for s in sf_of(r[1])] == [(2, 'OPEN')])
check('integrity clean', integrity() == [])

print('\n--- 5. Resolving a shortfall')
check('FOUND without a batch -> BATCH_REQUIRED', resolve(pc, sf3, 'FOUND')[1].startswith('BATCH_REQUIRED'))
check('unknown action -> INVALID_ACTION', resolve(pc, sf3, 'MAYBE')[1].startswith('INVALID_ACTION'))
check('cashier cannot resolve -> FORBIDDEN', resolve(cc, sf3, 'WRITE_OFF', None, 'x')[1].startswith('FORBIDDEN'))
check('unknown shortfall -> SHORTFALL_NOT_FOUND', resolve(pc, uuid.uuid4(), 'WRITE_OFF', None, 'x')[1].startswith('SHORTFALL_NOT_FOUND'))
check('batch of a different product -> BATCH_PRODUCT_MISMATCH', resolve(pc, sf3, 'FOUND', bA[0])[1].startswith('BATCH_PRODUCT_MISMATCH'))
be_exp = mkbatch(p, 0, d(-1))                      # an expired batch of the SAME product
check('expired batch -> EXPIRED_BATCH', resolve(pc, sf3, 'FOUND', be_exp)[1].startswith('EXPIRED_BATCH'))
check('WRITE_OFF needs a reason -> REASON_REQUIRED', resolve(pc, sf3, 'WRITE_OFF')[1].startswith('REASON_REQUIRED'))
mv_before = qone('select count(*) from stock_movements')
# two pharmacists resolve the SAME shortfall at the same time
res = run_parallel([lambda: resolve(pc, sf3, 'FOUND', b, 'found on the shelf'), lambda: resolve(pc2, sf3, 'FOUND', b, 'found on the shelf')])
check('simultaneous resolves: exactly one succeeds, the other SHORTFALL_NOT_OPEN',
      sorted(r[0] for r in res) == ['err', 'ok'] and any(r[0] == 'err' and r[1].startswith('SHORTFALL_NOT_OPEN') for r in res), str(res)[:100])
check('FOUND on an empty batch: CORRECTION +2 then SALE -2 (2 new ledger rows), stock still 0',
      qone('select count(*) from stock_movements') == mv_before + 2 and stock(p) == 0 and bq(b) == 0)
check('the sale line is now covered by allocations (3 + 2)', qone(
    'select coalesce(sum(sib.quantity),0) from sale_item_batches sib join sale_items si on si.id=sib."saleItemId" where si."saleId"=%s', (sale3['id'],)) == 5)
check('status RESOLVED_FOUND; resolving again -> SHORTFALL_NOT_OPEN',
      qone('select status::text from sale_shortfalls where id=%s', (sf3,)) == 'RESOLVED_FOUND' and resolve(pc, sf3, 'WRITE_OFF', None, 'x')[1].startswith('SHORTFALL_NOT_OPEN'))
check('integrity clean (RESOLVED_FOUND is not double counted)', integrity() == [], str(integrity()))

# FOUND from a batch that already has stock: only the SALE row, no correction
p5, (b5a,) = mkprod('Found2', 5.0, [(1, d(30))])
s5 = offline(cc, dev, uuid.uuid4(), [line(p5, 4)])[1]
b5b = mkbatch(p5, 10, d(90))                        # stock arrives later
mv = qone('select count(*) from stock_movements')
r = resolve(pc, sf_of(s5)[0]['id'], 'FOUND', b5b)
check('FOUND from a batch that holds enough: only a SALE row, batch 10 -> 7', r[0] == 'ok'
      and qone('select count(*) from stock_movements') == mv + 1 and bq(b5b) == 7, f'batch={bq(b5b)}')

# WRITE_OFF
p6, (b6,) = mkprod('WriteOff', 5.0, [(2, d(30))])
s6 = offline(cc, dev, uuid.uuid4(), [line(p6, 5)])[1]
mv = qone('select count(*) from stock_movements')
r = resolve(pc, sf_of(s6)[0]['id'], 'WRITE_OFF', None, 'stock record was wrong')
check('WRITE_OFF: no stock movement, shortfall WRITTEN_OFF, sale stands', r[0] == 'ok'
      and qone('select count(*) from stock_movements') == mv and qone('select status::text from sale_shortfalls where id=%s', (sf_of(s6)[0]['id'],)) == 'WRITTEN_OFF')
check('integrity clean after a write-off', integrity() == [])

print('\n--- 6. Voiding a sale that has shortfalls')
p7, (b7,) = mkprod('VoidOpen', 5.0, [(3, d(30))])
s7 = offline(cc, dev, uuid.uuid4(), [line(p7, 5)])[1]
check('void with an OPEN shortfall: allocated 3 return, shortfall VOIDED',
      void(pc, s7['id'])[0] == 'ok' and bq(b7) == 3 and qone('select status::text from sale_shortfalls where id=%s', (sf_of(s7)[0]['id'],)) == 'VOIDED')
check('voiding again is refused', void(pc, s7['id'])[1].startswith('SALE_NOT_VOIDABLE'))
p8, (b8,) = mkprod('VoidFound', 5.0, [(3, d(30))])
s8 = offline(cc, dev, uuid.uuid4(), [line(p8, 5)])[1]
resolve(pc, sf_of(s8)[0]['id'], 'FOUND', b8)
check('void after FOUND returns all 5 (the found stock stays in the system)', void(pc, s8['id'])[0] == 'ok' and bq(b8) == 5 and stock(p8) == 5, f'batch={bq(b8)}')
p9, (b9,) = mkprod('VoidWritten', 5.0, [(3, d(30))])
s9 = offline(cc, dev, uuid.uuid4(), [line(p9, 5)])[1]
resolve(pc, sf_of(s9)[0]['id'], 'WRITE_OFF', None, 'record wrong')
check('void after WRITE_OFF returns only the 3 that left the ledger', void(pc, s9['id'])[0] == 'ok' and bq(b9) == 3)
check('integrity clean after all voids', integrity() == [], str(integrity()))

print('\n--- 7. Payment, price, clock and device rules')
p, (b,) = mkprod('Rules', 5.0, [(100, d(60))])
r = offline(cc, dev, uuid.uuid4(), [line(p, 1)], pm='MOBILE_MONEY')
check('non-cash -> OFFLINE_CASH_ONLY, nothing recorded', r[1].startswith('OFFLINE_CASH_ONLY') and stock(p) == 100)
r = offline(cc, dev, uuid.uuid4(), [line(p, 2, 4.0)])
check('price paid kept (4.00 x 2 = 8.00); PRICE_MISMATCH flagged', r[0] == 'ok' and float(r[1]['total']) == 8.0 and flags_of(r[1]) == {'PRICE_MISMATCH'}, str(r[1]['flags'])[:80] if r[0] == 'ok' else str(r))
r = offline(cc, dev, uuid.uuid4(), [line(p, 2, 5.0)])
check('matching price: no flags', r[0] == 'ok' and flags_of(r[1]) == set())
r = offline(cc, dev, uuid.uuid4(), [line(p, 1)], off_s=7200)
check('device clock 2h ahead: accepted, CLOCK_SKEW flagged', r[0] == 'ok' and flags_of(r[1]) == {'CLOCK_SKEW'})
r = offline(cc, dev, uuid.uuid4(), [line(p, 1)], off_s=-100 * 3600)
check('offline 100h: accepted, LONG_OFFLINE flagged', r[0] == 'ok' and flags_of(r[1]) == {'LONG_OFFLINE'})
r = offline(cc, dev, uuid.uuid4(), [line(p, 1)], off_s=-3600)
check('1h offline: no flags', r[0] == 'ok' and flags_of(r[1]) == set())
check('unknown device -> DEVICE_UNKNOWN', offline(cc, uuid.uuid4(), uuid.uuid4(), [line(p, 1)])[1].startswith('DEVICE_UNKNOWN'))
check('cashier cannot register a device', call(cc, "select register_device('x')", ())[1].startswith('FORBIDDEN'))
reg = call(pc, "select register_device('Counter 2')", ())
check('pharmacist can register a device', reg[0] == 'ok' and reg[1]['name'] == 'Counter 2')
rdev = reg[1]['id']
accepted_cid = uuid.uuid4()
check('sale from the new device accepted', offline(cc, rdev, accepted_cid, [line(p, 1)], off_s=-60)[0] == 'ok')
check('cashier cannot revoke a device', call(cc, "select revoke_device(%s)", (str(rdev),))[1].startswith('FORBIDDEN'))
check('pharmacist revokes the device', call(pc, "select revoke_device(%s)", (str(rdev),))[0] == 'ok')
check('a sale that happened AFTER the revocation -> DEVICE_REVOKED', offline(cc, rdev, uuid.uuid4(), [line(p, 1)], off_s=0)[1].startswith('DEVICE_REVOKED'))
check('a sale from BEFORE the revocation is still accepted', offline(cc, rdev, uuid.uuid4(), [line(p, 1)], off_s=-600)[0] == 'ok')
check('a replay of an earlier accepted sale still returns it', (lambda r: r[0] == 'ok' and r[1]['replayed'])(offline(cc, rdev, accepted_cid, [line(p, 1)], off_s=-60)))

print('\n--- 8. Validation and atomicity')
p, (b,) = mkprod('Valid', 5.0, [(20, d(60))]); px, _ = mkprod('Valid2', 5.0, [(20, d(60))])
sales_before = qone('select count(*) from sales')
r = offline(cc, dev, uuid.uuid4(), [line(p, 2), line(px, 0)])
check('one bad line rejects the whole submission, no trace', r[1].startswith('INVALID_QUANTITY') and qone('select count(*) from sales') == sales_before and stock(p) == 20)
for name, items, exp in [('empty cart', [], 'INVALID_ITEMS'), ('garbage product id', [{'productId': 'nope', 'quantity': 1, 'unitPrice': 1}], 'INVALID_ITEMS'),
                         ('missing price', [{'productId': str(p), 'quantity': 1}], 'INVALID_ITEMS'),
                         ('negative price', [line(p, 1, -1)], 'INVALID_ITEMS'),
                         ('unknown product', [line(uuid.uuid4(), 1)], 'PRODUCT_NOT_FOUND'),
                         ('same product at two prices', [line(p, 1, 5.0), line(p, 1, 4.0)], 'INVALID_ITEMS'),
                         ('line discount above line total', [line(p, 1, 5.0, discount=50)], 'INVALID_DISCOUNT')]:
    r = offline(cc, dev, uuid.uuid4(), items); check(f'reject: {name}', r[0] == 'err' and r[1].startswith(exp), r[1] if r[0] == 'err' else 'accepted!')
r = offline(cc, dev, uuid.uuid4(), [line(p, 1, 5.0), line(p, 2, 5.0)])
check('same product, same price: lines merge (1+2=3)', r[0] == 'ok' and len(r[1]['saleItems']) == 1 and r[1]['saleItems'][0]['quantity'] == 3 and stock(p) == 17)
r = offline(cc, dev, uuid.uuid4(), [line(p, 1)], discount=999)
check('cart discount above subtotal -> INVALID_DISCOUNT', r[1].startswith('INVALID_DISCOUNT'))
anon = psycopg2.connect(DSN); anon.autocommit = True; ca = anon.cursor(); ca.execute("set role anon")
for fn in ["select submit_offline_sale(null,null,now(),'[]'::jsonb)", "select resolve_shortfall(null,'FOUND')", "select register_device('x')", "select revoke_device(null)"]:
    try: ca.execute(fn); got = 'allowed'
    except psycopg2.Error: got = 'blocked'
    check(f'anon cannot run {fn.split("(")[0][7:]}', got == 'blocked')
nouser = conn_as(None)
check('no signed-in user -> UNAUTHORIZED', call(nouser, "select submit_offline_sale(%s,%s,now(),'[]'::jsonb)", (str(dev), str(uuid.uuid4())))[1].startswith('UNAUTHORIZED'))
cur = cc.cursor()
try: cur.execute("select count(*) from sale_shortfalls"); n = cur.fetchone()[0]
except psycopg2.Error: n = -1
check('cashier cannot read the shortfall queue (RLS)', n == 0)
cur = pc.cursor(); cur.execute("select count(*) from sale_shortfalls"); check('pharmacist can read it', cur.fetchone()[0] > 0)

print('\n--- 9. The new integrity rule catches a broken sale line')
ps, _ = mkprod('Tamper', 5.0, [(10, d(60))])
st = offline(cc, dev, uuid.uuid4(), [line(ps, 4)])[1]
check('clean before tampering', integrity() == [])
ac.execute('delete from sale_item_batches where "saleItemId" in (select id from sale_items where "saleId"=%s)', (st['id'],))
bad = integrity()
check('deleting an allocation is reported as a sale_item mismatch', any(k == 'sale_item' for k, _, _, _ in bad), str(bad[:2]))
ac.execute('insert into sale_item_batches("saleItemId","batchId",quantity) select si.id, (select id from product_batches where "productId"=%s), 4 from sale_items si where si."saleId"=%s', (ps, st['id']))
check('clean again after repair', integrity() == [])

print('\n--- 10. Online and offline together: no deadlock, no oversell')
dev = new_device('mixed')
pa, ba = mkprod('MixA', 5.0, [(60, d(15)), (60, d(45)), (60, None)]); pb, bb = mkprod('MixB', 5.0, [(60, d(20)), (60, d(50)), (60, None)])
def mixed(i):
    its = [(pa, 2), (pb, 3)];  its = its[::-1] if i % 2 else its
    if i % 3 == 0: return online(cash[i % 30], [{'productId': str(p_), 'quantity': q} for p_, q in its])
    return offline(cash[i % 30], dev, uuid.uuid4(), [line(p_, q) for p_, q in its])
res = run_parallel([(lambda i=i: mixed(i)) for i in range(120)])
unexpected = {r[1] for r in res if r[0] == 'err' and not r[1].startswith('INSUFFICIENT_STOCK')}
check('no deadlocks or unexpected errors', not unexpected, str(unexpected))
check('stock never negative; integrity clean', qone('select count(*) from product_batches where "quantityOnHand" < 0') == 0 and integrity() == [], str(integrity()[:2]))
ac.execute("select count(*), count(distinct \"saleNumber\") from sales where \"saleNumber\" like %s", (f"POS-{TODAY:%Y%m%d}-%",))
n1, n2 = ac.fetchone(); mx = qone("select last_number from sale_counters where day=(now() at time zone 'Africa/Accra')::date")
check('sale numbers unique and gapless across online and offline', n1 == n2 == mx, f'{n1}/{n2}/{mx}')

print('\n--- 11. Randomised stress: devices, duplicates, replays, resolutions and voids, all concurrent')
random.seed(5)
sp = [mkprod(f'S{i}', 5.0, [(random.randint(3, 8), d(random.choice([10, 40, 200]))) for _ in range(random.randint(1, 2))]) for i in range(6)]
initial = {p_: stock(p_) for p_, _ in sp}
devs = [new_device(f'dev{i}') for i in range(4)]
submitted_ok = set(); lock = threading.Lock(); sale_ids = []; shortfall_ids = []
def rnd_submit(i):
    dv = random.choice(devs); cid = uuid.uuid4()
    its = [line(p_, random.randint(1, 5)) for p_, _ in random.sample(sp, random.randint(1, 3))]
    r = offline(cash[i % 30], dv, cid, its)
    if r[0] == 'ok':
        with lock:
            submitted_ok.add((str(dv), str(cid))); sale_ids.append(r[1]['id']); shortfall_ids.extend(s['id'] for s in r[1]['shortfalls'])
    return (dv, cid, its, r)
subs = [rnd_submit(i) for i in range(10)]                 # seed some sales first
def resubmit(i):                                           # a duplicate of an earlier sale
    dv, cid, its, _ = random.choice(subs); return offline(cash[i % 30], dv, cid, its)
def rnd_resolve(i):
    with lock: sf = random.choice(shortfall_ids) if shortfall_ids else None
    if not sf: return ('ok', None)
    if random.random() < .5: return resolve(pharm[i % 10], sf, 'WRITE_OFF', None, 'wrong record')
    pid = qone('select "productId" from sale_shortfalls where id=%s', (sf,))
    bid = qone('select id from product_batches where "productId"=%s and ("expiryDate" is null or "expiryDate" >= current_date) order by id limit 1', (pid,))
    return resolve(pharm[i % 10], sf, 'FOUND', bid, 'found') if bid else ('ok', None)
def rnd_void(i):
    with lock: sid = random.choice(sale_ids) if sale_ids else None
    return void(pharm[i % 10], sid) if sid else ('ok', None)
tasks = [(lambda i=i: rnd_submit(i)) for i in range(120)] + [(lambda i=i: resubmit(i)) for i in range(60)] \
      + [(lambda i=i: rnd_resolve(i)) for i in range(40)] + [(lambda i=i: rnd_void(i)) for i in range(25)]
random.shuffle(tasks)
res = run_parallel(tasks)
errs = {r[1] if isinstance(r, tuple) and r[0] == 'err' else None for r in res if isinstance(r, tuple) and r[0] == 'err'}
unexpected = {e for e in errs if not e.startswith(('SHORTFALL_NOT_OPEN', 'SALE_NOT_VOIDABLE', 'EXPIRED_BATCH'))}
check('no unexpected errors (deadlocks, constraint violations...)', not unexpected, str(unexpected))
check('integrity clean: ledger == batches == products, and every sale line is fully explained', integrity() == [], str(integrity()[:3]))
check('no negative batch', qone('select count(*) from product_batches where "quantityOnHand" < 0') == 0)
check('one sale per distinct (device, client sale id) that was accepted',
      qone("select count(*) from sales where source='OFFLINE' and \"deviceId\" = any(%s::uuid[])", ([str(x) for x in devs],)) == len(submitted_ok),
      f'{qone("select count(*) from sales where source=%s and \"deviceId\" = any(%s::uuid[])", ("OFFLINE", [str(x) for x in devs]))} vs {len(submitted_ok)}')
ok_cons = True
for p_, _ in sp:
    on_hand = stock(p_)
    corr = qone("select coalesce(sum(quantity),0) from stock_movements where \"productId\"=%s and type='CORRECTION'", (p_,))
    alloc = qone("select coalesce(sum(sib.quantity),0) from sale_item_batches sib join sale_items si on si.id=sib.\"saleItemId\" join sales s on s.id=si.\"saleId\" where si.\"productId\"=%s and s.status='COMPLETED'", (p_,))
    if on_hand != initial[p_] + corr - alloc: ok_cons = False; print('   mismatch', p_, initial[p_], corr, alloc, on_hand)
check('conservation per product: on hand = initial + found stock - units allocated to completed sales', ok_cons)
n_open = qone("select count(*) from sale_shortfalls where status='OPEN'")
print(f'   (stress produced {qone("select count(*) from sale_shortfalls")} shortfalls, {n_open} still open)')

print(f'\n{"FAILED" if fails else "ALL PASSED"}  ({passes} passed, {fails} failed)')
sys.exit(1 if fails else 0)
