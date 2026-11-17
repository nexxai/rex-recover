import { execFileSync } from 'node:child_process';
import {
    closeSync, fstatSync, openSync, readSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { basename, isAbsolute, resolve } from 'node:path';
import { Plugin } from '@opencode/plugin/tui';
import { createEffect, onCleanup, untrack } from 'solid-js';
import { Rex } from './rpc.mjs';

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

function clientContext() {
    try {
        if (unsupportedOverrides.some(name => Boolean(process.env[name]))
            || ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']
                .some(name => process.env[name] && !isAbsolute(process.env[name]))
            || !validPath(homedir())) {
            return;
        }
        const home = realpathSync(homedir());
        const environment = {};
        for (const [name, suffix] of Object.entries({
            XDG_CONFIG_HOME: '.config', XDG_DATA_HOME: '.local/share',
            XDG_STATE_HOME: '.local/state', XDG_CACHE_HOME: '.cache',
        })) {
            environment[name] = realpathSync(process.env[name] || resolve(home, suffix));
            if (!validPath(environment[name]) || !statSync(environment[name]).isDirectory()) {
                return;
            }
        }
        if (!validPath(home) || !statSync(home).isDirectory()) return;
        return { home, env: environment };
    } catch {
        return;
    }
}

function localStorage(storage, client) {
    if (storage.home !== client.home || Object.keys(client.env).some(name => storage.env[name] !== client.env[name])) {
        return false;
    }
    try {
        const database = realpathSync(storage.env.OPENCODE_DB);
        if (database !== storage.env.OPENCODE_DB) return false;
        const file = openSync(database, 'r');
        try {
            const status = fstatSync(file);
            const header = Buffer.alloc(16);
            return status.isFile() && String(status.dev) === storage.file.dev && String(status.ino) === storage.file.ino
                && readSync(file, header, 0, 16, 0) === 16 && header.toString() === 'SQLite format 3\0';
        } finally {
            closeSync(file);
        }
    } catch (error) {
        if (!['ENOENT', 'ENOTDIR', 'ELOOP'].includes(error.code)) {
            throw error;
        }
        return false;
    }
}

function loopbackOrigin(url) {
    // Do not resolve DNS or accept URL-normalized aliases (127.1, integer IPs).
    if (typeof url !== 'string' || !/^https?:\/\/(?:127\.0\.0\.1|\[::1\])(?::[0-9]+)?\/?$/.test(url)) {
        return;
    }
    try {
        return new URL(url).origin;
    } catch {
        return;
    }
}

function managedService(file, connected) {
    let registration;
    try {
        registration = JSON.parse(readBounded(file));
    } catch (error) {
        if (error.code === 'ENOENT' || error instanceof SyntaxError) return false;
        throw error;
    }
    if (!registration || typeof registration !== 'object' || Array.isArray(registration)) {
        return false;
    }
    // Native v2.3.0 Service.Info is flat. Read only these metadata fields;
    // registration credentials are never accessed or used for another client.
    const { pid, version, url } = registration;
    if (!Number.isSafeInteger(pid) || pid < 1 || pid !== connected.pid || version !== connected.version
        || !Array.isArray(connected.urls)) {
        return false;
    }
    const origin = loopbackOrigin(url);
    return origin !== undefined && connected.urls.some(value => loopbackOrigin(value) === origin);
}

function readBounded(path) {
    const file = openSync(path, 'r');
    try {
        if (!fstatSync(file).isFile()) {
            throw new Error('Invalid observer file');
        }
        const buffer = Buffer.alloc(65537);
        const length = readSync(file, buffer, 0, buffer.length, 0);
        if (length > 65536) {
            throw new Error('Observer file too large');
        }
        return buffer.subarray(0, length).toString('utf8');
    } finally {
        closeSync(file);
    }
}

function launchBinding() {
    const { REX_SESSION: session, REX_BLOCK: block } = process.env;
    if (!/^session:[a-zA-Z0-9:-]+$/.test(session || '') || !/^block:[a-zA-Z0-9:-]+$/.test(block || '')) {
        return;
    }
    const state = process.env.REX_RECOVER_STATE_DIR
        || `${process.env.XDG_STATE_HOME || `${homedir()}/.local/state`}/rex-recover`;
    const directory = process.env.REX_RECOVER_LAUNCH_DIR || `${state}/launches`;
    if (!validPath(directory)) return;
    const path = resolve(directory, block);
    const status = statSync(path);
    if (realpathSync(directory) !== directory || (statSync(directory).mode & 0o077) !== 0
        || (status.mode & 0o077) !== 0 || realpathSync(path) !== path) {
        return;
    }
    const text = readBounded(path);
    const fields = text.split('\0');
    if (fields.pop() !== '' || fields.length < 10 || fields[0] !== 'rex-recover-launch-v2'
        || fields[1] !== session || fields[2] !== block || !/^[1-9]\d*$/.test(fields[3])
        || !fields[4] || fields.some(value => controls.test(value))
        || fields[5] !== 'opencode' || fields[7] !== 'anomalyco-opencode'
        || ![fields[6], fields[8], fields[9]].every(validPath)) {
        return;
    }
    const launch = {
        pid: Number(fields[3]), started_at: fields[4], session_id: session, block_id: block, app: fields[5],
    };
    if (!Number.isSafeInteger(launch.pid)) return;
    const snapshot = execFileSync('ps', ['-axo', 'pid=,ppid=,lstart=,comm='],
        { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' }, timeout: 2000, maxBuffer: 1048576 });
    const processes = new Map();
    for (const line of snapshot.split('\n')) {
        const row = line.match(/^\s*(\d+)\s+(\d+)\s+(.{24})\s+(.+?)\s*$/);
        if (row) processes.set(Number(row[1]), { parent: Number(row[2]), started: row[3], name: basename(row[4]) });
    }
    const owner = processes.get(process.pid);
    let current = process.pid;
    let natives = 0;
    for (let depth = 0; depth < 64 && processes.has(current); depth++) {
        const entry = processes.get(current);
        if (entry.name === 'opencode' && ++natives > 1) return;
        if (current === launch.pid) {
            if (entry.started !== launch.started_at || (current !== process.pid && owner.name !== 'opencode')) return;
            return {
                path, status, launch, owner_pid: process.pid, owner_started_at: owner.started,
                selection: `${path}.${launch.pid}.${Buffer.from(launch.started_at).toString('hex')}.session`,
            };
        }
        current = entry.parent;
    }
}

export default Plugin.define({
    id: 'rex-recover.opencode',
    setup(context) {
        let binding;
        try {
            binding = launchBinding();
        } catch {}
        if (!binding) return;
        const client = clientContext();
        let generation = 0;
        let controller;
        let timeout;
        let selectedSessionID;
        let awaitingCreation = false;
        let connectionInvalidated = false;
        let stopCreation = () => {};
        let stopped = true;
        let lastReadyStorage;
        let lastPublished;
        let routeKey;
        let warned = false;

        function ownsSelection() {
            const status = statSync(binding.path);
            const current = JSON.parse(readBounded(binding.selection));
            return status.dev === binding.status.dev && status.ino === binding.status.ino
                && JSON.stringify(current.launch) === JSON.stringify(binding.launch)
                && current.owner_pid === binding.owner_pid && current.owner_started_at === binding.owner_started_at;
        }

        function publish(signal, ownedOnly = false) {
            let temporary;
            let file;
            try {
                const status = statSync(binding.path);
                if (status.dev !== binding.status.dev || status.ino !== binding.status.ino) return;
                if (ownedOnly && !ownsSelection()) return;
                const text = JSON.stringify({
                    version: 1, launch: binding.launch,
                    owner_pid: binding.owner_pid, owner_started_at: binding.owner_started_at, ...signal,
                });
                if (text === lastPublished || Buffer.byteLength(text) > 65536) return;
                const candidate = `${binding.selection}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
                file = openSync(candidate, 'wx', 0o600);
                temporary = candidate;
                writeFileSync(file, text);
                closeSync(file);
                file = undefined;
                renameSync(temporary, binding.selection);
                lastPublished = text;
            } catch {
                if (signal.state === 'none') {
                    try {
                        if (ownsSelection()) {
                            unlinkSync(binding.selection);
                            lastPublished = undefined;
                        }
                        return;
                    } catch (error) {
                        if (error.code === 'ENOENT') return;
                    }
                }
                if (!warned) {
                    warned = true;
                    console.warn('Rex Recover: OpenCode selection could not be updated; recovery metadata may be stale.');
                }
            } finally {
                if (file !== undefined) {
                    try { closeSync(file); } catch {}
                }
                if (temporary) {
                    try { unlinkSync(temporary); } catch {}
                }
            }
        }

        const mode = process.env.REX_RECOVER_SESSIONS;
        if (mode !== '1' && !mode?.split(',').includes('opencode')) {
            publish({ state: 'none' }, true);
            return;
        }

        function cancelLookup() {
            generation++;
            clearTimeout(timeout);
            controller?.abort();
            controller = undefined;
        }

        async function lookup(sessionID, currentGeneration, signal) {
            try {
                const location = context.location ?? context.data.location.default();
                const storage = await context.client.rpc(Rex).context({ sessionID }, { location, signal });
                if (currentGeneration !== generation || stopped) return;
                if (storage?.state === 'unsupported') {
                    publish({ state: 'none' });
                    return;
                }
                const absent = storage?.state === 'absent';
                const session = storage?.session;
                if (!['ready', 'absent'].includes(storage?.state)
                    || (absent ? session !== undefined
                        : !session || session.id !== sessionID || !validPath(session.location?.directory))
                    || !Number.isSafeInteger(storage.pid) || storage.pid < 1
                    || typeof storage.version !== 'string' || !storage.version
                    || typeof storage.channel !== 'string' || !storage.channel || !validPath(storage.home)
                    || ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'OPENCODE_DB']
                        .some(name => !validPath(storage.env?.[name]))
                    || ['dev', 'ino'].some(name => typeof storage.file?.[name] !== 'string'
                        || !/^\d+$/.test(storage.file[name]))) {
                    publish({ state: 'error' });
                    return;
                }
                if (session?.parentID !== undefined) {
                    publish({ state: 'none' });
                    return;
                }
                const connected = await context.client.server.info({ signal });
                if (currentGeneration !== generation || stopped) return;
                if (!connected || !Number.isSafeInteger(connected.pid) || typeof connected.version !== 'string') {
                    throw new Error('Invalid server metadata');
                }
                if (connected.pid !== storage.pid || connected.version !== storage.version) {
                    publish({ state: absent ? 'error' : 'none' });
                    return;
                }
                // Native v2.3.0 service-config.ts filename(): unlike the DB, prod
                // has its own service registration. Never read/migrate legacy files.
                const registration = ['latest', 'dev', 'beta', 'next'].includes(storage.channel)
                    ? 'service.json' : `service-${storage.channel.replace(/[^a-zA-Z0-9._-]/g, '-')}.json`;
                const managed = managedService(resolve(client.env.XDG_STATE_HOME, 'opencode', registration), connected);
                if (JSON.stringify(clientContext()) !== JSON.stringify(client) || !localStorage(storage, client)) {
                    publish({ state: absent ? 'error' : 'none' });
                    return;
                }
                const identity = JSON.stringify([
                    storage.version, storage.channel, storage.home, storage.env, storage.file, managed,
                ]);
                if (absent) {
                    // Missing on a different backend is not evidence that the
                    // previously observed session was deleted. PID changes alone
                    // remain valid when a daemon restarts on the same store.
                    publish({ state: lastReadyStorage && lastReadyStorage !== identity ? 'error' : 'none' });
                    return;
                }
                lastReadyStorage = identity;
                awaitingCreation = false;
                publish({ state: 'ready', id: sessionID, home: storage.home, env: storage.env, managed });
            } catch (error) {
                if (currentGeneration === generation && !stopped) {
                    publish({ state: 'error' });
                }
            } finally {
                if (currentGeneration === generation) {
                    clearTimeout(timeout);
                    controller = undefined;
                }
            }
        }

        function refresh() {
            if (stopped || connectionInvalidated || !selectedSessionID || controller) return;
            const currentGeneration = ++generation;
            controller = new AbortController();
            timeout = setTimeout(() => {
                if (currentGeneration !== generation || stopped) return;
                cancelLookup();
                publish({ state: 'error' });
            }, 2000);
            void lookup(selectedSessionID, currentGeneration, controller.signal);
        }

        function stop() {
            if (stopped) return;
            stopped = true;
            cancelLookup();
            stopCreation();
            publish({ state: 'none' }, true);
        }

        const stopConnection = context.data.on('server.connected', () => untrack(() => {
            cancelLookup();
            connectionInvalidated = true;
            if (!stopped) publish({ state: selectedSessionID ? 'error' : 'none' });
        }));
        const unregister = context.ui.slot({
            append: 'app',
            render() {
                stopped = false;
                routeKey = undefined;
                onCleanup(stop);
                stopCreation = context.data.on('session.created', event => {
                    if (!stopped && !connectionInvalidated && awaitingCreation && event.data.sessionID === selectedSessionID) {
                        awaitingCreation = false;
                        cancelLookup();
                        refresh();
                    }
                });
                createEffect(() => {
                    const route = context.ui.router.current();
                    const sessionID = route.type === 'session' ? route.sessionID : undefined;
                    const location = context.location ?? context.data.location.default();
                    const key = JSON.stringify([sessionID, location.directory, location.workspaceID]);
                    if (key === routeKey) return;
                    routeKey = key;
                    untrack(() => {
                        cancelLookup();
                        selectedSessionID = client && typeof sessionID === 'string'
                            && /^ses[\w-]+$/.test(sessionID) && sessionID.length <= 256 ? sessionID : undefined;
                        awaitingCreation = Boolean(selectedSessionID);
                        publish({ state: selectedSessionID ? (connectionInvalidated ? 'error' : 'pending') : 'none' });
                        refresh();
                    });
                });
                return null;
            },
        });
        return () => {
            stop();
            stopConnection();
            unregister();
        };
    },
});
