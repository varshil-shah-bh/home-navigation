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
 * Realtime hub over one WebSocket endpoint. Every cross-user message goes through Redis
 * pub/sub, so each server instance fans it out to its own sockets:
 *   - presence + live locations: employee -> PUBLISH -> admin sockets
 *   - call signalling (WebRTC offer/answer/ICE): caller -> PUBLISH -> callee's socket
 * Media never touches the server; peers connect directly using STUN.
 */

const LOCATION_CHANNEL = 'locations:events';
const SIGNAL_CHANNEL = 'signals:events';
const LOCATION_PREFIX = 'location:user:';
const PRESENCE_PREFIX = 'presence:user:';
const KEY_TTL_SECONDS = 45;
const HEARTBEAT_MS = 15_000;
const MIN_UPDATE_INTERVAL_MS = 200;
const MAX_BUFFERED_BYTES = 1_000_000;
const SIGNAL_WINDOW_MS = 10_000;
const MAX_SIGNALS_PER_WINDOW = 60;

// Metres in map space; generous bounds just reject garbage.
const locationMessage = z.object({
  type: z.literal('location'),
  x: z.number().finite().min(0).max(1000),
  y: z.number().finite().min(0).max(1000),
});

const signalMessage = z.object({
  type: z.literal('signal'),
  to: z.uuid(),
  callId: z.string().min(1).max(64),
  kind: z.enum(['offer', 'answer', 'candidate', 'reject', 'hangup']),
  data: z.record(z.string(), z.unknown()).optional(),
});

// Admins call employees; employees only answer.
const allowedSignals: Record<UserRole, ReadonlySet<string>> = {
  admin: new Set(['offer', 'candidate', 'hangup']),
  employee: new Set(['answer', 'candidate', 'reject', 'hangup']),
};

interface Client {
  ws: WebSocket;
  userId: string;
  name: string;
  role: UserRole;
  alive: boolean;
  lastUpdateAt: number;
  signalWindowStart: number;
  signalCount: number;
  /** Keeps a caller's offer and ICE candidates in order across async checks. */
  queue: Promise<void>;
}

const clients = new Map<WebSocket, Client>();

const locationKey = (userId: string) => `${LOCATION_PREFIX}${userId}`;
const presenceKey = (userId: string) => `${PRESENCE_PREFIX}${userId}`;
const logError = (err: unknown) => console.error('[ws]', err instanceof Error ? err.message : err);

function send(ws: WebSocket, payload: string) {
  if (ws.readyState === WebSocket.OPEN && ws.bufferedAmount < MAX_BUFFERED_BYTES) ws.send(payload);
}

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

async function scanValues(prefix: string): Promise<unknown[]> {
  const keys: string[] = [];
  for await (const batch of redis.scanStream({ match: `${prefix}*`, count: 100 })) {
    keys.push(...(batch as string[]));
  }
  if (keys.length === 0) return [];
  const values = await redis.mget(keys);
  return values.flatMap((v) => (v ? [JSON.parse(v)] : []));
}

async function snapshot() {
  const [locations, online] = await Promise.all([scanValues(LOCATION_PREFIX), scanValues(PRESENCE_PREFIX)]);
  return { type: 'snapshot', users: locations, online };
}

function handleLocation(client: Client, json: unknown) {
  if (client.role !== 'employee') return;

  const now = Date.now();
  if (now - client.lastUpdateAt < MIN_UPDATE_INTERVAL_MS) return;

  const parsed = locationMessage.safeParse(json);
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
    .set(locationKey(client.userId), payload, 'EX', KEY_TTL_SECONDS)
    .publish(LOCATION_CHANNEL, payload)
    .exec()
    .catch(logError);
}

async function handleSignal(client: Client, json: unknown) {
  const parsed = signalMessage.safeParse(json);
  if (!parsed.success) return;
  const msg = parsed.data;

  if (!allowedSignals[client.role].has(msg.kind) || msg.to === client.userId) return;

  const now = Date.now();
  if (now - client.signalWindowStart > SIGNAL_WINDOW_MS) {
    client.signalWindowStart = now;
    client.signalCount = 0;
  }
  if (++client.signalCount > MAX_SIGNALS_PER_WINDOW) return;

  // Only online employees can be called.
  if (msg.kind === 'offer' && !(await redis.exists(presenceKey(msg.to)))) {
    send(
      client.ws,
      JSON.stringify({
        type: 'signal',
        from: msg.to,
        fromName: '',
        fromRole: 'employee',
        callId: msg.callId,
        kind: 'unavailable',
      }),
    );
    return;
  }

  await redis.publish(
    SIGNAL_CHANNEL,
    JSON.stringify({
      type: 'signal',
      from: client.userId,
      fromName: client.name,
      fromRole: client.role,
      to: msg.to,
      callId: msg.callId,
      kind: msg.kind,
      data: msg.data,
    }),
  );
}

function onMessage(client: Client, data: RawData) {
  let json: unknown;
  try {
    json = JSON.parse(data.toString());
  } catch {
    return;
  }
  const type = (json as { type?: unknown } | null)?.type;

  if (type === 'location') {
    handleLocation(client, json);
  } else if (type === 'signal') {
    client.queue = client.queue.then(() => handleSignal(client, json)).catch(logError);
  }
}

function onClose(client: Client) {
  clients.delete(client.ws);
  if (client.role !== 'employee') return;

  const stillConnected = [...clients.values()].some((c) => c.userId === client.userId);
  if (stillConnected) return;

  redis
    .multi()
    .del(locationKey(client.userId), presenceKey(client.userId))
    .publish(LOCATION_CHANNEL, JSON.stringify({ type: 'offline', userId: client.userId }))
    .exec()
    .catch(logError);
}

export async function attachRealtimeHub(server: Server) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 });

  await redisSub.subscribe(LOCATION_CHANNEL, SIGNAL_CHANNEL);
  redisSub.on('message', (channel, message) => {
    if (channel === LOCATION_CHANNEL) {
      for (const { ws, role } of clients.values()) {
        if (role === 'admin') send(ws, message);
      }
    } else if (channel === SIGNAL_CHANNEL) {
      let to: unknown;
      try {
        to = JSON.parse(message).to;
      } catch {
        return;
      }
      for (const { ws, userId } of clients.values()) {
        if (userId === to) send(ws, message);
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
      signalWindowStart: 0,
      signalCount: 0,
      queue: Promise.resolve(),
    };
    clients.set(ws, client);

    ws.on('pong', () => {
      client.alive = true;
      // Keeps a stationary but connected employee from expiring.
      if (client.role === 'employee') {
        redis
          .multi()
          .expire(locationKey(client.userId), KEY_TTL_SECONDS)
          .expire(presenceKey(client.userId), KEY_TTL_SECONDS)
          .exec()
          .catch(logError);
      }
    });
    ws.on('message', (data) => onMessage(client, data));
    ws.on('close', () => onClose(client));
    ws.on('error', logError);

    if (client.role === 'employee') {
      const presence = JSON.stringify({ userId: client.userId, name: client.name });
      redis
        .multi()
        .set(presenceKey(client.userId), presence, 'EX', KEY_TTL_SECONDS)
        .publish(LOCATION_CHANNEL, JSON.stringify({ type: 'online', userId: client.userId, name: client.name }))
        .exec()
        .catch(logError);
    } else {
      snapshot()
        .then((payload) => send(ws, JSON.stringify(payload)))
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
