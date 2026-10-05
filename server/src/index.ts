import { createServer } from 'node:http';

import express, { type ErrorRequestHandler } from 'express';

import { env } from './config/env.js';
import { attachLocationHub } from './realtime/location.hub.js';
import { authRouter } from './routes/auth.routes.js';

const app = express();

app.disable('x-powered-by');
app.use(express.json({ limit: '10kb' }));

app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

app.use('/api/auth', authRouter);

app.use((_req, res) => {
  res.status(404).json({ message: 'Not found' });
});

const errorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  if (err?.type === 'entity.parse.failed') {
    return res.status(400).json({ message: 'Malformed JSON body' });
  }
  console.error(err);
  res.status(500).json({ message: 'Internal server error' });
};
app.use(errorHandler);

const server = createServer(app);
const hub = await attachLocationHub(server);

server.listen(env.PORT, env.HOST, () => {
  console.log(`API listening on http://${env.HOST}:${env.PORT} (WebSocket at /ws)`);
});

function shutdown() {
  hub.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
