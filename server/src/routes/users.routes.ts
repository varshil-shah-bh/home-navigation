import { asc, eq } from 'drizzle-orm';
import { type Response, Router } from 'express';

import { db } from '../db/index.js';
import { users } from '../db/schema.js';
import { type AuthLocals, requireAuth } from '../middleware/auth.js';

export const usersRouter = Router();

usersRouter.get('/employees', requireAuth, async (_req, res: Response<unknown, AuthLocals>) => {
  if (res.locals.auth.role !== 'admin') {
    return res.status(403).json({ message: 'Admins only' });
  }
  const employees = await db.query.users.findMany({
    where: eq(users.role, 'employee'),
    columns: { id: true, name: true, email: true },
    orderBy: asc(users.name),
  });
  res.json({ employees });
});
