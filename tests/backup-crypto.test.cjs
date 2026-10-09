const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const {test} = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../installer/installer.sh'), 'utf8');
const script = source.split("initialize_panel_backups() {")[1].split("<<'JS'\n")[1].split('\nJS\n')[0];
test('first-install backup key and envelope use the panel formats and reject overwrites', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'remnacust-backup-crypto-'));
    try {
        const password = 'Test-backup-123456789!';
        const secret = 'test-app-secret';
        let output = '', failure = '';
        const process = {env: {APP_SECRET: secret}, stdout: {write: (s) => {output += s;}}, exitCode: 0};
        const files = {
            ...fs,
            readFileSync: () => Buffer.from(password),
            lstatSync: () => fs.lstatSync(root),
            chmodSync: () => {},
            writeFileSync: (name, bytes, options) => fs.writeFileSync(path.join(root, path.basename(name)), bytes, options)
        };
        const context = {Buffer, process, require: (name) => name === 'node:fs' ? files : require(name), console: {error: (s) => {failure += s;}}};
        vm.runInNewContext(script, {...context});
        assert.equal(process.exitCode, 0);
        assert.equal(failure, '');
        assert.ok(output.startsWith('xera1:'));
        assert.ok(!output.includes(password));
        const raw = Buffer.from(output.slice(6), 'base64');
        const key = crypto.createHmac('sha256', secret).update('xera-keyring-v1').digest();
        const decipher = crypto.createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
        decipher.setAuthTag(raw.subarray(12, 28));
        assert.equal(Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString(), password);
        const verification = fs.readFileSync(path.join(root, '.backup-key'));
        assert.equal(verification.length, 48);
        assert.deepEqual(crypto.scryptSync(password, verification.subarray(0, 16), 32), verification.subarray(16));
        assert.notDeepEqual(crypto.scryptSync('wrong-password', verification.subarray(0, 16), 32), verification.subarray(16));
        output = '';
        vm.runInNewContext(script, {...context});
        assert.equal(process.exitCode, 1);
        assert.equal(output, '');
        assert.deepEqual(fs.readFileSync(path.join(root, '.backup-key')), verification);
    } finally {
        fs.rmSync(root, {recursive: true, force: true});
    }
});
