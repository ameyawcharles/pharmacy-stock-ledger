-- A guided tour of the ledger. Run with: bash scripts/demo.sh
-- Each step runs as a real signed-in user (the `authenticated` role plus a user id), so
-- row-level security and permissions apply exactly as they would through an API.
\set QUIET on
\pset border 2
\pset footer off
\set pharmacist '''a0000000-0000-0000-0000-000000000001'''
\set cashier    '''a0000000-0000-0000-0000-000000000002'''

select id as para from products where name = 'Paracetamol 500mg' \gset

\echo
\echo '== 1. The pharmacist receives two batches of Paracetamol (the later-expiring one first)'
set role authenticated;
select set_config('request.jwt.claim.sub', :pharmacist, false) \gset
select r->>'batchNumber' as batch, r->>'expiryDate' as expires, r->>'quantityOnHand' as on_hand
from (select receive_stock(:'para', 100, 'PCM-LATE', current_date + 120) as r) s;
select r->>'batchNumber' as batch, r->>'expiryDate' as expires, r->>'quantityOnHand' as on_hand
from (select receive_stock(:'para',  50, 'PCM-SOON', current_date + 20) as r) s;

\echo
\echo '== 2. The cashier sells 120 units. Stock is taken from the batch expiring soonest'
select set_config('request.jwt.claim.sub', :cashier, false) \gset
select s->>'saleNumber' as sale, s->>'total' as total, b->>'batchNumber' as batch, b->>'quantity' as taken
from (select create_sale(jsonb_build_array(jsonb_build_object('productId', :'para', 'quantity', 120)),
                         'CASH', 0, null, 'demo-key-1') as s) x,
     jsonb_array_elements(s->'saleItems'->0->'batches') b;

\echo
\echo '== 3. The same request is retried (a network timeout, say). Same sale, no second charge'
select s->>'saleNumber' as sale, s->>'replayed' as replayed
from (select create_sale(jsonb_build_array(jsonb_build_object('productId', :'para', 'quantity', 120)),
                         'CASH', 0, null, 'demo-key-1') as s) x;
select b."batchNumber" as batch, b."quantityOnHand" as on_hand from product_batches b order by b."expiryDate";

\set QUIET off
\set ON_ERROR_STOP off
\echo
\echo '== 4. Things that must fail'
\echo '-- selling more than exists:'
select create_sale(jsonb_build_array(jsonb_build_object('productId', :'para', 'quantity', 999)));
\echo '-- the cashier trying to void a sale:'
select void_sale((select id from sales limit 1));
\echo '-- the pharmacist hand-editing stock (editing a price is fine, stock is not):'
select set_config('request.jwt.claim.sub', :pharmacist, false) \gset
update products set "stockQuantity" = 9999;
\echo '-- rewriting the ledger:'
update stock_movements set quantity = 1;
\set ON_ERROR_STOP on
\set QUIET on

\echo
\echo '== 5. The pharmacist voids the sale. Stock returns to the SAME batches, exactly once'
select s->>'status' as status from (select void_sale((select id from sales limit 1), 'customer returned') as s) x;
select b."batchNumber" as batch, b."quantityOnHand" as on_hand from product_batches b order by b."expiryDate";

\echo
\echo '== 6. The ledger: every change to stock, in order'
select m.type, m.quantity, b."batchNumber" as batch
from stock_movements m join product_batches b on b.id = m."batchId"
order by m."createdAt", b."expiryDate", m.type;

\echo
\echo '== 7. Integrity check: recompute everything from the ledger (0 = consistent)'
select count(*) as mismatches from verify_stock_integrity();
