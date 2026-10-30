'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');

function helper() {
    const module = { exports: {} };
    const signed = [];
    const scope = { module, require: name => {
        if (name === '@prisma/client') return { PrismaClient: class {} };
        if (name === 'jsonwebtoken') return {
            sign: (...args) => { signed.push(args); return 'fixture.jwt.value'; },
            verify: (token, key, options) => {
                assert.deepEqual(JSON.parse(JSON.stringify(options)),{algorithms:['HS256']});
                if(token==='invalid.jwt.token')throw new Error('invalid signature');
                return {role:'API',uuid};
            },
        };
        throw new Error('Unexpected module');
    }, process: {argv: ['node', '/fixture/helper.cjs']}, Date };
    vm.runInNewContext(fs.readFileSync(require.resolve('../installer/subscription.cjs'), 'utf8'), scope);
    return {...module.exports, signed};
}
const uuid = 'd2ddf079-6f2c-463a-9c0a-cac0f9b6f292';
const secret = 'fixture-only-secret-with-more-than-32-characters';

test('provision and retry keep the same identity and read-only rights', async () => {
    const h = helper(); let row; let creates = 0;
    const prisma = {apiTokens: {
        findUnique: async () => row,
        create: async ({data}) => { creates++; row = {...data, createdAt: new Date()}; return row; },
    }};
    await h.provision(prisma, uuid, secret);
    await h.provision(prisma, uuid, secret);
    assert.equal(creates, 1);
    assert.deepEqual(JSON.parse(JSON.stringify(h.signed[0])), JSON.parse(JSON.stringify(h.signed[1])));
    assert.equal(h.signed[0][0].role, 'API');
    assert(!row.scopes.some(s => s.includes('*') || s.startsWith('users:') || s.startsWith('api-tokens:')));
    assert.equal(row.scopes.length, 4);
});

test('retry never restores altered rights or expiration', async () => {
    const h = helper(); let written = false;
    for (const changed of [{scopes: []}, {expireAt: new Date(0)}, {name: 'another token'}]) {
        const row = {uuid, name:'Remnacust subscription page', createdAt:new Date(),
            expireAt:new Date(Date.now()+86400000), scopes:[...h.SCOPES], ...changed};
        const prisma = {apiTokens: {findUnique:async () => row, create:async () => {written = true;}}};
        await assert.rejects(h.provision(prisma, uuid, secret));
    }
    assert.equal(written, false);
    assert.equal(h.signed.length, 0);
});

test('invalid UUID or application secret is rejected before touching the database', async () => {
    const h = helper(); const prisma = {apiTokens: {findUnique:async () => {throw new Error('Unexpected DB access');}}};
    await assert.rejects(h.provision(prisma, 'invalid', secret), /Invalid installation/);
    await assert.rejects(h.provision(prisma, uuid, 'short'), /Invalid installation/);
});

test('reinstall reuses its valid token and narrows only the known obsolete grant',async()=>{
    const h=helper();let creates=0,updates=0;
    let row={uuid,name:'Remnacust subscription page',scopes:[...h.SCOPES,'subscription:get'],createdAt:new Date(),expireAt:new Date(Date.now()+86400000)};
    const prisma={apiTokens:{findUnique:async({where})=>where.uuid===uuid?row:null,
        update:async({data})=>{updates++;row={...row,...data};return row;},
        create:async()=>{creates++;throw new Error('must reuse existing token');}}};
    await h.provisionForInstall(prisma,'79bb6909-1f98-47d8-b835-13af536ab8f2',secret,'valid.jwt.token');
    assert.equal(creates,0);assert.equal(updates,1);assert.equal(row.scopes.length,4);
    assert.equal(h.signed[0][0].uuid,uuid);
});

test('reinstall never resurrects a deleted identity or reinstates revoked rights',async()=>{
    const next='79bb6909-1f98-47d8-b835-13af536ab8f2';
    for(const candidate of [null,{uuid,name:'Remnacust subscription page',scopes:[],expireAt:new Date(Date.now()+86400000)},
        {uuid,name:'someone else',scopes:[],expireAt:new Date(Date.now()+86400000)}]) {
        const h=helper();const created=[];
        const prisma={apiTokens:{findUnique:async({where})=>where.uuid===uuid?candidate:null,
            create:async({data})=>{created.push(data.uuid);return{...data,createdAt:new Date()};}}};
        await h.provisionForInstall(prisma,next,secret,'valid.jwt.token');
        assert.deepEqual(created,[next]);assert.equal(h.signed[0][0].uuid,next);
    }
});
