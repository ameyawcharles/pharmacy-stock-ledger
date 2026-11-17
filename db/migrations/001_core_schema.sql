-- 001_core_schema.sql
-- The minimum schema the stock ledger needs: staff, products, suppliers, sales.
-- A real product would add categories, settings, insurance claims and so on.
--
-- Authorization model: Supabase-style. `auth.uid()` returns the signed-in user's id,
-- and the `authenticated` / `anon` roles are what API requests run as.
-- (db/test-support/stub_auth.sql fakes this for a plain Postgres.)

create type user_role as enum ('ADMIN', 'PHARMACIST', 'CASHIER');
create type sale_status as enum ('COMPLETED', 'VOIDED', 'REFUNDED');
create type payment_method as enum ('CASH', 'MOBILE_MONEY', 'CARD');

create table users (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  email       text not null unique,
  role        user_role not null default 'CASHIER',
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now()
);

create table suppliers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  "createdAt" timestamptz not null default now()
);

create table products (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  "sellingPrice"  numeric(10,2) not null check ("sellingPrice" >= 0),
  "costPrice"     numeric(10,2),
  "supplierId"    uuid references suppliers(id) on delete set null,
  -- Cache of SUM(product_batches."quantityOnHand"); only ledger writes change it (see 002).
  "stockQuantity" integer not null default 0 check ("stockQuantity" >= 0),
  "isActive"      boolean not null default true,
  "createdAt"     timestamptz not null default now(),
  "updatedAt"     timestamptz not null default now()
);

create table sales (
  id              uuid primary key default gen_random_uuid(),
  "saleNumber"    text not null unique,
  "userId"        uuid references users(id) on delete set null,
  subtotal        numeric(10,2) not null,
  discount        numeric(10,2) not null default 0,
  total           numeric(10,2) not null,
  "paymentMethod" payment_method not null default 'CASH',
  status          sale_status not null default 'COMPLETED',
  notes           text,
  "createdAt"     timestamptz not null default now(),
  "updatedAt"     timestamptz not null default now()
);

create table sale_items (
  id          uuid primary key default gen_random_uuid(),
  "saleId"    uuid not null references sales(id) on delete cascade,
  "productId" uuid not null references products(id) on delete restrict,
  quantity    integer not null check (quantity > 0),
  "unitPrice" numeric(10,2) not null,
  discount    numeric(10,2) not null default 0,
  total       numeric(10,2) not null,
  "createdAt" timestamptz not null default now()
);
create index idx_sale_items_sale    on sale_items ("saleId");
create index idx_sale_items_product on sale_items ("productId");

-- ─────────────────────────────────────────
-- Role lookup used by the row-level-security policies
-- ─────────────────────────────────────────

create or replace function get_user_role()
returns user_role
language sql stable security definer
set search_path = public, pg_temp
as $$ select role from users where id = auth.uid() $$;

-- ─────────────────────────────────────────
-- Row-level security
-- Sales and stock are READ-ONLY to API users. They are written only by the
-- SECURITY DEFINER functions in 002 and 003, so there are deliberately no
-- INSERT/UPDATE/DELETE policies on sales or sale_items.
-- ─────────────────────────────────────────

alter table users     enable row level security;
alter table suppliers enable row level security;
alter table products  enable row level security;
alter table sales     enable row level security;
alter table sale_items enable row level security;

create policy "read_own_user"      on users for select to authenticated using (id = auth.uid());
create policy "admin_read_users"   on users for select to authenticated using (get_user_role() = 'ADMIN');

create policy "auth_read_suppliers" on suppliers for select to authenticated using (true);

create policy "auth_read_products"   on products for select to authenticated using (true);
create policy "staff_insert_products" on products for insert to authenticated
  with check (get_user_role() in ('ADMIN', 'PHARMACIST'));
create policy "staff_update_products" on products for update to authenticated
  using (get_user_role() in ('ADMIN', 'PHARMACIST'));

create policy "auth_read_sales"      on sales      for select to authenticated using (true);
create policy "auth_read_sale_items" on sale_items for select to authenticated using (true);

revoke all on users, suppliers, products, sales, sale_items from anon;
