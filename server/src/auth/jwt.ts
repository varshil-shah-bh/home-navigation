import jwt from 'jsonwebtoken';

import { env } from '../config/env.js';
import type { UserRole } from '../models/user.js';

export interface AuthClaims {
  sub: string;
  role: UserRole;
}

export function signToken(claims: AuthClaims): string {
  return jwt.sign({ role: claims.role }, env.JWT_SECRET, {
    subject: claims.sub,
    algorithm: 'HS256',
    expiresIn: env.JWT_EXPIRES_IN as jwt.SignOptions['expiresIn'],
  });
}

export function verifyToken(token: string): AuthClaims {
  const payload = jwt.verify(token, env.JWT_SECRET, { algorithms: ['HS256'] });
  if (typeof payload === 'string' || !payload.sub) {
    throw new Error('Invalid token payload');
  }
  return { sub: payload.sub, role: payload.role as UserRole };
}
