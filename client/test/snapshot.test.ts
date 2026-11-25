import { describe, it, expect } from 'vitest'
import { stockWarnings, type StockSnapshot } from '../src'

const now = new Date('2026-11-23T12:00:00Z')
const fresh: StockSnapshot = { asOf: '2026-11-23T08:00:00Z', quantities: { a: 10, b: 2 } }
const old: StockSnapshot = { asOf: '2026-11-20T08:00:00Z', quantities: { a: 10 } }

describe('stockWarnings', () => {
  it('is quiet when the snapshot is fresh and has enough', () => {
    expect(stockWarnings(fresh, [{ productId: 'a', quantity: 3, unitPrice: 1 }], { now })).toEqual([])
  })
  it('warns when the sale is more than the snapshot says', () => {
    expect(stockWarnings(fresh, [{ productId: 'b', quantity: 5, unitPrice: 1 }], { now })).toEqual([
      { productId: 'b', requested: 5, available: 2, stale: false },
    ])
  })
  it('subtracts what this device already sold since the snapshot', () => {
    const w = stockWarnings(fresh, [{ productId: 'a', quantity: 4, unitPrice: 1 }], { now, alreadySold: { a: 8 } })
    expect(w).toEqual([{ productId: 'a', requested: 4, available: 2, stale: false }])
  })
  it('warns about a product the snapshot does not know', () => {
    expect(stockWarnings(fresh, [{ productId: 'zzz', quantity: 1, unitPrice: 1 }], { now })[0]).toMatchObject({ productId: 'zzz', available: undefined })
  })
  it('warns on every line when the snapshot is stale, and says so', () => {
    const w = stockWarnings(old, [{ productId: 'a', quantity: 1, unitPrice: 1 }], { now })
    expect(w).toEqual([{ productId: 'a', requested: 1, available: 10, stale: true }])
  })
  it('warns when there is no snapshot at all', () => {
    expect(stockWarnings(undefined, [{ productId: 'a', quantity: 1, unitPrice: 1 }], { now })[0]).toMatchObject({ stale: true, available: undefined })
  })
})
