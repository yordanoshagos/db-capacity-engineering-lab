'use strict';

// C3 — GetSecretValue at boot via the AWS SDK.
// Client uses endpoint: process.env.AWS_ENDPOINT_URL (unset on real AWS).

const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require('@aws-sdk/client-secrets-manager');

let source = { arn: 'env', versionId: 'n/a' };
let loadError = null;

function getSecretSource() {
  return { arn: source.arn, versionId: source.versionId };
}

function secretLoadError() {
  return loadError;
}

function client() {
  const endpoint = process.env.AWS_ENDPOINT_URL;
  return new SecretsManagerClient({
    region: process.env.AWS_DEFAULT_REGION || 'us-east-1',
    ...(endpoint ? { endpoint } : {}),
  });
}

async function loadDbCredentials() {
  loadError = null;
  const arn = process.env.DB_SECRET_ARN;
  if (!arn) {
    source = { arn: 'env', versionId: 'n/a' };
    return {
      engine: 'mysql',
      username: process.env.MYSQL_USER || 'root',
      password: process.env.MYSQL_PASSWORD || 'labpassword',
      host: process.env.MYSQL_HOST || 'mysql-db',
      port: Number(process.env.MYSQL_PORT || 3306),
      dbname: process.env.MYSQL_DATABASE || 'capacity_lab',
    };
  }

  const out = await client().send(new GetSecretValueCommand({ SecretId: arn }));
  if (!out.SecretString) {
    loadError = new Error('GetSecretValue returned no SecretString');
    throw loadError;
  }
  const parsed = JSON.parse(out.SecretString);
  source = { arn: out.ARN || arn, versionId: out.VersionId || 'n/a' };
  // eslint-disable-next-line no-console
  console.log(`boot: resolved DB secret arn=${source.arn} version=${source.versionId}`);
  return parsed;
}

module.exports = { loadDbCredentials, getSecretSource, secretLoadError };
