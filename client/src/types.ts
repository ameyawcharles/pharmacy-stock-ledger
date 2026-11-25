// The shapes the device and the server agree on. See docs/adr/0003-offline-selling.md.

export interface SaleItemInput {
  productId: string
  quantity: number
  /** The price the customer actually paid, in GH₵. */
  unitPrice: number
  /** A discount on this line, in GH₵. */
  discount?: number
}

/**
 * Where a queued sale is in its life. A sale that the server has acknowledged is REMOVED from
 * the queue, so there is no "synced" status here.
 *
 *   PENDING   saved on the device, not yet acknowledged
 *   SENDING   a send is in flight (if the app dies now, it comes back as PENDING)
 *   REJECTED  the server refused it for good; it stays so a person can deal with it
 */
export type QueuedStatus = 'PENDING' | 'SENDING' | 'REJECTED'

export interface QueuedSale {
  /** Created on the device before the receipt is shown. The server uses it to spot duplicates. */
  clientSaleId: string
  deviceId: string
  /** Position in this device's history. Orders the queue and numbers the receipts. */
  seq: number
  /** What the customer's paper or screen receipt says, e.g. OFF-1a2b-0007. */
  receiptNumber: string
  /** The device clock when the sale happened (ISO 8601). Never trusted for accounting. */
  occurredAt: string
  items: SaleItemInput[]
  /** A discount on the whole sale, in GH₵. */
  discount: number
  notes: string | null
  status: QueuedStatus
  attempts: number
  lastError: string | null
}

export interface Shortfall {
  id: string
  productId: string
  quantity: number
  status: string
}

export interface SaleFlag {
  code: string
  detail: unknown
}

export interface SubmitAccepted {
  ok: true
  saleId: string
  saleNumber: string
  /** True when the server had already recorded this sale (a retry or a lost acknowledgment). */
  replayed: boolean
  shortfalls: Shortfall[]
  flags: SaleFlag[]
}

/** The server understood the request and said no. Retrying the same sale will not change that. */
export interface SubmitRejected {
  ok: false
  code: string
}

export type SubmitResult = SubmitAccepted | SubmitRejected

/**
 * How a sale reaches the server.
 *
 * Contract: RESOLVE with a result when the server answered. THROW when the outcome is unknown
 * (no network, timeout, connection dropped), because the sale may or may not have been recorded.
 * The engine treats a throw as "try again later", which is safe because submission is idempotent.
 */
export interface Transport {
  submit(sale: QueuedSale): Promise<SubmitResult>
}
