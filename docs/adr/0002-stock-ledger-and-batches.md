# ADR 0002: Stock is an append-only ledger over batches, sold first-expiry-first-out

- Status: accepted
- Code: `db/migrations/002_stock_ledger_and_batches.sql`; tests in `tests/harness.py` (sections 2, 5, 6, 7, 10, 11)

## Context

A single mutable stock number per product has three problems for a pharmacy:

1. **No trustworthy history.** A total can be changed to anything, with or without a log row, and the
   log and the number drift apart.
2. **No expiry tracking.** A pharmacy sells batches, not products. One expiry date per product cannot say
   which units expire first, cannot stop an expired pack being sold, and cannot answer a recall ("which
   sales included batch X?").
3. **No way to prove the numbers add up.**

## Decision

| Piece | Role |
|---|---|
| `stock_movements` | Append-only ledger. One signed row per change: `RECEIPT`, `SALE`, `SALE_VOID`, `DAMAGE`, `EXPIRY_WRITEOFF`, `RETURN_TO_SUPPLIER`, `CORRECTION`, `OPENING`. UPDATE and DELETE raise `LEDGER_IMMUTABLE`, even for a superuser. A CHECK ties the sign to the type; a composite foreign key forces the batch to belong to the product. |
| `product_batches` | One row per received batch: number, expiry, cost. `quantityOnHand` is a cache of the ledger. |
| `products."stockQuantity"` | A cache of the sum of its batches, so list screens need no aggregate. |
| Trigger `apply_stock_movement` | Inserting a ledger row updates the batch and product caches in the same transaction. |
| Trigger `guard_stock_cache` | API roles (`authenticated`, `anon`) cannot write the cached quantities. Only the functions change stock. |
| `sale_item_batches` | Which batches each sale line came from. A void returns stock to the same batches, and a recall can be traced. |
| `create_sale` | Allocates first-expiry-first-out across batches; expired batches are never sold. |
| `receive_stock`, `adjust_stock` | The only ways to add or remove stock by hand. Role-checked, validated and idempotent. |
| `verify_stock_integrity()` | Recomputes ledger, batches and products, and returns any mismatch. |

**Lock order, used by every function:** product rows (by id), then batch rows (by product, expiry, id),
then the sale counter. Overlapping carts cannot deadlock; a test runs 250 opposite-order, multi-batch
carts.

## Alternatives considered

1. **Derive stock only from the ledger with no cache.** The purest option, but every list or search would
   aggregate the ledger. The cache plus a trigger gives the same guarantee, because nothing can change it
   without a ledger row.
2. **Keep the stock number and add an audit table.** The log and the number can drift, and nothing stops a
   direct edit.
3. **Optional batches.** Two code paths in every function, and an expired unbatched product can still be sold.

## Consequences

- A database superuser or the Supabase service role can still bypass the guard on the cached columns. That
  is deliberate, for repairs, and `verify_stock_integrity()` is how a bypass is detected. The ledger itself
  stays immutable.
- A product whose only stock is expired shows stock but refuses to sell (`PRODUCT_EXPIRED`) until the
  expired stock is written off.
- `receive_stock` and `adjust_stock` accept an idempotency key so a double-submitted form applies once.
