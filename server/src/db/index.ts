import { readFileSync } from 'node:fs';

import { drizzle } from 'drizzle-orm/node-postgres';
import pg from 'pg';

import { env } from '../config/env.js';
import * as schema from './schema.js';

export const pool = new pg.Pool({
  host: env.PGHOST,
  port: env.PGPORT,
  user: env.PGUSER,
  password: env.PGPASSWORD,
  database: env.PGDATABASE,
  ssl: env.PGSSL
    ? {
      rejectUnauthorized: true,
      ...(env.PGSSL_CA ? { ca: readFileSync(env.PGSSL_CA, 'utf8') } : {}),
    }
    : false,
});

export const db = drizzle({ client: pool, schema });
