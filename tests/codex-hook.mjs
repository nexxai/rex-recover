import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const hook = fileURLToPath(new URL('../scripts/codex-session-start.mjs', import.meta.url));
const alpha = '019a80b1-1234-7000-8000-111111111111';
const beta = '019a80b2-1234-7000-8000-222222222222';

test('the recorded TUI can publish a start; its descendant daemon cannot publish B', () => {
    const root = realpathSync(mkdtempSync(join(process.env.REX_TEST_TMPDIR || tmpdir(), 'rex-codex-hook.')));
    try {
        const home = join(root, "store's home");
        const launches = join(root, 'launches');
        const transcripts = join(home, 'sessions/2026/11/16');
        mkdirSync(launches, { mode: 0o700 });
        mkdirSync(transcripts, { recursive: true });
        const events = {};
        for (const id of [alpha, beta]) {
            const path = join(transcripts, `rollout-2026-11-16T12-00-00-${id}.jsonl`);
            writeFileSync(path, JSON.stringify({
                type: 'session_meta',
                payload: { id, session_id: id, source: 'cli', thread_source: 'user', cli_version: '0.169.0' },
            }) + '\n{"type":"response_item","payload":"never copy transcript text"}\n');
            events[id] = JSON.stringify({
                hook_event_name: 'SessionStart', session_id: id, transcript_path: path,
                cwd: root, model: 'test', permission_mode: 'default', source: 'startup',
            });
        }
        const descendant = '019a80b3-1234-7000-8000-333333333333';
        const transcript = join(transcripts, `rollout-2026-11-16T12-00-00-${descendant}.jsonl`);
        writeFileSync(transcript, JSON.stringify({
            type: 'session_meta',
            payload: { id: descendant, session_id: alpha, parent_thread_id: alpha, source: 'cli',
                thread_source: 'subagent', cli_version: '0.169.0' },
        }) + '\n');
        events.subagent = JSON.stringify({
            ...JSON.parse(events[alpha]), session_id: descendant, transcript_path: transcript,
        });
        events.compact = JSON.stringify({ ...JSON.parse(events[beta]), source: 'compact' });
        const collision = '00000000-0000-4000-8000-000000000000';
        writeFileSync(join(root, 'collision.cjs'), `
            require('node:crypto').randomUUID = () => '${collision}';
            require('node:module').syncBuiltinESMExports();
        `);
        writeFileSync(join(root, 'unreadable-config.cjs'), `
            const fs = require('node:fs');
            const open = fs.openSync;
            fs.openSync = (path, ...args) => {
                if (path === process.env.CODEX_HOME + '/config.toml') {
                    throw Object.assign(new Error('fixture I/O failure'), { code: 'EACCES', syscall: 'open' });
                }
                return open(path, ...args);
            };
            require('node:module').syncBuiltinESMExports();
        `);

        // The mock host stays alive while its `sh -c 'exec node ...'` hook
        // runs. B is a valid same-store root event, with A's stale Rex env.
        const mock = join(root, 'mock-tui.mjs');
        writeFileSync(mock, `
            import { spawnSync } from 'node:child_process';
            import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
            const [root, home, launches, hook, alpha, beta, scenario] = process.argv.slice(2);
            const launch = launches + '/block:codex';
            const birth = spawnSync('/bin/ps', ['-p', String(process.pid), '-o', 'lstart='],
                { env: { LC_ALL: 'C' }, encoding: 'utf8' }).stdout.trim();
            const argv = scenario === 'flagless' ? ['--', '--no-daemon']
                : ['--model', 'model', 'resume', alpha, '--no-daemon', 'do not replay this'];
            writeFileSync(launch, ['rex-recover-launch-v2', 'session:fixture', 'block:codex',
                process.pid, birth, 'codex', root, 'openai-codex', home, '/fixture/codex',
                ...argv].join('\\0') + '\\0', { mode: 0o600 });
            const invoke = (nested, id, env = process.env) => {
                const result = spawnSync('/bin/sh', ['-c', nested ? '"$@" & wait' : 'exec "$@"',
                    'hook-shell', process.execPath, hook], {
                    detached: true, input: readFileSync(root + '/' + id), env, encoding: 'utf8',
                });
                if (result.error || result.status || result.stdout || result.stderr) throw new Error(JSON.stringify(result));
            };
            const sidecar = launch + '.' + process.pid + '.' + Buffer.from(birth).toString('hex') + '.session';
            if (scenario === 'background') {
                const [group, foreground] = spawnSync('/bin/ps', ['-p', String(process.pid), '-o', 'pgid=,tpgid='],
                    { encoding: 'utf8' }).stdout.trim().split(/\\s+/);
                if (group === foreground || Number(foreground) < 1) throw new Error('fixture is not in a background job');
                invoke(false, beta);
                if (existsSync(sidecar)) throw new Error('a background launch created the sidecar');
                writeFileSync(root + '/background-checked', 'yes');
                process.exit(0);
            }
            if (scenario) {
                const config = home + '/config.toml';
                writeFileSync(config, '[features]\\ndaemon_auto_start = false\\n');
                invoke(false, alpha);
                const saved = JSON.parse(readFileSync(sidecar, 'utf8'));
                invoke(false, beta, { ...process.env, NODE_OPTIONS: '--require=./unreadable-config.cjs' });
                const afterError = JSON.parse(readFileSync(sidecar, 'utf8'));
                if (scenario === 'flagless') {
                    if (!saved.configDisabled || afterError.id !== alpha || !afterError.configDisabled) {
                        throw new Error('config I/O failure replaced the last valid flagless record');
                    }
                    writeFileSync(config, '[features]\\ndaemon_auto_start = true\\n');
                    invoke(false, beta);
                    const reenabled = JSON.parse(readFileSync(sidecar, 'utf8'));
                    if (reenabled.id !== beta || reenabled.configDisabled !== false) {
                        throw new Error('reenabled config was not recorded');
                    }
                    unlinkSync(config);
                    invoke(false, alpha);
                    const missing = JSON.parse(readFileSync(sidecar, 'utf8'));
                    if (missing.id !== alpha || missing.configDisabled !== false) {
                        throw new Error('missing config was not recorded');
                    }
                } else if (afterError.id !== beta) {
                    throw new Error('config I/O failure prevented explicit --no-daemon capture');
                }
                if (existsSync(config)) unlinkSync(config);
                writeFileSync(root + '/' + scenario + '-checked', 'yes');
                process.exit(0);
            }
            writeFileSync(root + '/sidecar-path', sidecar);
            invoke(false, alpha, { ...process.env, REX_RECOVER_SESSIONS: 'not-codex,codex-extra' });
            invoke(false, 'subagent');
            invoke(true, beta);
            if (existsSync(sidecar)) throw new Error('an unqualified call created the sidecar');
            invoke(false, alpha);
            const staging = launches + '/.codex-session.${collision}';
            writeFileSync(staging, 'owned by another writer');
            invoke(false, beta, { ...process.env, NODE_OPTIONS: '--require=./collision.cjs' });
            if (readFileSync(staging, 'utf8') !== 'owned by another writer') throw new Error('staging file changed');
            invoke(true, beta);
            invoke(false, 'compact');
            invoke(false, 'subagent');
        `);
        for (const [id, event] of Object.entries(events)) writeFileSync(join(root, id), event);
        const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
        const argv = [process.execPath, mock, root, home, launches, hook, alpha, beta];
        const mockShell = ['/bin/bash', '--noprofile', '--norc', '-imc', '"$@" & wait $!', 'fixture', ...argv];
        const input = openSync('/dev/null', 'r');
        const options = {
            cwd: root, stdio: [input, 'pipe', 'pipe'], encoding: 'utf8', timeout: 6000,
            env: { PATH: '/usr/bin:/bin', HOME: root, CODEX_HOME: home, REX_RECOVER_LAUNCH_DIR: launches,
                REX_RECOVER_SESSIONS: 'opencode,codex', REX_SESSION: 'session:fixture', REX_BLOCK: 'block:codex' },
        };
        try {
            for (const command of [argv, [...mockShell, 'background'], [...argv, 'flagless'], [...argv, 'explicit']]) {
                const scriptArgs = process.platform === 'darwin' ? ['-q', '/dev/null', ...command]
                    : ['-qec', command.map(quote).join(' '), '/dev/null'];
                const result = spawnSync('/usr/bin/script', scriptArgs, options);
                assert.equal(result.error, undefined);
                assert.equal(result.status, 0, result.stdout + result.stderr);
                assert.doesNotMatch(result.stdout, /Error:/);
            }
        } finally {
            closeSync(input);
        }
        assert.equal(readFileSync(join(root, 'background-checked'), 'utf8'), 'yes');
        assert.equal(readFileSync(join(root, 'flagless-checked'), 'utf8'), 'yes');
        assert.equal(readFileSync(join(root, 'explicit-checked'), 'utf8'), 'yes');
        const path = readFileSync(join(root, 'sidecar-path'), 'utf8');
        const proof = readFileSync(path, 'utf8');
        const observed = JSON.parse(proof);
        assert.equal(observed.id, alpha);
        assert.equal(observed.transcript, JSON.parse(events[alpha]).transcript_path);
        assert.equal(statSync(path).mode & 0o777, 0o600);
        assert.doesNotMatch(proof, /never copy transcript text|do not replay this/);
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});
