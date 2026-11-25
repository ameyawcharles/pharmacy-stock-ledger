import type { QueueStore } from './store'
import type { QueuedSale, SaleItemInput } from './types'

export class OfflineCashOnlyError extends Error {
  constructor() {
    super('Offline sales accept cash only: mobile money and card cannot be verified without a connection')
    this.name = 'OfflineCashOnlyError'
  }
}

export class InvalidSaleError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'InvalidSaleError'
  }
}

export interface NewSale {
  items: SaleItemInput[]
  /** A discount on the whole sale, in GH₵. */
  discount?: number
  notes?: string
  /** Anything but 'CASH' is refused. */
  paymentMethod?: string
}

/** GH₵ to pesewas. Compare money as whole numbers: 0.1 + 0.2 is not 0.3 in floating point. */
const toPesewas = (cedis: number): number => Math.round(cedis * 100)

/**
 * Takes sales while offline. A sale is saved to the store BEFORE createSale returns, so a crash or a
 * dead battery after the cashier sees the receipt cannot lose it.
 */
export class OfflineQueue {
  constructor(
    private readonly store: QueueStore,
    readonly deviceId: string,
    private readonly clock: () => Date = () => new Date(),
    private readonly newId: () => string = () => crypto.randomUUID(),
  ) {}

  async createSale(input: NewSale): Promise<QueuedSale> {
    if ((input.paymentMethod ?? 'CASH') !== 'CASH') throw new OfflineCashOnlyError()

    const items = this.normalise(input.items)
    const discount = input.discount ?? 0
    if (!Number.isFinite(discount) || discount < 0) throw new InvalidSaleError('discount must be 0 or more')
    const subtotal = items.reduce(
      (sum, i) => sum + toPesewas(i.unitPrice) * i.quantity - toPesewas(i.discount ?? 0),
      0,
    )
    if (toPesewas(discount) > subtotal) throw new InvalidSaleError('discount is larger than the sale')

    const seq = await this.store.nextSeq()
    const sale: QueuedSale = {
      clientSaleId: this.newId(),
      deviceId: this.deviceId,
      seq,
      receiptNumber: `OFF-${this.deviceId.slice(0, 4)}-${String(seq).padStart(4, '0')}`,
      occurredAt: this.clock().toISOString(),
      items,
      discount,
      notes: input.notes ?? null,
      status: 'PENDING',
      attempts: 0,
      lastError: null,
    }
    await this.store.put(sale) // durable first, receipt second
    return sale
  }

  async all(): Promise<QueuedSale[]> {
    return this.store.list()
  }
  async pending(): Promise<QueuedSale[]> {
    return (await this.store.list()).filter((s) => s.status !== 'REJECTED')
  }
  async rejected(): Promise<QueuedSale[]> {
    return (await this.store.list()).filter((s) => s.status === 'REJECTED')
  }

  /** After the cause of a rejection is fixed (for example a till was un-revoked), try it again. */
  async requeue(clientSaleId: string): Promise<void> {
    const sale = await this.store.get(clientSaleId)
    if (!sale || sale.status !== 'REJECTED') return
    await this.store.put({ ...sale, status: 'PENDING', attempts: 0, lastError: null })
  }

  /** Checks one sale the same way the server will, and merges repeated lines of the same product and price. */
  private normalise(items: SaleItemInput[]): SaleItemInput[] {
    if (!Array.isArray(items) || items.length === 0) throw new InvalidSaleError('a sale needs at least one item')

    const merged = new Map<string, SaleItemInput>()
    const priceOf = new Map<string, number>()
    for (const item of items) {
      if (!item.productId) throw new InvalidSaleError('every item needs a product')
      if (!Number.isInteger(item.quantity) || item.quantity <= 0) {
        throw new InvalidSaleError('quantity must be a whole number above 0')
      }
      if (!Number.isFinite(item.unitPrice) || item.unitPrice < 0) throw new InvalidSaleError('price must be 0 or more')
      const discount = item.discount ?? 0
      if (!Number.isFinite(discount) || discount < 0) throw new InvalidSaleError('discount must be 0 or more')

      const knownPrice = priceOf.get(item.productId)
      if (knownPrice !== undefined && knownPrice !== item.unitPrice) {
        throw new InvalidSaleError('the same product cannot appear at two different prices in one sale')
      }
      priceOf.set(item.productId, item.unitPrice)

      const existing = merged.get(item.productId)
      merged.set(item.productId, {
        productId: item.productId,
        unitPrice: item.unitPrice,
        quantity: (existing?.quantity ?? 0) + item.quantity,
        discount: (existing?.discount ?? 0) + discount,
      })
    }
    for (const line of merged.values()) {
      if (toPesewas(line.discount ?? 0) > toPesewas(line.unitPrice) * line.quantity) {
        throw new InvalidSaleError('a line discount is larger than the line')
      }
    }
    return [...merged.values()]
  }
}
