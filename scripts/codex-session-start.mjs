// Codex 0.169.0 user command hooks are spawned by the app-server host.
// Install as `exec '<absolute-node>' '<runtime>/scripts/codex-session-start.mjs'`
// so the immediate OS parent is that host, not a shell or a daemon ancestor.
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import {
    closeSync, constants, fstatSync, lstatSync, openSync, readSync, realpathSync,
    renameSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const path = value => typeof value === 'string' && value.startsWith('/') && !/[\x00-\x1f\x7f]/.test(value);
const privateOwner = status => status.uid === process.getuid() && (status.mode & 0o077) === 0;
const sources = ['startup', 'resume', 'clear', 'fork'];
const valueOptions = new Set([
    '--model', '-m', '--sandbox', '-s', '--ask-for-approval', '-a', '--cd', '-C', '--add-dir',
]);
const switchOptions = new Set(['--no-alt-screen', '--all', '--last']);

function readBounded(fd, limit, delimiter) {
    const buffer = Buffer.alloc(limit + 1);
    let bytes = 0;
    while (bytes < buffer.length) {
        const count = readSync(fd, buffer, bytes, buffer.length - bytes);
        if (!count) return delimiter ? undefined : buffer.subarray(0, bytes).toString('utf8');
        bytes += count;
        const end = delimiter ? buffer.indexOf(delimiter) : -1;
        if (end >= 0 && end < bytes) return buffer.subarray(0, end).toString('utf8');
    }
}

function readFile(pathname, limit, delimiter, own) {
    const fd = openSync(pathname, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const status = fstatSync(fd);
        if (status.isFile() && (!own || privateOwner(status))) return readBounded(fd, limit, delimiter);
    } finally {
        closeSync(fd);
    }
}

function foregroundParent(pid, startedAt) {
    if (process.ppid !== pid) return false;
    const row = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'pgid=,tpgid=,lstart='], {
        encoding: 'utf8', env: { LC_ALL: 'C' }, timeout: 300,
    }).trim();
    const [, group, foreground, birth] = row.match(/^([1-9]\d*)\s+([1-9]\d*)\s+(.+)$/) ?? [];
    return group !== undefined && group === foreground && birth === startedAt;
}

function hasExplicitNoDaemon(argv) {
    // Only the driver's supported option vocabulary. Never scan past `--` or
    // reinterpret an unknown option's value as an explicit opt-in.
    for (let index = 0; index < argv.length; index++) {
        const argument = argv[index];
        if (argument === '--no-daemon') return true;
        if (!argument.startsWith('-') || switchOptions.has(argument)) continue;
        const [option] = argument.split('=', 1);
        if (!valueOptions.has(option)) return false;
        if (argument === option) {
            const value = argv[++index];
            if (!value || value.startsWith('-')) return false;
        } else if (!option.startsWith('--')) {
            return false;
        }
    }
    return false;
}

function daemonDisabled(home) {
    let text;
    try {
        text = readFile(join(home, 'config.toml'), 65536);
    } catch (error) {
        if (error.syscall === 'open' && (error.code === 'ENOENT' || error.code === 'ELOOP')) return false;
        throw error;
    }
    // Match the same deliberately narrow user config shape as restore.
    if (!text || text.includes('"""') || text.includes("'''")) return false;
    let features = false;
    let disabled;
    for (const line of text.split('\n')) {
        if (/^\s*\[/.test(line)) {
            features = /^\s*\[features\]\s*(?:#.*)?$/.test(line);
        } else if (features && /^\s*daemon_auto_start\s*=/.test(line)) {
            if (disabled !== undefined) return false;
            disabled = /^\s*daemon_auto_start\s*=\s*false\s*(?:#.*)?$/.test(line);
        }
    }
    return disabled === true;
}

function record() {
    const env = process.env;
    if (env.REX_RECOVER_SESSIONS !== '1' && !env.REX_RECOVER_SESSIONS?.split(',').includes('codex')) return;
    const session = env.REX_SESSION;
    const block = env.REX_BLOCK;
    if (!/^session:[\w:-]+$/.test(session) || !/^block:[\w:-]+$/.test(block)) return;
    const directory = env.REX_RECOVER_LAUNCH_DIR ||
        join(env.REX_RECOVER_STATE_DIR || join(env.XDG_STATE_HOME || join(env.HOME, '.local/state'), 'rex-recover'),
            'launches');
    if (!path(directory)) return;
    const status = lstatSync(directory);
    if (!status.isDirectory() || !privateOwner(status)) return;
    const launch = join(directory, block);
    const fields = readFile(launch, 64 * 1024, undefined, true)?.split('\0') ?? [];
    const [version, sessionId, blockId, pid, startedAt, app, cwd, driver, home, executable, ...argv] = fields;
    if (version !== 'rex-recover-launch-v2' || sessionId !== session || blockId !== block ||
        app !== 'codex' || driver !== 'openai-codex' || fields.at(-1) !== '' || !path(cwd) ||
        !path(home) || !path(executable) || !/^[1-9]\d*$/.test(pid) || !foregroundParent(Number(pid), startedAt)) return;
    const store = realpathSync(resolve(cwd, env.CODEX_HOME || join(env.HOME, '.codex')));
    if (store !== home) return;

    const event = JSON.parse(readBounded(0, 16 * 1024));
    const { session_id: id, transcript_path: transcript, source } = event;
    if (event.hook_event_name !== 'SessionStart' || !sources.includes(source) || !uuid.test(id) ||
        !path(transcript) || !transcript.startsWith(`${home}/sessions/`) || realpathSync(transcript) !== transcript) return;
    const name = transcript.slice(home.length + 1);
    const match = name.match(/^sessions\/(\d{4})\/(\d{2})\/(\d{2})\/rollout-(\d{4}-\d{2}-\d{2})T\d{2}-\d{2}-\d{2}-(.+)\.jsonl$/);
    if (!match || `${match[1]}-${match[2]}-${match[3]}` !== match[4]) return;
    const [threadId, rolloutId, extra] = match[5].split('_');
    if (threadId !== id || extra !== undefined || (rolloutId !== undefined && !uuid.test(rolloutId))) return;
    const metadata = JSON.parse(readFile(transcript, 64 * 1024, '\n'));
    const root = metadata.payload;
    if (metadata.type !== 'session_meta' || root?.id !== id || root.session_id !== id ||
        root.source !== 'cli' || root.thread_source !== 'user' || root.parent_thread_id != null) return;
    // Flagged launches do not depend on config. For flagless launches an I/O
    // failure aborts publication, preserving the previous qualifying event.
    const configDisabled = !hasExplicitNoDaemon(argv) && daemonDisabled(home);

    // Recheck the live instance before publishing. Only metadata is persisted.
    if (!foregroundParent(Number(pid), startedAt)) return;
    const proof = JSON.stringify({
        version: 2, event: 'SessionStart', session, block, pid: Number(pid),
        startedAt, home, cwd, executable, id, transcript, source, configDisabled,
    });
    if (Buffer.byteLength(proof) > 8192) return;
    const destination = `${launch}.${pid}.${Buffer.from(startedAt).toString('hex')}.session`;
    const staging = join(directory, `.codex-session.${randomUUID()}`);
    const fd = openSync(staging, 'wx', 0o600);
    try {
        try {
            writeFileSync(fd, proof);
        } finally {
            closeSync(fd);
        }
        renameSync(staging, destination);
    } finally {
        try { unlinkSync(staging); } catch {}
    }
}

// No stdout: SessionStart hook output can be injected into model context.
try { record(); } catch {}
