import 'dotenv/config';

import bcrypt from 'bcryptjs';
import express from 'express';
import { rateLimit } from 'express-rate-limit';
import helmet from 'helmet';
import jwt from 'jsonwebtoken';
import { MongoClient } from 'mongodb';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const tokenLifetime = '12h';

export function isDateKey(value) {
  if (typeof value !== 'string' || !datePattern.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(parsed.valueOf()) &&
    parsed.toISOString().slice(0, 10) === value;
}

export function createApp({
  attendance,
  username,
  passwordHash,
  jwtSecret,
}) {
  if (!attendance || !username || !passwordHash || !jwtSecret) {
    throw new Error('Attendance storage and authentication settings are required.');
  }

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1);
  app.use(helmet());
  app.use(express.json({ limit: '16kb' }));

  app.get('/health', (_request, response) => {
    response.json({ status: 'ok' });
  });

  app.post(
    '/api/auth/login',
    rateLimit({
      windowMs: 15 * 60 * 1000,
      limit: 10,
      standardHeaders: 'draft-8',
      legacyHeaders: false,
    }),
    async (request, response, next) => {
      try {
        const { password } = request.body ?? {};
        if (typeof password !== 'string' || password.length === 0 || password.length > 512) {
          response.status(400).json({ error: 'Enter a valid password.' });
          return;
        }

        const passwordMatches = await bcrypt.compare(password, passwordHash);
        if (!passwordMatches) {
          response.status(401).json({ error: 'Incorrect password.' });
          return;
        }

        const token = jwt.sign({ sub: username }, jwtSecret, {
          expiresIn: tokenLifetime,
          issuer: 'sync-attendance-api',
          audience: 'sync-attendance-app',
        });
        response.json({ token });
      } catch (error) {
        next(error);
      }
    },
  );

  app.use('/api', (request, response, next) => {
    const authorization = request.get('authorization');
    const token = authorization?.match(/^Bearer (.+)$/i)?.[1];
    if (!token) {
      response.status(401).json({ error: 'Sign in to continue.' });
      return;
    }

    try {
      const payload = jwt.verify(token, jwtSecret, {
        issuer: 'sync-attendance-api',
        audience: 'sync-attendance-app',
      });
      if (typeof payload === 'string' || payload.sub !== username) {
        response.status(401).json({ error: 'Your session is invalid. Sign in again.' });
        return;
      }
      request.userId = username;
      next();
    } catch {
      response.status(401).json({ error: 'Your session has expired. Sign in again.' });
    }
  });

  app.get('/api/attendance/today', async (request, response, next) => {
    try {
      const date = request.query.date;
      if (!isDateKey(date)) {
        response.status(400).json({ error: 'A valid local date is required.' });
        return;
      }

      const record = await attendance.findOne({
        userId: request.userId,
        date,
      });
      response.json({ record: record ? publicRecord(record) : null });
    } catch (error) {
      next(error);
    }
  });

  app.get('/api/attendance', async (request, response, next) => {
    try {
      const records = await attendance
        .find({ userId: request.userId })
        .sort({ date: -1 })
        .limit(100)
        .toArray();
      response.json({ records: records.map(publicRecord) });
    } catch (error) {
      next(error);
    }
  });

  app.post('/api/attendance/time-in', async (request, response, next) => {
    try {
      const { date } = request.body ?? {};
      if (!isDateKey(date)) {
        response.status(400).json({ error: 'A valid local date is required.' });
        return;
      }

      const now = new Date();
      try {
        await attendance.insertOne({
          userId: request.userId,
          date,
          timeIn: now,
          timeOut: null,
          createdAt: now,
          updatedAt: now,
        });
      } catch (error) {
        if (error?.code !== 11000) throw error;
        response.status(409).json({ error: 'Time In is already recorded for today.' });
        return;
      }

      const record = await attendance.findOne({ userId: request.userId, date });
      if (!record) throw new Error('The saved Time In record could not be reloaded.');
      response.status(201).json({ record: publicRecord(record) });
    } catch (error) {
      next(error);
    }
  });

  app.post('/api/attendance/time-out', async (request, response, next) => {
    try {
      const { date } = request.body ?? {};
      if (!isDateKey(date)) {
        response.status(400).json({ error: 'A valid local date is required.' });
        return;
      }

      const now = new Date();
      const result = await attendance.updateOne(
        {
          userId: request.userId,
          date,
          timeIn: { $exists: true },
          timeOut: null,
        },
        { $set: { timeOut: now, updatedAt: now } },
      );

      if (result.modifiedCount !== 1) {
        const existing = await attendance.findOne({
          userId: request.userId,
          date,
        });
        const error = existing?.timeOut
          ? 'Time Out is already recorded for today.'
          : 'Record Time In before recording Time Out.';
        response.status(409).json({ error });
        return;
      }

      const record = await attendance.findOne({ userId: request.userId, date });
      if (!record) throw new Error('The saved attendance record could not be reloaded.');
      response.json({ record: publicRecord(record) });
    } catch (error) {
      next(error);
    }
  });

  app.use('/api', (_request, response) => {
    response.status(404).json({ error: 'API route not found.' });
  });

  app.use((error, _request, response, _next) => {
    console.error(
      'SYNC API request failed:',
      error instanceof Error ? error.name : 'Unknown error',
    );
    response.status(500).json({ error: 'The server could not complete the request.' });
  });

  return app;
}

function publicRecord(record) {
  return {
    date: record.date,
    timeIn: record.timeIn?.toISOString() ?? null,
    timeOut: record.timeOut?.toISOString() ?? null,
  };
}

async function startServer() {
  const required = [
    'MONGODB_URI',
    'MONGODB_DATABASE',
    'SYNC_USERNAME',
    'SYNC_PASSWORD_HASH',
    'JWT_SECRET',
  ];
  const missing = required.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }
  if (Buffer.byteLength(process.env.JWT_SECRET, 'utf8') < 32) {
    throw new Error('JWT_SECRET must be at least 32 bytes long.');
  }

  const client = new MongoClient(process.env.MONGODB_URI, {
    serverSelectionTimeoutMS: 10_000,
  });
  await client.connect();
  const database = client.db(process.env.MONGODB_DATABASE);
  await database.command({ ping: 1 });
  const attendance = database.collection('attendance');
  await attendance.createIndex({ userId: 1, date: 1 }, { unique: true });

  const app = createApp({
    attendance,
    username: process.env.SYNC_USERNAME,
    passwordHash: process.env.SYNC_PASSWORD_HASH,
    jwtSecret: process.env.JWT_SECRET,
  });
  const port = Number(process.env.PORT ?? 3000);
  const server = app.listen(port, '0.0.0.0', () => {
    console.log(`SYNC API listening on port ${port}`);
  });

  const shutdown = async () => {
    await new Promise((resolve) => server.close(resolve));
    await client.close();
    process.exit(0);
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  startServer().catch((error) => {
    const detail =
      error instanceof Error &&
      error.message.startsWith('Missing required environment variables:')
        ? error.message
        : error instanceof Error
          ? error.name
          : 'Unknown error';
    console.error('SYNC API could not start:', detail);
    process.exitCode = 1;
  });
}
