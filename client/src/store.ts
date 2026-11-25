import type { QueuedSale } from './types'

/**
 * Where queued sales are kept on the device. It must survive the app being closed, which is why
 * a sale is written here BEFORE the cashier is shown a receipt.
 */
export interface QueueStore {
  put(sale: QueuedSale): Promise<void>
  get(clientSaleId: string): Promise<QueuedSale | undefined>
  /** Every queued sale, oldest first (by seq). */
  list(): Promise<QueuedSale[]>
  remove(clientSaleId: string): Promise<void>
  /** A number that goes up by one on every call and never repeats, even across restarts. */
  nextSeq(): Promise<number>
}

/** For tests, and for anything that does not need to survive a restart. */
export class MemoryStore implements QueueStore {
  private readonly sales = new Map<string, QueuedSale>()
  private seq = 0

  async put(sale: QueuedSale): Promise<void> {
    this.sales.set(sale.clientSaleId, structuredClone(sale))
  }
  async get(id: string): Promise<QueuedSale | undefined> {
    const sale = this.sales.get(id)
    return sale ? structuredClone(sale) : undefined
  }
  async list(): Promise<QueuedSale[]> {
    return [...this.sales.values()].map((s) => structuredClone(s)).sort((a, b) => a.seq - b.seq)
  }
  async remove(id: string): Promise<void> {
    this.sales.delete(id)
  }
  async nextSeq(): Promise<number> {
    this.seq += 1
    return this.seq
  }
}

const SALES = 'sales'
const META = 'meta'

function requestToPromise<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

function transactionDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
    tx.onabort = () => reject(tx.error ?? new Error('IndexedDB transaction aborted'))
  })
}

/** The browser's durable storage. Two object stores: the queued sales, and a small meta store. */
export class IndexedDbStore implements QueueStore {
  private constructor(private readonly db: IDBDatabase) {}

  static async open(name = 'offline-sales', factory: IDBFactory = indexedDB): Promise<IndexedDbStore> {
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = factory.open(name, 1)
      request.onupgradeneeded = () => {
        request.result.createObjectStore(SALES, { keyPath: 'clientSaleId' })
        request.result.createObjectStore(META)
      }
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
    return new IndexedDbStore(db)
  }

  close(): void {
    this.db.close()
  }

  async put(sale: QueuedSale): Promise<void> {
    const tx = this.db.transaction(SALES, 'readwrite')
    tx.objectStore(SALES).put(sale)
    await transactionDone(tx)
  }

  async get(id: string): Promise<QueuedSale | undefined> {
    const tx = this.db.transaction(SALES, 'readonly')
    return (await requestToPromise(tx.objectStore(SALES).get(id))) as QueuedSale | undefined
  }

  async list(): Promise<QueuedSale[]> {
    const tx = this.db.transaction(SALES, 'readonly')
    const all = (await requestToPromise(tx.objectStore(SALES).getAll())) as QueuedSale[]
    return all.sort((a, b) => a.seq - b.seq)
  }

  async remove(id: string): Promise<void> {
    const tx = this.db.transaction(SALES, 'readwrite')
    tx.objectStore(SALES).delete(id)
    await transactionDone(tx)
  }

  async nextSeq(): Promise<number> {
    // Read and write in ONE transaction, so two callers can never get the same number.
    const tx = this.db.transaction(META, 'readwrite')
    const meta = tx.objectStore(META)
    const current = ((await requestToPromise(meta.get('seq'))) as number | undefined) ?? 0
    const next = current + 1
    meta.put(next, 'seq')
    await transactionDone(tx)
    return next
  }
}
