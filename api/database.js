'use strict';

/**
 * database.js
 * -----------------------------------------------------------------------------
 * Connection factories for MySQL and MongoDB.
 */

const mysql = require('mysql2/promise');
const { MongoClient } = require('mongodb');

// ---------------------------------------------------------------------------
// Environment configuration (with defaults for local runs)
// ---------------------------------------------------------------------------
const MYSQL_CONFIG = {
  host: process.env.MYSQL_HOST || 'mysql-db',
  port: Number(process.env.MYSQL_PORT || 3306),
  user: process.env.MYSQL_USER || 'root',
  password: process.env.MYSQL_PASSWORD || 'labpassword',
  database: process.env.MYSQL_DATABASE || 'capacity_lab',

  // OPS-2202: pool of 2 serialises the whole API under surge while MySQL sits
  // idle (Threads_running ≈ pool size). Size via Little's Law:
  //   connections ≈ target_throughput × service_time
  // For recent-patients, service_time ≈ 5–15ms. Targeting ~2k req/s headroom
  // needs ~20–40 conns; 50 leaves margin without approaching max_connections.
  // queueLimit: 0 = wait (latency rises under overload). For production, prefer
  // a finite queueLimit + load shedding so bursts fail fast instead of melting.
  waitForConnections: true,
  connectionLimit: 50,
  queueLimit: 0,
  connectTimeout: 10_000,
  maxIdle: 50,
  idleTimeout: 60_000,
  enableKeepAlive: true,
};

const MONGO_URI = process.env.MONGO_URI || 'mongodb://mongo-db:27017';
const MONGO_DB_NAME = process.env.MONGO_DB || 'capacity_lab';

// ---------------------------------------------------------------------------
// MySQL pool (singleton)
// ---------------------------------------------------------------------------
let pool;

function applySecret(secret) {
  MYSQL_CONFIG.host = secret.host;
  MYSQL_CONFIG.port = Number(secret.port);
  MYSQL_CONFIG.user = secret.username;
  MYSQL_CONFIG.password = secret.password;
  MYSQL_CONFIG.database = secret.dbname;
  MYSQL_CONFIG.ssl = { rejectUnauthorized: false };
  pool = undefined;
}

function poolStats() {
  if (!pool || !pool.pool) {
    return { inUse: 0, waiting: 0, limit: MYSQL_CONFIG.connectionLimit };
  }
  const inner = pool.pool;
  const all = inner._allConnections ? inner._allConnections.length : 0;
  const free = inner._freeConnections ? inner._freeConnections.length : 0;
  const waiting = inner._connectionQueue ? inner._connectionQueue.length : 0;
  return {
    inUse: Math.max(0, all - free),
    waiting,
    limit: MYSQL_CONFIG.connectionLimit,
  };
}

function isPoolSaturated() {
  const s = poolStats();
  return s.inUse >= s.limit && s.waiting > 0;
}

function getPool() {
  if (!pool) {
    pool = mysql.createPool(MYSQL_CONFIG);
  }
  return pool;
}

// ---------------------------------------------------------------------------
// MongoDB client (singleton, lazily connected)
// ---------------------------------------------------------------------------
let mongoClient;
let mongoDb;

async function getMongo() {
  if (!mongoDb) {
    mongoClient = new MongoClient(MONGO_URI, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await mongoClient.connect();
    mongoDb = mongoClient.db(MONGO_DB_NAME);
  }
  return mongoDb;
}

// ---------------------------------------------------------------------------
// Graceful shutdown helpers
// ---------------------------------------------------------------------------
async function closeAll() {
  if (pool) {
    try { await pool.end(); } catch (_) { /* ignore */ }
    pool = undefined;
  }
  if (mongoClient) {
    try { await mongoClient.close(); } catch (_) { /* ignore */ }
    mongoClient = undefined;
    mongoDb = undefined;
  }
}

module.exports = {
  MYSQL_CONFIG,
  MONGO_URI,
  MONGO_DB_NAME,
  applySecret,
  poolStats,
  isPoolSaturated,
  getPool,
  getMongo,
  closeAll,
};
