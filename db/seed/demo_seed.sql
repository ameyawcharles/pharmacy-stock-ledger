-- Synthetic demo data. No real people, prices or products.
insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'),
  ('a0000000-0000-0000-0000-000000000002');

insert into users (id, name, email, role) values
  ('a0000000-0000-0000-0000-000000000001', 'Demo Pharmacist', 'pharmacist@example.test', 'PHARMACIST'),
  ('a0000000-0000-0000-0000-000000000002', 'Demo Cashier',    'cashier@example.test',    'CASHIER');

insert into products (name, "sellingPrice", "costPrice") values
  ('Paracetamol 500mg', 3.00, 1.80),
  ('Amoxicillin 500mg', 12.00, 7.50),
  ('Oral rehydration salts', 1.50, 0.70);
