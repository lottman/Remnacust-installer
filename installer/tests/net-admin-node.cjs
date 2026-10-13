'use strict';
const assert = require('node:assert/strict');
const net = require('node:net');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');

const expected = process.env.EXPECTED_NET_ADMIN === 'true';
const allowUnsupported = process.env.ALLOW_UNSUPPORTED_SOCKET_DESTROY === 'true';
const native = (name) => require(`/opt/app/dist/node_modules/${name}/prebuilds/linux-${process.arch}/${name}.glibc.node`);
const sockets = native('sockdestroy');
const { NftManager } = native('nftables-napi');
const watchdog = setTimeout(() => { console.error('NET_ADMIN test timed out'); process.exit(1); }, 20000);

(async () => {
    assert.equal(sockets.hasCapNetAdmin(), expected);
    const manager = new NftManager({ tableName: 'remnacust_netadmin_test', ingressAddrSets: ['blocked'], logging: false });
    if (expected) {
        await manager.createTable();
        try {
            await manager.addAddress({ ip: '198.51.100.10', set: 'blocked' });
            await manager.removeAddress({ ip: '198.51.100.10', set: 'blocked' });
        } finally {
            await manager.deleteTable();
        }
    } else {
        await assert.rejects(() => manager.createTable(), /Operation not permitted|Permission denied|EPERM|EACCES/i);
    }

    const server = net.createServer();
    let client, peer;
    let socketCheck = 'TCP destruction';
    try {
        server.listen(0, '127.0.0.1');
        await once(server, 'listening');
        const accepted = once(server, 'connection');
        client = net.createConnection(server.address().port, '127.0.0.1');
        client.on('error', () => {});
        const closed = new Promise((resolve) => client.once('close', resolve));
        await once(client, 'connect');
        [peer] = await accepted;
        peer.on('error', () => {});
        const result = await sockets.killSockets({ src: '127.0.0.1' });
        assert.ok(result.found >= 1, 'fixture connection was not found');
        if (result.destroyErrno === 95) {
            assert.ok(allowUnsupported, 'kernel does not support SOCK_DESTROY (EOPNOTSUPP)');
            assert.equal(result.killed, 0);
            socketCheck = 'TCP destruction SKIPPED: kernel lacks SOCK_DESTROY';
        } else if (expected) {
            assert.ok(result.killed >= 1, 'NET_ADMIN did not allow socket destruction');
            await Promise.race([closed, delay(5000, null, { ref: false }).then(() => { throw new Error('connection remained open'); })]);
        } else {
            assert.equal(result.killed, 0);
            assert.equal(result.destroyErrno, 1);
            assert.equal(client.destroyed, false);
        }
    } finally {
        client?.destroy();
        peer?.destroy();
        server.close();
        clearTimeout(watchdog);
    }
    console.log(`PASS node NET_ADMIN=${expected}: native capability, nftables; ${socketCheck}`);
})().catch((error) => { console.error(error); process.exit(1); });
