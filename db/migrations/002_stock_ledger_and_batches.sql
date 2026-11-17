-- 002_stock_ledger_and_batches.sql
-- Stock is an append-only LEDGER over BATCHES.
--
--   stock_movements   one signed row per change to stock. Immutable.
--   product_batches   one row per received batch (batch number + expiry).
--                     "quantityOnHand" is a cache maintained by a trigger.
--   sale_item_batches which batches each sale line was taken from.
--   products."stockQuantity" is a cache of SUM(batch quantities).
--
-- Neither cache can be written by API users: only a ledger insert changes them.
--
-- Lock order used by every function (prevents deadlocks):
--   product rows (by id) -> batch rows (by product, expiry, id) -> sale counter.

-- ─────────────────────────────────────────
-- Types and tables
-- ─────────────────────────────────────────

create type movement_type as enum (
  'OPENING',            -- balance carried over when the ledger was introduced
  'RECEIPT',            -- goods received (+)
  'SALE',               -- sold at the till (-)
  'SALE_VOID',          -- sale voided, stock returned (+)
  'DAMAGE',             -- damaged (-)
  'EXPIRY_WRITEOFF',    -- expired stock removed (-)
  'RETURN_TO_SUPPLIER', -- returned to supplier (-)
  'CORRECTION'          -- stock-count correction (+ or -, reason required)
);

create table product_batches (
  id               uuid primary key default gen_random_uuid(),
  "productId"      uuid not null references products(id) on delete restrict,
  "batchNumber"    text not null check (length(btrim("batchNumber")) > 0),
  "expiryDate"     date,
  "costPrice"      numeric(10,2),
  "supplierId"     uuid references suppliers(id) on delete set null,
  "quantityOnHand" integer not null default 0 check ("quantityOnHand" >= 0),
  "createdAt"      timestamptz not null default now(),
  unique ("productId", "batchNumber"),
  unique (id, "productId")
);
-- FEFO scan: sellable batches of a product, soonest expiry first.
create index idx_batches_fefo on product_batches ("productId", "expiryDate" nulls last, id)
  where "quantityOnHand" > 0;

create table stock_movements (
  id               uuid primary key default gen_random_uuid(),
  "productId"      uuid not null references products(id) on delete restrict,
  "batchId"        uuid not null,
  type             movement_type not null,
  quantity         integer not null check (quantity <> 0),   -- signed
  "saleId"         uuid references sales(id) on delete restrict,
  "userId"         uuid references users(id) on delete set null,
  reason           text,
  "idempotencyKey" text,
  "createdAt"      timestamptz not null default now(),
  -- the batch must belong to the product
  foreign key ("batchId", "productId")
    references product_batches (id, "productId") on delete restrict,
  -- the sign must match the movement type
  constraint chk_movement_sign check (
       (type in ('OPENING', 'RECEIPT', 'SALE_VOID') and quantity > 0)
    or (type in ('SALE', 'DAMAGE', 'EXPIRY_WRITEOFF', 'RETURN_TO_SUPPLIER') and quantity < 0)
    or  type = 'CORRECTION'
  )
);
create index idx_movements_batch   on stock_movements ("batchId", "createdAt");
create index idx_movements_product on stock_movements ("productId", "createdAt" desc);
create index idx_movements_sale    on stock_movements ("saleId") where "saleId" is not null;
create unique index uq_movements_idempotency on stock_movements ("idempotencyKey")
  where "idempotencyKey" is not null;

create table sale_item_batches (
  "saleItemId" uuid not null references sale_items(id) on delete cascade,
  "batchId"    uuid not null references product_batches(id) on delete restrict,
  quantity     integer not null check (quantity > 0),
  primary key ("saleItemId", "batchId")
);
create index idx_sib_batch on sale_item_batches ("batchId");

-- ─────────────────────────────────────────
-- Access: read-only for API users; all writes go through the functions
-- ─────────────────────────────────────────

alter table product_batches   enable row level security;
alter table stock_movements   enable row level security;
alter table sale_item_batches enable row level security;

create policy "auth_read_batches" on product_batches
  for select to authenticated using (true);
create policy "staff_read_movements" on stock_movements
  for select to authenticated using (get_user_role() in ('ADMIN', 'PHARMACIST'));
create policy "auth_read_sale_item_batches" on sale_item_batches
  for select to authenticated using (true);

revoke all on product_batches, stock_movements, sale_item_batches from anon;
revoke insert, update, delete, truncate
  on product_batches, stock_movements, sale_item_batches from authenticated;


-- ─────────────────────────────────────────
-- Invariants enforced by triggers
-- ─────────────────────────────────────────

-- 1. The ledger is immutable.
create or replace function forbid_ledger_change() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  raise exception 'LEDGER_IMMUTABLE' using errcode = 'P0001';
end $$;

create trigger trg_ledger_immutable
  before update or delete on stock_movements
  for each row execute function forbid_ledger_change();

-- 2. A ledger row is the ONLY way stock changes: it updates the batch and the
--    product cache in the same transaction.
create or replace function apply_stock_movement() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  update product_batches
     set "quantityOnHand" = "quantityOnHand" + new.quantity
   where id = new."batchId";
  update products
     set "stockQuantity" = "stockQuantity" + new.quantity,
         "updatedAt"     = now()
   where id = new."productId";
  return new;
end $$;

create trigger trg_apply_stock_movement
  after insert on stock_movements
  for each row execute function apply_stock_movement();

-- 3. API users cannot write the cached quantities directly (e.g. an old
--    client PUTting a stale stockQuantity). Functions run as the owner and
--    migrations/seeds as postgres, so those are unaffected.
create or replace function guard_stock_cache() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_table_name = 'products' then
      if (tg_op = 'INSERT' and new."stockQuantity" <> 0)
         or (tg_op = 'UPDATE' and new."stockQuantity" is distinct from old."stockQuantity") then
        raise exception 'STOCK_LEDGER_ONLY' using errcode = 'P0001';
      end if;
    elsif tg_table_name = 'product_batches' then
      if (tg_op = 'INSERT' and new."quantityOnHand" <> 0)
         or (tg_op = 'UPDATE' and new."quantityOnHand" is distinct from old."quantityOnHand") then
        raise exception 'STOCK_LEDGER_ONLY' using errcode = 'P0001';
      end if;
    end if;
  end if;
  return new;
end $$;

create trigger trg_guard_products_stock
  before insert or update on products
  for each row execute function guard_stock_cache();
create trigger trg_guard_batches_stock
  before insert or update on product_batches
  for each row execute function guard_stock_cache();

-- ─────────────────────────────────────────
-- Integrity check: does the cache equal the ledger?
-- ─────────────────────────────────────────

create or replace function verify_stock_integrity()
returns table (kind text, id uuid, expected bigint, actual bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is not null
     and coalesce((select u.role::text from users u where u.id = auth.uid()), '')
         not in ('ADMIN', 'PHARMACIST') then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  return query
    select 'batch'::text, b.id, coalesce(sum(m.quantity), 0)::bigint, b."quantityOnHand"::bigint
      from product_batches b
      left join stock_movements m on m."batchId" = b.id
     group by b.id
    having coalesce(sum(m.quantity), 0) <> b."quantityOnHand"
    union all
    select 'product'::text, p.id, coalesce(sum(b."quantityOnHand"), 0)::bigint, p."stockQuantity"::bigint
      from products p
      left join product_batches b on b."productId" = p.id
     group by p.id
    having coalesce(sum(b."quantityOnHand"), 0) <> p."stockQuantity";
end $$;

-- ─────────────────────────────────────────
-- Expiry watch
-- ─────────────────────────────────────────

create or replace view expiring_batches with (security_invoker = true) as
select b.id                    as "batchId",
       b."productId",
       p.name                  as "productName",
       b."batchNumber",
       b."expiryDate",
       b."quantityOnHand",
       b."expiryDate" - (now() at time zone 'Africa/Accra')::date as "daysToExpiry"
  from product_batches b
  join products p on p.id = b."productId"
 where b."quantityOnHand" > 0
   and b."expiryDate" is not null
   and b."expiryDate" <= (now() at time zone 'Africa/Accra')::date + 90
   and p."isActive";
revoke all on expiring_batches from anon;
grant select on expiring_batches to authenticated;

-- ─────────────────────────────────────────
-- receive_stock: goods in, creates (or tops up) a batch
-- ─────────────────────────────────────────

create or replace function receive_stock(
  p_product_id      uuid,
  p_quantity        integer,
  p_batch_number    text,
  p_expiry_date     date    default null,
  p_cost_price      numeric default null,
  p_supplier_id     uuid    default null,
  p_reason          text    default null,
  p_idempotency_key text    default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := auth.uid();
  v_role  user_role;
  v_key   text;
  v_today date := (now() at time zone 'Africa/Accra')::date;
  v_prod  products%rowtype;
  v_batch product_batches%rowtype;
  v_batch_no text := btrim(coalesce(p_batch_number, ''));
  v_existing uuid;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null or v_role not in ('ADMIN', 'PHARMACIST') then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'INVALID_QUANTITY' using errcode = 'P0001';
  end if;
  if v_batch_no = '' then raise exception 'INVALID_BATCH' using errcode = 'P0001'; end if;
  if p_expiry_date is not null and p_expiry_date < v_today then
    raise exception 'EXPIRED_BATCH' using errcode = 'P0001';
  end if;
  if p_cost_price is not null and p_cost_price < 0 then
    raise exception 'INVALID_COST' using errcode = 'P0001';
  end if;

  if p_idempotency_key is not null then
    v_key := v_uid::text || ':' || p_idempotency_key;
    perform pg_advisory_xact_lock(hashtextextended('stock:' || v_key, 0));
    select "batchId" into v_existing from stock_movements where "idempotencyKey" = v_key;
    if v_existing is not null then
      select * into v_batch from product_batches where id = v_existing;
      return jsonb_build_object('batchId', v_batch.id, 'productId', v_batch."productId",
        'batchNumber', v_batch."batchNumber", 'expiryDate', v_batch."expiryDate",
        'quantityOnHand', v_batch."quantityOnHand", 'replayed', true);
    end if;
  end if;

  select * into v_prod from products where id = p_product_id for update;
  if not found then raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0001'; end if;
  if not v_prod."isActive" then
    raise exception 'PRODUCT_INACTIVE|%', v_prod.name using errcode = 'P0001';
  end if;

  select * into v_batch from product_batches
   where "productId" = p_product_id and "batchNumber" = v_batch_no for update;
  if found then
    if v_batch."expiryDate" is distinct from p_expiry_date then
      raise exception 'BATCH_EXPIRY_MISMATCH|%', v_batch_no using errcode = 'P0001';
    end if;
  else
    insert into product_batches ("productId", "batchNumber", "expiryDate", "costPrice", "supplierId")
    values (p_product_id, v_batch_no, p_expiry_date, p_cost_price, p_supplier_id)
    returning * into v_batch;
  end if;

  insert into stock_movements ("productId", "batchId", type, quantity, "userId", reason, "idempotencyKey")
  values (p_product_id, v_batch.id, 'RECEIPT', p_quantity, v_uid, p_reason, v_key);

  select * into v_batch from product_batches where id = v_batch.id;
  return jsonb_build_object('batchId', v_batch.id, 'productId', v_batch."productId",
    'batchNumber', v_batch."batchNumber", 'expiryDate', v_batch."expiryDate",
    'quantityOnHand', v_batch."quantityOnHand", 'replayed', false);
end $$;

-- ─────────────────────────────────────────
-- adjust_stock: damage / expiry write-off / supplier return / count correction
-- ─────────────────────────────────────────
-- p_delta is signed. DAMAGE, EXPIRY_WRITEOFF and RETURN_TO_SUPPLIER must be
-- negative; CORRECTION may be either way and needs a reason.

create or replace function adjust_stock(
  p_batch_id        uuid,
  p_delta           integer,
  p_type            movement_type,
  p_reason          text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := auth.uid();
  v_role  user_role;
  v_key   text;
  v_prod_id uuid;
  v_batch product_batches%rowtype;
  v_existing uuid;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null or v_role not in ('ADMIN', 'PHARMACIST') then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  if p_type not in ('DAMAGE', 'EXPIRY_WRITEOFF', 'RETURN_TO_SUPPLIER', 'CORRECTION') then
    raise exception 'INVALID_TYPE' using errcode = 'P0001';
  end if;
  if p_delta is null or p_delta = 0
     or (p_type <> 'CORRECTION' and p_delta > 0) then
    raise exception 'INVALID_QUANTITY' using errcode = 'P0001';
  end if;
  if p_type = 'CORRECTION' and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'REASON_REQUIRED' using errcode = 'P0001';
  end if;

  if p_idempotency_key is not null then
    v_key := v_uid::text || ':' || p_idempotency_key;
    perform pg_advisory_xact_lock(hashtextextended('stock:' || v_key, 0));
    select "batchId" into v_existing from stock_movements where "idempotencyKey" = v_key;
    if v_existing is not null then
      select * into v_batch from product_batches where id = v_existing;
      return jsonb_build_object('batchId', v_batch.id, 'productId', v_batch."productId",
        'batchNumber', v_batch."batchNumber", 'quantityOnHand', v_batch."quantityOnHand",
        'replayed', true);
    end if;
  end if;

  select "productId" into v_prod_id from product_batches where id = p_batch_id;
  if v_prod_id is null then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001'; end if;

  perform 1 from products where id = v_prod_id for update;           -- product first
  select * into v_batch from product_batches where id = p_batch_id for update;  -- then batch

  if v_batch."quantityOnHand" + p_delta < 0 then
    raise exception 'INSUFFICIENT_STOCK|%|%', v_batch."batchNumber", v_batch."quantityOnHand"
      using errcode = 'P0001';
  end if;

  insert into stock_movements ("productId", "batchId", type, quantity, "userId", reason, "idempotencyKey")
  values (v_prod_id, p_batch_id, p_type, p_delta, v_uid, nullif(btrim(p_reason), ''), v_key);

  select * into v_batch from product_batches where id = p_batch_id;
  return jsonb_build_object('batchId', v_batch.id, 'productId', v_batch."productId",
    'batchNumber', v_batch."batchNumber", 'quantityOnHand', v_batch."quantityOnHand",
    'replayed', false);
end $$;

-- ─────────────────────────────────────────
-- Permissions: signed-in users only (Supabase grants new functions to anon by default)
-- ─────────────────────────────────────────

revoke all on function
  receive_stock(uuid, integer, text, date, numeric, uuid, text, text),
  adjust_stock(uuid, integer, movement_type, text, text),
  verify_stock_integrity()
from public, anon;
grant execute on function
  receive_stock(uuid, integer, text, date, numeric, uuid, text, text),
  adjust_stock(uuid, integer, movement_type, text, text),
  verify_stock_integrity()
to authenticated;
