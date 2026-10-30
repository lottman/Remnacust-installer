'use strict';

const { PrismaClient } = require('@prisma/client');
const jwt = require('jsonwebtoken');

const SCOPES = Object.freeze([
    'system:metadata', 'subscriptions:subpage-config',
    'subscription-page-configs:get', 'subscription-page-configs:list',
]);

function reusable(row) {
    return row && row.name === 'Remnacust subscription page' &&
        (row.expireAt === null || row.expireAt > new Date()) &&
        (row.scopes.length === SCOPES.length ||
            (row.scopes.length === SCOPES.length + 1 && row.scopes.includes('subscription:get'))) &&
        SCOPES.every(scope => row.scopes.includes(scope));
}

async function provision(prisma, uuid, secret) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid || '') ||
        typeof secret !== 'string' || secret.length < 32) throw new Error('Invalid installation credentials');
    const name = 'Remnacust subscription page';
    const existing = await prisma.apiTokens.findUnique({ where: { uuid } });
    // Resume after a file-write failure, preserving expiry and any intentional revocation of rights.
    if (existing && !reusable(existing)) {
        throw new Error('Service token changed; restore its protected environment file');
    }
    let row = existing || await prisma.apiTokens.create({ data: {
        uuid, name, expireAt: new Date(Date.now() + 10 * 365 * 86400000), scopes: [...SCOPES],
    } });
    // This old grant never corresponded to an authenticated endpoint. Remove
    // only that exact legacy extra, preserving the identity and expiration.
    if (existing && existing.scopes.includes('subscription:get')) {
        row = await prisma.apiTokens.update({where:{uuid},data:{scopes:[...SCOPES]}});
    }
    return jwt.sign({ uuid, username: null, role: 'API',
        iat: Math.floor(row.createdAt.getTime() / 1000),
        ...(row.expireAt === null ? {permanent: true} : {exp: Math.floor(row.expireAt.getTime() / 1000)}) },
        secret, { algorithm: 'HS256' });
}

async function provisionForInstall(prisma, uuid, secret, candidate) {
    if (candidate) {
        let claims;
        try { claims = jwt.verify(candidate, secret, {algorithms: ['HS256']}); } catch { /* A different panel or revoked credential gets a new identity. */ }
        if (claims && claims.role === 'API' && typeof claims.uuid === 'string' &&
            /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(claims.uuid)) {
            const row = await prisma.apiTokens.findUnique({where: {uuid: claims.uuid}});
            if (reusable(row)) return provision(prisma, claims.uuid, secret);
        }
    }
    return provision(prisma, uuid, secret);
}

if (require.main === module || process.argv[1] === '-') {
    const prisma = new PrismaClient();
    provisionForInstall(prisma, process.env.REMNACUST_SUBSCRIPTION_TOKEN_UUID, process.env.APP_SECRET,
        process.env.REMNACUST_SUBSCRIPTION_REUSE_TOKEN)
        .then(token => process.stdout.write(token + '\n'))
        .catch(() => { console.error('Не удалось создать ограниченный токен сайта подписки. Проверьте БД и сохранённый subscription.env.'); process.exitCode = 1; })
        .finally(() => prisma.$disconnect());
}
module.exports = { provision, provisionForInstall, SCOPES };
