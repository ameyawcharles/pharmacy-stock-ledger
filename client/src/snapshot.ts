import type { SaleItemInput } from './types'

/** The stock the device last heard about from the server. A guide only: the shelf is the truth. */
export interface StockSnapshot {
  /** When the snapshot was taken (ISO 8601). */
  asOf: string
  /** productId -> units the server said it had. */
  quantities: Record<string, number>
}

export interface StockWarning {
  productId: string
  requested: number
  /** Undefined when the product is not in the snapshot at all. */
  available: number | undefined
  /** True when the snapshot is older than the freshness limit. */
  stale: boolean
}

/**
 * Tells the cashier a sale may exceed the stock the device knows about. It never blocks the sale:
 * the medicine is on the counter, and the server turns any real shortage into a shortfall.
 * `alreadySold` is what this device has sold since the snapshot, per product.
 */
export function stockWarnings(
  snapshot: StockSnapshot | undefined,
  items: SaleItemInput[],
  options: { now?: Date; staleAfterHours?: number; alreadySold?: Record<string, number> } = {},
): StockWarning[] {
  const staleAfterMs = (options.staleAfterHours ?? 24) * 3_600_000
  const now = (options.now ?? new Date()).getTime()
  const stale = !snapshot || now - new Date(snapshot.asOf).getTime() > staleAfterMs

  const warnings: StockWarning[] = []
  for (const item of items) {
    const known = snapshot?.quantities[item.productId]
    const available = known === undefined ? undefined : known - (options.alreadySold?.[item.productId] ?? 0)
    if (available === undefined || item.quantity > available || stale) {
      warnings.push({ productId: item.productId, requested: item.quantity, available, stale })
    }
  }
  return warnings
}
