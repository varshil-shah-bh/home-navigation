import { Redis } from 'ioredis';

import { env } from '../config/env.js';

function connect(name: string): Redis {
  const client = new Redis(env.REDIS_URL);
  client.on('error', (err) => console.error(`[redis:${name}]`, err.message));
  return client;
}

/** General commands and PUBLISH. */
export const redis = connect('cmd');

/** A connection in subscriber mode cannot run other commands, so it is dedicated. */
export const redisSub = connect('sub');
