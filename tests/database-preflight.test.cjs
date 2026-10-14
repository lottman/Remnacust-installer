'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../installer/database.cjs'), 'utf8');
const legacy = fs.readFileSync(path.join(__dirname, 'fixtures/legacy-always-available.sql'), 'utf8').replace(/\r\n/g, '\n');
const comments = '-- Shared by node startup and subscription rendering. Any ordinary alias on the\n' +
    '-- same inbound closes the exception; flags never override squad restrictions.\n';
const current = legacy.replace(comments, '');
const name = '20260911203000_era_always_available_hosts';
const sha = (sql) => crypto.createHash('sha256').update(sql).digest('hex');
const applied = (checksum, migration_name = name) => ({ migration_name, checksum, finished_at: new Date(), rolled_back_at: null });

async function preflight(rows, { sql = current, files = true, encrypted = false, secret = 'fixture-secret' } = {}) {
    let stdout = '', stderr = '', disconnected = false;
    const queries = [];
    let password = 'fixture-protected-password';
    if (encrypted) {
        const key = crypto.createHmac('sha256', 'fixture-secret').update('xera-keyring-v1').digest();
        const nonce = Buffer.alloc(12, 1);
        const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
        const data = Buffer.concat([cipher.update(password, 'utf8'), cipher.final()]);
        password = 'xera1:' + Buffer.concat([nonce, cipher.getAuthTag(), data]).toString('base64');
    }
    const user = { id: 1n, short_uuid: 'fixture-short-uuid', username: 'fixture-user',
        trojan_password: password, vless_uuid: 'fixture-vless-uuid', ss_password: password };
    const client = {
        async $queryRawUnsafe(query) {
            queries.push(query);
            assert.match(query, /^SELECT /, 'preflight must remain read-only');
            if (query.includes('FROM "_prisma_migrations"')) return rows;
            if (query.includes('FROM information_schema.tables')) return [{ table_name: 'users' }];
            if (query.includes('FROM information_schema.columns')) return Object.keys(user).map((column_name) => ({ column_name }));
            if (query.includes('FROM "users"')) return [{ ...user }];
            throw new Error('Unexpected query: ' + query);
        },
        async $disconnect() { disconnected = true; },
    };
    const process = { argv: ['node', '-', 'preflight'], env: { APP_SECRET: secret },
        stdout: { write: (value) => { stdout += value; } }, exitCode: 0 };
    await vm.runInNewContext(source, { Buffer, process,
        console: { error: (value) => { stderr += value; } },
        require: (module) => {
            if (module === '/opt/app/node_modules/@prisma/client') return { PrismaClient: class { constructor() { return client; } } };
            if (module === 'node:fs') return { existsSync: () => files, readFileSync: () => Buffer.from(sql) };
            return require(module);
        },
    });
    assert.equal(disconnected, true);
    assert.ok(!stdout.includes('fixture-protected-password') && !stderr.includes('fixture-protected-password'));
    assert.ok(!stdout.includes(secret) && !stderr.includes(secret));
    return { code: process.exitCode, stdout, stderr, queries };
}

test('fixture proves the approved historical change removed comments only', () => {
    assert.equal(sha(current), '1903dab82af3f21623204385707350286f77118c86cb8b3d81e0c295a9dae07b');
    assert.equal(sha(legacy), '4cd72fdfe7de50e07a5d9e6cca1282c8268fca6ba79748c0bf21530e973cd5d7');
    assert.equal(sha(legacy.replace(/\n/g, '\r\n')), 'cfa557c6bb9fe4dfc992da3d78111f17a19d61df307352f8335721188f2a2aa5');
});

test('current and historical LF/CRLF checksums pass without rewriting migration history', async () => {
    for (const sql of [current, current.replace(/\n/g, '\r\n')]) {
        for (const old of [current, legacy]) {
            for (const content of [old, old.replace(/\n/g, '\r\n')]) {
                const rows = [applied(sha(content))];
                const before = JSON.stringify(rows);
                const result = await preflight(rows, { sql, encrypted: true });
                assert.equal(result.code, 0, result.stderr);
                assert.match(result.stdout, /Database preflight passed/);
                assert.equal(JSON.stringify(rows), before);
            }
        }
    }
});

test('unknown checksums, changed release SQL and unrelated migrations remain blocked', async () => {
    for (const [row, options] of [
        [applied('f'.repeat(64)), {}],
        [applied(sha(legacy)), { sql: current.replace('DEFAULT false', 'DEFAULT true') }],
        [applied(sha(legacy), 'unrelated_migration'), {}],
        [applied(sha(legacy)), { files: false }],
    ]) {
        const result = await preflight([row], options);
        assert.equal(result.code, 1);
        assert.match(result.stderr, /unknown or modified migration/);
        assert.match(result.stderr, /stored checksum:/);
        assert.equal(result.queries.length, 1);
    }
});

test('incomplete migrations and invalid hashes are rejected; rolled-back entries are ignored', async () => {
    let result = await preflight([{ ...applied(sha(legacy)), finished_at: null }]);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /incomplete migration/);
    result = await preflight([applied('not-a-hash')]);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /invalid migration checksum/);
    result = await preflight([{ ...applied('not-a-hash', 'old_rolled_back'), finished_at: null, rolled_back_at: new Date() }]);
    assert.equal(result.code, 0, result.stderr);
});

test('approved legacy history does not bypass the original APP_SECRET check', async () => {
    const result = await preflight([applied(sha(legacy))], { encrypted: true, secret: 'wrong-fixture-secret' });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /verify original APP_SECRET/);
    assert.doesNotMatch(result.stdout, /Database preflight passed/);
});
