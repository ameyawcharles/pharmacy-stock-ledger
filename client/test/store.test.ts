import 'fake-indexeddb/auto'
import { describe, it, expect } from 'vitest'
import { IndexedDbStore, MemoryStore, type QueueStore, type QueuedSale } from '../src'

let n = 0
const sale = (seq: number, overrides: Partial<QueuedSale> = {}): QueuedSale => ({
  clientSaleId: `sale-${seq}-${++n}`,
  deviceId: 'dev',
  seq,
  receiptNumber: `OFF-dev-${seq}`,
  occurredAt: '2026-11-23T10:00:00.000Z',
  items: [{ productId: 'p', quantity: 1, unitPrice: 5 }],
  discount: 0,
  notes: null,
  status: 'PENDING',
  attempts: 0,
  lastError: null,
  ...overrides,
})

// The same behaviour is required of every store, so the engine can run on either.
const factories: Array<[string, () => Promise<QueueStore>]> = [
  ['MemoryStore', async () => new MemoryStore()],
  ['IndexedDbStore', async () => IndexedDbStore.open(`test-${++n}`)],
]

describe.each(factories)('%s', (_name, make) => {
  it('stores and returns a sale', async () => {
    const store = await make()
    const s = sale(1)
    await store.put(s)
    expect(await store.get(s.clientSaleId)).toEqual(s)
    expect(await store.get('missing')).toBeUndefined()
  })

  it('returns copies, so changing what you were given does not change what is stored', async () => {
    const store = await make()
    const s = sale(1)
    await store.put(s)
    const got = await store.get(s.clientSaleId)
    got!.items[0]!.quantity = 999
    expect((await store.get(s.clientSaleId))!.items[0]!.quantity).toBe(1)
  })

  it('lists oldest first by seq, however they were inserted', async () => {
    const store = await make()
    for (const seq of [3, 1, 2]) await store.put(sale(seq))
    expect((await store.list()).map((s) => s.seq)).toEqual([1, 2, 3])
  })

  it('put replaces a sale with the same id', async () => {
    const store = await make()
    const s = sale(1)
    await store.put(s)
    await store.put({ ...s, status: 'REJECTED', lastError: 'X' })
    const all = await store.list()
    expect(all).toHaveLength(1)
    expect(all[0]).toMatchObject({ status: 'REJECTED', lastError: 'X' })
  })

  it('removes a sale', async () => {
    const store = await make()
    const s = sale(1)
    await store.put(s)
    await store.remove(s.clientSaleId)
    expect(await store.list()).toEqual([])
  })

  it('numbers go up by one and never repeat, even when asked at the same time', async () => {
    const store = await make()
    const seqs = await Promise.all(Array.from({ length: 20 }, () => store.nextSeq()))
    expect(new Set(seqs).size).toBe(20)
    expect([...seqs].sort((a, b) => a - b)).toEqual(Array.from({ length: 20 }, (_, i) => i + 1))
  })
})

describe('IndexedDbStore durability', () => {
  it('keeps sales and the counter after the database is closed and opened again', async () => {
    const name = `durable-${++n}`
    const first = await IndexedDbStore.open(name)
    const s = sale(1)
    await first.put(s)
    expect(await first.nextSeq()).toBe(1)
    first.close()

    const second = await IndexedDbStore.open(name)
    expect(await second.get(s.clientSaleId)).toEqual(s)
    expect(await second.nextSeq()).toBe(2)
  })
})
