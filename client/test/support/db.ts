import pg from 'pg'
import { randomUUID } from 'node:crypto'
import type { QueuedSale, SubmitResult, Transport } from '../../src'

// Connection settings come from the usual PG* environment variables (PGHOST, PGUSER, PGPASSWORD).
// scripts/run_tests.sh builds the database these tests use.
export const dbName = process.env.LEDGER_DB ?? 'ledger_test'

/** A superuser connection, for setting up and inspecting data (it ignores row-level security). */
export async function admin(): Promise<pg.Client> {
  const client = new pg.Client({ database: dbName })
  await client.connect()
  return client
}

export async function resetDatabase(a: pg.Client): Promise<void> {
  await a.query(
    'truncate sales, sale_items, sale_item_batches, stock_movements, product_batches, sale_counters, ' +
      'sale_shortfalls, sale_flags, devices, products, users, auth.users restart identity cascade',
  )
}

export async function addUser(a: pg.Client, role: 'ADMIN' | 'PHARMACIST' | 'CASHIER'): Promise<string> {
  const id = randomUUID()
  await a.query('insert into auth.users (id) values ($1)', [id])
  await a.query('insert into users (id, name, email, role) values ($1, $2, $3, $4)', [id, role, `${id}@example.test`, role])
  return id
}

/** A product with batches: [units, days until expiry (null = never expires)]. */
export async function addProduct(
  a: pg.Client,
  name: string,
  batches: Array<[number, number | null]>,
  price = 5,
): Promise<{ productId: string; batchIds: string[] }> {
  const { rows } = await a.query('insert into products (name, "sellingPrice") values ($1, $2) returning id', [name, price])
  const productId = rows[0].id as string
  const batchIds: string[] = []
  for (const [i, [units, days]] of batches.entries()) {
    const b = await a.query(
      'insert into product_batches ("productId", "batchNumber", "expiryDate") ' +
        'values ($1, $2, case when $3::int is null then null else current_date + $3::int end) returning id',
      [productId, `${name}-${i}`, days],
    )
    batchIds.push(b.rows[0].id as string)
    if (units > 0) {
      await a.query(
        `insert into stock_movements ("productId", "batchId", type, quantity, reason) values ($1, $2, 'OPENING', $3, 'test')`,
        [productId, b.rows[0].id, units],
      )
    }
  }
  return { productId, batchIds }
}

export async function addDevice(a: pg.Client, name = 'till'): Promise<string> {
  const { rows } = await a.query('insert into devices (name) values ($1) returning id', [name])
  return rows[0].id as string
}

export const stockOf = async (a: pg.Client, productId: string): Promise<number> =>
  (await a.query('select "stockQuantity" as q from products where id = $1', [productId])).rows[0].q as number

export const count = async (a: pg.Client, table: string): Promise<number> =>
  Number((await a.query(`select count(*) as n from ${table}`)).rows[0].n)

/** Anything the ledger's own self-check reports. An empty list means the books balance. */
export async function integrityProblems(a: pg.Client): Promise<unknown[]> {
  return (await a.query('select kind, id, expected, actual from verify_stock_integrity()')).rows
}

/**
 * The real server, as seen by one signed-in cashier: it calls submit_offline_sale in Postgres with row-level
 * security on. A database error with our own code becomes a rejection; anything else (a dropped connection)
 * is thrown, because then we do not know whether the sale was recorded.
 */
export class PgTransport implements Transport {
  private constructor(private readonly client: pg.Client) {}

  /** userId = null means nobody is signed in. */
  static async connect(userId: string | null): Promise<PgTransport> {
    const client = new pg.Client({ database: dbName })
    await client.connect()
    await client.query('set role authenticated')
    if (userId) await client.query(`select set_config('request.jwt.claim.sub', $1, false)`, [userId])
    return new PgTransport(client)
  }

  async submit(sale: QueuedSale): Promise<SubmitResult> {
    try {
      const { rows } = await this.client.query(
        `select submit_offline_sale($1, $2, $3, $4::jsonb, 'CASH', $5, $6, $7) as r`,
        [sale.deviceId, sale.clientSaleId, sale.occurredAt, JSON.stringify(sale.items), sale.discount, sale.notes, sale.receiptNumber],
      )
      const r = rows[0].r
      return { ok: true, saleId: r.id, saleNumber: r.saleNumber, replayed: r.replayed, shortfalls: r.shortfalls, flags: r.flags }
    } catch (error) {
      const e = error as { code?: string; message?: string }
      if (e.code === 'P0001' && e.message) return { ok: false, code: e.message.split('|')[0]! }
      throw error
    }
  }

  async close(): Promise<void> {
    await this.client.end()
  }
}

export type Plan = 'ok' | 'fail-before' | 'fail-after'

/**
 * Wraps a transport and breaks it on purpose.
 *   fail-before  the request never reaches the server (the sale is NOT recorded)
 *   fail-after   the server records the sale, but the answer is lost (the sale IS recorded, the device does not know)
 */
export class FlakyTransport implements Transport {
  calls = 0
  constructor(private readonly inner: Transport, private plan: (call: number, sale: QueuedSale) => Plan) {}
  setPlan(plan: (call: number, sale: QueuedSale) => Plan): void { this.plan = plan }
  async submit(sale: QueuedSale): Promise<SubmitResult> {
    const mode = this.plan(++this.calls, sale)
    if (mode === 'fail-before') throw new Error('network down')
    const result = await this.inner.submit(sale)
    if (mode === 'fail-after') throw new Error('acknowledgment lost')
    return result
  }
}
