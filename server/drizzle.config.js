import 'dotenv/config';
import { readFileSync } from 'node:fs';
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  schema: './src/db/schema.ts',
  out: './drizzle',
  dialect: 'postgresql',
  dbCredentials: {
    host: process.env.PGHOST,
    port: Number(process.env.PGPORT ?? 5432),
    user: process.env.PGUSER,
    password: process.env.PGPASSWORD,
    database: process.env.PGDATABASE,
    ssl:
      process.env.PGSSL === 'true'
        ? process.env.PGSSL_CA
          ? {
            rejectUnauthorized: true,
            ca: readFileSync(process.env.PGSSL_CA, 'utf8'),
          }
          : true
        : false,
  },
});
