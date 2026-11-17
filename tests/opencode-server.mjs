import assert from 'node:assert/strict';
import * as crypto from 'node:crypto';
import * as filesystem from 'node:fs';
import * as operatingSystem from 'node:os';
import * as paths from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const pluginDirectory = new URL('../plugins/opencode-recover/', import.meta.url);
// Literal from the v2.3.0 host's UTF-16 namespace contract, not the implementation under test.
const namespace = 'plugin:007200650078002d007200650063006f007600650072002e006f00700065006e0063006f00640065:';

async function fixture(t, options = {}) {
    const directory = filesystem.realpathSync(filesystem.mkdtempSync(paths.join(operatingSystem.tmpdir(), 'rex-server-')));
    t.after(() => filesystem.rmSync(directory, { recursive: true, force: true }));
    const home = paths.join(directory, 'home');
    for (const suffix of ['', '.config', '.local/share/opencode', '.local/state', '.cache']) {
        filesystem.mkdirSync(paths.join(home, suffix), { recursive: true });
    }
    const database = paths.join(home, '.local/share/opencode/opencode.db');
    filesystem.writeFileSync(database, 'SQLite format 3\0private database');
    const environment = { HOME: home, ...options.env };
    const rows = new Map();
    const writes = [];
    const removals = [];
    const reads = [];
    const opened = [];
    let handler;
    let definition;
    let metadata = input => ({ id: input.sessionID, location: { directory }, title: 'private title', tokens: 999 });
    let read = key => rows.get(key);
    let write = (key, value) => rows.set(namespace + key, JSON.stringify(value));
    let remove = key => rows.delete(namespace + key);
    let now = 1700000000000;
    const sandbox = vm.createContext({ Buffer, process: { env: environment, pid: 4242 }, Date: { now: () => now } });
    const rawFileTripwire = () => { throw new Error('daemon must not open/read/close raw database descriptors'); };
    const external = {
        'node:fs': options.rawFileTripwire
            ? {
                ...filesystem,
                openSync: rawFileTripwire, readSync: rawFileTripwire, closeSync: rawFileTripwire,
                readFileSync: rawFileTripwire, fstatSync: rawFileTripwire,
            }
            : filesystem,
        'node:path': paths,
        'node:os': { homedir: () => environment.HOME },
        'node:crypto': crypto,
        '@opencode/plugin': { Plugin: { define: value => value } },
        '@opencode/plugin/rpc': { Rpc: { define: value => value } },
        'bun:sqlite': {
            Database: class {
                constructor(file, options) {
                    assert.deepEqual(JSON.parse(JSON.stringify(options)), { readonly: true, create: false });
                    opened.push(file);
                    this.file = file;
                }
                query(sql) {
                    assert.equal(sql, 'SELECT value FROM kv WHERE key = ?');
                    const file = this.file;
                    return { get(key) {
                        assert.ok(key.startsWith(namespace + 'database-proof:'));
                        reads.push(key);
                        // SQLite must parse the DB schema for this SELECT; invalid
                        // database bytes fail at the external SQLite boundary.
                        if (filesystem.readFileSync(file).subarray(0, 16).toString() !== 'SQLite format 3\0') {
                            throw Object.assign(new Error('file is not a database'), { code: 'SQLITE_NOTADB' });
                        }
                        const value = read(key);
                        return value === undefined ? null : { value };
                    } };
                }
                close() {}
            },
        },
    };
    const modules = new Map();
    async function load(url) {
        if (modules.has(url.href)) {
            return modules.get(url.href);
        }
        const module = new vm.SourceTextModule(filesystem.readFileSync(url, 'utf8'), {
            context: sandbox, identifier: url.href,
        });
        modules.set(url.href, module);
        await module.link(async specifier => {
            if (specifier.startsWith('.')) {
                return load(new URL(specifier, url));
            }
            assert.ok(external[specifier], `unexpected dependency ${specifier}`);
            const exports = external[specifier];
            return new vm.SyntheticModule(Object.keys(exports), function () {
                for (const [name, value] of Object.entries(exports)) {
                    this.setExport(name, value);
                }
            }, { context: sandbox });
        });
        return module;
    }
    const module = await load(new URL('server.mjs', pluginDirectory));
    await module.evaluate();
    const context = {
        app: { name: 'opencode', version: '2.3.0', channel: options.channel || 'latest' },
        location: { directory, workspaceID: options.workspaceID },
        session: { get: (input, options) => metadata(input, options) },
        storage: {
            async set(key, value) {
                writes.push({ key, value });
                await write(key, value);
            },
            async remove(key) {
                removals.push(key);
                await remove(key);
            },
        },
        rpc: { async register(contract, handlers) {
            // Native V2.3.0 initializes this map when a contract is registered;
            // Rpc.define itself does not fill in the required empty events map.
            assert.deepEqual(Object.entries(contract.events), []);
            definition = contract;
            handler = handlers.context;
            return { dispose() {} };
        } },
    };
    assert.equal(module.namespace.default.id, 'rex-recover.opencode');
    await module.namespace.default.setup(context);
    return {
        directory, home, database, environment, rows, writes, removals, reads, opened, context,
        get definition() { return definition; },
        setMetadata(callback) { metadata = callback; },
        setRead(callback) { read = callback; },
        setWrite(callback) { write = callback; },
        setRemove(callback) { remove = callback; },
        advance(milliseconds) { now += milliseconds; },
        async call(sessionID = 'ses_selected') {
            return JSON.parse(JSON.stringify(await handler({ sessionID }, { signal: new AbortController().signal })));
        },
    };
}

test('the connected server proves its default DB with only a fresh namespaced KV read and returns metadata only', async t => {
    const server = await fixture(t);
    assert.equal(server.definition.id, 'rex-recover');
    assert.deepEqual(Object.keys(server.definition.methods), ['context']);
    assert.deepEqual(JSON.parse(JSON.stringify(server.definition.methods.context.input)), {
        type: 'object', properties: { sessionID: { type: 'string' } },
        required: ['sessionID'], additionalProperties: false,
    });
    const result = await server.call();
    const status = filesystem.statSync(server.database);
    assert.deepEqual(result, {
        state: 'ready', pid: 4242, version: '2.3.0', channel: 'latest', home: server.home,
        env: {
            XDG_CONFIG_HOME: paths.join(server.home, '.config'),
            XDG_DATA_HOME: paths.join(server.home, '.local/share'),
            XDG_STATE_HOME: paths.join(server.home, '.local/state'),
            XDG_CACHE_HOME: paths.join(server.home, '.cache'),
            OPENCODE_DB: server.database,
        },
        file: { dev: String(status.dev), ino: String(status.ino) },
        session: { id: 'ses_selected', location: { directory: server.directory } },
    });
    assert.equal(server.writes.length, 1);
    assert.match(server.writes[0].value.nonce, /^[a-f0-9]{64}$/);
    assert.deepEqual(Object.keys(server.writes[0].value), ['nonce']);
    assert.equal(server.removals[0], server.writes[0].key);
    assert.equal(server.rows.size, 0);
    assert.deepEqual(server.opened, [server.database]);
});

test('daemon context proof uses no raw DB descriptors that could release Core’s POSIX locks', async t => {
    const server = await fixture(t, { rawFileTripwire: true });
    assert.equal((await server.call()).state, 'ready');
    assert.equal((await server.call()).state, 'ready', 'cached proof must also avoid raw descriptor operations');
    assert.equal(server.writes.length, 1, 'validating the cached file must not write another witness');
});

test('SQLite rejects an invalid DB before proof and after caching without allowing ready', async t => {
    for (const cached of [false, true]) {
        const server = await fixture(t, { rawFileTripwire: true });
        if (cached) {
            assert.equal((await server.call()).state, 'ready');
        }
        filesystem.writeFileSync(server.database, 'not a SQLite database');
        await assert.rejects(server.call(), /file is not a database/);
        assert.equal(server.rows.size, 0);
        assert.equal(server.writes.length, 1);
    }
});

test('a delayed proof is independent of wall-clock movement and still cleans and caches its fresh nonce', async t => {
    const server = await fixture(t);
    let entered;
    let release;
    const writing = new Promise(resolve => { entered = resolve; });
    const blocked = new Promise(resolve => { release = resolve; });
    server.setWrite(async (key, value) => {
        server.rows.set(namespace + key, JSON.stringify(value));
        entered();
        await blocked;
    });
    const pending = server.call();
    await writing;
    server.advance(86400000);
    release();
    assert.equal((await pending).state, 'ready');
    server.advance(-172800000);
    assert.equal((await server.call()).state, 'ready');
    assert.equal(server.writes.length, 1);
    assert.equal(server.rows.size, 0);
    assert.equal(server.removals.length, 1);
});

test('different plugin locations use isolated stable keys and another daemon gets a fresh proof', async t => {
    const first = await fixture(t);
    const second = await fixture(t, { workspaceID: 'wrk_other' });
    await Promise.all([first.call(), second.call()]);
    assert.notEqual(first.writes[0].key, second.writes[0].key);
    assert.notEqual(first.writes[0].value.nonce, second.writes[0].value.nonce);
    assert.equal(first.rows.size, 0);
    assert.equal(second.rows.size, 0);
});

test('a copied DB containing the same session and an old proof cannot pass a new unpredictable witness', async t => {
    const server = await fixture(t);
    await server.call();
    const old = JSON.stringify(server.writes[0].value);
    // Replacing the candidate invalidates the cache even when the session ID is unchanged.
    filesystem.renameSync(server.database, server.database + '.old');
    filesystem.writeFileSync(server.database, 'SQLite format 3\0copied sessions');
    server.setRead(() => old);
    assert.deepEqual(await server.call(), { state: 'unsupported' });
    assert.notEqual(server.writes[1].value.nonce, server.writes[0].value.nonce);
    assert.equal(server.writes[1].key, server.writes[0].key, 'crash leftovers remain bounded to one location key');
    assert.equal(server.rows.size, 0);
});

test('proof is cached per canonical context and inode; concurrent callers share even a failed proof', async t => {
    const server = await fixture(t);
    await Promise.all([server.call(), server.call(), server.call('ses_other')]);
    await server.call();
    assert.equal(server.writes.length, 1);
    filesystem.renameSync(server.database, server.database + '.old');
    filesystem.writeFileSync(server.database, 'SQLite format 3\0replacement');
    server.setRead(() => undefined);
    assert.deepEqual(await Promise.all([server.call(), server.call()]), [
        { state: 'unsupported' }, { state: 'unsupported' },
    ]);
    assert.equal(server.writes.length, 2, 'in-flight failure must not trigger a second simultaneous witness');
});

test('session absence includes attested storage context instead of trusting an arbitrary daemon’s missing ID', async t => {
    const server = await fixture(t);
    const schema = server.definition.methods.context.output.oneOf
        .find(schema => schema.properties.state.const === 'absent');
    assert.deepEqual([...schema.required].sort(), ['channel', 'env', 'file', 'home', 'pid', 'state', 'version']);
    assert.equal(schema.additionalProperties, false);
    assert.equal(schema.properties.session, undefined);
    assert.deepEqual([...schema.properties.env.required].sort(), [
        'OPENCODE_DB', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME',
    ]);
    assert.deepEqual([...schema.properties.file.required].sort(), ['dev', 'ino']);
    server.setMetadata(() => { throw Object.assign(new Error('missing'), {
        _tag: 'Session.NotFoundError', sessionID: 'ses_selected',
    }); });
    const status = filesystem.statSync(server.database);
    assert.deepEqual(await server.call(), {
        state: 'absent', pid: 4242, version: '2.3.0', channel: 'latest', home: server.home,
        env: {
            XDG_CONFIG_HOME: paths.join(server.home, '.config'),
            XDG_DATA_HOME: paths.join(server.home, '.local/share'),
            XDG_STATE_HOME: paths.join(server.home, '.local/state'),
            XDG_CACHE_HOME: paths.join(server.home, '.cache'),
            OPENCODE_DB: server.database,
        },
        file: { dev: String(status.dev), ino: String(status.ino) },
    });
    assert.equal(server.writes.length, 1);
    assert.equal(server.rows.size, 0);
});

test('a missing ID on an unproved copied DB is unsupported and cleanup failure still rejects absence', async t => {
    for (const failCleanup of [false, true]) {
        const server = await fixture(t);
        server.setMetadata(() => { throw Object.assign(new Error('missing'), {
            _tag: 'Session.NotFoundError', sessionID: 'ses_selected',
        }); });
        server.setRead(() => undefined);
        if (failCleanup) {
            server.setRemove(() => { throw new Error('cleanup failure'); });
            await assert.rejects(server.call(), /cleanup failure/);
        } else {
            assert.deepEqual(await server.call(), { state: 'unsupported' });
        }
        assert.equal(server.writes.length, 1);
        assert.equal(server.removals.length, 1);
    }
});

test('malformed session metadata and transient lookup errors reject; children remain ineligible without proof', async t => {
    const server = await fixture(t);
    for (const metadata of [
        null, { data: { id: 'ses_selected' } }, { id: 'ses_different', location: { directory: server.directory } },
        { id: 'ses_selected', location: { directory: 'relative' } },
    ]) {
        server.setMetadata(() => metadata);
        await assert.rejects(server.call(), /Invalid session metadata/);
    }
    server.setMetadata(() => { throw new Error('transport failure'); });
    await assert.rejects(server.call(), /transport failure/);
    server.setMetadata(() => { throw Object.assign(new Error('unrelated absence'), {
        _tag: 'Session.NotFoundError', sessionID: 'ses_different',
    }); });
    await assert.rejects(server.call(), /unrelated absence/);
    server.setMetadata(() => ({ id: 'ses_selected', parentID: 'ses_parent', location: { directory: server.directory } }));
    assert.deepEqual(await server.call(), { state: 'unsupported' });
    assert.equal(server.writes.length, 0);
    await assert.rejects(server.call('new'), /Invalid session ID/);
});

test('read/schema/write/cleanup failures reject, always attempt cleanup, and are never cached', async t => {
    for (const failure of ['read', 'json', 'write', 'cleanup']) {
        const server = await fixture(t);
        if (failure === 'read') {
            server.setRead(() => { throw new Error('schema or permission failure'); });
        } else if (failure === 'json') {
            server.setRead(() => 'not JSON');
        } else if (failure === 'write') {
            server.setWrite(() => { throw new Error('write failure'); });
        } else {
            server.setRemove(() => { throw new Error('cleanup failure'); });
        }
        await assert.rejects(server.call());
        await assert.rejects(server.call());
        assert.equal(server.removals.length, 2, failure);
        assert.equal(server.writes.length, 2, failure);
    }
});

test('relative/default/channel DB candidates follow native v2.3.0 filenames rather than project cwd', async t => {
    for (const [channel, override, disable, filename] of [
        ['latest', undefined, undefined, 'opencode.db'],
        ['dev', undefined, undefined, 'opencode.db'],
        ['beta', undefined, undefined, 'opencode.db'],
        ['next', undefined, undefined, 'opencode.db'],
        ['prod', undefined, undefined, 'opencode.db'],
        ['feature/a b', undefined, undefined, 'opencode-feature-a-b.db'],
        ['feature', undefined, 'true', 'opencode.db'],
        ['feature', undefined, '1', 'opencode.db'],
        ['feature', undefined, 'false', 'opencode-feature.db'],
        ['latest', 'relative.db', undefined, 'relative.db'],
    ]) {
        const server = await fixture(t, { channel, env: { OPENCODE_DB: override, OPENCODE_DISABLE_CHANNEL_DB: disable } });
        const expected = paths.join(server.home, '.local/share/opencode', filename);
        filesystem.writeFileSync(expected, 'SQLite format 3\0fixture');
        assert.equal((await server.call()).env.OPENCODE_DB, expected);
    }
});

test('server HOME/XDG and explicit DB candidates canonicalize independently and reject unsupported selectors', async t => {
    const server = await fixture(t);
    const explicit = paths.join(server.directory, 'explicit.db');
    filesystem.writeFileSync(explicit, 'SQLite format 3\0fixture');
    filesystem.symlinkSync(explicit, explicit + '.link');
    server.environment.OPENCODE_DB = explicit + '.link';
    for (const name of ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']) {
        const root = paths.join(server.directory, name);
        filesystem.mkdirSync(root);
        filesystem.symlinkSync(root, root + '.link');
        server.environment[name] = root + '.link';
    }
    const result = await server.call();
    assert.equal(result.env.OPENCODE_DB, explicit);
    for (const name of ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']) {
        assert.equal(result.env[name], paths.join(server.directory, name));
    }
    for (const [name, value] of [
        ['HOME', 'relative'], ['XDG_CONFIG_HOME', 'relative'], ['XDG_DATA_HOME', 'relative'],
        ['XDG_STATE_HOME', 'relative'], ['XDG_CACHE_HOME', 'relative'],
        ['OPENCODE_DB', ':memory:'], ['OPENCODE_DB', ''], ['OPENCODE_CONFIG_DIR', 'private'],
        ['OPENCODE_CONFIG', 'private'], ['OPENCODE_CONFIG_CONTENT', 'private'],
        ['OPENCODE_CLI_CONFIG_CONTENT', 'private'], ['OPENCODE_CONFIG_PROJECT_DISABLE', '0'],
        ['OPENCODE_DISABLE_PROJECT_CONFIG', '1'], ['OPENCODE_DISABLE_CLAUDE_CODE', '1'],
        ['OPENCODE_DISABLE_CLAUDE_CODE_SKILLS', '1'], ['OPENCODE_TEST_HOME', '/private'],
        ['OPENCODE_FLAGS', 'private'], ['OPENCODE_SIMULATE', '1'],
        ['OPENCODE_SERVICE_FILE', '/private/custom-service.json'],
    ]) {
        const previous = server.environment[name];
        server.environment[name] = value;
        assert.deepEqual(await server.call(), { state: 'unsupported' }, name);
        server.environment[name] = previous;
    }
});

test('a DB/header/context change during the witness cannot produce ready or seed the cache', async t => {
    for (const change of ['inode', 'header', 'env']) {
        const server = await fixture(t);
        server.setRead(key => {
            const value = server.rows.get(key);
            if (change === 'inode') {
                filesystem.renameSync(server.database, server.database + '.old');
                filesystem.writeFileSync(server.database, 'SQLite format 3\0replacement');
            } else if (change === 'header') {
                filesystem.writeFileSync(server.database, 'not sqlite');
            } else {
                server.environment.OPENCODE_CONFIG_CONTENT = 'unsupported';
            }
            return value;
        });
        if (change === 'env') {
            assert.deepEqual(await server.call(), { state: 'unsupported' });
        } else {
            await assert.rejects(server.call(), /Database file changed during proof/);
        }
        assert.equal(server.rows.size, 0);
    }
});

test('canonical directory targets with terminal controls are unsupported even behind harmless symlinks', async t => {
    const server = await fixture(t);
    const unsafeHome = paths.join(server.directory, 'home-\u001bunsafe');
    filesystem.mkdirSync(unsafeHome);
    const link = paths.join(server.directory, 'safe-link');
    filesystem.symlinkSync(unsafeHome, link);
    for (const [name, suffix] of Object.entries({
        XDG_CONFIG_HOME: '.config', XDG_DATA_HOME: '.local/share',
        XDG_STATE_HOME: '.local/state', XDG_CACHE_HOME: '.cache',
    })) {
        server.environment[name] = paths.join(server.home, suffix);
    }
    server.environment.HOME = link;
    assert.deepEqual(await server.call(), { state: 'unsupported' });
    assert.equal(server.writes.length, 0);
});
