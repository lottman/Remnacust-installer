/* Only used by check-panel-runtime.sh against its empty disposable database. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const crypto = require('node:crypto');
const { PrismaClient } = require('/opt/app/node_modules/@prisma/client');
const db = new PrismaClient();
const headers = { 'Content-Type': 'application/json', 'X-Forwarded-Proto': 'https',
    'X-Forwarded-For': '192.0.2.1', 'X-Remnawave-Client-Type': 'browser' };
const filename = '/tmp/subscription-gateway-state.json';
const bytes = Buffer.from(JSON.stringify({ version: 3, rules: [{ domain_suffix: ['fixture.example.test'] }] }));
async function api(route, method = 'GET', body, token) {
    const response = await fetch('http://127.0.0.1:3000/api/' + route, {
        method, headers: { ...headers, ...(token ? { Authorization: 'Bearer ' + token } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(15000),
    });
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null };
}
async function prepare() {
    assert.equal(await db.users.count(), 0, 'Gateway fixture requires an empty user database');
    assert.equal(await db.admin.count(), 0, 'Gateway fixture requires an empty administrator database');
    const registered = await api('auth/register', 'POST', { username: 'gateway_fixture_admin', password: 'Aa1' + crypto.randomBytes(24).toString('hex') });
    assert.equal(registered.status, 201);
    const admin = registered.body.response.accessToken;
    const main = (await api('subscription-domains', 'GET', undefined, admin)).body.response.find(row => row.isDefault);
    const alias = await api('subscription-domains', 'POST', { name: 'Gateway CDN fixture', domain: 'gateway-cdn.example.test', kind: 'CDN', parentUuid: main.uuid, isDefault: false, path: '' }, admin);
    assert.equal(alias.status, 201);
    const cdn = alias.body.response;
    const created = await api('users', 'POST', { username: 'gateway_fixture_user', hwidDeviceLimit: 0, expireAt: new Date(Date.now() + 3600000).toISOString(), subscriptionDomainUuid: cdn.uuid }, admin);
    assert.equal(created.status, 201);
    const user = created.body.response;
    assert.equal(user.subscriptionUrl, cdn.publicBaseUrl + '/' + user.shortUuid);
    const token = await api('tokens', 'POST', { name: 'Gateway fixture page', expiresInDays: 1,
        scopes: ['system:metadata', 'subscriptions:subpage-config', 'subscription-page-configs:get', 'subscription-page-configs:list'] }, admin);
    assert.equal(token.status, 201);
    const uploaded = await fetch('http://127.0.0.1:3000/api/geofiles/upload?name=gateway-fixture&kind=singbox-json', {
        method: 'POST', headers: { ...headers, 'Content-Type': 'application/octet-stream', Authorization: 'Bearer ' + admin },
        body: bytes, signal: AbortSignal.timeout(15000),
    });
    assert.equal(uploaded.status, 201);
    const file = (await uploaded.json()).response;
    const state = { admin, cdn, user, token: token.body.response, file };
    process.stdout.write(JSON.stringify(state));
}
function page(route, agent = 'INCY/2.6.2/iOS', cdnId) {
    return new Promise((resolve, reject) => {
        const request = http.get({ hostname: 'gateway-page', port: 3010, path: route,
            headers: { ...headers, host: 'sub.example.com', 'User-Agent': agent,
                Accept: agent.startsWith('Mozilla/') ? 'text/html' : '*/*',
                ...(cdnId ? { 'X-Remnacust-CDN': cdnId } : {}),
                'X-Forwarded-Host': 'forged.example.test', 'X-Remnacust-Subscription-Domain': crypto.randomUUID() }, timeout: 15000 }, response => {
            const chunks = []; let size = 0;
            response.on('data', chunk => { size += chunk.length; if (size > 2 * 1024 * 1024) request.destroy(Error('Fixture response too large')); else chunks.push(chunk); });
            response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
            response.on('error', reject);
        });
        request.on('error', reject);
        request.on('timeout', () => request.destroy(Error('Fixture request timed out')));
    });
}
async function verify() {
    const state = JSON.parse(fs.readFileSync(filename, 'utf8'));
    const prefix = '/cdn/' + state.cdn.uuid;
    const json = await page(prefix + '/' + state.user.shortUuid + '/json');
    assert.equal(json.status, 200, 'Prefixed subscription reaches the real Nest subscription controller');
    assert.ok(Array.isArray(JSON.parse(json.body)));
    const legacy = await page('/' + state.user.shortUuid + '/json');
    assert.equal(legacy.status, 200, 'Legacy subscription remains available');
    const header = await page('/' + state.user.shortUuid + '/json', undefined, state.cdn.uuid);
    assert.equal(header.status, 200, 'A configured CDN request header accepts an unchanged client URL');
    assert.ok(Array.isArray(JSON.parse(header.body)));
    assert.equal((await page('/' + state.user.shortUuid + '/json', undefined, crypto.randomUUID())).status, 404, 'Unknown CDN headers cannot silently fall back to the main domain');
    assert.equal((await page(prefix + '/' + state.user.shortUuid + '/json', undefined, crypto.randomUUID())).status, 404, 'Conflicting path and header IDs are rejected');
    const html = await page(prefix + '/' + state.user.shortUuid, 'Mozilla/5.0');
    assert.equal(html.status, 200);
    const data = /data-panel="([^"]+)"/.exec(html.body.toString());
    assert.ok(data, 'HTML includes subscription metadata');
    const metadata = JSON.parse(Buffer.from(data[1], 'base64').toString());
    assert.equal(metadata.response.subscriptionUrl, state.user.subscriptionUrl);
    const file = await page(prefix + '/geofiles/' + state.file.id + '/' + state.file.filename);
    assert.equal(file.status, 200, 'Geofiles retain the gateway even when origin Host differs');
    assert.deepEqual(file.body, bytes);
    assert.equal((await page('/cdn/' + crypto.randomUUID() + '/' + state.user.shortUuid + '/json')).status, 404);
    assert.equal((await api('subscription-domains')).status, 401);
    assert.equal((await api('users/' + state.user.id, 'DELETE', undefined, state.admin)).status, 204);
    assert.equal((await api('subscription-domains/' + state.cdn.uuid, 'DELETE', undefined, state.admin)).status, 204);
    assert.equal((await api('geofiles/' + state.file.id, 'DELETE', undefined, state.admin)).status, 200);
    assert.ok([200, 204].includes((await api('tokens/' + state.token.uuid, 'DELETE', undefined, state.admin)).status));
    await db.admin.deleteMany({ where: { username: 'gateway_fixture_admin' } });
    console.log('PASS paired release images: CDN request header with unchanged client URL, conflicting selectors, rewritten origin Host, scoped page token, JSON, HTML/QR, geofiles and legacy URLs');
}
(process.argv[2] === 'prepare' ? prepare() : verify())
    .catch(error => { console.error(error.stack ?? error.message); process.exitCode = 1; })
    .finally(() => db.$disconnect());
