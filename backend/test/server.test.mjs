import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { after, before, test } from 'node:test';

import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';

import { createApp, isDateKey } from '../server.mjs';

const username = 'test-user';
const jwtSecret = 'test-secret-with-at-least-thirty-two-bytes';
const date = '2026-11-02';
const records = new Map();
let server;
let baseUrl;
let token;

const attendance = {
  async findOne(query) {
    return records.get(`${query.userId}:${query.date}`) ?? null;
  },
  find(query) {
    let matchingRecords = [...records.values()].filter(
      (record) => record.userId === query.userId,
    );
    return {
      sort() {
        matchingRecords = matchingRecords.sort((left, right) =>
          right.date.localeCompare(left.date),
        );
        return this;
      },
      limit(count) {
        matchingRecords = matchingRecords.slice(0, count);
        return this;
      },
      async toArray() {
        return matchingRecords;
      },
    };
  },
  async insertOne(record) {
    const key = `${record.userId}:${record.date}`;
    if (records.has(key)) {
      const error = new Error('Duplicate key.');
      error.code = 11000;
      throw error;
    }
    records.set(key, record);
  },
  async updateOne(query, update) {
    const key = `${query.userId}:${query.date}`;
    const existing = records.get(key);
    if (!existing || !existing.timeIn || existing.timeOut !== null) {
      return { modifiedCount: 0 };
    }
    records.set(key, { ...existing, ...update.$set });
    return { modifiedCount: 1 };
  },
};

before(async () => {
  const passwordHash = await bcrypt.hash('test-password', 4);
  const app = createApp({ attendance, username, passwordHash, jwtSecret });
  server = createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
  token = jwt.sign({ sub: username }, jwtSecret, {
    expiresIn: '5m',
    issuer: 'sync-attendance-api',
    audience: 'sync-attendance-app',
  });
});

after(async () => {
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
});

test('accepts real calendar dates and rejects invalid dates', () => {
  assert.equal(isDateKey('2026-11-02'), true);
  assert.equal(isDateKey('2026-02-29'), false);
  assert.equal(isDateKey('2026-11-2'), false);
  assert.equal(isDateKey('../admin'), false);
});

test('requires authentication for attendance records', async () => {
  const response = await fetch(`${baseUrl}/api/attendance/today?date=${date}`);
  assert.equal(response.status, 401);
  const historyResponse = await fetch(`${baseUrl}/api/attendance`);
  assert.equal(historyResponse.status, 401);
});

test('authenticates with the configured password', async () => {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ password: 'test-password' }),
  });
  assert.equal(response.status, 200);
  assert.equal(typeof (await response.json()).token, 'string');

  const invalidPassword = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ password: 'wrong-password' }),
  });
  assert.equal(invalidPassword.status, 401);
});

test('requires time in before time out and saves each time once', async () => {
  const headers = {
    authorization: `Bearer ${token}`,
    'content-type': 'application/json',
  };
  const payload = JSON.stringify({ date });

  const empty = await fetch(`${baseUrl}/api/attendance/today?date=${date}`, {
    headers,
  });
  assert.deepEqual(await empty.json(), { record: null });

  const earlyTimeOut = await fetch(`${baseUrl}/api/attendance/time-out`, {
    method: 'POST',
    headers,
    body: payload,
  });
  assert.equal(earlyTimeOut.status, 409);

  const timeIn = await fetch(`${baseUrl}/api/attendance/time-in`, {
    method: 'POST',
    headers,
    body: payload,
  });
  assert.equal(timeIn.status, 201);
  assert.ok((await timeIn.json()).record.timeIn);

  const duplicateTimeIn = await fetch(`${baseUrl}/api/attendance/time-in`, {
    method: 'POST',
    headers,
    body: payload,
  });
  assert.equal(duplicateTimeIn.status, 409);

  const timeOut = await fetch(`${baseUrl}/api/attendance/time-out`, {
    method: 'POST',
    headers,
    body: payload,
  });
  assert.equal(timeOut.status, 200);
  assert.ok((await timeOut.json()).record.timeOut);

  const duplicateTimeOut = await fetch(`${baseUrl}/api/attendance/time-out`, {
    method: 'POST',
    headers,
    body: payload,
  });
  assert.equal(duplicateTimeOut.status, 409);

  const history = await fetch(`${baseUrl}/api/attendance`, { headers });
  assert.equal(history.status, 200);
  assert.deepEqual((await history.json()).records.map((record) => record.date), [date]);
});
