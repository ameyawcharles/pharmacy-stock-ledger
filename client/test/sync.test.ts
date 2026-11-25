import { describe, it, expect } from 'vitest'
import {
  MemoryStore, OfflineQueue, SyncEngine, backoffDelay, defaultBackoff,
  type QueuedSale, type SubmitResult, type Transport,
} from '../src'

const accepted = (n: number, extra: Partial<Extract<SubmitResult, { ok: true }>> = {}): SubmitResult => ({
  ok: true, saleId: `id-${n}`, saleNumber: `POS-${n}`, replayed: false, shortfalls: [], flags: [], ...extra,
})

/** A transport you control: it answers from a script, and records every sale it was asked to send. */
class ScriptedTransport implements Transport {
  sent: string[] = []
  constructor(private readonly script: (sale: QueuedSale, call: number) => SubmitResult | Error) {}
  async submit(sale: QueuedSale): Promise<SubmitResult> {
    this.sent.push(sale.receiptNumber)
    const out = this.script(sale, this.sent.length)
    if (out instanceof Error) throw out
    return out
  }
}

async function setup(count: number, script: ConstructorParameters<typeof ScriptedTransport>[0], hooks = {}, options = {}) {
  const store = new MemoryStore()
  const queue = new OfflineQueue(store, 'dev1abcd-0000-4000-8000-000000000000')
  for (let i = 0; i < count; i++) await queue.createSale({ items: [{ productId: 'p', quantity: 1, unitPrice: 5 }] })
  const transport = new ScriptedTransport(script)
  return { store, queue, transport, engine: new SyncEngine(store, transport, hooks, options) }
}

describe('SyncEngine.syncOnce', () => {
  it('sends oldest first and removes each sale only after it is acknowledged', async () => {
    const { store, transport, engine } = await setup(3, (_s, call) => accepted(call))
    const report = await engine.syncOnce()
    expect(transport.sent).toEqual(['OFF-dev1-0001', 'OFF-dev1-0002', 'OFF-dev1-0003'])
    expect(report).toEqual({ synced: 3, rejected: 0, remaining: 0, stoppedBy: 'DRAINED' })
    expect(await store.list()).toEqual([])
  })

  it('keeps the sale in storage while the send is in flight, so a crash then cannot lose it', async () => {
    const store = new MemoryStore()
    const sale = await new OfflineQueue(store, 'dev1abcd').createSale({ items: [{ productId: 'p', quantity: 1, unitPrice: 5 }] })
    let duringSend: QueuedSale | undefined
    const engine = new SyncEngine(store, {
      submit: async (s) => {
        duringSend = await store.get(s.clientSaleId) // look at the storage while the call is outstanding
        return accepted(1)
      },
    })
    await engine.syncOnce()
    expect(duringSend).toMatchObject({ clientSaleId: sale.clientSaleId, status: 'SENDING' })
    expect(await store.get(sale.clientSaleId)).toBeUndefined() // gone only after the acknowledgment
  })

  it('on a network failure keeps the sale, counts the attempt and stops', async () => {
    const { store, transport, engine } = await setup(3, (_s, call) => (call === 2 ? new Error('timeout') : accepted(call)))
    const report = await engine.syncOnce()
    expect(report).toEqual({ synced: 1, rejected: 0, remaining: 2, stoppedBy: 'NETWORK' })
    expect(transport.sent).toHaveLength(2) // the third was never tried
    const left = await store.list()
    expect(left.map((s) => s.receiptNumber)).toEqual(['OFF-dev1-0002', 'OFF-dev1-0003'])
    expect(left[0]).toMatchObject({ status: 'PENDING', attempts: 1, lastError: 'timeout' })
  })

  it('parks a refused sale as REJECTED and carries on with the rest', async () => {
    const rejected: string[] = []
    const { store, queue, engine } = await setup(
      3,
      (s, call) => (s.receiptNumber.endsWith('0002') ? { ok: false, code: 'DEVICE_REVOKED' } : accepted(call)),
      { onRejected: (s: QueuedSale, code: string) => rejected.push(`${s.receiptNumber}:${code}`) },
    )
    const report = await engine.syncOnce()
    expect(report).toEqual({ synced: 2, rejected: 1, remaining: 0, stoppedBy: 'DRAINED' })
    expect(rejected).toEqual(['OFF-dev1-0002:DEVICE_REVOKED'])
    const parked = await queue.rejected()
    expect(parked).toHaveLength(1)
    expect(parked[0]).toMatchObject({ status: 'REJECTED', lastError: 'DEVICE_REVOKED', attempts: 1 })
    expect(await store.list()).toHaveLength(1)
  })

  it('a rejected sale is not sent again on the next pass', async () => {
    const { transport, engine } = await setup(1, () => ({ ok: false, code: 'OFFLINE_CASH_ONLY' }))
    await engine.syncOnce()
    await engine.syncOnce()
    expect(transport.sent).toHaveLength(1)
  })

  it('when the sign-in has expired, stops, keeps the sale PENDING and does not count an attempt', async () => {
    let asked = 0
    const { store, engine } = await setup(2, () => ({ ok: false, code: 'UNAUTHORIZED' }), { onAuthRequired: () => asked++ })
    const report = await engine.syncOnce()
    expect(report).toMatchObject({ synced: 0, rejected: 0, remaining: 2, stoppedBy: 'AUTH' })
    expect(asked).toBe(1)
    expect((await store.list()).map((s) => [s.status, s.attempts])).toEqual([['PENDING', 0], ['PENDING', 0]])
  })

  it('tells the screen about shortfalls and flags', async () => {
    const heard: string[] = []
    const { engine } = await setup(
      1,
      () => accepted(1, {
        shortfalls: [{ id: 's1', productId: 'p', quantity: 2, status: 'OPEN' }],
        flags: [{ code: 'PRICE_MISMATCH', detail: {} }],
      }),
      {
        onSynced: () => heard.push('synced'),
        onShortfall: (_s: QueuedSale, sf: { quantity: number }[]) => heard.push(`shortfall:${sf[0]!.quantity}`),
        onFlags: (_s: QueuedSale, fl: { code: string }[]) => heard.push(`flag:${fl[0]!.code}`),
      },
    )
    await engine.syncOnce()
    expect(heard).toEqual(['synced', 'shortfall:2', 'flag:PRICE_MISMATCH'])
  })

  it('a faulty screen callback cannot stop the queue draining', async () => {
    const { store, engine } = await setup(2, (_s, call) => accepted(call), { onSynced: () => { throw new Error('UI bug') } })
    expect((await engine.syncOnce()).synced).toBe(2)
    expect(await store.list()).toEqual([])
  })

  it('does not run two passes at once', async () => {
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    const store = new MemoryStore()
    await new OfflineQueue(store, 'dev1abcd').createSale({ items: [{ productId: 'p', quantity: 1, unitPrice: 5 }] })
    const sent: string[] = []
    const engine = new SyncEngine(store, { submit: async (s) => { sent.push(s.receiptNumber); await gate; return accepted(1) } })
    const first = engine.syncOnce()
    const second = await engine.syncOnce()
    expect(second.stoppedBy).toBe('BUSY')
    release()
    expect((await first).synced).toBe(1)
    expect(sent).toHaveLength(1)
  })
})

describe('SyncEngine.recover', () => {
  it('puts a sale left SENDING by a crash back to PENDING, and it is then sent again', async () => {
    const { store, transport, engine } = await setup(2, (_s, call) => accepted(call))
    const [first] = await store.list()
    await store.put({ ...first!, status: 'SENDING' }) // the app died mid-send
    expect(await engine.recover()).toBe(1)
    expect((await store.list())[0]!.status).toBe('PENDING')
    await engine.syncOnce()
    expect(transport.sent).toContain('OFF-dev1-0001')
  })
  it('leaves everything else alone', async () => {
    const { store, engine } = await setup(2, (_s, call) => accepted(call))
    expect(await engine.recover()).toBe(0)
    expect((await store.list()).every((s) => s.status === 'PENDING')).toBe(true)
  })
})

describe('backoffDelay', () => {
  const policy = { baseMs: 1000, capMs: 60_000, jitter: 0.2 }
  it('doubles each time', () => {
    expect([0, 1, 2, 3].map((n) => backoffDelay(n, policy, () => 0))).toEqual([1000, 2000, 4000, 8000])
  })
  it('never goes above the cap', () => {
    expect(backoffDelay(30, policy, () => 0)).toBe(60_000)
    expect(backoffDelay(30, policy, () => 1)).toBe(60_000)
  })
  it('adds up to the jitter fraction', () => {
    expect(backoffDelay(0, policy, () => 1)).toBe(1200)
    expect(backoffDelay(0, policy, () => 0.5)).toBe(1100)
  })
  it('has sensible defaults', () => {
    expect(defaultBackoff).toEqual({ baseMs: 1000, capMs: 60_000, jitter: 0.2 })
  })
})

describe('SyncEngine.runUntilDrained', () => {
  it('waits longer after each network failure, then drains, and resets after progress', async () => {
    const waits: number[] = []
    const { store, engine } = await setup(
      2,
      (_s, call) => (call <= 3 ? new Error('offline') : accepted(call)),
      {},
      { sleep: async (ms: number) => { waits.push(ms) }, random: () => 0 },
    )
    const report = await engine.runUntilDrained()
    expect(waits).toEqual([1000, 2000, 4000])
    expect(report).toMatchObject({ synced: 2, remaining: 0, stoppedBy: 'DRAINED' })
    expect(await store.list()).toEqual([])
  })

  it('gives up after maxRounds and keeps the sales', async () => {
    const { store, engine } = await setup(1, () => new Error('offline'), {}, { sleep: async () => {}, random: () => 0 })
    const report = await engine.runUntilDrained({ maxRounds: 3 })
    expect(report).toMatchObject({ synced: 0, remaining: 1, stoppedBy: 'NETWORK' })
    expect(await store.list()).toHaveLength(1)
  })

  it('stops when asked to', async () => {
    const controller = new AbortController()
    const { transport, engine } = await setup(1, () => new Error('offline'), {}, {
      sleep: async () => controller.abort(), random: () => 0,
    })
    await engine.runUntilDrained({ signal: controller.signal })
    expect(transport.sent).toHaveLength(2) // one try, one sleep (which aborted), one more try, then stop
  })

  it('stops at once when the sign-in has expired instead of retrying', async () => {
    const waits: number[] = []
    const { engine } = await setup(1, () => ({ ok: false, code: 'UNAUTHORIZED' }), {}, { sleep: async (ms: number) => { waits.push(ms) } })
    expect((await engine.runUntilDrained()).stoppedBy).toBe('AUTH')
    expect(waits).toEqual([])
  })
})
