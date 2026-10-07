/* Run inside the verified panel image. Output contains hashes, never credentials. */
'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const { PrismaClient } = require('/opt/app/node_modules/@prisma/client');
const db = new PrismaClient();
class CheckError extends Error {}
const stable = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v);
const hash = value => crypto.createHash('sha256').update(stable(value)).digest('hex');
function protectedLeaves(value, path = [], result = {}) {
    if (value && typeof value === 'object' && !Array.isArray(value) && !(value instanceof Date) && !Buffer.isBuffer(value)) {
        result[JSON.stringify(path)] = hash('object');
        for (const key of Object.keys(value)) protectedLeaves(value[key], [...path, key], result);
    } else result[JSON.stringify(path)] = hash(value);
    return result;
}
function plain(value) {
    if (typeof value !== 'string' || !value.startsWith('xera1:')) return value;
    const bytes = Buffer.from(value.slice(6), 'base64');
    const key = crypto.createHmac('sha256', process.env.APP_SECRET).update('xera-keyring-v1').digest();
    const cipher = crypto.createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
    cipher.setAuthTag(bytes.subarray(12, 28));
    return Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString('utf8');
}
async function snapshot(previous) {
    const tables = await db.$queryRawUnsafe("SELECT table_name FROM information_schema.tables WHERE table_schema='public'");
    const names = new Set(tables.map(t => t.table_name));
    for (const pair of [['admin', 'xera_admin'], ['remnawave_settings', 'xera_remnawave_settings']]) {
        if (names.has(pair[0]) && names.has(pair[1])) throw new CheckError('conflicting legacy tables');
    }
    const specs = {
        users: ['id', 'short_uuid', 'username', 'trojan_password', 'vless_uuid', 'ss_password'],
        admin: ['uuid', 'username', 'password_hash', 'role'],
        config_profiles: null, remnawave_settings: null,
    };
    const result = {};
    const inboundTags = new Set();
    for (const [canonical, fields] of Object.entries(specs)) {
        const legacy = canonical === 'admin' ? 'xera_admin' : 'xera_' + canonical;
        const table = names.has(canonical) ? canonical : names.has(legacy) ? legacy : null;
        if (!table) { if (canonical === 'users') throw new CheckError('missing users'); continue; }
        const available = await db.$queryRawUnsafe('SELECT column_name FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 ORDER BY ordinal_position', 'public', table);
        const columns = previous?.[canonical]?.columns || fields || available.map(c => c.column_name).filter(c => !['updated_at', 'created_at'].includes(c));
        if (columns.some(c => !available.some(a => a.column_name === c))) throw new CheckError('missing protected column in ' + canonical);
        const id = available.some(c => c.column_name === 'uuid') ? 'uuid' : 'id';
        const selected = [...new Set([id, ...columns])];
        const rows = await db.$queryRawUnsafe(`SELECT ${selected.map(c => '"'+c+'"').join(',')} FROM "${table}"`);
        const hashes = {}, fieldsById = {};
        for (const row of rows) {
            if (canonical === 'config_profiles') {
                if (!Array.isArray(row.config?.inbounds) || !row.config.inbounds.length) throw new CheckError('profile has no inbounds');
                for (const inbound of row.config.inbounds) {
                    if (!inbound.tag || inboundTags.has(inbound.tag)) throw new CheckError('missing or duplicate inbound tag');
                    inboundTags.add(inbound.tag);
                }
            }
            for (const column of ['trojan_password', 'ss_password']) if (column in row) row[column] = plain(row[column]);
            hashes[String(row[id])] = hash(selected.map(c => row[c]));
            fieldsById[String(row[id])] = Object.fromEntries(selected.map(c => [c,
                canonical === 'remnawave_settings' && row[c] === null ? {} : protectedLeaves(row[c])
            ]));
        }
        result[canonical] = {columns, hashes, fields: fieldsById};
        if (previous?.[canonical]) for (const [key, digest] of Object.entries(previous[canonical].hashes)) {
            if (hashes[key] !== digest) {
                const changed = selected.filter(c => {
                    const oldFields = previous[canonical].fields?.[key]?.[c];
                    if (!oldFields) return true;
                    return Object.entries(oldFields).some(([path, value]) => value !== fieldsById[key]?.[c]?.[path]);
                });
                if (changed.length) throw new CheckError('protected data changed in ' + canonical + ': ' + changed.join(', '));
            }
        }
    }
    return result;
}
async function main() {
    if (process.argv[2] === 'preflight') {
        const migrations = await db.$queryRawUnsafe('SELECT migration_name, checksum, finished_at, rolled_back_at FROM "_prisma_migrations"');
        for (const item of migrations) {
            if (item.rolled_back_at) continue;
            const name = item.migration_name;
            if (!/^[a-zA-Z0-9_]+$/.test(name) || !item.finished_at) throw new CheckError('incomplete migration');
            const path = '/opt/app/prisma/migrations/' + name + '/migration.sql';
            const bytes = fs.existsSync(path) ? fs.readFileSync(path) : null;
            const lf = bytes?.toString('utf8').replace(/\r\n/g, '\n');
            const checksums = bytes ? [bytes, lf, lf.replace(/\n/g, '\r\n')].map(content => crypto.createHash('sha256').update(content).digest('hex')) : [];
            if (!checksums.includes(item.checksum)) {
                throw new CheckError('unknown or modified migration: ' + name);
            }
        }
        await snapshot();
        process.stdout.write('Database preflight passed\n');
    } else if (process.argv[2] === 'snapshot') {
        process.stdout.write(stable(await snapshot()) + '\n');
    } else if (process.argv[2] === 'verify') {
        const previous = JSON.parse(fs.readFileSync(0, 'utf8'));
        await snapshot(previous);
        process.stdout.write('Protected users, keys, administrators, profiles and settings verified\n');
    } else throw Error('invalid operation');
}
main().catch(error => { console.error(error instanceof CheckError ? 'Database check failed: ' + error.message : 'Database check failed: verify original APP_SECRET, migration history and conflicting tables. No credentials printed.'); process.exitCode = 1; }).finally(() => db.$disconnect());
