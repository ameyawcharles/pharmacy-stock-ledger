-- 003_checkout.sql
-- Atomic, idempotent checkout and void as Postgres functions.
--
--   create_sale(...)  validates, prices from the database, locks stock rows,
--                     allocates stock first-expiry-first-out across batches,
--                     writes the sale and the ledger rows, in ONE transaction.
--                     Idempotent per (user, idempotency key).
--   void_sale(...)    locks the sale, returns stock to the SAME batches, once.
--
-- Both are SECURITY DEFINER so a cashier can sell without any direct write
-- access to products; authorization is checked inside the functions.

alter table sales add column "idempotencyKey" text;
create unique index uq_sales_idempotency_key on sales ("idempotencyKey");

-- Per-day sale number counter. One row per local day, locked briefly at the end of a sale.
create table sale_counters (
  day         date primary key,
  last_number integer not null default 0
);
alter table sale_counters enable row level security;   -- no policies: functions only
revoke all on sale_counters from anon, authenticated;

-- ─────────────────────────────────────────
-- sale_to_json: now includes which batches each line came from
-- ─────────────────────────────────────────

create or replace function sale_to_json(p_sale_id uuid)
returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', s.id, 'saleNumber', s."saleNumber", 'userId', s."userId",
    'subtotal', s.subtotal, 'discount', s.discount, 'total', s.total,
    'paymentMethod', s."paymentMethod", 'status', s.status, 'notes', s.notes,
    'createdAt', s."createdAt", 'updatedAt', s."updatedAt",
    'user', (select jsonb_build_object('id', u.id, 'name', u.name)
               from users u where u.id = s."userId"),
    'saleItems', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', si.id, 'quantity', si.quantity, 'unitPrice', si."unitPrice",
          'discount', si.discount, 'total', si.total,
          'product', jsonb_build_object('id', p.id, 'name', p.name),
          'batches', coalesce((
            select jsonb_agg(jsonb_build_object(
                     'batchNumber', b."batchNumber", 'expiryDate', b."expiryDate",
                     'quantity', sib.quantity) order by b."expiryDate" nulls last, b.id)
              from sale_item_batches sib
              join product_batches b on b.id = sib."batchId"
             where sib."saleItemId" = si.id), '[]'::jsonb)
        ) order by si."createdAt", si.id)
      from sale_items si
      join products p on p.id = si."productId"
      where si."saleId" = s.id
    ), '[]'::jsonb)
  )
  from sales s
  where s.id = p_sale_id
$$;

-- ─────────────────────────────────────────
-- create_sale: now allocates stock FEFO across batches
-- ─────────────────────────────────────────

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
  v_need         integer;
  v_sellable     integer;
  v_expired      integer;
  v_take         integer;
  r              record;
  b              record;
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

    v_need := r.qty; v_sellable := 0; v_expired := 0;
    for b in
      select id, "quantityOnHand" as qty, "expiryDate" as expiry
        from product_batches
       where "productId" = r.id and "quantityOnHand" > 0
       order by "expiryDate" nulls last, id
         for update
    loop
      if b.expiry is not null and b.expiry < v_today then
        v_expired := v_expired + b.qty;          -- expired stock is never sold
        continue;
      end if;
      v_sellable := v_sellable + b.qty;
      v_take := least(v_need, b.qty);
      v_alloc := v_alloc || jsonb_build_object(
        'productId', r.id, 'batchId', b.id, 'quantity', v_take);
      v_need := v_need - v_take;
      exit when v_need = 0;
    end loop;

    if v_need > 0 then
      if v_sellable = 0 and v_expired > 0 then
        raise exception 'PRODUCT_EXPIRED|%', r.name using errcode = 'P0001';
      end if;
      raise exception 'INSUFFICIENT_STOCK|%|%', r.name, v_sellable using errcode = 'P0001';
    end if;

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

-- ─────────────────────────────────────────
-- void_sale: returns stock to the batches the sale took it from
-- ─────────────────────────────────────────

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


  update sales
     set status = 'VOIDED',
         notes = concat_ws(E'\n', notes,
                   'VOIDED: ' || coalesce(nullif(p_reason, ''), 'no reason given')),
         "updatedAt" = now()
   where id = p_sale_id;

  return sale_to_json(p_sale_id);
end $$;

-- ─────────────────────────────────────────
-- Permissions: signed-in users only
-- ─────────────────────────────────────────

revoke all on function sale_to_json(uuid) from public, anon, authenticated;
revoke all on function
  create_sale(jsonb, payment_method, numeric, text, text),
  void_sale(uuid, text)
from public, anon;
grant execute on function
  create_sale(jsonb, payment_method, numeric, text, text),
  void_sale(uuid, text)
to authenticated;
