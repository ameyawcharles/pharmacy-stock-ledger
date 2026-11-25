# Offline sales client

The part of offline selling that lives on the till (see [ADR 0003](../docs/adr/0003-offline-selling.md)):
a queue that keeps sales safe while the network is down, and an engine that sends them to the server when it
comes back. Plain TypeScript with no framework.

## What it guarantees

- **A sale is saved before the receipt is shown.** `createSale` returns only after the store has finished writing,
  so a crash or a dead battery right after the receipt cannot lose the sale.
- **A sale is forgotten only after the server acknowledged it.** While a send is in flight the sale stays in
  storage as `SENDING`.
- **An unknown outcome is retried, never assumed.** If the connection drops mid-send, the sale stays queued. The
  server recognises a sale it already recorded (`replayed: true`), so retrying cannot charge twice.
- **One bad sale does not block the rest.** A sale the server refuses is parked as `REJECTED` and the queue
  carries on. Nothing is thrown away.
- **An expired sign-in is not a rejection.** The engine stops and keeps everything until the cashier signs in again.
- **Cash only.** Mobile money and card cannot be verified offline, so `createSale` refuses them.

## Use

```ts
import { IndexedDbStore, OfflineQueue, SyncEngine, type Transport } from './src'

const store = await IndexedDbStore.open()           // survives the browser closing
const queue = new OfflineQueue(store, deviceId)     // deviceId comes from register_device
const engine = new SyncEngine(store, transport, {
  onShortfall: (sale, shortfalls) => showBanner(sale.receiptNumber, shortfalls),
  onRejected: (sale, code) => flagForStaff(sale.receiptNumber, code),
  onAuthRequired: () => showSignIn(),
})

await engine.recover()                              // once, when the app starts
const sale = await queue.createSale({ items })      // works with no network; print sale.receiptNumber
window.addEventListener('online', () => engine.runUntilDrained())
```

A `Transport` is one method. It must **resolve** when the server answered, and **throw** when the outcome is unknown:

```ts
// Sketch for Supabase. NOT tested in this repo: the tests use a direct Postgres connection instead.
const transport: Transport = {
  async submit(sale) {
    const { data, error } = await supabase.rpc('submit_offline_sale', {
      p_device_id: sale.deviceId, p_client_sale_id: sale.clientSaleId, p_occurred_at: sale.occurredAt,
      p_items: sale.items, p_discount: sale.discount, p_notes: sale.notes, p_client_receipt_number: sale.receiptNumber,
    })
    if (error?.code === 'P0001') return { ok: false, code: error.message.split('|')[0] }   // the server said no
    if (error) throw new Error(error.message)                                            // outcome unknown
    return { ok: true, saleId: data.id, saleNumber: data.saleNumber, replayed: data.replayed,
             shortfalls: data.shortfalls, flags: data.flags }
  },
}
```

`stockWarnings(snapshot, items)` tells the cashier when a sale may exceed the stock the till last heard about.
It warns and never blocks, because the medicine is already on the counter.

## Tests

```bash
cd client
npm ci
PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=pw npm test      # needs the database from scripts/run_tests.sh
npm run typecheck
```

68 tests. Storage, queue rules and sync logic run without a database, with failures injected: a network that
drops, a lost acknowledgment, a crash after the server recorded the sale. The rest run end to end against the real
database: a lost connection and restart, a revoked till, a shortage, and two tills syncing at once on scarce stock.
