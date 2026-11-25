import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type pg from 'pg'
import {
  MemoryStore, OfflineQueue, SyncEngine, type QueuedSale, type SaleFlag, type Shortfall, type SubmitAccepted,
} from '../src'
import {
  FlakyTransport, PgTransport, addDevice, addProduct, addUser, admin, count, integrityProblems, resetDatabase, stockOf,
} from './support/db'

// These tests run the real client against the real database (the migrations in db/migrations).

let a: pg.Client
let cashier: string
const open: PgTransport[] = []

beforeAll(async () => { a = await admin() })
afterAll(async () => { await Promise.all(open.map((t) => t.close())); await a.end() })
beforeEach(async () => {
  await resetDatabase(a)
  cashier = await addUser(a, 'CASHIER')
})

async function transportFor(userId: string | null): Promise<PgTransport> {
  const t = await PgTransport.connect(userId)
  open.push(t)
  return t
}

/** One till: its own queue and storage (as if on its own tablet), talking to the real server. */
async function till(opts: { transport?: PgTransport; flaky?: (call: number, sale: QueuedSale) => 'ok' | 'fail-before' | 'fail-after'; clock?: () => Date } = {}) {
  const deviceId = await addDevice(a)
  const store = new MemoryStore()
  const queue = new OfflineQueue(store, deviceId, opts.clock)
  const real = opts.transport ?? (await transportFor(cashier))
  const transport = new FlakyTransport(real, opts.flaky ?? (() => 'ok'))
  const heard = { synced: [] as SubmitAccepted[], shortfalls: [] as Shortfall[][], flags: [] as SaleFlag[][], rejected: [] as string[] }
  const engine = new SyncEngine(store, transport, {
    onSynced: (_s, r) => heard.synced.push(r),
    onShortfall: (_s, sf) => heard.shortfalls.push(sf),
    onFlags: (_s, fl) => heard.flags.push(fl),
    onRejected: (_s, code) => heard.rejected.push(code),
  }, { sleep: async () => {}, random: () => 0 })
  const sell = (productId: string, quantity: number, unitPrice = 5) =>
    queue.createSale({ items: [{ productId, quantity, unitPrice }] })
  return { deviceId, store, queue, transport, engine, heard, sell }
}

describe('a till that loses its connection', () => {
  it('keeps selling, survives a restart, and syncs everything in order when the network returns', async () => {
    const { productId } = await addProduct(a, 'Paracetamol', [[100, 60]])
    const t = await till({ flaky: () => 'fail-before' })

    for (let i = 0; i < 5; i++) await t.sell(productId, 2)
    expect((await t.engine.syncOnce()).stoppedBy).toBe('NETWORK')
    expect(await count(a, 'sales')).toBe(0)
    expect(await stockOf(a, productId)).toBe(100) // nothing reached the server

    // "Restart the app": new objects over the same saved storage.
    const queue2 = new OfflineQueue(t.store, t.deviceId)
    const engine2 = new SyncEngine(t.store, await transportFor(cashier), {}, { sleep: async () => {} })
    expect(await engine2.recover()).toBe(0)
    expect(await queue2.pending()).toHaveLength(5)

    const report = await engine2.runUntilDrained()
    expect(report).toMatchObject({ synced: 5, remaining: 0, stoppedBy: 'DRAINED' })
    expect(await t.store.list()).toEqual([])
    expect(await count(a, 'sales')).toBe(5)
    expect(await stockOf(a, productId)).toBe(90)

    const receipts = (await a.query(`select "clientReceiptNumber" as r from sales order by "receivedAt", id`)).rows.map((r) => r.r)
    expect(receipts.sort()).toEqual(['OFF-' + t.deviceId.slice(0, 4) + '-0001', ...[2, 3, 4, 5].map((n) => `OFF-${t.deviceId.slice(0, 4)}-000${n}`)].sort())
    expect(await integrityProblems(a)).toEqual([])
  })

  it('backs off between attempts while the network is down, then drains', async () => {
    const { productId } = await addProduct(a, 'Backoff', [[10, 60]])
    const t = await till({ flaky: (call) => (call <= 2 ? 'fail-before' : 'ok') })
    await t.sell(productId, 1)
    const report = await t.engine.runUntilDrained()
    expect(report).toMatchObject({ synced: 1, stoppedBy: 'DRAINED' })
    expect(t.transport.calls).toBe(3)
  })
})

describe('a lost acknowledgment', () => {
  it('does not create a second sale or move stock twice when the device retries', async () => {
    const { productId } = await addProduct(a, 'AckLost', [[50, 60]])
    // The server records the first send, but the answer never arrives.
    const t = await till({ flaky: (call) => (call === 1 ? 'fail-after' : 'ok') })
    await t.sell(productId, 3)

    const first = await t.engine.syncOnce()
    expect(first).toMatchObject({ synced: 0, remaining: 1, stoppedBy: 'NETWORK' })
    expect(await count(a, 'sales')).toBe(1) // the server DID record it
    expect(await stockOf(a, productId)).toBe(47)

    const second = await t.engine.syncOnce()
    expect(second).toMatchObject({ synced: 1, remaining: 0 })
    expect(t.heard.synced[0]!.replayed).toBe(true) // the server recognised the sale it already had
    expect(await count(a, 'sales')).toBe(1)
    expect(await stockOf(a, productId)).toBe(47) // moved once
    expect(await t.store.list()).toEqual([])
  })

  it('survives a crash after the server recorded the sale but before the device forgot it', async () => {
    const { productId } = await addProduct(a, 'Crash', [[50, 60]])
    const t = await till()
    const sale = await t.sell(productId, 4)

    await (await transportFor(cashier)).submit(sale) // the server records it...
    await t.store.put({ ...sale, status: 'SENDING' }) // ...and the app dies before removing it

    const restarted = new SyncEngine(t.store, await transportFor(cashier))
    expect(await restarted.recover()).toBe(1)
    await restarted.syncOnce()

    expect(await count(a, 'sales')).toBe(1)
    expect(await stockOf(a, productId)).toBe(46)
    expect(await t.store.list()).toEqual([])
  })
})

describe('what the server can refuse', () => {
  it('parks a sale the server rejects without blocking the ones behind it', async () => {
    const { productId } = await addProduct(a, 'Mixed', [[20, 60]])
    const t = await till()
    await t.sell(productId, 1)
    await t.sell('00000000-0000-4000-8000-000000000000', 1) // a product the server has never heard of
    await t.sell(productId, 1)

    const report = await t.engine.syncOnce()
    expect(report).toMatchObject({ synced: 2, rejected: 1, remaining: 0 })
    expect(t.heard.rejected).toEqual(['PRODUCT_NOT_FOUND'])
    const parked = await t.queue.rejected()
    expect(parked).toHaveLength(1)
    expect(parked[0]).toMatchObject({ status: 'REJECTED', lastError: 'PRODUCT_NOT_FOUND' })
    expect(await count(a, 'sales')).toBe(2)
  })

  it('accepts a sale made before the till was revoked, and rejects one made after', async () => {
    const { productId } = await addProduct(a, 'Revoked', [[20, 60]])
    const t = await till({ clock: () => new Date(Date.now() + 60_000) }) // device clock is a minute ahead of the server
    const early = await t.queue.createSale({ items: [{ productId, quantity: 1, unitPrice: 5 }] })
    const real = await t.queue.createSale({ items: [{ productId, quantity: 1, unitPrice: 5 }] })
    expect(early.occurredAt > new Date().toISOString()).toBe(true)

    // The pharmacist revokes the till now. Both queued sales claim to have happened after that.
    await a.query('update devices set "revokedAt" = now() where id = $1', [t.deviceId])
    const report = await t.engine.syncOnce()
    expect(report).toMatchObject({ synced: 0, rejected: 2 })
    expect(t.heard.rejected).toEqual(['DEVICE_REVOKED', 'DEVICE_REVOKED'])
    expect(await count(a, 'sales')).toBe(0)
    expect(await t.queue.rejected()).toHaveLength(2) // nothing was thrown away
    expect(real.clientSaleId).not.toBe(early.clientSaleId)
  })

  it('accepts a sale made before the revocation', async () => {
    const { productId } = await addProduct(a, 'BeforeRevoke', [[20, 60]])
    const t = await till()
    await t.sell(productId, 1) // occurredAt is now
    await new Promise((r) => setTimeout(r, 20))
    await a.query('update devices set "revokedAt" = now() where id = $1', [t.deviceId])
    expect(await t.engine.syncOnce()).toMatchObject({ synced: 1, rejected: 0 })
    expect(await count(a, 'sales')).toBe(1)
  })

  it('stops and keeps every sale when nobody is signed in', async () => {
    const { productId } = await addProduct(a, 'NoAuth', [[20, 60]])
    const t = await till({ transport: await transportFor(null) })
    await t.sell(productId, 1)
    await t.sell(productId, 1)
    const report = await t.engine.syncOnce()
    expect(report).toMatchObject({ synced: 0, rejected: 0, remaining: 2, stoppedBy: 'AUTH' })
    expect((await t.store.list()).map((s) => s.status)).toEqual(['PENDING', 'PENDING'])
    expect(await count(a, 'sales')).toBe(0)
  })
})

describe('when the shelf and the books disagree', () => {
  it('records the sale, tells the cashier about the shortfall, and leaves the ledger balanced', async () => {
    const { productId } = await addProduct(a, 'Short', [[3, 60]])
    const t = await till()
    await t.sell(productId, 5)

    expect(await t.engine.syncOnce()).toMatchObject({ synced: 1, remaining: 0 })
    expect(t.heard.shortfalls).toHaveLength(1)
    expect(t.heard.shortfalls[0]).toMatchObject([{ quantity: 2, status: 'OPEN' }])
    expect(await stockOf(a, productId)).toBe(0)
    expect(await count(a, 'sale_shortfalls')).toBe(1)
    expect(await integrityProblems(a)).toEqual([])
  })

  it('flags a price that differs from the server price', async () => {
    const { productId } = await addProduct(a, 'Priced', [[10, 60]], 5)
    const t = await till()
    await t.sell(productId, 2, 4) // sold at 4 while the server price is 5
    await t.engine.syncOnce()
    expect(t.heard.flags[0]!.map((f) => f.code)).toEqual(['PRICE_MISMATCH'])
    const row = (await a.query('select total from sales')).rows[0]
    expect(Number(row.total)).toBe(8) // the price the customer paid is what is recorded
  })
})

describe('two tills at once', () => {
  it('stay consistent when they sync in parallel against the same scarce stock', async () => {
    const { productId } = await addProduct(a, 'Shared', [[25, 30], [25, 90]])
    const t1 = await till()
    const t2 = await till({ transport: await transportFor(cashier) })
    let sold = 0
    for (let i = 0; i < 30; i++) {
      const q1 = 1 + (i % 3); const q2 = 1 + ((i + 1) % 3)
      await t1.sell(productId, q1); await t2.sell(productId, q2); sold += q1 + q2
    }

    const [r1, r2] = await Promise.all([t1.engine.runUntilDrained(), t2.engine.runUntilDrained()])
    expect(r1.synced + r2.synced).toBe(60)
    expect(await count(a, 'sales')).toBe(60)
    expect(await t1.store.list()).toEqual([])
    expect(await t2.store.list()).toEqual([])
    expect(await stockOf(a, productId)).toBe(Math.max(0, 50 - sold))
    expect((await a.query('select count(*) as n from product_batches where "quantityOnHand" < 0')).rows[0].n).toBe('0')
    expect(await integrityProblems(a)).toEqual([]) // ledger, batches, products and every sale line agree

    const units = (await a.query('select sum(quantity) as n from sale_items')).rows[0].n
    const covered = (await a.query(
      `select coalesce((select sum(quantity) from sale_item_batches),0) + coalesce((select sum(quantity) from sale_shortfalls),0) as n`,
    )).rows[0].n
    expect(Number(units)).toBe(sold)
    expect(Number(covered)).toBe(sold) // every unit sold is either taken from a batch or recorded as a shortfall
  })
})
