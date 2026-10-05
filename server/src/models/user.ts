import { z } from 'zod';

import { userRole, users } from '../db/schema.js';

export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;
export type UserRole = (typeof userRole.enumValues)[number];

/** Shape returned to clients — never includes the password hash. */
export type PublicUser = Omit<User, 'passwordHash' | 'updatedAt'>;

export function toPublicUser(user: User): PublicUser {
  return {
    id: user.id,
    name: user.name,
    email: user.email,
    role: user.role,
    hasDisability: user.hasDisability,
    createdAt: user.createdAt,
  };
}

const email = z.string().trim().toLowerCase().email('Enter a valid email').max(255);
// bcrypt only uses the first 72 bytes.
const password = z.string().min(8, 'Password must be at least 8 characters').max(72);

export const signupSchema = z.object({
  name: z.string().trim().min(2, 'Name must be at least 2 characters').max(100),
  email,
  password,
  role: z.enum(userRole.enumValues),
  hasDisability: z.boolean(),
});

export const loginSchema = z.object({
  email,
  password: z.string().min(1).max(72),
});

export type SignupInput = z.infer<typeof signupSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
