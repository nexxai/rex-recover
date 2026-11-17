// Stage settings independently of the checkout and of any running app server.
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import {
    chmodSync, closeSync, constants, fstatSync, linkSync, lstatSync, mkdirSync, mkdtempSync,
    openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, normalize, resolve } from 'node:path';

function requireSafeDirectory(path) {
    if (path === '/') {
        return;
    }
    requireSafeDirectory(dirname(path));
    const entry = lstatSync(path, { throwIfNoEntry: false });
    if (entry && !entry.isDirectory()) {
        throw new Error('Codex settings directory is symlinked or not a directory; edit manually.');
    }
}

function readSettings(path) {
    requireSafeDirectory(dirname(path));
    const entry = lstatSync(path, { throwIfNoEntry: false });
    if (!entry) {
        return { fingerprint: null, contents: Buffer.alloc(0) };
    }
    if (!entry.isFile() || entry.nlink !== 1 || entry.uid !== process.getuid()) {
        throw new Error('Codex settings are linked, not a regular file, or not owned by you; edit manually.');
    }
    const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const current = fstatSync(fd);
        if (!current.isFile() || current.ino !== entry.ino || current.dev !== entry.dev) {
            throw new Error('Codex settings changed during planning; rerun setup.');
        }
        const contents = readFileSync(fd);
        const { dev, ino, mode, mtimeMs, ctimeMs } = current;
        const hash = createHash('sha256').update(contents).digest('hex');
        return { fingerprint: { dev, ino, mode, mtimeMs, ctimeMs, hash }, contents };
    } finally {
        closeSync(fd);
    }
}

function snapshot(path, stage) {
    const { fingerprint, contents } = readSettings(path);
    mkdirSync(stage);
    writeFileSync(join(stage, 'snapshot'), JSON.stringify(fingerprint));
    return { fingerprint, contents };
}

function check(path, stage) {
    const current = readSettings(path);
    if (JSON.stringify(current.fingerprint) !== readFileSync(join(stage, 'snapshot'), 'utf8')) {
        throw new Error('Codex settings changed during planning; rerun setup.');
    }
    return current;
}

function publish(path, stage) {
    const updated = join(stage, 'updated');
    const original = check(path, stage);
    if (!lstatSync(updated, { throwIfNoEntry: false })) {
        return;
    }
    const directory = dirname(path);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const temporary = mkdtempSync(join(directory, '.rex-recover-stage-'));
    try {
        const replacement = join(temporary, 'updated');
        writeFileSync(replacement, readFileSync(updated), { mode: 0o600 });
        if (original.fingerprint) {
            chmodSync(replacement, original.fingerprint.mode & 0o777);
            check(path, stage);
            const backup = `${path}.rex-recover-backup-${randomUUID()}`;
            writeFileSync(backup, original.contents, { flag: 'wx', mode: 0o600 });
            console.log(`Backed up: ${backup}`);
            check(path, stage);
            // Atomic rename never writes through a symlink. The snapshot detects
            // ordinary intervening edits; Codex doesn't share an installer lock.
            renameSync(replacement, path);
        } else {
            check(path, stage);
            linkSync(replacement, path); // Never replace a concurrently created file.
        }
    } finally {
        rmSync(temporary, { recursive: true, force: true });
    }
}

function decode(bytes) {
    // A byte-exact UTF-8 round trip also prevents invalid input being rewritten.
    const text = bytes.toString('utf8');
    if (!Buffer.from(text).equals(bytes)) {
        throw new Error('Codex settings must be UTF-8; edit manually.');
    }
    return text;
}

const assignmentPrefix = '[ \\t]*daemon_auto_start[ \\t]*=[ \\t]*';
const assignmentSuffix = '[ \\t]*(?:#[^\\r\\n]*)?\\r?$';
const enabledLine = new RegExp(`^(${assignmentPrefix})true(${assignmentSuffix})`);
const insertion = new RegExp(`^(?:\\[features\\]\\r?\\n)?${assignmentPrefix}false[ \\t]*\\r?$`);

function supportsFlaglessRecovery(text) {
    // Match the bounded config readers in codex-session-start.mjs and openai-codex.lua.
    if (Buffer.byteLength(text) > 65536 || text.includes('"""') || text.includes("'''")) {
        return false;
    }
    let features = false;
    let disabled;
    for (const line of text.split('\n')) {
        if (/^[ \t]*\[/.test(line)) {
            features = /^[ \t]*\[features\][ \t]*(?:#[^\r\n]*)?\r?$/.test(line);
        } else if (features && /^[ \t]*daemon_auto_start[ \t]*=/.test(line)) {
            if (disabled !== undefined) {
                return false;
            }
            disabled = /^[ \t]*daemon_auto_start[ \t]*=[ \t]*false[ \t]*(?:#[^\r\n]*)?\r?$/.test(line);
        }
    }
    return disabled === true;
}

function isOnlyDaemonEdit(original, updated) {
    // Native Codex parses and edits TOML. This check only authorizes a bounded
    // byte difference, not a rewrite of a differently formatted valid config.
    // ponytail: unusual output (e.g. inline table edits) can be applied manually.
    if (original === updated) {
        return true;
    }
    const after = updated.split('\n');
    const before = original.split('\n');
    let start = 0;
    while (before[start] === after[start]) {
        start++;
    }
    while (before.length > start && after.length > start && before.at(-1) === after.at(-1)) {
        before.pop();
        after.pop();
    }
    const added = after.slice(start);
    if (before.length - start === 1 && added.length === 1 && enabledLine.test(before[start])) {
        return before[start].replace(enabledLine, '$1false$2') === added[0];
    }
    return before.length === start && insertion.test(added.filter(line => !/^[ \t\r]*$/.test(line)).join('\n'));
}

function editDaemon(path, stage, codex) {
    const original = check(path, stage);
    const scratch = realpathSync(mkdtempSync(join(stage, 'codex-')));
    const config = join(scratch, 'config.toml');
    if (original.fingerprint) {
        writeFileSync(config, original.contents, { mode: 0o600 });
    }
    // This native settings-only subcommand is not a Codex launch. Do not expose
    // the real home, login, cwd, or service state to it.
    const safePath = (process.env.PATH || '').split(':').filter(entry => isAbsolute(entry)).join(':');
    const result = spawnSync(codex, ['features', 'disable', 'daemon_auto_start'], {
        cwd: scratch,
        env: {
            PATH: safePath || '/usr/bin:/bin', HOME: scratch, CODEX_HOME: scratch, XDG_CONFIG_HOME: scratch,
            XDG_DATA_HOME: scratch, XDG_STATE_HOME: scratch, XDG_CACHE_HOME: scratch, TMPDIR: scratch,
        },
        stdio: 'ignore',
        timeout: 10000,
    });
    const edited = result.status === 0 && readSettings(config);
    if (!edited?.fingerprint) {
        throw new Error("Codex's native editor could not set daemon_auto_start; use --no-daemon or edit config.toml manually.");
    }
    const updated = decode(edited.contents);
    if (!supportsFlaglessRecovery(updated)) {
        throw new Error('Rex Recover only recognizes an unquoted [features] stanza with a plain daemon_auto_start key in a config of at most 64 KiB and without multiline TOML strings. Rerun setup, decline the daemon setting change, and use codex --no-daemon.');
    }
    if (!isOnlyDaemonEdit(decode(original.contents), updated)) {
        throw new Error('Codex editor changed unexpected TOML bytes or did not set daemon_auto_start=false; edit manually.');
    }
    check(path, stage);
    if (!edited.contents.equals(original.contents)) {
        writeFileSync(join(stage, 'updated'), edited.contents);
    }
}

// JSON.parse checks syntax. This token walk finds insertion boundaries and
// rejects duplicate keys without serializing other people's hook definitions.
function hookContainers(text) {
    const stack = [];
    const locations = { groups: [] };
    for (const token of text.matchAll(/("(?:[^"\\]|\\.)*")([ \t\n\r]*:)?|[{}[\]]/g)) {
        const [value, string, colon] = token;
        const parent = stack[stack.length - 1];
        if (colon) {
            const key = JSON.parse(string);
            if (parent.keys.has(key)) {
                throw new Error('Duplicate keys in hooks.json; edit manually.');
            }
            parent.keys.add(key);
            parent.key = key;
        } else if (value === '{' || value === '[') {
            const name = !parent ? 'root' :
                parent.name === 'root' && parent.key === 'hooks' ? 'hooks' :
                parent.name === 'hooks' && parent.key === 'SessionStart' ? 'sessions' :
                parent.name === 'sessions' ? 'group' : null;
            const entry = { name, keys: new Set(), start: token.index, end: undefined };
            if (name === 'group') {
                locations.groups.push(entry);
            } else if (name) {
                locations[name] = entry;
            }
            stack.push(entry);
        } else if (value === '}' || value === ']') {
            stack.pop().end = token.index;
        }
    }
    return locations;
}

function object(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function parseHooks(text) {
    let config;
    try {
        config = JSON.parse(text);
    } catch {
        throw new Error('hooks.json must be strict JSON; edit manually.');
    }
    if (!object(config) || (Object.hasOwn(config, 'hooks') && !object(config.hooks)) ||
        Object.keys(config).some(key => key !== 'hooks' && key !== 'description') ||
        (config.description != null && typeof config.description !== 'string')) {
        throw new Error('Unsupported Codex hooks.json settings shape; edit manually.');
    }
    const groups = config.hooks?.SessionStart;
    if (groups !== undefined && (!Array.isArray(groups) ||
        groups.some(group => !object(group) || !Array.isArray(group.hooks) || !group.hooks.every(object)))) {
        throw new Error('Unsupported Codex SessionStart settings shape; edit manually.');
    }
    return { config, groups };
}

const hookGroup = command => ({ hooks: [{ type: 'command', command }] });

function isManagedGroup(group, command) {
    return !!group && Object.keys(group).length === 1 && group.hooks.length === 1 &&
        Object.keys(group.hooks[0]).length === 2 && group.hooks[0].type === 'command' &&
        group.hooks[0].command === command;
}

function installHooks(path, stage, command, runtime, previous = '') {
    const { fingerprint, contents } = snapshot(path, stage);
    const original = fingerprint ? decode(contents) : '{}\n';
    const { config, groups } = parseHooks(original);
    const { root, hooks, sessions, groups: groupLocations } = hookContainers(original);
    const existing = groups?.flatMap(group => group.hooks) || [];
    const aliases = existing.filter(handler => handler.command === command || (previous && handler.command === previous));
    if (aliases.length > 1 || (!aliases.length &&
        existing.some(handler => typeof handler.command === 'string' &&
            handler.command.includes(basename(runtime))))) {
        throw new Error('An existing Rex Recover hook was customized or duplicated; review it in hooks.json manually.');
    }
    const active = aliases[0]?.command || command;
    const owned = aliases.length ? (active === previous ? previous : '') : command;
    if (!aliases.length) {
        const newGroup = hookGroup(command);
        let offset;
        let addition;
        if (sessions) {
            const lastGroup = groupLocations.at(-1);
            offset = lastGroup ? lastGroup.end + 1 : sessions.start + 1;
            addition = `${lastGroup ? ', ' : ''}${JSON.stringify(newGroup)}`;
        } else if (hooks) {
            offset = hooks.end;
            addition = `${Object.keys(config.hooks).length ? ', ' : ''}"SessionStart": ${JSON.stringify([newGroup])}`;
        } else {
            offset = root.end;
            addition = `${Object.keys(config).length ? ', ' : ''}"hooks": ${JSON.stringify({ SessionStart: [newGroup] })}`;
        }
        writeFileSync(join(stage, 'updated'), `${original.slice(0, offset)}${addition}${original.slice(offset)}`);
    }
    writeFileSync(join(stage, 'active-command'), active);
    writeFileSync(join(stage, 'owned-command'), owned);
}

function removeHooks(path, stage, command, runtime) {
    const escapedRuntime = runtime.replaceAll("'", "'\\''");
    if (command && (!command.startsWith('exec ') || !command.endsWith(` '${escapedRuntime}'`))) {
        throw new Error('Invalid managed Codex hook command in manifest; resolve it manually.');
    }
    const { fingerprint, contents } = snapshot(path, stage);
    if (!fingerprint) {
        return;
    }
    const original = decode(contents);
    const { config, groups } = parseHooks(original);
    const { groups: groupLocations } = hookContainers(original);
    const ownedGroups = command ? (groups ?? []).filter(group => isManagedGroup(group, command)) : [];
    const managed = ownedGroups.length === 1 ? ownedGroups[0] : undefined;
    for (const [event, eventGroups] of Object.entries(config.hooks ?? {})) {
        if (!Array.isArray(eventGroups)) {
            continue;
        }
        const handlers = eventGroups
            .filter(group => group !== managed)
            .flatMap(group => Array.isArray(group?.hooks) ? group.hooks : []);
        if (handlers.some(handler => [handler?.command, handler?.command_windows].some(value =>
            typeof value === 'string' && (value.includes(runtime) || value.includes(escapedRuntime))))) {
            throw new Error(`Remove or repoint only the ${JSON.stringify(event)} hook command that uses ${runtime} in ${path}, then rerun uninstall.`);
        }
    }
    if (!managed) {
        return;
    }
    const index = groups.indexOf(managed);
    const { start, end } = groupLocations[index];
    const prefix = original.slice(0, start);
    const suffix = original.slice(end + 1);
    // Codex trust keys use the group index. v0.169.0 accepts an empty handler
    // list and enumerates groups before handlers, so later hooks stay trusted.
    const updated = index === groups.length - 1
        ? `${prefix.replace(/,[ \t\n\r]*$/, '')}${suffix}`
        : `${prefix}{"hooks":[]}${suffix}`;
    writeFileSync(join(stage, 'updated'), updated);
}

try {
    const [operation, path, directory, ...parameters] = process.argv.slice(2);
    const stage = resolve(directory);
    if (!isAbsolute(path) || normalize(path) !== path || !['config.toml', 'hooks.json'].includes(basename(path))) {
        throw new Error('Invalid Codex settings path; use a normalized absolute CODEX_HOME.');
    }
    if (operation === 'snapshot') {
        snapshot(path, stage);
    } else if (operation === 'check') {
        check(path, stage);
    } else if (operation === 'publish') {
        publish(path, stage);
    } else if (operation === 'edit-daemon') {
        editDaemon(path, stage, ...parameters);
    } else if (operation === 'install-hooks') {
        installHooks(path, stage, ...parameters);
    } else if (operation === 'remove-hooks') {
        removeHooks(path, stage, ...parameters);
    } else {
        throw new Error('Unsupported Codex settings operation.');
    }
} catch (error) {
    console.error(`Rex Recover: ${error.message}`);
    process.exitCode = 1;
}
