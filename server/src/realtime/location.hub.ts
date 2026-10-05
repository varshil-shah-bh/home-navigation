import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';

import { eq } from 'drizzle-orm';
import { type RawData, WebSocket, WebSocketServer } from 'ws';
import { z } from 'zod';

import { verifyToken } from '../auth/jwt.js';
import { db } from '../db/index.js';
import { users } from '../db/schema.js';
import type { UserRole } from '../models/user.js';
import { redis, redisSub } from './redis.js';

/**
 * Fan-out of live employee locations:
 *   employee socket -> Redis PUBLISH -> every server instance's SUBSCRIBE -> its admin sockets.
 * The latest fix per employee is also kept in Redis (with a TTL) so a new admin gets a snapshot.
 */

const CHANNEL = 'locations:events';
const KEY_PREFIX = 'location:user:';
const LOCATION_TTL_SECONDS = 45;
const HEARTBEAT_MS = 15_000;
const MIN_UPDATE_INTERVAL_MS = 200;
const MAX_BUFFERED_BYTES = 1_000_000;

// Metres in map space; generous bounds just reject garbage.
const locationMessage = z.object({
  type: z.literal('location'),
  x: z.number().finite().min(0).max(1000),
  y: z.number().finite().min(0).max(1000),
});

interface Client {
  ws: WebSocket;
  userId: string;
  name: string;
  role: UserRole;
  alive: boolean;
  lastUpdateAt: number;
}

const clients = new Map<WebSocket, Client>();

const keyFor = (userId: string) => `${KEY_PREFIX}${userId}`;
const logError = (err: unknown) => console.error('[ws]', err instanceof Error ? err.message : err);

async function authenticate(req: IncomingMessage) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) return null;
  try {
    const claims = verifyToken(header.slice('Bearer '.length));
    const user = await db.query.users.findFirst({
      where: eq(users.id, claims.sub),
      columns: { id: true, name: true, role: true },
    });
    return user ?? null;
  } catch {
    return null;
  }
}

function reject(socket: Duplex, status: number, text: string) {
  socket.write(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\n\r\n`);
  socket.destroy();
}

async function snapshot(): Promise<unknown[]> {
  const keys: string[] = [];
  for await (const batch of redis.scanStream({ match: `${KEY_PREFIX}*`, count: 100 })) {
    keys.push(...(batch as string[]));
  }
  if (keys.length === 0) return [];
  const values = await redis.mget(keys);
  return values.flatMap((v) => (v ? [JSON.parse(v)] : []));
}

function onMessage(client: Client, data: RawData) {
  if (client.role !== 'employee') return;

  const now = Date.now();
  if (now - client.lastUpdateAt < MIN_UPDATE_INTERVAL_MS) return;

  let parsed: ReturnType<typeof locationMessage.safeParse>;
  try {
    parsed = locationMessage.safeParse(JSON.parse(data.toString()));
  } catch {
    return;
  }
  if (!parsed.success) return;

  client.lastUpdateAt = now;
  const payload = JSON.stringify({
    type: 'location',
    userId: client.userId,
    name: client.name,
    x: parsed.data.x,
    y: parsed.data.y,
    ts: now,
  });
  redis
    .multi()
    .set(keyFor(client.userId), payload, 'EX', LOCATION_TTL_SECONDS)
    .publish(CHANNEL, payload)
    .exec()
    .catch(logError);
}

function onClose(client: Client) {
  clients.delete(client.ws);
  if (client.role !== 'employee') return;

  const stillConnected = [...clients.values()].some((c) => c.userId === client.userId);
  if (stillConnected) return;

  redis
    .multi()
    .del(keyFor(client.userId))
    .publish(CHANNEL, JSON.stringify({ type: 'offline', userId: client.userId }))
    .exec()
    .catch(logError);
}

export async function attachLocationHub(server: Server) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 });

  await redisSub.subscribe(CHANNEL);
  redisSub.on('message', (channel, message) => {
    if (channel !== CHANNEL) return;
    for (const { ws, role } of clients.values()) {
      if (role === 'admin' && ws.readyState === WebSocket.OPEN && ws.bufferedAmount < MAX_BUFFERED_BYTES) {
        ws.send(message);
      }
    }
  });

  function onConnection(ws: WebSocket, user: { id: string; name: string; role: UserRole }) {
    const client: Client = {
      ws,
      userId: user.id,
      name: user.name,
      role: user.role,
      alive: true,
      lastUpdateAt: 0,
    };
    clients.set(ws, client);

    ws.on('pong', () => {
      client.alive = true;
      // Keeps a stationary but connected employee from expiring.
      if (client.role === 'employee') {
        redis.expire(keyFor(client.userId), LOCATION_TTL_SECONDS).catch(logError);
      }
    });
    ws.on('message', (data) => onMessage(client, data));
    ws.on('close', () => onClose(client));
    ws.on('error', logError);

    if (client.role === 'admin') {
      snapshot()
        .then((list) => {
          if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'snapshot', users: list }));
        })
        .catch(logError);
    }
  }

  server.on('upgrade', (req, socket, head) => {
    socket.on('error', logError);
    void (async () => {
      const path = new URL(req.url ?? '/', 'http://localhost').pathname;
      if (path !== '/ws') return reject(socket, 404, 'Not Found');

      const user = await authenticate(req);
      if (!user) return reject(socket, 401, 'Unauthorized');

      wss.handleUpgrade(req, socket, head, (ws) => onConnection(ws, user));
    })().catch((err) => {
      logError(err);
      reject(socket, 500, 'Internal Server Error');
    });
  });

  const heartbeat = setInterval(() => {
    for (const client of clients.values()) {
      if (!client.alive) {
        client.ws.terminate();
        continue;
      }
      client.alive = false;
      client.ws.ping();
    }
  }, HEARTBEAT_MS);

  return {
    close() {
      clearInterval(heartbeat);
      for (const { ws } of clients.values()) ws.close(1001, 'Server shutting down');
      wss.close();
    },
  };
}
