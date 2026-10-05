import type { NextFunction, Request, Response } from 'express';

import { type AuthClaims, verifyToken } from '../auth/jwt.js';

export type AuthLocals = { auth: AuthClaims };

export function requireAuth(req: Request, res: Response<unknown, AuthLocals>, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return res.status(401).json({ message: 'Missing bearer token' });
  }

  try {
    res.locals.auth = verifyToken(header.slice('Bearer '.length));
    next();
  } catch {
    res.status(401).json({ message: 'Invalid or expired token' });
  }
}
