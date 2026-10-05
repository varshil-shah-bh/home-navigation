import bcrypt from 'bcryptjs';
import { eq } from 'drizzle-orm';
import { type Response, Router } from 'express';
import { rateLimit } from 'express-rate-limit';

import { signToken } from '../auth/jwt.js';
import { db } from '../db/index.js';
import { users } from '../db/schema.js';
import { type AuthLocals, requireAuth } from '../middleware/auth.js';
import { loginSchema, signupSchema, toPublicUser } from '../models/user.js';

const BCRYPT_ROUNDS = 12;
// Compared against when the email is unknown so response time doesn't reveal which emails exist.
const DUMMY_HASH = bcrypt.hashSync('dummy-password-for-timing', BCRYPT_ROUNDS);

const credentialLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 20,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { message: 'Too many attempts, please try again later' },
});

function isUniqueViolation(err: unknown): boolean {
  const e = err as { code?: string; cause?: { code?: string } };
  return e?.code === '23505' || e?.cause?.code === '23505';
}

export const authRouter = Router();

authRouter.post('/signup', credentialLimiter, async (req, res) => {
  const parsed = signupSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ message: parsed.error.issues[0]?.message ?? 'Invalid input' });
  }
  const { name, email, password, role, hasDisability } = parsed.data;

  const existing = await db.query.users.findFirst({ where: eq(users.email, email), columns: { id: true } });
  if (existing) {
    return res.status(409).json({ message: 'An account with this email already exists' });
  }

  try {
    const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);
    const [user] = await db
      .insert(users)
      .values({ name, email, passwordHash, role, hasDisability })
      .returning();

    const token = signToken({ sub: user.id, role: user.role });
    res.status(201).json({ token, user: toPublicUser(user) });
  } catch (err) {
    if (isUniqueViolation(err)) {
      return res.status(409).json({ message: 'An account with this email already exists' });
    }
    throw err;
  }
});

authRouter.post('/login', credentialLimiter, async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ message: 'Invalid email or password' });
  }
  const { email, password } = parsed.data;

  const user = await db.query.users.findFirst({ where: eq(users.email, email) });
  const valid = await bcrypt.compare(password, user?.passwordHash ?? DUMMY_HASH);
  if (!user || !valid) {
    return res.status(401).json({ message: 'Invalid email or password' });
  }

  const token = signToken({ sub: user.id, role: user.role });
  res.json({ token, user: toPublicUser(user) });
});

authRouter.get('/me', requireAuth, async (_req, res: Response<unknown, AuthLocals>) => {
  const user = await db.query.users.findFirst({ where: eq(users.id, res.locals.auth.sub) });
  if (!user) {
    return res.status(401).json({ message: 'Account no longer exists' });
  }
  res.json({ user: toPublicUser(user) });
});
