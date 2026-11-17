import { createHash, randomBytes } from 'node:crypto';
import { realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, resolve } from 'node:path';
import { Plugin } from '@opencode/plugin';
import { Database } from 'bun:sqlite';
import { Rex } from './rpc.mjs';

const pluginID = 'rex-recover.opencode';
const controls = /[\u0000-\u001f\u007f-\u009f]/;
const unsupportedOverrides = [
    'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG', 'OPENCODE_CONFIG_CONTENT', 'OPENCODE_CLI_CONFIG_CONTENT',
    'OPENCODE_CONFIG_PROJECT_DISABLE', 'OPENCODE_DISABLE_PROJECT_CONFIG', 'OPENCODE_DISABLE_CLAUDE_CODE',
    'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS', 'OPENCODE_TEST_HOME', 'OPENCODE_FLAGS', 'OPENCODE_SIMULATE',
    'OPENCODE_SERVICE_FILE',
];

function validPath(value) {
    return typeof value === 'string' && isAbsolute(value) && !controls.test(value);
}

function directory(value) {
    if (!validPath(value)) {
        return;
    }
    const canonical = realpathSync(value);
    return validPath(canonical) && statSync(canonical).isDirectory() ? canonical : undefined;
}

function fileIdentity(database) {
    const status = statSync(database);
    return status.isFile() ? { dev: String(status.dev), ino: String(status.ino) } : undefined;
}

function storageContext(channel) {
    try {
        if (unsupportedOverrides.some(name => Boolean(process.env[name]))) {
            return;
        }
        const home = directory(homedir());
        if (!home) {
            return;
        }
        const env = {};
        for (const [name, suffix] of Object.entries({
            XDG_CONFIG_HOME: '.config', XDG_DATA_HOME: '.local/share',
            XDG_STATE_HOME: '.local/state', XDG_CACHE_HOME: '.cache',
        })) {
            env[name] = directory(process.env[name] || resolve(home, suffix));
            if (!env[name]) {
                return;
            }
        }
        const filename = process.env.OPENCODE_DB ?? (
            ['latest', 'dev', 'beta', 'next', 'prod'].includes(channel)
            || ['1', 'true'].includes(process.env.OPENCODE_DISABLE_CHANNEL_DB)
                ? 'opencode.db' : `opencode-${channel.replace(/[^a-zA-Z0-9._-]/g, '-')}.db`
        );
        if (!filename || filename === ':memory:' || controls.test(filename)) {
            return;
        }
        env.OPENCODE_DB = realpathSync(resolve(env.XDG_DATA_HOME, 'opencode', filename));
        if (!validPath(env.OPENCODE_DB)) {
            return;
        }
        const file = fileIdentity(env.OPENCODE_DB);
        return file ? { home, env, file } : undefined;
    } catch (error) {
        if (!['ENOENT', 'ENOTDIR', 'ELOOP'].includes(error.code)) {
            throw error;
        }
    }
}

export default Plugin.define({
    id: pluginID,
    async setup(context) {
        let proven;
        let inFlight;
        let provingIdentity;
        // v2.3.0 host.ts namespaces plugin storage by UTF-16 hex; KV is JSON text in
        // kv(key,value), backed by the actual core DB. This narrow adapter reads ONLY
        // our exact proof key, never sessions/config/user rows. Schema errors fail closed.
        const namespace = 'plugin:' + pluginID.split('')
            .map(value => value.charCodeAt(0).toString(16).padStart(4, '0')).join('') + ':';
        const key = 'database-proof:' + createHash('sha256')
            .update(JSON.stringify([context.location.directory, context.location.workspaceID ?? null])).digest('hex');

        function readProof(storage) {
            // Native v2.3.0 Core's #sqlite bun condition uses
            // @effect/sql-sqlite-bun@4.1.0, which imports this SAME bun:sqlite
            // engine. Only SQLite may open/close this file: raw descriptors can
            // release Core's POSIX locks (see Core restrictToOwner()).
            const before = statSync(storage.env.OPENCODE_DB, { bigint: true });
            const database = new Database(storage.env.OPENCODE_DB, { readonly: true, create: false });
            let row;
            try {
                row = database.query('SELECT value FROM kv WHERE key = ?').get(namespace + key);
            } finally {
                database.close();
            }
            const after = statSync(storage.env.OPENCODE_DB, { bigint: true });
            if (['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].some(name => before[name] !== after[name])) {
                throw new Error('Database file changed during proof');
            }
            return row;
        }

        async function prove(storage) {
            const identity = JSON.stringify(storage);
            if (identity === proven) {
                // Keep malformed-file rejection on refresh without a fresh write.
                // This only reads our exact (normally removed) proof key.
                readProof(storage);
                return true;
            }
            if (inFlight) {
                if (identity === provingIdentity) {
                    return inFlight;
                }
                await inFlight;
                return prove(storage);
            }
            provingIdentity = identity;
            inFlight = (async () => {
                const witness = { nonce: randomBytes(32).toString('hex') };
                let matches = false;
                try {
                    await context.storage.set(key, witness);
                    const row = readProof(storage);
                    const value = row ? JSON.parse(row.value) : undefined;
                    matches = value?.nonce === witness.nonce
                        && JSON.stringify(storageContext(context.app.channel)) === identity;
                } finally {
                    // Public v2.3.0 StorageDomain calls this remove(), not delete().
                    // One stable key per location bounds leftovers if the host crashes.
                    await context.storage.remove(key);
                }
                if (matches) {
                    proven = identity;
                }
                return matches;
            })();
            try {
                return await inFlight;
            } finally {
                inFlight = undefined;
            }
        }

        const registration = await context.rpc.register(Rex, {
            async context(input, request) {
                if (typeof input?.sessionID !== 'string' || !/^ses/.test(input.sessionID)
                    || controls.test(input.sessionID)) {
                    throw new Error('Invalid session ID');
                }
                let session;
                let absent = false;
                try {
                    session = await context.session.get({ sessionID: input.sessionID }, { signal: request.signal });
                } catch (error) {
                    if (error?._tag === 'Session.NotFoundError' && error.sessionID === input.sessionID) {
                        absent = true;
                    } else {
                        throw error;
                    }
                }
                if (!absent && (!session || session.id !== input.sessionID || !validPath(session.location?.directory))) {
                    throw new Error('Invalid session metadata');
                }
                if (session?.parentID !== undefined || typeof context.app?.channel !== 'string'
                    || !context.app.channel || typeof context.app.version !== 'string' || !context.app.version
                    || typeof context.storage?.set !== 'function' || typeof context.storage?.remove !== 'function') {
                    return { state: 'unsupported' };
                }
                const storage = storageContext(context.app.channel);
                if (!storage || !await prove(storage)
                    || JSON.stringify(storageContext(context.app.channel)) !== JSON.stringify(storage)) {
                    return { state: 'unsupported' };
                }
                const result = {
                    state: absent ? 'absent' : 'ready',
                    pid: process.pid, version: context.app.version, channel: context.app.channel,
                    ...storage,
                };
                if (!absent) {
                    result.session = { id: session.id, location: { directory: session.location.directory } };
                }
                return result;
            },
        });
        return () => registration.dispose();
    },
});
