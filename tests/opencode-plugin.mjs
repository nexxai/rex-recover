import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import * as filesystem from 'node:fs';
import * as operatingSystem from 'node:os';
import * as paths from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const pluginDirectory = new URL('../plugins/opencode-recover/', import.meta.url);
const manifest = JSON.parse(filesystem.readFileSync(new URL('package.json', pluginDirectory), 'utf8'));
const birth = 'Mon Nov 16 12:00:00 2026';
const overrides = [
    'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG', 'OPENCODE_CONFIG_CONTENT', 'OPENCODE_CLI_CONFIG_CONTENT',
    'OPENCODE_CONFIG_PROJECT_DISABLE', 'OPENCODE_DISABLE_PROJECT_CONFIG', 'OPENCODE_DISABLE_CLAUDE_CODE',
    'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS', 'OPENCODE_TEST_HOME', 'OPENCODE_FLAGS', 'OPENCODE_SIMULATE',
    'OPENCODE_SERVICE_FILE',
];

function deferred() {
    let resolve;
    let reject;
    const promise = new Promise((accept, fail) => { resolve = accept; reject = fail; });
    return { promise, resolve, reject };
}

async function settle() {
    for (let count = 0; count < 40; count++) { await Promise.resolve(); }
}

function clock() {
    let now = 0;
    let nextID = 0;
    const tasks = new Map();
    return {
        tasks,
        setTimeout(callback, delay) { const id = ++nextID; tasks.set(id, { callback, at: now + delay }); return id; },
        clearTimeout: id => tasks.delete(id),
        setInterval() { throw new Error('selection observation must not poll'); },
        clearInterval() { throw new Error('selection observation must not poll'); },
        async advance(duration) {
            now += duration;
            for (const [id, task] of [...tasks]) {
                if (task.at <= now) { tasks.delete(id); task.callback(); await settle(); }
            }
        },
    };
}

async function fixture(t, options = {}) {
    const directory = options.host?.directory
        || filesystem.realpathSync(filesystem.mkdtempSync(paths.join(operatingSystem.tmpdir(), 'rex-plugin-')));
    if (!options.host) { t.after(() => filesystem.rmSync(directory, { recursive: true, force: true })); }
    const home = paths.join(directory, 'home');
    for (const suffix of ['', '.config', '.local/share', '.local/state', '.cache']) {
        filesystem.mkdirSync(paths.join(home, suffix), { recursive: true });
    }
    const database = paths.join(directory, 'sessions.db');
    if (!options.host) { filesystem.writeFileSync(database, 'SQLite format 3\0private database'); }
    const launchDirectory = paths.join(directory, 'launches');
    filesystem.mkdirSync(launchDirectory, { recursive: true, mode: 0o700 });
    const pid = options.pid || 7001;
    const ownerPID = options.ownerPID || pid;
    const environment = {
        HOME: home, OPENCODE_DB: database, REX_RECOVER_SESSIONS: '1',
        REX_SESSION: 'session:fixture', REX_BLOCK: options.block || 'block:fixture',
        REX_RECOVER_LAUNCH_DIR: launchDirectory, ...options.env,
    };
    const launch = {
        pid, started_at: birth, session_id: 'session:fixture',
        block_id: options.block || 'block:fixture', app: 'opencode',
    };
    const launchFile = paths.join(launchDirectory, launch.block_id);
    const launchText = [
        'rex-recover-launch-v2', launch.session_id, launch.block_id, String(pid), birth,
        'opencode', directory, 'anomalyco-opencode', home, '/fixture/opencode',
    ].join('\0') + '\0';
    filesystem.writeFileSync(launchFile, launchText, { mode: 0o600 });
    const selectionFile = `${launchFile}.${pid}.${Buffer.from(birth).toString('hex')}.session`;
    const env = {
        XDG_CONFIG_HOME: paths.join(home, '.config'), XDG_DATA_HOME: paths.join(home, '.local/share'),
        XDG_STATE_HOME: paths.join(home, '.local/state'), XDG_CACHE_HOME: paths.join(home, '.cache'),
        OPENCODE_DB: database,
    };
    const status = filesystem.statSync(database);
    const storage = { home, env, file: { dev: String(status.dev), ino: String(status.ino) } };
    const registrationFile = paths.join(env.XDG_STATE_HOME, 'opencode/service.json');
    filesystem.mkdirSync(paths.dirname(registrationFile), { recursive: true });
    const registration = { pid: 4242, version: '2.3.0', url: 'http://127.0.0.1:4096', password: 'private-password' };
    filesystem.writeFileSync(registrationFile, JSON.stringify(registration));
    const ready = (id, extra = {}) => ({
        state: 'ready', pid: 4242, version: '2.3.0', channel: 'latest', ...storage,
        session: { id, location: { directory: '/workspace/project' } }, ...extra,
    });
    const absent = (extra = {}) => {
        const result = ready('unused', { ...extra, state: 'absent' });
        delete result.session;
        return result;
    };
    let lookup = async ({ sessionID }) => ready(sessionID);
    let connected = async () => ({ pid: 4242, version: '2.3.0', urls: ['http://127.0.0.1:4096'] });
    let registrationError;
    let fileError;
    let beforeRename = () => {};
    let partialWrite = false;
    let collideTemporary = false;
    let unlinkFailure = false;
    const calls = [];
    const infoCalls = [];
    const registrationReads = [];
    const fileReads = [];
    const writes = [];
    const titles = [];
    const warnings = [];
    const descriptors = new Map();
    const timer = clock();
    const events = new EventEmitter();
    const renderer = new EventEmitter();
    renderer.setTerminalTitle = value => titles.push(value);
    const effects = new Set();
    let cleanups = [];
    let route = { type: 'home' };
    let slot;
    let cleanup;
    let unregisters = 0;
    const modules = {
        'node:fs': {
            ...filesystem,
            openSync(file, flags, mode) {
                if (fileError && file === selectionFile) { throw fileError; }
                if (collideTemporary && flags === 'wx') {
                    collideTemporary = false;
                    filesystem.writeFileSync(file, 'foreign temporary', { mode: 0o600 });
                }
                if (paths.basename(file).startsWith('service')) {
                    registrationReads.push(file);
                    if (registrationError) { throw registrationError; }
                    assert.ok(file.startsWith(directory + '/'), 'never inspect host service registrations');
                }
                const descriptor = filesystem.openSync(file, flags, mode);
                descriptors.set(descriptor, file);
                return descriptor;
            },
            closeSync(descriptor) { descriptors.delete(descriptor); filesystem.closeSync(descriptor); },
            readSync(descriptor, ...arguments_) {
                fileReads.push(descriptors.get(descriptor));
                return filesystem.readSync(descriptor, ...arguments_);
            },
            writeFileSync(file, text, settings) {
                const target = typeof file === 'number' ? descriptors.get(file) : file;
                if (partialWrite && target.startsWith(selectionFile + '.') && target.endsWith('.tmp')) {
                    filesystem.writeFileSync(file, text.slice(0, 8), settings);
                    throw Object.assign(new Error('private partial write error'), { code: 'EIO' });
                }
                filesystem.writeFileSync(file, text, settings);
            },
            unlinkSync(file) {
                if (unlinkFailure && file === selectionFile) {
                    throw Object.assign(new Error('private unlink error'), { code: 'EACCES' });
                }
                filesystem.unlinkSync(file);
            },
            renameSync(from, to) {
                assert.equal(filesystem.statSync(from).mode & 0o777, 0o600);
                assert.equal(paths.dirname(from), paths.dirname(to));
                writes.push(filesystem.readFileSync(from, 'utf8'));
                beforeRename(from, to);
                filesystem.renameSync(from, to);
            },
        },
        'node:child_process': {
            execFileSync(command, arguments_, settings) {
                assert.equal(command, 'ps');
                assert.equal(settings.env.LC_ALL, 'C');
                if (options.startError) { throw new Error('process start unavailable'); }
                if (arguments_[0] === '-p') {
                    assert.deepEqual(Array.from(arguments_), ['-p', String(ownerPID), '-o', 'lstart=']);
                    return options.started || birth + '\n';
                }
                assert.deepEqual(Array.from(arguments_), ['-axo', 'pid=,ppid=,lstart=,comm=']);
                assert.equal(settings.maxBuffer, 1048576);
                return options.processes || `${pid} 1 ${options.started || birth} /fixture/opencode\n`;
            },
        },
        'node:os': { homedir: () => environment.HOME },
        'node:path': paths,
        '@opencode/plugin/tui': { Plugin: { define: value => value } },
        '@opencode/plugin/rpc': { Rpc: { define: value => value } },
        'solid-js': {
            untrack: callback => callback(),
            createEffect(callback) { effects.add(callback); cleanups.push(() => effects.delete(callback)); callback(); },
            onCleanup(callback) { cleanups.push(callback); },
        },
    };
    const sandbox = vm.createContext({
        ...timer, Buffer, AbortController, URL, console: { warn: message => warnings.push(message) },
        process: { env: environment, pid: ownerPID, cwd: () => directory, argv: ['/fixture/opencode'] },
    });
    const loaded = new Map();
    async function load(url) {
        if (loaded.has(url.href)) { return loaded.get(url.href); }
        const module = new vm.SourceTextModule(filesystem.readFileSync(url, 'utf8'), { context: sandbox });
        loaded.set(url.href, module);
        await module.link(specifier => {
            if (specifier.startsWith('.')) { return load(new URL(specifier, url)); }
            const exports = modules[specifier];
            assert.ok(exports, `unbundled dependency ${specifier}`);
            return new vm.SyntheticModule(Object.keys(exports), function () {
                for (const [name, value] of Object.entries(exports)) { this.setExport(name, value); }
            }, { context: sandbox });
        });
        return module;
    }
    const module = await load(new URL(manifest.exports['./tui'], pluginDirectory));
    await module.evaluate();
    const context = {
        app: { version: '2.3.0', channel: 'latest' }, location: { directory: '/workspace/project' }, renderer,
        client: {
            rpc(contract) {
                assert.equal(contract.id, 'rex-recover');
                return { context(input, settings) {
                    assert.ok(settings.signal instanceof AbortSignal);
                    calls.push({ input: JSON.parse(JSON.stringify(input)), settings });
                    return lookup(input, settings);
                } };
            },
            server: { info(settings) { infoCalls.push(settings); return connected(settings); } },
        },
        data: {
            location: { default: () => ({ directory: '/workspace/fallback' }) },
            on(type, callback) { events.on(type, callback); return () => events.off(type, callback); },
        },
        ui: {
            router: { current: () => route },
            slot(claim) {
                assert.equal(claim.append, 'app');
                slot = claim;
                return () => { unregisters++; unmount(); slot = undefined; };
            },
        },
    };
    function unmount() {
        const disposing = cleanups;
        cleanups = [];
        for (const dispose of disposing.reverse()) { dispose(); }
    }
    const pane = {
        directory, home, database, environment, launch, launchFile, launchText, selectionFile, registrationFile,
        storage, registration, ready, absent, calls, infoCalls, registrationReads, fileReads, writes, titles,
        timer, context, events, renderer, warnings,
        get slot() { return slot; },
        get unregisters() { return unregisters; },
        setLookup(value) { lookup = value; },
        setConnected(value) { connected = value; },
        setRegistrationError(value) { registrationError = value; },
        setFileError(value) { fileError = value; },
        setBeforeRename(value) { beforeRename = value; },
        setPartialWrite(value) { partialWrite = value; },
        setUnlinkFailure(value) { unlinkFailure = value; },
        collideTemporary() { collideTemporary = true; },
        temporaryFiles() {
            return filesystem.readdirSync(launchDirectory).filter(name =>
                name.startsWith(paths.basename(selectionFile) + '.') && name.endsWith('.tmp'));
        },
        writeRegistration(value = registration, file = registrationFile) {
            filesystem.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value));
        },
        sidecar() { return JSON.parse(filesystem.readFileSync(selectionFile, 'utf8')); },
        signal() {
            const { version, launch: bound, owner_pid, owner_started_at, ...signal } = pane.sidecar();
            assert.equal(version, 1);
            assert.deepEqual(bound, launch);
            assert.equal(owner_pid, ownerPID);
            assert.equal(owner_started_at, birth);
            return signal;
        },
        mount() { assert.ok(slot); assert.equal(slot.render(), null); },
        navigate(next) { route = next; for (const effect of [...effects]) { effect(); } },
        emit(type, sessionID) { events.emit(type, { type, data: sessionID === undefined ? {} : { sessionID } }); },
        unmount,
        cleanup() { cleanup?.(); cleanup = undefined; unmount(); },
    };
    options.prepare?.(pane);
    cleanup = await module.namespace.default.setup(context);
    t.after(() => pane.cleanup());
    return pane;
}

async function select(pane, id = 'ses_selected') {
    pane.navigate({ type: 'session', sessionID: id });
    await settle();
}

test('selection is published to its immutable launch sidecar without touching terminal titles', async t => {
    const pane = await fixture(t);
    pane.mount();
    await select(pane, 'ses_selectedBeta');
    assert.deepEqual(pane.titles, []);
    assert.deepEqual(pane.sidecar(), {
        version: 1, launch: pane.launch, owner_pid: 7001, owner_started_at: birth,
        state: 'ready', id: 'ses_selectedBeta', home: pane.home, env: pane.storage.env, managed: true,
    });
    assert.equal(filesystem.statSync(pane.selectionFile).mode & 0o777, 0o600);
    assert.equal(pane.fileReads.filter(file => file === pane.launchFile).length, 1);
    assert.equal(pane.fileReads.filter(file => file === pane.database).length, 1,
        'the final post-await local DB check is sufficient');
    assert.equal(manifest.dependencies?.['@opencode/client'], undefined);
    assert.equal(manifest.peerDependencies?.['@opencode/client'], undefined);
});

test('same-project panes follow independent idle switches; idle time and equivalent effects do no work', async t => {
    const first = await fixture(t);
    const second = await fixture(t, { host: first, pid: 7002, block: 'block:other' });
    first.mount();
    second.mount();
    await select(first, 'ses_firstAlpha');
    await select(second, 'ses_secondAlpha');
    await select(first, 'ses_firstBeta');
    const before = [first.calls.length, first.infoCalls.length, first.writes.length, first.fileReads.length];
    await first.timer.advance(3600000);
    await select(first, 'ses_firstBeta');
    first.context.location = { directory: '/workspace/project' };
    await select(first, 'ses_firstBeta');
    assert.deepEqual([first.calls.length, first.infoCalls.length, first.writes.length, first.fileReads.length], before);
    assert.equal(first.signal().id, 'ses_firstBeta');
    assert.equal(second.signal().id, 'ses_secondAlpha');
    assert.equal(second.calls.length, 1);
    assert.equal(first.timer.tasks.size, 0);
    assert.equal(first.renderer.eventNames().length, 0);
});

test('the installed Codex and OpenCode opt-ins do not exclude each other', async t => {
    const pane = await fixture(t, { env: { REX_RECOVER_SESSIONS: 'opencode,codex' } });
    pane.mount();
    await select(pane);
    assert.equal(pane.signal().id, 'ses_selected');
});

test('native server.connected latches this plugin context even when its captured client remains healthy', async t => {
    const pane = await fixture(t);
    pane.mount();
    await select(pane, 'ses_first');
    const calls = pane.calls.length;
    pane.emit('server.connected');
    assert.deepEqual(pane.signal(), { state: 'error' });
    assert.equal(pane.calls.length, calls, 'the old healthy client must not reauthorize READY');
    await select(pane, 'ses_other');
    pane.emit('session.created', 'ses_other');
    pane.emit('server.connected');
    await settle();
    assert.deepEqual(pane.signal(), { state: 'error' });
    assert.equal(pane.calls.length, calls);
    pane.navigate({ type: 'home' });
    assert.deepEqual(pane.signal(), { state: 'none' });
    pane.unmount();
    pane.mount();
    await select(pane, 'ses_afterRemount');
    assert.deepEqual(pane.signal(), { state: 'error' }, 'remounting within the same setup must retain the latch');
    assert.equal(pane.calls.length, calls);
    const before = [pane.calls.length, pane.infoCalls.length, pane.writes.length, pane.fileReads.length];
    await pane.timer.advance(3600000);
    assert.deepEqual([pane.calls.length, pane.infoCalls.length, pane.writes.length, pane.fileReads.length], before);
    pane.cleanup();
    const after = [pane.calls.length, pane.writes.length];
    pane.emit('server.connected');
    assert.deepEqual([pane.calls.length, pane.writes.length], after);
    assert.equal(pane.events.eventNames().length, 0, 'both native event subscriptions are released');
    const fresh = await fixture(t, { host: pane });
    fresh.mount();
    await select(fresh, 'ses_freshSetup');
    assert.equal(fresh.signal().id, 'ses_freshSetup', 'a new setup with a new native context can attest again');
    assert.equal(fresh.calls.length, 1);
});

test('connected-event invalidation cancels in-flight proof and ignores late successful or failed replies', async t => {
    for (const outcome of ['healthy-old-client', 'failed-old-client']) {
        const pane = await fixture(t);
        pane.mount();
        const delayed = deferred();
        pane.setLookup(() => delayed.promise);
        pane.navigate({ type: 'session', sessionID: 'ses_selected' });
        const signal = pane.calls[0].settings.signal;
        pane.emit('server.connected');
        assert.deepEqual(pane.signal(), { state: 'error' });
        assert.equal(signal.aborted, true);
        if (outcome === 'healthy-old-client') { delayed.resolve(pane.ready('ses_selected')); }
        else { delayed.reject(new Error('the old client failed')); }
        await settle();
        assert.deepEqual(pane.signal(), { state: 'error' }, outcome);
        assert.equal(pane.calls.length, 1);
        assert.equal(pane.infoCalls.length, 0, 'late metadata cannot advance to server-info proof');
    }
});

test('a connection change while the slot is unmounted invalidates the same setup before remount', async t => {
    const pane = await fixture(t);
    pane.mount();
    await select(pane, 'ses_selected');
    assert.equal(pane.calls.length, 1);
    pane.unmount();
    assert.deepEqual(pane.signal(), { state: 'none' });
    const writes = pane.writes.length;
    pane.emit('server.connected');
    assert.equal(pane.writes.length, writes, 'an unmounted connection event must not replace cleared NONE');
    pane.mount();
    await settle();
    assert.equal(pane.calls.length, 1, 'a remount must not reuse the healthy but unassociated captured client');
    assert.deepEqual(pane.signal(), { state: 'error' });
    assert.equal(pane.events.listenerCount('session.created'), 1);
    assert.equal(pane.events.listenerCount('server.connected'), 1);
    pane.unmount();
    assert.equal(pane.events.listenerCount('session.created'), 0);
    assert.equal(pane.events.listenerCount('server.connected'), 1, 'connection ownership lasts for the setup');
    pane.cleanup();
    assert.equal(pane.events.eventNames().length, 0);
});

test('outdated RPC and connected-info successes or errors cannot replace a later selection', async t => {
    for (const stage of ['rpc', 'info']) {
        for (const outcome of ['success', 'error']) {
            const pane = await fixture(t);
            pane.mount();
            const delayed = deferred();
            if (stage === 'rpc') { pane.setLookup(() => delayed.promise); }
            else { pane.setConnected(() => delayed.promise); }
            pane.navigate({ type: 'session', sessionID: 'ses_old' });
            await settle();
            const oldSignal = pane.calls[0].settings.signal;
            pane.setLookup(async ({ sessionID }) => pane.ready(sessionID));
            pane.setConnected(async () => ({ pid: 4242, version: '2.3.0', urls: [pane.registration.url] }));
            await select(pane, 'ses_current');
            if (outcome === 'error') { delayed.reject(new Error('private stale token')); }
            else { delayed.resolve(stage === 'rpc' ? pane.ready('ses_old') : { pid: 7, version: 'other' }); }
            await settle();
            assert.equal(pane.signal().id, 'ses_current');
            assert.equal(oldSignal.aborted, true);
        }
    }
});

test('home, new, plugin pages, child sessions and disposal clear; errors and deadlines publish no secrets', async t => {
    const pane = await fixture(t);
    pane.mount();
    for (const destination of [{ type: 'home' }, { type: 'session', sessionID: 'new' }, { type: 'plugin', id: 'other' }]) {
        await select(pane);
        pane.navigate(destination);
        assert.deepEqual(pane.signal(), { state: 'none' });
    }
    pane.setLookup(async ({ sessionID }) => pane.ready(sessionID, {
        session: { id: sessionID, parentID: 'ses_parent', location: { directory: '/workspace/project' } },
    }));
    await select(pane);
    assert.deepEqual(pane.signal(), { state: 'none' });
    pane.navigate({ type: 'home' });
    const delayed = deferred();
    pane.setLookup(() => delayed.promise);
    pane.navigate({ type: 'session', sessionID: 'ses_timeout' });
    await pane.timer.advance(2000);
    assert.deepEqual(pane.signal(), { state: 'error' });
    delayed.resolve(pane.ready('ses_timeout'));
    await settle();
    assert.deepEqual(pane.signal(), { state: 'error' });
    pane.cleanup();
    assert.deepEqual(pane.signal(), { state: 'none' });
    assert.equal(pane.timer.tasks.size, 0);
    assert.equal(pane.events.eventNames().length, 0);
    assert.equal(pane.unregisters, 1);
    assert.equal(pane.writes.some(text => /password|token|https?:|transcript/.test(text)), false);
});

test('only native creation of the pending selected ID retries an optimistic selection, including in-flight absence', async t => {
    for (const inFlight of [false, true]) {
        const pane = await fixture(t);
        pane.mount();
        const delayed = deferred();
        pane.setLookup(() => inFlight ? delayed.promise : Promise.resolve(pane.absent()));
        pane.navigate({ type: 'session', sessionID: 'ses_optimistic' });
        if (!inFlight) { await settle(); }
        const count = pane.calls.length;
        pane.emit('session.created', 'ses_foreign');
        assert.equal(pane.calls.length, count);
        pane.setLookup(async ({ sessionID }) => pane.ready(sessionID));
        pane.emit('session.created', 'ses_optimistic');
        delayed.resolve(pane.absent());
        await settle();
        assert.equal(pane.signal().id, 'ses_optimistic');
        assert.equal(pane.calls.length, count + 1);
        const writes = pane.writes.length;
        pane.emit('session.created', 'ses_optimistic');
        await settle();
        assert.equal(pane.calls.length, count + 1, 'durable selections do not follow server activity');
        assert.equal(pane.writes.length, writes);
    }
});

test('fresh full attestation is required before accepting absence, including backend changes and daemon replacement', async t => {
    for (const change of ['minimal', 'db', 'inode', 'home', 'version', 'connected', 'registration', 'replacement', 'same']) {
        const pane = await fixture(t);
        pane.mount();
        await select(pane);
        const result = pane.absent();
        if (change === 'minimal') { delete result.file; }
        if (change === 'db') {
            const file = paths.join(pane.directory, 'other.db');
            filesystem.writeFileSync(file, 'SQLite format 3\0copy');
            const stat = filesystem.statSync(file);
            result.env = { ...result.env, OPENCODE_DB: file };
            result.file = { dev: String(stat.dev), ino: String(stat.ino) };
        }
        if (change === 'inode') { result.file = { dev: '1', ino: '999' }; }
        if (change === 'home') { result.home = '/other'; }
        if (change === 'version') {
            result.version = 'other';
            pane.setConnected(async () => ({ pid: 4242, version: 'other', urls: [pane.registration.url] }));
            pane.writeRegistration({ ...pane.registration, version: 'other' });
        }
        if (change === 'connected') { pane.setConnected(async () => ({ pid: 7, version: 'other' })); }
        if (change === 'registration') { pane.writeRegistration({ ...pane.registration, pid: 7 }); }
        if (change === 'replacement') {
            result.pid = 5252;
            pane.setConnected(async () => ({ pid: 5252, version: '2.3.0', urls: [pane.registration.url] }));
            pane.writeRegistration({ ...pane.registration, pid: 5252 });
        }
        pane.setLookup(async () => result);
        pane.context.location = { directory: '/workspace/changed' };
        await select(pane);
        assert.deepEqual(pane.signal(), { state: ['same', 'replacement'].includes(change) ? 'none' : 'error' }, change);
    }
});

test('RPC, info and registration errors remain errors; explicit unsupported clears', async t => {
    for (const stage of ['rpc', 'info', 'registration', 'unsupported']) {
        const pane = await fixture(t);
        pane.mount();
        const fail = async () => { throw new Error('private password'); };
        if (stage === 'rpc') { pane.setLookup(fail); }
        if (stage === 'info') { pane.setConnected(fail); }
        if (stage === 'registration') { pane.setRegistrationError(Object.assign(new Error('private password'), { code: 'EACCES' })); }
        if (stage === 'unsupported') { pane.setLookup(async () => ({ state: 'unsupported' })); }
        await select(pane);
        assert.deepEqual(pane.signal(), { state: stage === 'unsupported' ? 'none' : 'error' });
        assert.equal(pane.writes.some(text => text.includes('private password')), false);
    }
});

test('represented roots and actual local SQLite identity must agree, never client DB guesses', async t => {
    for (const change of ['home', ...Object.keys((await fixture(t)).storage.env).filter(name => name !== 'OPENCODE_DB'), 'inode', 'header']) {
        const pane = await fixture(t);
        pane.mount();
        const result = pane.ready('ses_selected');
        if (change === 'home') { result.home = '/other'; }
        else if (change === 'inode') { result.file = { dev: '1', ino: '999' }; }
        else if (change === 'header') { filesystem.writeFileSync(pane.database, 'not SQLite'); }
        else { result.env = { ...result.env, [change]: '/other' }; }
        pane.setLookup(async () => result);
        await select(pane);
        assert.deepEqual(pane.signal(), { state: 'none' }, change);
    }
    for (const OPENCODE_DB of [undefined, '', ':memory:', 'relative.db']) {
        const pane = await fixture(t, { env: { OPENCODE_DB } });
        pane.mount();
        await select(pane);
        assert.equal(pane.signal().env.OPENCODE_DB, pane.database);
    }
});

test('flat registration requires exact PID/version and literal-loopback origins, never legacy or credential fields', async t => {
    for (const invalid of [
        null, [], false, '{private-password', {}, { pid: 4242 },
        { pid: '4242', version: '2.3.0', url: 'http://127.0.0.1:4096' },
        { pid: 7, version: '2.3.0', url: 'http://127.0.0.1:4096' },
        { pid: 4242, version: 'other', url: 'http://127.0.0.1:4096' },
    ]) {
        const pane = await fixture(t);
        pane.writeRegistration(invalid);
        pane.mount();
        await select(pane);
        assert.equal(pane.signal().managed, false);
    }
    for (const url of ['http://localhost:4096', 'http://127.1:4096', 'http://2130706433:4096',
        'http://secret@127.0.0.1:4096', 'http://192.0.2.1:4096', 'http://127.0.0.1:4097',
        'https://127.0.0.1:4096', 'http://127.0.0.1:99999', 'http://127.0.0.1:4096/path']) {
        const pane = await fixture(t);
        pane.writeRegistration({ ...pane.registration, url });
        pane.mount();
        await select(pane);
        assert.equal(pane.signal().managed, false, url);
    }
    for (const urls of [undefined, [], 'http://127.0.0.1:4096', ['http://127.1:4096'], ['http://localhost:4096']]) {
        const pane = await fixture(t);
        pane.setConnected(async () => ({ pid: 4242, version: '2.3.0', urls }));
        pane.mount();
        await select(pane);
        assert.equal(pane.signal().managed, false);
    }
    for (const [url, urls] of [['http://127.0.0.1:80', ['http://127.0.0.1/']], ['https://[::1]:443/', ['https://[::1]']]]) {
        const pane = await fixture(t);
        pane.writeRegistration({ ...pane.registration, url, password: { private: 'never-accessed' } });
        pane.setConnected(async () => ({ pid: 4242, version: '2.3.0', urls }));
        pane.mount();
        await select(pane);
        assert.equal(pane.signal().managed, true);
    }
});

test('native channel-specific registration and missing files remain unmanaged without fallback', async t => {
    for (const [channel, filename] of [['latest', 'service.json'], ['prod', 'service-prod.json'], ['feature/a b', 'service-feature-a-b.json']]) {
        const pane = await fixture(t);
        pane.writeRegistration(pane.registration, paths.join(paths.dirname(pane.registrationFile), filename));
        pane.setLookup(async ({ sessionID }) => pane.ready(sessionID, { channel }));
        pane.mount();
        await select(pane);
        assert.equal(pane.signal().managed, true);
        filesystem.unlinkSync(paths.join(paths.dirname(pane.registrationFile), filename));
        pane.context.location = { directory: '/workspace/other' };
        await select(pane);
        assert.equal(pane.signal().managed, false);
    }
});

test('wrong launch, unsafe paths, start failures and malformed immutable input opt out without publishing', async t => {
    for (const options of [
        { env: { REX_SESSION: 'session:foreign' } }, { env: { REX_BLOCK: '../foreign' } },
        { env: { REX_RECOVER_LAUNCH_DIR: 'relative' } }, { startError: true }, { started: 'different birth' },
        { prepare: pane => filesystem.writeFileSync(pane.launchFile, 'corrupt') },
        { prepare: pane => filesystem.writeFileSync(pane.launchFile, 'x'.repeat(65537)) },
        { prepare: pane => filesystem.chmodSync(pane.launchFile, 0o644) },
    ]) {
        const pane = await fixture(t, options);
        assert.equal(pane.slot, undefined);
        assert.equal(pane.writes.length, 0);
        assert.equal(pane.calls.length, 0);
    }
});

test('foreign, nested, non-native and reused-launch producers cannot overwrite an eligible outer selection', async t => {
    for (const processes of [
        `7002 1 ${birth} /fixture/opencode\n7001 1 ${birth} /fixture/opencode\n`,
        `7002 7001 ${birth} /fixture/opencode\n7001 1 ${birth} /fixture/opencode\n`,
        `7002 7001 ${birth} /fixture/node\n7001 1 ${birth} /fixture/node\n`,
        `7002 7001 ${birth} /fixture/opencode\n7001 1 Tue Nov 17 12:00:00 2026 /fixture/node\n`,
    ]) {
        for (const env of [{}, { REX_RECOVER_SESSIONS: '0' }, { OPENCODE_CONFIG_CONTENT: 'unsupported' }]) {
            let original;
            let inode;
            const pane = await fixture(t, {
                ownerPID: 7002, processes, env,
                prepare(current) {
                    original = JSON.stringify({
                        version: 1, launch: current.launch, owner_pid: 7001, owner_started_at: birth,
                        state: 'ready', id: 'ses_outer', home: current.home, env: current.storage.env, managed: true,
                    });
                    filesystem.writeFileSync(current.selectionFile, original, { mode: 0o600 });
                    inode = filesystem.statSync(current.selectionFile).ino;
                },
            });
            if (pane.slot) { pane.mount(); await select(pane, 'ses_nested'); }
            assert.equal(filesystem.readFileSync(pane.selectionFile, 'utf8'), original);
            assert.equal(filesystem.statSync(pane.selectionFile).ino, inode);
            assert.equal(pane.writes.length, 0);
            assert.equal(pane.calls.length, 0);
        }
    }
});

test('one native descendant of the recorded launcher can publish, ignoring native ancestors outside that launch', async t => {
    const pane = await fixture(t, {
        ownerPID: 7002,
        processes: `7002 7001 ${birth} /fixture/opencode\n7001 6001 ${birth} /fixture/node\n6001 1 ${birth} /outer/opencode\n`,
    });
    pane.mount();
    await select(pane, 'ses_descendant');
    assert.equal(pane.sidecar().owner_pid, 7002);
    assert.equal(pane.signal().id, 'ses_descendant');
});

test('unsupported configuration and explicit disable clear an existing same-owned ready record', async t => {
    for (const env of [
        { REX_RECOVER_SESSIONS: '0' },
        { REX_RECOVER_SESSIONS: 'my-opencode,codex' },
        ...overrides.map(name => ({ [name]: 'private selector' })),
    ]) {
        const pane = await fixture(t, {
            env,
            prepare(current) {
                filesystem.writeFileSync(current.selectionFile, JSON.stringify({
                    version: 1, launch: current.launch, owner_pid: 7001, owner_started_at: birth,
                    state: 'ready', id: 'ses_old',
                }));
            },
        });
        if (pane.slot) { pane.mount(); await select(pane); }
        assert.deepEqual(pane.signal(), { state: 'none' });
        assert.equal(pane.calls.length, 0);
    }
});

test('replacement launches and foreign/unreadable sidecars cannot be cleared by stale teardown', async t => {
    for (const mutation of ['launch', 'owner', 'corrupt', 'unreadable']) {
        const pane = await fixture(t);
        pane.mount();
        await select(pane);
        if (mutation === 'launch') {
            filesystem.writeFileSync(pane.launchFile + '.new', pane.launchText.replace('7001\0', '8001\0'), { mode: 0o600 });
            filesystem.renameSync(pane.launchFile + '.new', pane.launchFile);
        } else if (mutation === 'owner') {
            filesystem.writeFileSync(pane.selectionFile, JSON.stringify({ ...pane.sidecar(), owner_pid: 8001 }));
        } else if (mutation === 'corrupt') {
            filesystem.writeFileSync(pane.selectionFile, '{corrupt');
        } else {
            pane.setFileError(Object.assign(new Error('unreadable'), { code: 'EACCES' }));
        }
        const before = filesystem.readFileSync(pane.selectionFile, 'utf8');
        pane.cleanup();
        assert.equal(filesystem.readFileSync(pane.selectionFile, 'utf8'), before, mutation);
    }
});

test('partial publication failures remove only owned staging files and preserve pre-existing collision files', async t => {
    const pane = await fixture(t);
    pane.mount();
    await select(pane, 'ses_saved');
    pane.setPartialWrite(true);
    await select(pane, 'ses_changed');
    assert.deepEqual(pane.temporaryFiles(), [], 'failed writes must not accumulate staging files');
    pane.setPartialWrite(false);
    pane.collideTemporary();
    pane.navigate({ type: 'home' });
    const foreign = pane.temporaryFiles();
    assert.equal(foreign.length, 1);
    assert.equal(filesystem.readFileSync(paths.join(paths.dirname(pane.selectionFile), foreign[0]), 'utf8'),
        'foreign temporary');
});

test('failed home publication revokes only the live same-owned artifact when unlink remains possible', async t => {
    for (const owner of ['same', 'foreign', 'new-launch']) {
        const pane = await fixture(t);
        pane.mount();
        await select(pane, 'ses_saved');
        if (owner === 'foreign') {
            filesystem.writeFileSync(pane.selectionFile, JSON.stringify({ ...pane.sidecar(), owner_pid: 9999 }));
        }
        if (owner === 'new-launch') {
            filesystem.writeFileSync(pane.launchFile + '.new', pane.launchText.replace('7001\0', '8001\0'), { mode: 0o600 });
            filesystem.renameSync(pane.launchFile + '.new', pane.launchFile);
        }
        const before = filesystem.readFileSync(pane.selectionFile, 'utf8');
        pane.setPartialWrite(true);
        pane.navigate({ type: 'home' });
        if (owner === 'same') {
            assert.equal(filesystem.existsSync(pane.selectionFile), false, 'failed NONE must not leave old READY usable');
        } else {
            assert.equal(filesystem.readFileSync(pane.selectionFile, 'utf8'), before);
        }
        assert.deepEqual(pane.temporaryFiles(), []);
        assert.equal(pane.warnings.length, 0);
    }
});

test('unwritable and unremovable selections report one nonsecret warning rather than claiming revocation', async t => {
    const pane = await fixture(t);
    pane.mount();
    await select(pane, 'ses_saved');
    const before = filesystem.readFileSync(pane.selectionFile, 'utf8');
    pane.setPartialWrite(true);
    pane.setUnlinkFailure(true);
    pane.navigate({ type: 'home' });
    await select(pane, 'ses_other');
    pane.navigate({ type: 'home' });
    assert.equal(filesystem.readFileSync(pane.selectionFile, 'utf8'), before, 'the filesystem prevented revocation');
    assert.equal(pane.warnings.length, 1);
    assert.match(pane.warnings[0], /could not|unable/i);
    assert.equal(/private|password|ses_saved|ses_other|session:|block:/.test(pane.warnings[0]), false);
    assert.deepEqual(pane.temporaryFiles(), []);
});

test('qualified paths prevent an old in-flight producer from replacing a new launch selection', async t => {
    const old = await fixture(t);
    old.mount();
    const delayed = deferred();
    old.setLookup(() => delayed.promise);
    old.navigate({ type: 'session', sessionID: 'ses_old' });
    const current = await fixture(t, { host: old, pid: 8001 });
    current.mount();
    await select(current, 'ses_new');
    const before = filesystem.readFileSync(current.selectionFile, 'utf8');
    delayed.resolve(old.ready('ses_old'));
    await settle();
    old.cleanup();
    assert.notEqual(old.selectionFile, current.selectionFile);
    assert.equal(filesystem.readFileSync(current.selectionFile, 'utf8'), before);
});

test('a replacement between the old launch check and atomic rename cannot lose the new launch selection', async t => {
    const pane = await fixture(t);
    pane.mount();
    const delayed = deferred();
    pane.setLookup(() => delayed.promise);
    pane.navigate({ type: 'session', sessionID: 'ses_old' });
    const newSelection = `${pane.launchFile}.8001.${Buffer.from(birth).toString('hex')}.session`;
    const newRecord = {
        version: 1, launch: { ...pane.launch, pid: 8001 }, owner_pid: 8001, owner_started_at: birth,
        state: 'ready', id: 'ses_new', home: pane.home, env: pane.storage.env, managed: true,
    };
    pane.setBeforeRename(from => {
        if (JSON.parse(filesystem.readFileSync(from, 'utf8')).state !== 'ready') { return; }
        filesystem.writeFileSync(pane.launchFile + '.new', pane.launchText.replace('7001\0', '8001\0'), { mode: 0o600 });
        filesystem.renameSync(pane.launchFile + '.new', pane.launchFile);
        filesystem.writeFileSync(newSelection, JSON.stringify(newRecord), { mode: 0o600 });
    });
    delayed.resolve(pane.ready('ses_old'));
    await settle();
    assert.deepEqual(JSON.parse(filesystem.readFileSync(newSelection, 'utf8')), newRecord);
    assert.notEqual(newSelection, pane.selectionFile);
});

test('full bounded IDs survive unchanged; invalid IDs and relative XDG roots never trigger metadata reads', async t => {
    const pane = await fixture(t);
    pane.mount();
    const fullID = 'ses_' + 'full'.repeat(60);
    await select(pane, fullID);
    assert.equal(pane.signal().id, fullID);
    const before = pane.calls.length;
    for (const id of ['', 'creating', 'new', 'ses_bad/path', 'ses_bad\ninput', 'ses_' + 'x'.repeat(257)]) {
        await select(pane, id);
        assert.deepEqual(pane.signal(), { state: 'none' });
    }
    assert.equal(pane.calls.length, before);
    for (const name of ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']) {
        const invalid = await fixture(t, { env: { [name]: 'relative' } });
        invalid.mount();
        await select(invalid);
        assert.deepEqual(invalid.signal(), { state: 'none' });
        assert.equal(invalid.calls.length, 0);
    }
});

test('client HOME and independent XDG symlinks canonicalize without recording selector secrets', async t => {
    const pane = await fixture(t, {
        prepare(current) {
            const homeLink = paths.join(current.directory, 'home-link');
            filesystem.symlinkSync(current.home, homeLink);
            current.environment.HOME = homeLink;
            for (const [name, suffix] of Object.entries({
                XDG_CONFIG_HOME: 'config', XDG_DATA_HOME: 'data', XDG_STATE_HOME: 'state', XDG_CACHE_HOME: 'cache',
            })) {
                const target = paths.join(current.directory, suffix);
                filesystem.mkdirSync(target);
                filesystem.symlinkSync(target, target + '-link');
                current.environment[name] = target + '-link';
                current.storage.env[name] = target;
            }
            const registration = paths.join(current.storage.env.XDG_STATE_HOME, 'opencode/service.json');
            filesystem.mkdirSync(paths.dirname(registration));
            current.writeRegistration(current.registration, registration);
            current.environment.API_TOKEN = 'private-token';
        },
    });
    pane.mount();
    await select(pane);
    assert.equal(pane.signal().managed, true);
    assert.equal(pane.signal().home, pane.home);
    assert.deepEqual(pane.signal().env, pane.storage.env);
    assert.equal(pane.writes.some(text => /private-token|private-password|home-link|cache-link/.test(text)), false);
});

test('DB deletion, replacement, header changes and unsupported selectors cannot pass an async completion', async t => {
    for (const change of ['delete', 'replace', 'header', 'selector']) {
        const pane = await fixture(t);
        pane.mount();
        const delayed = deferred();
        pane.setLookup(() => delayed.promise);
        pane.navigate({ type: 'session', sessionID: 'ses_selected' });
        if (change === 'delete') { filesystem.unlinkSync(pane.database); }
        if (change === 'replace') {
            filesystem.renameSync(pane.database, pane.database + '.old');
            filesystem.writeFileSync(pane.database, 'SQLite format 3\0replacement');
        }
        if (change === 'header') { filesystem.writeFileSync(pane.database, 'invalid SQLite'); }
        if (change === 'selector') { pane.environment.OPENCODE_CONFIG_CONTENT = 'private override'; }
        delayed.resolve(pane.ready('ses_selected'));
        await settle();
        assert.deepEqual(pane.signal(), { state: 'none' });
    }
});

test('slot disposal cancels pending work; remount has one native listener and no persistent timer', async t => {
    const pane = await fixture(t);
    pane.mount();
    const delayed = deferred();
    pane.setLookup(() => delayed.promise);
    pane.navigate({ type: 'session', sessionID: 'ses_old' });
    const oldSignal = pane.calls[0].settings.signal;
    pane.unmount();
    assert.equal(oldSignal.aborted, true);
    assert.equal(pane.timer.tasks.size, 0);
    assert.equal(pane.events.listenerCount('session.created'), 0);
    assert.equal(pane.events.listenerCount('server.connected'), 1);
    assert.deepEqual(pane.signal(), { state: 'none' });
    pane.setLookup(async ({ sessionID }) => pane.ready(sessionID));
    pane.mount();
    await select(pane, 'ses_new');
    delayed.resolve(pane.ready('ses_old'));
    await settle();
    assert.equal(pane.signal().id, 'ses_new');
    assert.equal(pane.events.listenerCount('session.created'), 1);
    assert.equal(pane.timer.tasks.size, 0);
});
