import { describe, it, expect } from 'vitest'
import { InvalidSaleError, MemoryStore, OfflineCashOnlyError, OfflineQueue, type QueuedSale } from '../src'

const device = '1a2b3c4d-0000-4000-8000-000000000000'
const item = (productId = 'p1', quantity = 1, unitPrice = 5, discount?: number) => ({
  productId, quantity, unitPrice, ...(discount === undefined ? {} : { discount }),
})
const make = (store = new MemoryStore()) => ({ store, queue: new OfflineQueue(store, device) })

describe('OfflineQueue.createSale', () => {
  it('saves the sale before it returns, so a crash after the receipt cannot lose it', async () => {
    const { store, queue } = make()
    const sale = await queue.createSale({ items: [item()] })
    expect(await store.get(sale.clientSaleId)).toEqual(sale)
    expect(sale.status).toBe('PENDING')
    expect(sale.attempts).toBe(0)
  })

  it('does not hand back the receipt until the store has finished saving', async () => {
    // A real device store is slow. If the receipt came back first, a crash right then would lose the sale.
    let saved = false
    class SlowStore extends MemoryStore {
      override async put(sale: QueuedSale): Promise<void> {
        await new Promise((resolve) => setTimeout(resolve, 15))
        await super.put(sale)
        saved = true
      }
    }
    const queue = new OfflineQueue(new SlowStore(), device)
    await queue.createSale({ items: [item()] })
    expect(saved).toBe(true)
  })

  it('numbers receipts per device and keeps counting after a restart', async () => {
    const store = new MemoryStore()
    const a = await new OfflineQueue(store, device).createSale({ items: [item()] })
    const b = await new OfflineQueue(store, device).createSale({ items: [item()] }) // "restarted" app
    expect([a.receiptNumber, b.receiptNumber]).toEqual(['OFF-1a2b-0001', 'OFF-1a2b-0002'])
    expect(a.clientSaleId).not.toBe(b.clientSaleId)
  })

  it('records the device clock time of the sale', async () => {
    const store = new MemoryStore()
    const queue = new OfflineQueue(store, device, () => new Date('2026-11-23T09:30:00Z'))
    expect((await queue.createSale({ items: [item()] })).occurredAt).toBe('2026-11-23T09:30:00.000Z')
  })

  it('refuses anything but cash', async () => {
    const { queue } = make()
    await expect(queue.createSale({ items: [item()], paymentMethod: 'MOBILE_MONEY' })).rejects.toBeInstanceOf(OfflineCashOnlyError)
    await expect(queue.createSale({ items: [item()], paymentMethod: 'CARD' })).rejects.toBeInstanceOf(OfflineCashOnlyError)
    await expect(queue.createSale({ items: [item()], paymentMethod: 'CASH' })).resolves.toBeTruthy()
  })

  it('stores nothing when a sale is refused', async () => {
    const { store, queue } = make()
    await expect(queue.createSale({ items: [] })).rejects.toBeInstanceOf(InvalidSaleError)
    expect(await store.list()).toEqual([])
  })

  it.each([
    ['no items', [], undefined],
    ['zero quantity', [item('p1', 0)], undefined],
    ['fractional quantity', [item('p1', 1.5)], undefined],
    ['negative price', [item('p1', 1, -1)], undefined],
    ['missing product', [item('', 1)], undefined],
    ['line discount above the line', [item('p1', 1, 5, 6)], undefined],
    ['sale discount above the sale', [item('p1', 1, 5)], 6],
    ['negative sale discount', [item('p1', 1, 5)], -1],
    ['same product at two prices', [item('p1', 1, 5), item('p1', 1, 4)], undefined],
  ])('rejects %s', async (_name, items, discount) => {
    const { queue } = make()
    await expect(queue.createSale({ items, discount })).rejects.toBeInstanceOf(InvalidSaleError)
  })

  it('merges repeated lines of the same product and price', async () => {
    const { queue } = make()
    const sale = await queue.createSale({ items: [item('p1', 1, 5, 1), item('p1', 2, 5, 0.5), item('p2', 1, 3)] })
    expect(sale.items).toEqual([
      { productId: 'p1', quantity: 3, unitPrice: 5, discount: 1.5 },
      { productId: 'p2', quantity: 1, unitPrice: 3, discount: 0 },
    ])
  })

  it('compares money in pesewas, so floating point does not reject a valid discount', async () => {
    // 3 x GH₵0.10 = 0.30 exactly, but 0.1 * 3 is 0.30000000000000004 in floating point.
    const { queue } = make()
    await expect(queue.createSale({ items: [item('p1', 3, 0.1)], discount: 0.3 })).resolves.toBeTruthy()
    await expect(queue.createSale({ items: [item('p1', 3, 0.1)], discount: 0.31 })).rejects.toBeInstanceOf(InvalidSaleError)
  })
})

describe('OfflineQueue listing', () => {
  it('separates waiting sales from rejected ones, and requeue brings a rejected sale back', async () => {
    const { store, queue } = make()
    const a = await queue.createSale({ items: [item()] })
    const b = await queue.createSale({ items: [item()] })
    await store.put({ ...b, status: 'REJECTED', attempts: 3, lastError: 'DEVICE_REVOKED' })

    expect((await queue.pending()).map((s) => s.clientSaleId)).toEqual([a.clientSaleId])
    expect((await queue.rejected()).map((s) => s.clientSaleId)).toEqual([b.clientSaleId])

    await queue.requeue(b.clientSaleId)
    expect(await queue.rejected()).toEqual([])
    expect((await store.get(b.clientSaleId))).toMatchObject({ status: 'PENDING', attempts: 0, lastError: null })
  })

  it('requeue ignores a sale that is not rejected', async () => {
    const { store, queue } = make()
    const a = await queue.createSale({ items: [item()] })
    await queue.requeue(a.clientSaleId)
    await queue.requeue('missing')
    expect(await store.get(a.clientSaleId)).toEqual(a)
  })
})
