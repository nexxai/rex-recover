import assert from 'node:assert/strict';
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const helper = fileURLToPath(new URL('../scripts/opencode-config.mjs', import.meta.url));

function fixture(config) {
    const directory = mkdtempSync(join(tmpdir(), 'rex-opencode-config-'));
    const cli = join(directory, 'cli.json');
    const output = join(directory, 'output.json');
    const snapshot = join(directory, 'snapshot.json');
    const runtime = '/fixture/runtime/plugins/opencode-recover';
    const plugin = '/fixture/config/opencode/plugins/rex-recover';
    if (config !== undefined) {
        writeFileSync(cli, typeof config === 'string' ? config : `${JSON.stringify(config)}\n`);
    }
    return { directory, cli, output, snapshot, runtime, plugin };
}

function run(files, operation = 'install', priorTitle = '-', priorTerminal = '-') {
    return spawnSync(
        process.execPath,
        [helper, operation, files.cli, files.runtime, files.plugin, files.output, files.snapshot, priorTitle, priorTerminal],
        { encoding: 'utf8', env: { ...process.env, OPENCODE_CLI_CONFIG_CONTENT: undefined, OPENCODE_CONFIG_DIR: undefined } },
    );
}

test('fresh global discovery leaves missing CLI settings and native title preferences untouched', () => {
    for (const config of [
        undefined,
        '{ "theme": { "name": "personal" } }\n',
        '{"terminal":{"title":true,"cursor":"keep"},"plugins":["*","other"]}\n',
        '{"terminal":{"title":false,"cursor":"keep"}}\n',
        '{"terminal":{"cursor":"keep"}}\n',
    ]) {
        const files = fixture(config);
        const result = run(files);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(existsSync(files.output), false, 'no settings write should be staged');
        assert.equal(existsSync(files.snapshot), false, 'unmodified settings need no concurrency guard');
        assert.equal(existsSync(files.cli), config !== undefined);
        if (config !== undefined) {
            assert.equal(readFileSync(files.cli, 'utf8'), config);
        }
        assert.equal(result.stdout, '', 'fresh installation claims no legacy title ownership');
    }
});

test('install migrates exact legacy paths without overriding native title preferences', () => {
    const files = fixture({
        $schema: 'https://opencode.ai/v2/cli.json',
        theme: { name: 'personal', mode: 'dark' },
        terminal: { title: true, cursor: 'keep' },
        plugins: [
            '@other/plugin',
            { package: '@other/custom', options: { enabled: true } },
            '/fixture/runtime/plugins/opencode-recover',
            'file:///fixture/config/opencode/plugins/rex-recover',
        ],
    });
    const original = readFileSync(files.cli, 'utf8');
    const result = run(files);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(readFileSync(files.output, 'utf8')), {
        $schema: 'https://opencode.ai/v2/cli.json',
        theme: { name: 'personal', mode: 'dark' },
        terminal: { title: true, cursor: 'keep' },
        plugins: ['@other/plugin', { package: '@other/custom', options: { enabled: true } }],
    });
    assert.equal(readFileSync(files.cli, 'utf8'), original, 'planning must not write the real config');
    assert.equal(result.stdout, '');
});

test('explicit install removes only our exact negative selector; removal preserves explicit disables', () => {
    for (const operation of ['install', 'remove']) {
        const files = fixture({
            plugins: [
                '*', '-rex-recover.opencode', '-other.opencode', '-*', '-rex-recover.*', 'other',
                '/fixture/runtime/plugins/opencode-recover',
            ],
        });
        const original = readFileSync(files.cli, 'utf8');
        const result = run(files, operation);
        assert.equal(result.status, 0, result.stderr);
        assert.deepEqual(JSON.parse(readFileSync(files.output)), {
            plugins: operation === 'install'
                ? ['*', '-other.opencode', '-*', '-rex-recover.*', 'other']
                : ['*', '-rex-recover.opencode', '-other.opencode', '-*', '-rex-recover.*', 'other'],
        });
        assert.equal(readFileSync(files.cli, 'utf8'), original);
        writeFileSync(files.cli, readFileSync(files.output));
        unlinkSync(files.output);
        unlinkSync(files.snapshot);
        assert.equal(run(files, operation).status, 0);
        assert.equal(existsSync(files.output), false, 'idempotent install/removal must not stage a preference write');
    }
});

test('global discovery does not require parsing unrelated CLI preferences', () => {
    for (const config of [
        '{// private-sentinel\n}',
        '[]',
        '{"terminal":null}',
        '{"terminal":{"title":"private-sentinel"}}',
        '{"terminal":{"title":"true"}}',
        '{"terminal":{"title":"false"}}',
        '{"plugins":{}}',
        '{"plugins":[null]}',
        '{"terminal":{"title":true,"title":false}}',
        '{"plugins":["other"],"plugins":[]}',
    ]) {
        const files = fixture(config);
        const result = run(files);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(readFileSync(files.cli, 'utf8'), config);
        assert.equal(existsSync(files.output), false);
        assert.equal(existsSync(files.snapshot), false);
    }
});

test('ambiguous settings and owned plugin options refuse necessary migrations without writes or content logging', () => {
    for (const config of [
        '{// private-sentinel\n"plugins":["-rex-recover.opencode"]}',
        '["-rex-recover.opencode"]',
        '{"terminal":null,"plugins":["-rex-recover.opencode"]}',
        '{"terminal":{"title":"private-sentinel"},"plugins":["-rex-recover.opencode"]}',
        '{"terminal":{"title":"true"},"plugins":["-rex-recover.opencode"]}',
        '{"terminal":{"title":"false"},"plugins":["-rex-recover.opencode"]}',
        '{"plugins":{"package":"/fixture/runtime/plugins/opencode-recover"}}',
        '{"plugins":[null,"-rex-recover.opencode"]}',
        '{"terminal":{"title":true,"title":false},"plugins":["-rex-recover.opencode"]}',
        '{"plugins":["-rex-recover.opencode"],"plugins":[]}',
        '{"plugins":[{"package":"/fixture/runtime/plugins/opencode-recover","options":{"private-sentinel":true}}]}',
    ]) {
        const files = fixture(config);
        const result = run(files);
        assert.notEqual(result.status, 0, config);
        assert.equal(readFileSync(files.cli, 'utf8'), config);
        assert.equal(existsSync(files.output), false);
        assert.doesNotMatch(result.stderr, /private-sentinel/);
        assert.match(result.stderr, /manually|manual|strict JSON/);
    }
});

test('upgrade and removal restore only legacy-owned false titles without claiming new ownership', () => {
    for (const operation of ['install', 'remove']) {
        for (const [terminal, priorTitle, priorTerminal, expectedTerminal] of [
            [{ title: false }, 'absent', 'absent', undefined],
            [{ title: false }, 'absent', 'present', {}],
            [{ title: false, later: 2 }, 'absent', 'absent', { later: 2 }],
            [{ title: false, later: 2 }, 'true', 'present', { title: true, later: 2 }],
            [{ title: false }, 'false', 'present', { title: false }],
            [{ title: true, later: 2 }, 'absent', 'absent', { title: true, later: 2 }],
            [{ later: 2 }, 'true', 'present', { later: 2 }],
        ]) {
            const files = fixture({ terminal, mouse: false });
            const original = readFileSync(files.cli, 'utf8');
            const result = run(files, operation, priorTitle, priorTerminal);
            assert.equal(result.status, 0, result.stderr);
            assert.deepEqual(
                JSON.parse(readFileSync(existsSync(files.output) ? files.output : files.cli)),
                { ...(expectedTerminal === undefined ? {} : { terminal: expectedTerminal }), mouse: false },
            );
            assert.equal(result.stdout, '');
            assert.equal(readFileSync(files.cli, 'utf8'), original);
        }
    }
});

test('the public check command rejects changed bytes, replaced files, and retargeted config symlinks', () => {
    for (const initial of [
        { plugins: ['/fixture/runtime/plugins/opencode-recover'] },
        { plugins: ['-rex-recover.opencode'] },
    ]) {
        const files = fixture(initial);
        assert.equal(run(files).status, 0);
        const check = () => spawnSync(process.execPath, [helper, 'check', files.cli, files.snapshot], { encoding: 'utf8' });
        assert.equal(check().status, 0);
        if (initial.plugins[0] === '-rex-recover.opencode') {
            unlinkSync(files.cli);
        }
        writeFileSync(files.cli, '{"theme":{"name":"later"}}\n');
        const result = check();
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /changed.*no changes/i);
    }
    const files = fixture({ plugins: ['/fixture/runtime/plugins/opencode-recover'] });
    const first = join(files.directory, 'first.json');
    const second = join(files.directory, 'second.json');
    writeFileSync(first, '{"plugins":["/fixture/runtime/plugins/opencode-recover"]}');
    writeFileSync(second, '{"plugins":["/fixture/runtime/plugins/opencode-recover"]}');
    unlinkSync(files.cli);
    symlinkSync(first, files.cli);
    assert.equal(run(files).status, 0);
    unlinkSync(files.cli);
    symlinkSync(second, files.cli);
    assert.notEqual(spawnSync(process.execPath, [helper, 'check', files.cli, files.snapshot]).status, 0);
});

test('legacy file URL variants are removed only when they name this exact package', () => {
    const files = fixture({
        plugins: [
            'file:///fixture/User Home/runtime/plugins/opencode-recover',
            'file://localhost/fixture/User%20Home/config/opencode/plugins/rex-recover',
            '/fixture/User Home/runtime/plugins/opencode-recover-extra',
            { package: 'file:///other/package', options: { enabled: true } },
        ],
    });
    files.runtime = '/fixture/User Home/runtime/plugins/opencode-recover';
    files.plugin = '/fixture/User Home/config/opencode/plugins/rex-recover';
    const result = run(files);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(readFileSync(files.output)), {
        plugins: [
            '/fixture/User Home/runtime/plugins/opencode-recover-extra',
            { package: 'file:///other/package', options: { enabled: true } },
        ],
    });
});

test('publication refuses incomplete packages and symlinked targets and rolls back a failed rename', () => {
    for (const problem of ['incomplete', 'symlink', 'missing-stage', 'failed-rename']) {
        const directory = mkdtempSync(join(tmpdir(), 'rex-opencode-publish-'));
        const staged = join(directory, 'staged');
        const target = problem === 'failed-rename' ? join(staged, 'target') : join(directory, 'target');
        const personal = join(directory, 'personal');
        const backup = join(directory, 'backups', 'previous');
        mkdirSync(staged);
        mkdirSync(personal);
        writeFileSync(join(personal, 'notes'), 'personal notes');
        if (problem === 'symlink') {
            symlinkSync(personal, target);
        } else {
            mkdirSync(target);
            writeFileSync(join(target, 'notes'), 'original notes');
        }
        for (const name of ['package.json', 'tui.mjs', 'server.mjs', 'rpc.mjs']) {
            if (problem !== 'incomplete' || name === 'package.json') {
                writeFileSync(join(staged, name), name);
            }
        }
        const result = spawnSync(process.execPath, [
            helper, 'publish', problem === 'missing-stage' ? join(directory, 'missing') : staged, target, backup,
        ], { encoding: 'utf8' });
        assert.notEqual(result.status, 0, problem);
        if (problem === 'symlink') {
            assert.equal(lstatSync(target).isSymbolicLink(), true);
        } else {
            assert.equal(readFileSync(join(target, 'notes'), 'utf8'), 'original notes');
        }
        assert.equal(readFileSync(join(personal, 'notes'), 'utf8'), 'personal notes');
        assert.equal(existsSync(backup), false);
    }
});
