'use strict';

const { PrismaClient } = require('@prisma/client');
const jwt = require('jsonwebtoken');

const SCOPES = Object.freeze([
    'system:metadata', 'subscription:get', 'subscriptions:subpage-config',
    'subscription-page-configs:get', 'subscription-page-configs:list',
]);

async function provision(prisma, uuid, secret) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid || '') ||
        typeof secret !== 'string' || secret.length < 32) throw new Error('Invalid installation credentials');
    const name = 'Remnacust subscription page';
    const existing = await prisma.apiTokens.findUnique({ where: { uuid } });
    // Resume after a file-write failure, preserving expiry and any intentional revocation of rights.
    if (existing && (existing.name !== name || existing.expireAt <= new Date() ||
        existing.scopes.length !== SCOPES.length || !SCOPES.every(scope => existing.scopes.includes(scope)))) {
        throw new Error('Service token changed; restore its protected environment file');
    }
    const row = existing || await prisma.apiTokens.create({ data: {
        uuid, name, expireAt: new Date(Date.now() + 10 * 365 * 86400000), scopes: [...SCOPES],
    } });
    return jwt.sign({ uuid, username: null, role: 'API',
        iat: Math.floor(row.createdAt.getTime() / 1000), exp: Math.floor(row.expireAt.getTime() / 1000) },
        secret, { algorithm: 'HS256' });
}

if (require.main === module || process.argv[1] === '-') {
    const prisma = new PrismaClient();
    provision(prisma, process.env.REMNACUST_SUBSCRIPTION_TOKEN_UUID, process.env.APP_SECRET)
        .then(token => process.stdout.write(token + '\n'))
        .catch(() => { console.error('Не удалось создать ограниченный токен сайта подписки. Проверьте БД и сохранённый subscription.env.'); process.exitCode = 1; })
        .finally(() => prisma.$disconnect());
}
module.exports = { provision, SCOPES };
