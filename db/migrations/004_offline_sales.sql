-- 004_offline_sales.sql
-- Offline selling (see docs/adr/0003-offline-selling.md).
--
--   STEP 1  tables and columns             devices, sale_shortfalls, sale_flags, sales columns
--   (shared) allocate_stock + create_sale  one allocator, two policies
--   STEP 2  submit_offline_sale            idempotent submission of a sale made offline
--   STEP 3  shortfalls                     a shortage becomes a recorded, resolvable shortfall
--   STEP 4  resolve_shortfall, void_sale   a pharmacist closes the shortfall; voids close it too
--   STEP 5  verify_stock_integrity         extended with the sale-line invariant
--
-- Principles: the physical event wins; the ledger never goes negative or is rewritten;
-- every divergence becomes a visible, resolvable record.

-- ═════════════════════════════════════════
-- STEP 1: tables and columns
-- ═════════════════════════════════════════

create type sale_source as enum ('ONLINE', 'OFFLINE');
create type shortfall_status as enum ('OPEN', 'RESOLVED_FOUND', 'WRITTEN_OFF', 'VOIDED');

-- A till. Registered by staff; revoking it rejects offline sales made after the revocation.
create table devices (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  "registeredBy" uuid references users(id) on delete set null,
  "registeredAt" timestamptz not null default now(),
  "revokedAt"    timestamptz
);

alter table sales
  add column source                sale_source not null default 'ONLINE',
  add column "deviceId"            uuid references devices(id),
  add column "clientSaleId"        uuid,
  add column "clientReceiptNumber" text,
  add column "occurredAt"          timestamptz,   -- device clock: for display only
  add column "receivedAt"          timestamptz;   -- server clock: used for accounting

-- One sale per (device, client sale id). Online sales have neither, so they are unaffected.
create unique index uq_sales_device_client on sales ("deviceId", "clientSaleId");

-- Units that were sold but could not be taken from stock the ledger knew about.
create table sale_shortfalls (
  id           uuid primary key default gen_random_uuid(),
  "saleItemId" uuid not null references sale_items(id) on delete cascade,
  "productId"  uuid not null references products(id) on delete restrict,
  quantity     integer not null check (quantity > 0),
  status       shortfall_status not null default 'OPEN',
  resolution   text,
  "resolvedBy" uuid references users(id) on delete set null,
  "openedAt"   timestamptz not null default now(),
  "resolvedAt" timestamptz,
  constraint chk_shortfall_closed check ((status = 'OPEN') = ("resolvedAt" is null))
);
create index idx_shortfalls_open on sale_shortfalls (status) where status = 'OPEN';
create index idx_shortfalls_item on sale_shortfalls ("saleItemId");

create table sale_flags (
  id          uuid primary key default gen_random_uuid(),
  "saleId"    uuid not null references sales(id) on delete cascade,
  code        text not null check (code in ('PRICE_MISMATCH', 'CLOCK_SKEW', 'LONG_OFFLINE')),
  detail      jsonb,
  "createdAt" timestamptz not null default now()
);
create index idx_sale_flags_sale on sale_flags ("saleId");

alter table devices         enable row level security;
alter table sale_shortfalls enable row level security;
alter table sale_flags      enable row level security;
create policy "staff_read_devices"    on devices         for select to authenticated
  using (get_user_role() in ('ADMIN', 'PHARMACIST'));
create policy "staff_read_shortfalls" on sale_shortfalls for select to authenticated
  using (get_user_role() in ('ADMIN', 'PHARMACIST'));
create policy "staff_read_flags"      on sale_flags      for select to authenticated
  using (get_user_role() in ('ADMIN', 'PHARMACIST'));
revoke all on devices, sale_shortfalls, sale_flags from anon;
revoke insert, update, delete, truncate on devices, sale_shortfalls, sale_flags from authenticated;

-- ═════════════════════════════════════════
-- Shared allocator
-- ═════════════════════════════════════════
-- Locks a product's sellable batches soonest-expiry-first and takes `p_qty` from them.
-- It never raises on a shortage: it reports it, and the caller applies its own policy
-- (online checkout refuses; the offline path records a shortfall).
-- Caller must already hold the product row lock (lock order: product, then batches).

create or replace function allocate_stock(p_product_id uuid, p_qty integer, p_today date)
returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_need     integer := p_qty;
  v_sellable integer := 0;
  v_expired  integer := 0;
  v_take     integer;
  v_alloc    jsonb := '[]'::jsonb;
  b          record;
begin
  for b in
    select id, "quantityOnHand" as qty, "expiryDate" as expiry
      from product_batches
     where "productId" = p_product_id and "quantityOnHand" > 0
     order by "expiryDate" nulls last, id
       for update
  loop
    if b.expiry is not null and b.expiry < p_today then
      v_expired := v_expired + b.qty;            -- expired stock is never sold
      continue;
    end if;
    v_sellable := v_sellable + b.qty;
    v_take := least(v_need, b.qty);
    v_alloc := v_alloc || jsonb_build_object(
      'productId', p_product_id, 'batchId', b.id, 'quantity', v_take);
    v_need := v_need - v_take;
    exit when v_need = 0;
  end loop;

  return jsonb_build_object('allocations', v_alloc, 'shortfall', v_need,
                            'sellable', v_sellable, 'expired', v_expired);
end $$;
revoke all on function allocate_stock(uuid, integer, date) from public, anon, authenticated;

-- create_sale now uses the shared allocator. Its behaviour is unchanged.
create or replace function create_sale(
  p_items           jsonb,
  p_payment_method  payment_method default 'CASH',
  p_discount        numeric        default 0,
  p_notes           text           default null,
  p_idempotency_key text           default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid          uuid := auth.uid();
  v_role         user_role;
  v_key          text;
  v_existing     uuid;
  v_lines        jsonb;
  v_priced       jsonb := '[]'::jsonb;
  v_alloc        jsonb := '[]'::jsonb;
  v_expected     integer;
  v_found        integer := 0;
  v_today        date := (now() at time zone 'Africa/Accra')::date;
  v_counter      integer;
  v_sale_number  text;
  v_sale_id      uuid;
  v_item_id      uuid;
  v_subtotal     numeric(10,2) := 0;
  v_total        numeric(10,2);
  v_line_total   numeric(10,2);
  v_res          jsonb;
  r              record;
  x              jsonb;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null then raise exception 'FORBIDDEN' using errcode = 'P0001'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_CART' using errcode = 'P0001';
  end if;
  if p_discount is null or p_discount < 0 then
    raise exception 'INVALID_DISCOUNT' using errcode = 'P0001';
  end if;

  if p_idempotency_key is not null then
    v_key := v_uid::text || ':' || p_idempotency_key;
    perform pg_advisory_xact_lock(hashtextextended('create_sale:' || v_key, 0));
    select id into v_existing from sales where "idempotencyKey" = v_key;
    if v_existing is not null then
      return sale_to_json(v_existing) || jsonb_build_object('replayed', true);
    end if;
  end if;

  begin
    select jsonb_agg(jsonb_build_object('product_id', product_id, 'qty', qty, 'disc', disc))
      into v_lines
      from (
        select (e->>'productId')::uuid                      as product_id,
               sum((e->>'quantity')::integer)               as qty,
               sum(coalesce((e->>'discount')::numeric, 0))  as disc
        from jsonb_array_elements(p_items) e
        group by 1
      ) agg;
  exception when invalid_text_representation or numeric_value_out_of_range
            or null_value_not_allowed then
    raise exception 'INVALID_ITEMS' using errcode = 'P0001';
  end;

  v_expected := jsonb_array_length(v_lines);

  -- 1) Lock products in id order and validate price / activity / discount.
  -- 2) Per product, lock its sellable batches soonest-expiry-first and take
  --    stock from them until the line is covered (FEFO).
  for r in
    select p.id, p.name, p."sellingPrice" as price, p."isActive" as active, l.qty, l.disc
    from jsonb_to_recordset(v_lines) as l(product_id uuid, qty integer, disc numeric)
    join products p on p.id = l.product_id
    order by p.id
    for update of p
  loop
    v_found := v_found + 1;

    if r.qty is null or r.qty <= 0 then
      raise exception 'INVALID_QUANTITY|%', r.name using errcode = 'P0001';
    end if;
    if not r.active then
      raise exception 'PRODUCT_INACTIVE|%', r.name using errcode = 'P0001';
    end if;
    if r.disc < 0 or r.disc > r.price * r.qty then
      raise exception 'INVALID_DISCOUNT' using errcode = 'P0001';
    end if;

    -- Shared with the offline path (allocate_stock): first-expiry-first-out over the
    -- product's sellable batches. Online checkout refuses a shortage.
    v_res := allocate_stock(r.id, r.qty, v_today);
    if (v_res->>'shortfall')::integer > 0 then
      if (v_res->>'sellable')::integer = 0 and (v_res->>'expired')::integer > 0 then
        raise exception 'PRODUCT_EXPIRED|%', r.name using errcode = 'P0001';
      end if;
      raise exception 'INSUFFICIENT_STOCK|%|%', r.name, (v_res->>'sellable')::integer
        using errcode = 'P0001';
    end if;
    v_alloc := v_alloc || (v_res->'allocations');

    v_line_total := round(r.price * r.qty - r.disc, 2);
    v_subtotal   := v_subtotal + v_line_total;
    v_priced := v_priced || jsonb_build_object(
      'productId', r.id, 'quantity', r.qty, 'unitPrice', r.price,
      'discount', r.disc, 'total', v_line_total);
  end loop;

  if v_found <> v_expected then
    raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_discount > v_subtotal then
    raise exception 'INVALID_DISCOUNT' using errcode = 'P0001';
  end if;
  v_total := v_subtotal - round(p_discount, 2);

  insert into sale_counters as c (day, last_number) values (v_today, 1)
  on conflict (day) do update set last_number = c.last_number + 1
  returning last_number into v_counter;
  v_sale_number := 'POS-' || to_char(v_today, 'YYYYMMDD') || '-' || lpad(v_counter::text, 4, '0');

  insert into sales ("saleNumber", "userId", subtotal, discount, total,
                     "paymentMethod", status, notes, "idempotencyKey")
  values (v_sale_number, v_uid, v_subtotal, round(p_discount, 2), v_total,
          p_payment_method, 'COMPLETED', p_notes, v_key)
  returning id into v_sale_id;

  for x in select * from jsonb_array_elements(v_priced) loop
    insert into sale_items ("saleId", "productId", quantity, "unitPrice", discount, total)
    values (v_sale_id, (x->>'productId')::uuid, (x->>'quantity')::integer,
            (x->>'unitPrice')::numeric, (x->>'discount')::numeric, (x->>'total')::numeric)
    returning id into v_item_id;

    insert into sale_item_batches ("saleItemId", "batchId", quantity)
    select v_item_id, (a->>'batchId')::uuid, (a->>'quantity')::integer
      from jsonb_array_elements(v_alloc) a
     where (a->>'productId')::uuid = (x->>'productId')::uuid;
  end loop;

  -- Ledger rows; the trigger updates batches and product caches.
  insert into stock_movements ("productId", "batchId", type, quantity, "saleId", "userId", reason)
  select (a->>'productId')::uuid, (a->>'batchId')::uuid, 'SALE',
         -(a->>'quantity')::integer, v_sale_id, v_uid, 'Sale ' || v_sale_number
    from jsonb_array_elements(v_alloc) a
   order by (a->>'productId')::uuid, (a->>'batchId')::uuid;

  return sale_to_json(v_sale_id) || jsonb_build_object('replayed', false);
end $$;

-- ═════════════════════════════════════════
-- Devices
-- ═════════════════════════════════════════

create or replace function register_device(p_name text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := auth.uid();
  v_role user_role;
  v_dev  devices%rowtype;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null or v_role not in ('ADMIN', 'PHARMACIST') then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'INVALID_REQUEST' using errcode = 'P0001';
  end if;
  insert into devices (name, "registeredBy") values (btrim(p_name), v_uid) returning * into v_dev;
  return jsonb_build_object('id', v_dev.id, 'name', v_dev.name);
end $$;

create or replace function revoke_device(p_device_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := auth.uid();
  v_role user_role;
  v_dev  devices%rowtype;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null or v_role not in ('ADMIN', 'PHARMACIST') then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  update devices set "revokedAt" = coalesce("revokedAt", now())
   where id = p_device_id returning * into v_dev;
  if not found then raise exception 'DEVICE_UNKNOWN' using errcode = 'P0001'; end if;
  return jsonb_build_object('id', v_dev.id, 'revokedAt', v_dev."revokedAt");
end $$;

-- ═════════════════════════════════════════
-- The result of an offline submission: the sale, its shortfalls and its flags
-- ═════════════════════════════════════════

create or replace function offline_sale_result(p_sale_id uuid)
returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select sale_to_json(p_sale_id) || jsonb_build_object(
    'shortfalls', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', sf.id, 'productId', sf."productId",
               'quantity', sf.quantity, 'status', sf.status) order by sf.id)
        from sale_shortfalls sf join sale_items si on si.id = sf."saleItemId"
       where si."saleId" = p_sale_id), '[]'::jsonb),
    'flags', coalesce((
      select jsonb_agg(jsonb_build_object('code', f.code, 'detail', f.detail) order by f.id)
        from sale_flags f where f."saleId" = p_sale_id), '[]'::jsonb))
$$;
revoke all on function offline_sale_result(uuid) from public, anon, authenticated;

-- ═════════════════════════════════════════
-- STEP 2 and STEP 3: submit_offline_sale
-- ═════════════════════════════════════════
-- p_items: [{"productId": "<uuid>", "quantity": 2, "unitPrice": 3.00, "discount": 0}, ...]
-- unitPrice is the price the customer actually paid. Lines for the same product are merged
-- only if they carry the same price.
-- Errors: DEVICE_UNKNOWN, DEVICE_REVOKED, OFFLINE_CASH_ONLY, INVALID_REQUEST, INVALID_ITEMS,
--         INVALID_QUANTITY, INVALID_DISCOUNT, PRODUCT_NOT_FOUND, plus the usual UNAUTHORIZED
--         and FORBIDDEN. A rejected sale stays in the device's queue.

create or replace function submit_offline_sale(
  p_device_id             uuid,
  p_client_sale_id        uuid,
  p_occurred_at           timestamptz,
  p_items                 jsonb,
  p_payment_method        payment_method default 'CASH',
  p_discount              numeric        default 0,
  p_notes                 text           default null,
  p_client_receipt_number text           default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid         uuid := auth.uid();
  v_role        user_role;
  v_dev         devices%rowtype;
  v_existing    uuid;
  v_lines       jsonb;
  v_expected    integer;
  v_found       integer := 0;
  v_today       date := (now() at time zone 'Africa/Accra')::date;
  v_skew        interval := interval '15 minutes';   -- how far ahead of the server a device clock may be
  v_window      interval := interval '72 hours';     -- offline longer than this is flagged
  v_res         jsonb;
  v_priced      jsonb := '[]'::jsonb;
  v_alloc       jsonb := '[]'::jsonb;
  v_flags       jsonb := '[]'::jsonb;
  v_subtotal    numeric(10,2) := 0;
  v_total       numeric(10,2);
  v_line_total  numeric(10,2);
  v_counter     integer;
  v_sale_number text;
  v_sale_id     uuid;
  v_item_id     uuid;
  r             record;
  x             jsonb;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null then raise exception 'FORBIDDEN' using errcode = 'P0001'; end if;

  if p_device_id is null or p_client_sale_id is null or p_occurred_at is null then
    raise exception 'INVALID_REQUEST' using errcode = 'P0001';
  end if;

  -- STEP 2: idempotency. The advisory lock makes concurrent retries of the same sale queue up,
  -- so the second one finds the first one's sale and returns it.
  perform pg_advisory_xact_lock(
    hashtextextended('offline:' || p_device_id::text || ':' || p_client_sale_id::text, 0));
  select id into v_existing from sales
   where "deviceId" = p_device_id and "clientSaleId" = p_client_sale_id;
  if v_existing is not null then
    return offline_sale_result(v_existing) || jsonb_build_object('replayed', true);
  end if;

  -- Offline mode takes cash only: mobile money and card cannot be verified without a connection.
  if p_payment_method <> 'CASH' then
    raise exception 'OFFLINE_CASH_ONLY' using errcode = 'P0001';
  end if;

  select * into v_dev from devices where id = p_device_id;
  if not found then raise exception 'DEVICE_UNKNOWN' using errcode = 'P0001'; end if;
  if v_dev."revokedAt" is not null and p_occurred_at > v_dev."revokedAt" then
    raise exception 'DEVICE_REVOKED' using errcode = 'P0001';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'INVALID_ITEMS' using errcode = 'P0001';
  end if;
  if p_discount is null or p_discount < 0 then
    raise exception 'INVALID_DISCOUNT' using errcode = 'P0001';
  end if;

  begin
    select jsonb_agg(jsonb_build_object(
             'product_id', product_id, 'qty', qty, 'price', price, 'disc', disc))
      into v_lines
      from (
        select (e->>'productId')::uuid                      as product_id,
               sum((e->>'quantity')::integer)               as qty,
               (e->>'unitPrice')::numeric                   as price,
               sum(coalesce((e->>'discount')::numeric, 0))  as disc
          from jsonb_array_elements(p_items) e
         group by (e->>'productId')::uuid, (e->>'unitPrice')::numeric
      ) agg;
  exception when invalid_text_representation or numeric_value_out_of_range
            or null_value_not_allowed then
    raise exception 'INVALID_ITEMS' using errcode = 'P0001';
  end;

  v_expected := jsonb_array_length(v_lines);
  -- The same product at two different prices in one sale is not supported: allocation would
  -- run twice before stock is updated and could double-count the same units.
  if (select count(distinct (l->>'product_id')) from jsonb_array_elements(v_lines) l) <> v_expected then
    raise exception 'INVALID_ITEMS' using errcode = 'P0001';
  end if;

  -- Same lock order as create_sale: products by id, then each product's batches.
  for r in
    select p.id, p.name, p."sellingPrice" as server_price, l.qty, l.price, l.disc
      from jsonb_to_recordset(v_lines)
             as l(product_id uuid, qty integer, price numeric, disc numeric)
      join products p on p.id = l.product_id
     order by p.id
       for update of p
  loop
    v_found := v_found + 1;

    if r.qty is null or r.qty <= 0 then
      raise exception 'INVALID_QUANTITY|%', r.name using errcode = 'P0001';
    end if;
    if r.price is null or r.price < 0 then
      raise exception 'INVALID_ITEMS' using errcode = 'P0001';
    end if;
    if r.disc < 0 or r.disc > r.price * r.qty then
      raise exception 'INVALID_DISCOUNT' using errcode = 'P0001';
    end if;

    -- STEP 3: a shortage is recorded, not refused.
    v_res := allocate_stock(r.id, r.qty, v_today);
    v_alloc := v_alloc || (v_res->'allocations');

    v_line_total := round(r.price * r.qty - r.disc, 2);
    v_subtotal   := v_subtotal + v_line_total;
    v_priced := v_priced || jsonb_build_object(
      'productId', r.id, 'quantity', r.qty, 'unitPrice', r.price,
      'discount', r.disc, 'total', v_line_total,
      'shortfall', (v_res->>'shortfall')::integer);

    -- The customer paid this price. Keep it, and make a difference visible.
    if r.price is distinct from r.server_price then
      v_flags := v_flags || jsonb_build_object('code', 'PRICE_MISMATCH', 'detail',
        jsonb_build_object('productId', r.id, 'paid', r.price, 'current', r.server_price));
    end if;
  end loop;

  if v_found <> v_expected then
    raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_discount > v_subtotal then
    raise exception 'INVALID_DISCOUNT' using errcode = 'P0001';
  end if;
  v_total := v_subtotal - round(p_discount, 2);

  if p_occurred_at > now() + v_skew then
    v_flags := v_flags || jsonb_build_object('code', 'CLOCK_SKEW', 'detail',
      jsonb_build_object('occurredAt', p_occurred_at, 'receivedAt', now()));
  end if;
  if p_occurred_at < now() - v_window then
    v_flags := v_flags || jsonb_build_object('code', 'LONG_OFFLINE', 'detail',
      jsonb_build_object('occurredAt', p_occurred_at, 'receivedAt', now()));
  end if;

  -- The server assigns the real sale number now; the device's own receipt number is kept.
  insert into sale_counters as c (day, last_number) values (v_today, 1)
  on conflict (day) do update set last_number = c.last_number + 1
  returning last_number into v_counter;
  v_sale_number := 'POS-' || to_char(v_today, 'YYYYMMDD') || '-' || lpad(v_counter::text, 4, '0');

  insert into sales ("saleNumber", "userId", subtotal, discount, total, "paymentMethod", status,
                     notes, source, "deviceId", "clientSaleId", "clientReceiptNumber",
                     "occurredAt", "receivedAt")
  values (v_sale_number, v_uid, v_subtotal, round(p_discount, 2), v_total, 'CASH', 'COMPLETED',
          p_notes, 'OFFLINE', p_device_id, p_client_sale_id, p_client_receipt_number,
          p_occurred_at, now())
  returning id into v_sale_id;

  for x in select * from jsonb_array_elements(v_priced) loop
    insert into sale_items ("saleId", "productId", quantity, "unitPrice", discount, total)
    values (v_sale_id, (x->>'productId')::uuid, (x->>'quantity')::integer,
            (x->>'unitPrice')::numeric, (x->>'discount')::numeric, (x->>'total')::numeric)
    returning id into v_item_id;

    insert into sale_item_batches ("saleItemId", "batchId", quantity)
    select v_item_id, (a->>'batchId')::uuid, (a->>'quantity')::integer
      from jsonb_array_elements(v_alloc) a
     where (a->>'productId')::uuid = (x->>'productId')::uuid;

    if (x->>'shortfall')::integer > 0 then
      insert into sale_shortfalls ("saleItemId", "productId", quantity)
      values (v_item_id, (x->>'productId')::uuid, (x->>'shortfall')::integer);
    end if;
  end loop;

  insert into stock_movements ("productId", "batchId", type, quantity, "saleId", "userId", reason)
  select (a->>'productId')::uuid, (a->>'batchId')::uuid, 'SALE',
         -(a->>'quantity')::integer, v_sale_id, v_uid, 'Offline sale ' || v_sale_number
    from jsonb_array_elements(v_alloc) a
   order by (a->>'productId')::uuid, (a->>'batchId')::uuid;

  insert into sale_flags ("saleId", code, detail)
  select v_sale_id, f->>'code', f->'detail' from jsonb_array_elements(v_flags) f;

  return offline_sale_result(v_sale_id) || jsonb_build_object('replayed', false);
end $$;

-- ═════════════════════════════════════════
-- STEP 4: resolve_shortfall, and void_sale that closes shortfalls
-- ═════════════════════════════════════════
-- p_action = 'FOUND'      the stock existed and the ledger did not know. Takes the units from
--                         p_batch_id. If that batch holds fewer units than the shortfall, a
--                         CORRECTION for the difference is recorded first (the stock was found),
--                         then the SALE.
-- p_action = 'WRITE_OFF'  the stock record was wrong. No stock movement; the sale stands.
--                         A reason is required.
-- Lock order: sale, shortfall, product, batch (the same sale-first order as void_sale).

create or replace function resolve_shortfall(
  p_shortfall_id uuid,
  p_action       text,
  p_batch_id     uuid default null,
  p_reason       text default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid     uuid := auth.uid();
  v_role    user_role;
  v_today   date := (now() at time zone 'Africa/Accra')::date;
  v_sf      sale_shortfalls%rowtype;
  v_sale_id uuid;
  v_sale    sales%rowtype;
  v_batch   product_batches%rowtype;
  v_missing integer;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null or v_role not in ('ADMIN', 'PHARMACIST') then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  if p_action not in ('FOUND', 'WRITE_OFF') then
    raise exception 'INVALID_ACTION' using errcode = 'P0001';
  end if;

  select si."saleId" into v_sale_id
    from sale_shortfalls s join sale_items si on si.id = s."saleItemId"
   where s.id = p_shortfall_id;
  if v_sale_id is null then raise exception 'SHORTFALL_NOT_FOUND' using errcode = 'P0001'; end if;

  select * into v_sale from sales where id = v_sale_id for update;
  select * into v_sf from sale_shortfalls where id = p_shortfall_id for update;
  if v_sf.status <> 'OPEN' then
    raise exception 'SHORTFALL_NOT_OPEN|%', v_sf.status using errcode = 'P0001';
  end if;

  if p_action = 'WRITE_OFF' then
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'REASON_REQUIRED' using errcode = 'P0001';
    end if;
    update sale_shortfalls
       set status = 'WRITTEN_OFF', "resolvedBy" = v_uid, "resolvedAt" = now(),
           resolution = btrim(p_reason)
     where id = p_shortfall_id;
  else
    if p_batch_id is null then raise exception 'BATCH_REQUIRED' using errcode = 'P0001'; end if;

    perform 1 from products where id = v_sf."productId" for update;     -- product first
    select * into v_batch from product_batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001'; end if;
    if v_batch."productId" <> v_sf."productId" then
      raise exception 'BATCH_PRODUCT_MISMATCH' using errcode = 'P0001';
    end if;
    if v_batch."expiryDate" is not null and v_batch."expiryDate" < v_today then
      raise exception 'EXPIRED_BATCH' using errcode = 'P0001';
    end if;

    v_missing := v_sf.quantity - v_batch."quantityOnHand";
    if v_missing > 0 then
      insert into stock_movements ("productId", "batchId", type, quantity, "userId", reason)
      values (v_sf."productId", p_batch_id, 'CORRECTION', v_missing, v_uid,
              'Stock found while resolving shortfall ' || v_sf.id);
    end if;
    insert into stock_movements ("productId", "batchId", type, quantity, "saleId", "userId", reason)
    values (v_sf."productId", p_batch_id, 'SALE', -v_sf.quantity, v_sale_id, v_uid,
            'Shortfall resolved for ' || v_sale."saleNumber");

    insert into sale_item_batches ("saleItemId", "batchId", quantity)
    values (v_sf."saleItemId", p_batch_id, v_sf.quantity)
    on conflict ("saleItemId", "batchId")
      do update set quantity = sale_item_batches.quantity + excluded.quantity;

    update sale_shortfalls
       set status = 'RESOLVED_FOUND', "resolvedBy" = v_uid, "resolvedAt" = now(),
           resolution = coalesce(nullif(btrim(p_reason), ''), 'Stock found')
     where id = p_shortfall_id;
  end if;

  return jsonb_build_object('id', p_shortfall_id,
    'status', (select status from sale_shortfalls where id = p_shortfall_id));
end $$;

-- void_sale now also closes the sale's open shortfalls.
create or replace function void_sale(p_sale_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := auth.uid();
  v_role  user_role;
  v_sale  sales%rowtype;
begin
  if v_uid is null then raise exception 'UNAUTHORIZED' using errcode = 'P0001'; end if;
  select role into v_role from users where id = v_uid;
  if v_role is null or v_role not in ('ADMIN', 'PHARMACIST') then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  select * into v_sale from sales where id = p_sale_id for update;
  if not found then raise exception 'SALE_NOT_FOUND' using errcode = 'P0001'; end if;
  if v_sale.status <> 'COMPLETED' then
    raise exception 'SALE_NOT_VOIDABLE|%', v_sale.status using errcode = 'P0001';
  end if;

  -- Same lock order as create_sale: products by id, then batches.
  perform 1 from products
   where id in (select "productId" from sale_items where "saleId" = p_sale_id)
   order by id for update;

  perform 1 from product_batches
   where id in (select sib."batchId" from sale_item_batches sib
                  join sale_items si on si.id = sib."saleItemId"
                 where si."saleId" = p_sale_id)
   order by "productId", "expiryDate" nulls last, id for update;

  insert into stock_movements ("productId", "batchId", type, quantity, "saleId", "userId", reason)
  select b."productId", b.id, 'SALE_VOID', sib.quantity, p_sale_id, v_uid,
         'Void of ' || v_sale."saleNumber" || coalesce(': ' || nullif(p_reason, ''), '')
    from sale_item_batches sib
    join sale_items si on si.id = sib."saleItemId"
    join product_batches b on b.id = sib."batchId"
   where si."saleId" = p_sale_id
   order by b."productId", b.id;


  -- Shortfalls still waiting for a pharmacist are closed with the sale. Allocated stock was
  -- returned above; units that never left the ledger have nothing to return.
  update sale_shortfalls
     set status = 'VOIDED', "resolvedBy" = v_uid, "resolvedAt" = now(),
         resolution = 'Sale voided'
   where status = 'OPEN'
     and "saleItemId" in (select id from sale_items where "saleId" = p_sale_id);

  update sales
     set status = 'VOIDED',
         notes = concat_ws(E'\n', notes,
                   'VOIDED: ' || coalesce(nullif(p_reason, ''), 'no reason given')),
         "updatedAt" = now()
   where id = p_sale_id;

  return sale_to_json(p_sale_id);
end $$;

-- ═════════════════════════════════════════
-- STEP 5: the sale-line invariant in verify_stock_integrity
-- ═════════════════════════════════════════
-- Now also returns kind = 'sale_item' for any sale line whose quantity is not equal to
-- (units taken from batches) + (units recorded as a shortfall).

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
    having coalesce(sum(b."quantityOnHand"), 0) <> p."stockQuantity"
    union all
    -- Every sale line must be fully explained: the units taken from batches, plus the units
    -- still (or finally) recorded as a shortfall. A RESOLVED_FOUND shortfall has moved into
    -- sale_item_batches, so it is not counted twice.
    select 'sale_item'::text, t.id, t.quantity::bigint, t.covered::bigint
      from (
        select si.id, si.quantity,
               coalesce(a.q, 0) + coalesce(s.q, 0) as covered
          from sale_items si
          left join (select "saleItemId", sum(quantity) as q
                       from sale_item_batches group by "saleItemId") a
                 on a."saleItemId" = si.id
          left join (select "saleItemId", sum(quantity) as q
                       from sale_shortfalls where status <> 'RESOLVED_FOUND'
                      group by "saleItemId") s
                 on s."saleItemId" = si.id
      ) t
     where t.quantity <> t.covered;
end $$;

-- ═════════════════════════════════════════
-- Permissions
-- ═════════════════════════════════════════

revoke all on function
  register_device(text),
  revoke_device(uuid),
  resolve_shortfall(uuid, text, uuid, text),
  submit_offline_sale(uuid, uuid, timestamptz, jsonb, payment_method, numeric, text, text)
from public, anon;
grant execute on function
  register_device(text),
  revoke_device(uuid),
  resolve_shortfall(uuid, text, uuid, text),
  submit_offline_sale(uuid, uuid, timestamptz, jsonb, payment_method, numeric, text, text)
to authenticated;
