/* Run only inside the isolated, empty database fixture in check-panel-runtime.sh. */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { PrismaClient } = require('/opt/app/node_modules/@prisma/client');
const prisma = new PrismaClient();
const headers = { 'Content-Type': 'application/json', 'X-Forwarded-Proto': 'https',
    'X-Forwarded-For': '127.0.0.1', 'X-Remnawave-Client-Type': 'browser' };
const users = [];
let token;
let adminCreated = false;
let savedSettings;
async function request(path, method = 'GET', body, authenticated = true) {
    const response = await fetch('http://127.0.0.1:3000' + path, {
        method, headers: { ...headers, ...(authenticated && token ? { Authorization: 'Bearer ' + token } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(15000),
    });
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null };
}
async function createUser(name, limit) {
    const result = await request('/api/users', 'POST', {
        username: name, expireAt: new Date(Date.now() + 86400000).toISOString(),
        ...(limit === undefined ? {} : { hwidDeviceLimit: limit }),
    });
    assert.equal(result.status, 201, 'Fixture user creation');
    users.push(BigInt(result.body.response.id));
    return result.body.response;
}
async function checkGeofiles() {
    const endpoint = 'http://127.0.0.1:3000';
    let file, template;
    try {
        for (const [route, method] of [['', 'GET'], ['/upload?name=fixture&kind=singbox-json', 'POST'], ['/import', 'POST'], ['/invalid', 'DELETE']])
            assert.equal((await fetch(endpoint + '/api/geofiles' + route, { method, headers, signal: AbortSignal.timeout(10000) })).status, 401);
        const data = Buffer.from(JSON.stringify({ version: 3, rules: [{ domain_suffix: ['fixture.example.test'] }] }));
        const uploaded = await fetch(endpoint + '/api/geofiles/upload?name=runtime-fixture&kind=singbox-json', {
            method: 'POST', headers: { ...headers, 'Content-Type': 'application/octet-stream', Authorization: 'Bearer ' + token },
            body: data, signal: AbortSignal.timeout(10000),
        });
        assert.equal(uploaded.status, 201, 'Geofile upload through real JWT guard and raw HTTP body');
        file = (await uploaded.json()).response;
        const downloaded = await fetch(endpoint + `/api/sub/geofiles/${file.id}/${file.filename}`, { headers, signal: AbortSignal.timeout(10000) });
        assert.equal(downloaded.status, 200);
        assert.equal(downloaded.headers.get('x-content-type-options'), 'nosniff');
        assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), data);
        const created = await request('/api/subscription-templates', 'POST', { name: 'GEO_RUNTIME_FIXTURE', templateType: 'SINGBOX' });
        assert.equal(created.status, 201);
        template = created.body.response;
        assert.ok(template.uuid);
        assert.equal((await request('/api/subscription-templates', 'PATCH', {
            uuid: template.uuid,
            templateJson: { outbounds: [{ type: 'direct', tag: 'direct' }], route: { final: 'direct' },
                remnacust: { geofiles: [{ id: file.id, target: 'direct' }] } },
        })).status, 200, 'Geofile reference validates and persists through the production template service');
        assert.equal((await request('/api/geofiles/' + file.id, 'DELETE')).status, 409, 'Saved template prevents deleting its dataset');
    } finally {
        if (template) assert.equal((await request('/api/subscription-templates/' + template.uuid, 'DELETE')).status, 204);
        if (file) assert.equal((await request('/api/geofiles/' + file.id, 'DELETE')).status, 200);
    }
    console.log('PASS geofiles: real authentication, binary HTTP upload/download, database references and deletion protection');
}
async function main() {
    // Refuse accidental execution against an existing installation.
    assert.equal(await prisma.users.count(), 0, 'HWID fixture requires an empty user database');
    assert.equal(await prisma.admin.count(), 0, 'HWID fixture requires an empty administrator database');
    savedSettings = await prisma.subscriptionSettings.findFirstOrThrow();
    assert.equal(savedSettings.hwidSettings.enabled, true, 'Fresh database must enable HWID');
    assert.equal(savedSettings.hwidSettings.fallbackDeviceLimit, 999);
    try {
        assert.equal((await request('/api/hwid/devices', 'GET', undefined, false)).status, 401);
        const registration = await request('/api/auth/register', 'POST', {
            username: 'hwid_fixture_admin', password: 'Aa1' + crypto.randomBytes(24).toString('hex'),
        }, false);
        assert.equal(registration.status, 201);
        token = registration.body.response.accessToken;
        adminCreated = true;
        await checkGeofiles();
        const inherited = await createUser('hwid_fixture_inherited');
        assert.equal(inherited.hwidDeviceLimit, null, 'Omitted count must inherit the general limit');
        // Set the fallback through the real API so cached settings are invalidated too.
        assert.equal((await request('/api/subscription-settings', 'PATCH', {
            uuid: savedSettings.uuid, hwidSettings: { ...savedSettings.hwidSettings, fallbackDeviceLimit: 2 },
        })).status, 200);
        const registrations = await Promise.all(Array.from({ length: 8 }, (_, index) =>
            request('/api/hwid/devices', 'POST', { userId: inherited.id, hwid: 'hwid-fixture-' + index })));
        assert.equal(registrations.filter(result => result.status === 200).length, 2);
        for (const result of registrations.filter(result => result.status !== 200)) {
            assert.equal(result.status, 400);
            assert.equal(result.body.errorCode, 'A099');
        }
        let devices = await request('/api/hwid/devices/' + inherited.id);
        assert.equal(devices.body.response.total, 2);
        const first = devices.body.response.devices[0].hwid;
        assert.equal((await request('/api/hwid/devices/delete', 'POST', { userId: inherited.id, hwid: first })).status, 200);
        assert.equal((await request('/api/hwid/devices/delete', 'POST', { userId: inherited.id, hwid: first })).status, 200, 'Delete retry is idempotent');
        assert.equal((await request('/api/hwid/devices', 'POST', { userId: inherited.id, hwid: 'hwid-replacement' })).status, 200);
        const limited = await createUser('hwid_fixture_limited', 1);
        assert.equal((await request('/api/hwid/devices', 'POST', { userId: limited.id, hwid: 'hwid-personal-one' })).status, 200);
        assert.equal((await request('/api/hwid/devices', 'POST', { userId: limited.id, hwid: 'hwid-personal-two' })).body.errorCode, 'A099');
        const limitRemarks = ['HWID limit fixture', 'Contact fixture support'];
        assert.equal((await request('/api/subscription-settings', 'PATCH', {
            uuid: savedSettings.uuid,
            customRemarks: { ...savedSettings.customRemarks, HWIDMaxDevicesExceeded: limitRemarks },
        })).status, 200);
        const subscription = await fetch('http://127.0.0.1:3000/api/sub/' + limited.shortUuid + '/json', {
            headers: { ...headers, 'User-Agent': 'fixture-client', 'x-hwid': 'hwid-personal-two' },
            signal: AbortSignal.timeout(15000),
        });
        assert.equal(subscription.status, 200);
        assert.equal(subscription.headers.get('x-hwid-max-devices-reached'), 'true');
        assert.equal(subscription.headers.get('x-hwid-limit'), 'true');
        const configs = await subscription.json();
        assert.ok(Array.isArray(configs));
        assert.deepEqual(configs.map(config => config.remarks), limitRemarks);
        const unlimited = await createUser('hwid_fixture_unlimited', 0);
        for (let index = 0; index < 4; index++)
            assert.equal((await request('/api/hwid/devices', 'POST', { userId: unlimited.id, hwid: 'hwid-unlimited-' + index })).status, 200);
        assert.equal((await request('/api/hwid/devices/registration/' + unlimited.id, 'PATCH', { registrationAllowed: false })).status, 200);
        assert.equal((await request('/api/hwid/devices', 'POST', { userId: unlimited.id, hwid: 'hwid-denied-new' })).status, 403, 'Registration policy also applies to unlimited accounts');
        devices = await request('/api/hwid/devices/' + unlimited.id);
        assert.equal(devices.body.response.total, 4);
        console.log('PASS live panel HWID API: enabled seed, inherited and explicit capacity, concurrent admission, unlimited account, registration lock, idempotent deletion, protected routes and personalized subscription remarks');
    } finally {
        if (token) {
            assert.equal((await request('/api/subscription-settings', 'PATCH', {
                uuid: savedSettings.uuid, hwidSettings: savedSettings.hwidSettings, customRemarks: savedSettings.customRemarks,
            })).status, 200);
        }
        await prisma.users.deleteMany({ where: { id: { in: users } } });
        if (adminCreated) await prisma.admin.deleteMany({ where: { username: 'hwid_fixture_admin' } });
    }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; }).finally(() => prisma.$disconnect());
