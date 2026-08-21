'use strict';

/**
 * server.js
 * -----------------------------------------------------------------------------
 * Express API for the Regional Health admissions & patient-lookup service.
 *
 * Endpoints:
 *   GET  /api/patients/recent        Recent patients widget
 *   GET  /api/patients/search        Patient lookup by last name
 *   POST /api/hospitals/:id/admit    Admit a patient (decrement bed count)
 *   GET  /api/patients/export        Full patient export for the analytics team
 *   GET  /api/audit/ping             Mongo audit-store health probe
 *   GET  /metrics                    Prometheus metrics
 *   GET  /healthz                    liveness (process is up)
 *   GET  /readyz                     503 if DB down, pool saturated, or secret failed
 *   GET  /debug/secret-source        { arn, versionId } from Secrets Manager
 */

const express = require('express');
const client = require('prom-client');
const { getPool, getMongo, applySecret, isPoolSaturated, poolStats } = require('./database');
const { loadDbCredentials, getSecretSource, secretLoadError } = require('./secrets');

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 3000);

// ---------------------------------------------------------------------------
// Prometheus metrics
// ---------------------------------------------------------------------------
const register = new client.Registry();
register.setDefaultLabels({ app: 'capacity-api' });

// Default process/GC/heap metrics.
client.collectDefaultMetrics({ register, gcDurationBuckets: [0.001, 0.01, 0.1, 1, 2, 5] });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const dbErrorsTotal = new client.Counter({
  name: 'db_errors_total',
  help: 'Total number of database errors by type',
  labelNames: ['route', 'code'],
  registers: [register],
});

const mysqlPoolInUse = new client.Gauge({
  name: 'mysql_pool_in_use',
  help: 'MySQL pool connections currently checked out',
  registers: [register],
});
const mysqlPoolWaiting = new client.Gauge({
  name: 'mysql_pool_waiting',
  help: 'Callers waiting for a free MySQL pool connection',
  registers: [register],
});
const mysqlPoolLimit = new client.Gauge({
  name: 'mysql_pool_limit',
  help: 'MySQL pool connectionLimit',
  registers: [register],
});

setInterval(() => {
  const s = poolStats();
  mysqlPoolInUse.set(s.inUse);
  mysqlPoolWaiting.set(s.waiting);
  mysqlPoolLimit.set(s.limit);
}, 1000).unref();

// Per-request timing + counting middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const route = req.route ? req.baseUrl + req.route.path : req.path;
    const labels = { method: req.method, route, status_code: res.statusCode };
    end(labels);
    httpRequestsTotal.inc(labels);
  });
  next();
});

// ---------------------------------------------------------------------------
// Health & metrics
// ---------------------------------------------------------------------------
app.get('/health', (_req, res) => res.json({ status: 'ok' }));
app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

app.get('/readyz', async (_req, res) => {
  const src = getSecretSource();
  const secretFailed = Boolean(secretLoadError())
    || (process.env.DB_SECRET_ARN && !String(src.arn || '').startsWith('arn:aws:secretsmanager:'));
  if (secretFailed) {
    res.status(503).json({ status: 'not-ready', reason: 'secret-unresolved' });
    return;
  }
  if (isPoolSaturated()) {
    res.status(503).json({ status: 'not-ready', reason: 'pool-saturated', pool: poolStats() });
    return;
  }
  try {
    await getPool().query('SELECT 1');
    res.json({ status: 'ready' });
  } catch (err) {
    res.status(503).json({ status: 'not-ready', reason: 'db-unreachable', error: err.message });
  }
});

app.get('/debug/secret-source', (_req, res) => {
  res.json(getSecretSource());
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// ---------------------------------------------------------------------------
// Recent patients widget
// ---------------------------------------------------------------------------
app.get('/api/patients/recent', async (_req, res) => {
  try {
    const pool = getPool();
    const [rows] = await pool.query(
      'SELECT * FROM patients ORDER BY id DESC LIMIT 50'
    );
    res.json({ count: rows.length, data: rows });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/recent', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Patient lookup by last name
// OPS-2201 follow-up: index alone is not enough — SELECT * of ~10k Smith rows
// (incl. notes TEXT) keeps p95 multi-second under concurrency. Bound the
// result and omit the heavy notes column so the search SLO (p95 < 300ms) holds.
// ---------------------------------------------------------------------------
app.get('/api/patients/search', async (req, res) => {
  const lastName = req.query.lastName || '';
  const rawLimit = Number(req.query.limit ?? 50);
  const limit = Number.isFinite(rawLimit) ? Math.min(Math.max(rawLimit, 1), 100) : 50;
  try {
    const pool = getPool();
    const [rows] = await pool.query(
      `SELECT id, first_name, last_name, email, diagnosis, created_at
       FROM patients
       WHERE last_name = ?
       LIMIT ?`,
      [lastName, limit]
    );
    res.json({ count: rows.length, lastName, limit, data: rows });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/search', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Admit a patient to a hospital (decrement available beds).
// We update the bed count, then notify the regional bed registry that the
// count changed before finalizing, so the two systems stay consistent.
// ---------------------------------------------------------------------------
app.post('/api/hospitals/:id/admit', async (req, res) => {
  const hospitalId = Number(req.params.id);
  const pool = getPool();
  let conn;
  try {
    conn = await pool.getConnection();
    await conn.beginTransaction();

    // Keep the critical section short: touch the hot row and commit.
    // Holding the X lock across notifyBedRegistry (~500ms) caps throughput at
    // ~1/W admits/sec per hospital (OPS-2203).
    const [result] = await conn.query(
      'UPDATE hospitals SET available_beds = available_beds - 1 WHERE id = ? AND available_beds > 0',
      [hospitalId]
    );
    if (result.affectedRows === 0) {
      await conn.rollback();
      conn.release();
      conn = null;
      return res.status(409).json({ error: 'NO_BEDS', hospitalId });
    }

    await conn.commit();
    // Release the pool slot before external I/O — otherwise each admit still
    // occupies a connection for ~500ms and Little's Law caps λ ≈ pool/0.5.
    conn.release();
    conn = null;

    await notifyBedRegistry(hospitalId);

    res.json({ status: 'admitted', hospitalId });
  } catch (err) {
    if (conn) {
      try { await conn.rollback(); } catch (_) { /* ignore */ }
    }
    dbErrorsTotal.inc({ route: '/api/hospitals/:id/admit', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  } finally {
    if (conn) conn.release();
  }
});

// Stand-in for the external registry client used by the admit flow.
function notifyBedRegistry(_hospitalId) {
  return new Promise((r) => setTimeout(r, 500));
}

// ---------------------------------------------------------------------------
// Patient export for the analytics/ETL team (paginated).
// OPS-2204: never materialise the full table in process memory — that is O(N)
// heap and OOMs the 160MB container. Page with keyset pagination instead.
// ---------------------------------------------------------------------------
app.get('/api/patients/export', async (req, res) => {
  const rawLimit = Number(req.query.limit ?? 500);
  const limit = Number.isFinite(rawLimit) ? Math.min(Math.max(rawLimit, 1), 1000) : 500;
  const afterId = Number(req.query.afterId ?? 0);

  try {
    const pool = getPool();
    const [rows] = await pool.query(
      'SELECT * FROM patients WHERE id > ? ORDER BY id ASC LIMIT ?',
      [afterId, limit]
    );
    const nextAfterId = rows.length ? rows[rows.length - 1].id : null;
    res.json({
      count: rows.length,
      limit,
      afterId,
      nextAfterId,
      hasMore: rows.length === limit,
      data: rows,
    });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/export', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Mongo audit-store health probe
// ---------------------------------------------------------------------------
app.get('/api/audit/ping', async (_req, res) => {
  try {
    const db = await getMongo();
    const result = await db.command({ ping: 1 });
    res.json({ mongo: result });
  } catch (err) {
    res.status(500).json({ error: 'MONGO_ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Boot — resolve DB creds from Secrets Manager before listen (C3)
// ---------------------------------------------------------------------------
async function boot() {
  const creds = await loadDbCredentials();
  if (getSecretSource().arn !== 'env') {
    applySecret(creds);
  }
  app.listen(PORT, () => {
    // eslint-disable-next-line no-console
    console.log(`capacity-api listening on :${PORT} (metrics at /metrics)`);
  });
}

boot().catch((err) => {
  // eslint-disable-next-line no-console
  console.error('boot failed', err);
  process.exit(1);
});
