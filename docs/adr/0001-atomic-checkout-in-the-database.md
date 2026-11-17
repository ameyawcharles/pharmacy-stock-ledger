# ADR 0001: Checkout and void run as Postgres functions

- Status: accepted
- Code: `db/migrations/003_checkout.sql`; tests in `tests/harness.py` (sections 1, 3, 4, 8, 9, 10)

## Context

The usual way to build a checkout is in the application layer: read the stock, check it, insert the
sale, then write the new stock. With a database client that cannot hold a multi-statement transaction
(PostgREST, Supabase's JS client), that is four or more separate calls, and nothing makes them atomic.
Under concurrent registers this allows:

- **Overselling.** Two registers read the same stock, both pass the check, both sell.
- **Partial sales.** A failure after the sale insert leaves a sale with no items, or no stock change.
- **Lost updates.** Read-modify-write on a stock number loses concurrent changes.
- **Duplicate sale numbers.** `count(*) + 1` collides.
- **Double voids.** Two voids both pass the "not yet voided" check and return the stock twice.
- **Double charges.** A timeout followed by a retry creates a second sale.
- **Client-controlled prices.** The price arrives in the request body.

## Decision

Move checkout and void into two `SECURITY DEFINER` functions, `create_sale` and `void_sale`. Each
runs in one transaction. The application only validates the shape of the request and calls the function.

| Concern | Mechanism |
|---|---|
| No oversell | `SELECT ... FOR UPDATE` on the rows involved, then validate against the locked values |
| No deadlocks | Locks always taken in the same order: products by id, then batches by product, expiry, id |
| Atomic | One transaction; any `RAISE` rolls back the sale, items, ledger rows and counter |
| Idempotent retry | Key stored as `userId:key` under a unique index; `pg_advisory_xact_lock` serialises concurrent retries so the second one returns the first sale (`replayed: true`) |
| Gapless sale numbers | A per-day counter row upserted inside the transaction, taken last so it is held briefly |
| Server-side prices | `sellingPrice` is read from `products`; a client price is never accepted |
| Single void | `SELECT ... FOR UPDATE` on the sale; the second void sees `VOIDED` and is rejected |
| Authorization | The role is checked inside the functions; sales have no INSERT/UPDATE policies at all |

Errors are raised as `CODE|detail|detail` so an API layer can map them to HTTP responses without
exposing database text.

## Alternatives considered

1. **Optimistic concurrency in the application** (version column, retry on conflict). More round trips
   and code, and still no multi-row atomicity.
2. **`SERIALIZABLE` isolation.** Correct, but every caller needs retry logic for serialization failures.
   Explicit row locks are simpler to reason about for this workload.
3. **A service-role key in the application with application-level locking.** Widens the blast radius of
   a leaked key and still has no transaction.

## Consequences

- Business rules live in SQL, so they are tested with a SQL-level suite against a real database, not
  with application unit tests.
- All sales of one day briefly serialise on one counter row, and sales of the same product serialise on
  that product's rows. That is fine for one pharmacy; a multi-branch deployment should use a counter per
  branch.
- The local day is `Africa/Accra` and is set in the functions. Change it there for another time zone.
- Payment verification is out of scope: the payment method is recorded, not verified.
