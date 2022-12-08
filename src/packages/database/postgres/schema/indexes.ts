import getLogger from "@cocalc/backend/logger";
import getPool from "@cocalc/database/pool";
import { SCHEMA } from "@cocalc/util/schema";
import { make_valid_name } from "@cocalc/util/misc";

const log = getLogger("db:schema:indexes");

export async function createIndexesQueries(
  table: string
): { name: string; query: string; unique: boolean }[] {
  const schema = SCHEMA[table];
  if (schema == null) {
    throw Error(`invalid table - ${table}`);
  }
  const v = schema.pg_indexes ?? [];
  if (schema.fields.expire != null && !v.includes("expire")) {
    v.push("expire");
  }
  const queries: string[] = [];
  for (let query of v) {
    query = query.trim();
    const name = `${table}_${make_valid_name(query)}_idx`; // this first, then...
    if (query[0] !== "(") {
      // do this **after** making name, since it uses query before parens.
      query = `(${query})`;
    }
    queries.push({ name, query, unique: false });
  }
  const w = schema.pg_unique_indexes ?? [];
  for (let query of w) {
    query = query.trim();
    const name = `${table}_${make_valid_name(query)}_unique_idx`;
    if (query[0] !== "(") {
      query = `(${query})`;
    }
    queries.push({ name, query, unique: true });
  }
  return queries;
}

async function createIndexes(table: string): Promise<void> {
  log.debug("createIndexes", table, " creating SQL query");
  for (const { name, query, unique } of createIndexesQueries(table)) {
    // Shorthand index is just the part in parens.
    // 2020-10-12: it makes total sense to add CONCURRENTLY to this index command to avoid locking up the table,
    // but the first time we tried this in production (postgres 10), it just made "invalid" indices.
    // the problem might be that several create index commands were issued rapidly, which threw this off
    // So, for now, it's probably best to either create them manually first (concurrently) or be
    // aware that this does lock up briefly.
    const fullQuery = `CREATE ${
      unique ? "UNIQUE" : ""
    } INDEX ${name} ON ${table} ${query}`;
    await pool.query(fullQuery);
  }
}
