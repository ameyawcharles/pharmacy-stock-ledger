import type { QueueStore } from './store'
import type { QueuedSale, SaleFlag, Shortfall, SubmitAccepted, Transport } from './types'

export interface BackoffPolicy {
  baseMs: number
  capMs: number
  /** 0.2 means up to 20% extra, so many tills do not all retry at the same instant. */
  jitter: number
}

export const defaultBackoff: BackoffPolicy = { baseMs: 1_000, capMs: 60_000, jitter: 0.2 }

/** How long to wait before retry number `attempt` (0, 1, 2, ...): doubles each time, never above the cap. */
export function backoffDelay(attempt: number, policy: BackoffPolicy, random: () => number = Math.random): number {
  const raw = policy.baseMs * 2 ** attempt * (1 + policy.jitter * random())
  return Math.round(Math.min(policy.capMs, raw))
}

export interface SyncHooks {
  /** The server recorded the sale (it is now gone from the queue). */
  onSynced?(sale: QueuedSale, result: SubmitAccepted): void
  /** The sale was recorded but some units were not in stock: a pharmacist has to resolve it. */
  onShortfall?(sale: QueuedSale, shortfalls: Shortfall[]): void
  /** The sale was recorded with notes attached (price mismatch, clock skew, long offline). */
  onFlags?(sale: QueuedSale, flags: SaleFlag[]): void
  /** The server refused the sale for good. It stays in the queue. */
  onRejected?(sale: QueuedSale, code: string): void
  /** The signed-in session ended. Sales stay queued until the cashier signs in again. */
  onAuthRequired?(): void
}

export type StopReason = 'DRAINED' | 'NETWORK' | 'AUTH' | 'BUSY'

export interface SyncReport {
  synced: number
  rejected: number
  /** Sales still waiting to be acknowledged (rejected ones are not counted). */
  remaining: number
  stoppedBy: StopReason
}

/** Server answers that mean "sign in again", not "this sale is bad". Never reject a sale for these. */
const AUTH_CODES = new Set(['UNAUTHORIZED'])

export interface SyncOptions {
  backoff?: BackoffPolicy
  sleep?: (ms: number) => Promise<void>
  random?: () => number
}

/**
 * Sends the queue to the server, oldest first. Rules (ADR 0003):
 *  - A sale leaves the queue only after the server acknowledged it.
 *  - If the outcome is unknown (the call threw), the sale stays and is retried. This is safe because the
 *    server recognises a sale it has already recorded.
 *  - A sale the server refuses is parked as REJECTED and the rest of the queue carries on.
 */
export class SyncEngine {
  private busy = false

  constructor(
    private readonly store: QueueStore,
    private readonly transport: Transport,
    private readonly hooks: SyncHooks = {},
    private readonly options: SyncOptions = {},
  ) {}

  /**
   * Call once when the app starts. A sale left in SENDING means the app died mid-send, and we do not
   * know whether the server got it. Put it back to PENDING: re-sending is harmless.
   */
  async recover(): Promise<number> {
    let recovered = 0
    for (const sale of await this.store.list()) {
      if (sale.status === 'SENDING') {
        await this.store.put({ ...sale, status: 'PENDING' })
        recovered += 1
      }
    }
    return recovered
  }

  /** One pass over the queue. */
  async syncOnce(): Promise<SyncReport> {
    if (this.busy) return { synced: 0, rejected: 0, remaining: await this.remaining(), stoppedBy: 'BUSY' }
    this.busy = true
    try {
      return await this.pass()
    } finally {
      this.busy = false
    }
  }

  /** Keeps trying, backing off after each network failure, until the queue is empty, a sign-in is needed, or we give up. */
  async runUntilDrained(options: { maxRounds?: number; signal?: AbortSignal } = {}): Promise<SyncReport> {
    const maxRounds = options.maxRounds ?? 20
    const policy = this.options.backoff ?? defaultBackoff
    const sleep = this.options.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)))
    const total = { synced: 0, rejected: 0 }
    let failures = 0
    let report = await this.syncOnce()

    for (let round = 0; round < maxRounds; round++) {
      total.synced += report.synced
      total.rejected += report.rejected
      if (report.synced > 0) failures = 0
      if (report.stoppedBy !== 'NETWORK' || options.signal?.aborted) break
      await sleep(backoffDelay(failures, policy, this.options.random))
      failures += 1
      report = await this.syncOnce()
    }
    return { ...report, synced: total.synced, rejected: total.rejected }
  }

  private async remaining(): Promise<number> {
    return (await this.store.list()).filter((s) => s.status !== 'REJECTED').length
  }

  private async pass(): Promise<SyncReport> {
    let synced = 0
    let rejected = 0
    let stoppedBy: StopReason = 'DRAINED'

    const queue = (await this.store.list()).filter((s) => s.status === 'PENDING')
    for (const sale of queue) {
      await this.store.put({ ...sale, status: 'SENDING', attempts: sale.attempts + 1 })

      let result
      try {
        result = await this.transport.submit(sale)
      } catch (error) {
        // Outcome unknown. Keep the sale, and stop: the network is probably down for the rest too.
        await this.store.put({ ...sale, status: 'PENDING', attempts: sale.attempts + 1, lastError: describe(error) })
        stoppedBy = 'NETWORK'
        break
      }

      if (result.ok) {
        await this.store.remove(sale.clientSaleId) // only now is the sale safe to forget
        synced += 1
        this.tell(() => this.hooks.onSynced?.(sale, result))
        if (result.shortfalls.length > 0) this.tell(() => this.hooks.onShortfall?.(sale, result.shortfalls))
        if (result.flags.length > 0) this.tell(() => this.hooks.onFlags?.(sale, result.flags))
      } else if (AUTH_CODES.has(result.code)) {
        await this.store.put({ ...sale, status: 'PENDING', attempts: sale.attempts, lastError: result.code })
        this.tell(() => this.hooks.onAuthRequired?.())
        stoppedBy = 'AUTH'
        break
      } else {
        await this.store.put({ ...sale, status: 'REJECTED', attempts: sale.attempts + 1, lastError: result.code })
        rejected += 1
        this.tell(() => this.hooks.onRejected?.(sale, result.code))
        // carry on: one bad sale must not block the ones behind it
      }
    }

    return { synced, rejected, remaining: await this.remaining(), stoppedBy }
  }

  /** A faulty screen callback must never stop the queue from draining. */
  private tell(callback: () => void): void {
    try {
      callback()
    } catch {
      /* ignore */
    }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
