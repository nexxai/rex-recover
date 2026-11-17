// Stage legacy CLI migrations and atomically publish complete plugin folders. The shell
// owns config backups and symlink-preserving writes; no OpenCode API is used.
import { existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

function object(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function rejectDuplicateKeys(text) {
    // JSON.parse validates syntax. This token walk only prevents silently
    // selecting one of two conflicting preferences in an otherwise valid file.
    const scopes = [];
    for (const token of text.matchAll(/"(?:[^"\\]|\\.)*"|[{}[\]]/g)) {
        const [value] = token;
        if (value === '{' || value === '[') {
            scopes.push(new Set());
        } else if (value === '}' || value === ']') {
            scopes.pop();
        } else if (/^\s*:/.test(text.slice(token.index + value.length))) {
            const key = JSON.parse(value);
            const scope = scopes[scopes.length - 1];
            if (scope.has(key)) {
                throw new Error('Duplicate CLI setting keys are ambiguous; resolve them manually.');
            }
            scope.add(key);
        }
    }
}

function ownsPackage(entry, paths) {
    if (paths.includes(entry)) {
        return true;
    }
    try {
        const url = new URL(entry);
        return url.protocol === 'file:' && !url.search && !url.hash && paths.includes(fileURLToPath(url));
    } catch {
        return false;
    }
}

function fingerprint(path) {
    let entry;
    try {
        entry = lstatSync(path);
    } catch (error) {
        if (error.code === 'ENOENT') {
            return { exists: false };
        }
        throw error;
    }
    if ((!entry.isFile() && !entry.isSymbolicLink()) || !statSync(path).isFile()) {
        throw new Error('CLI settings must be a regular file or a symlink to one; resolve it manually.');
    }
    const target = statSync(path);
    return {
        exists: true,
        target: realpathSync(path),
        inode: entry.ino,
        targetInode: target.ino,
        mode: target.mode,
        hash: createHash('sha256').update(readFileSync(path)).digest('hex'),
    };
}

function plan() {
    const [operation, cli, runtime, plugin, output, snapshot, savedTitle = '-', savedTerminal = '-'] = process.argv.slice(2);
    if (operation === 'check') {
        if (JSON.stringify(fingerprint(cli)) !== readFileSync(runtime, 'utf8')) {
            throw new Error('CLI settings changed during planning; no changes made. Run setup again.');
        }
        return;
    }
    if (operation === 'publish') {
        const staged = cli;
        const target = runtime;
        const backup = plugin;
        if (!lstatSync(staged).isDirectory()) {
            throw new Error('The staged companion must be a complete directory.');
        }
        for (const name of ['package.json', 'tui.mjs', 'server.mjs', 'rpc.mjs']) {
            if (!lstatSync(`${staged}/${name}`).isFile()) {
                throw new Error('The staged companion is incomplete.');
            }
        }
        if (existsSync(backup)) {
            throw new Error('The companion backup destination already exists; resolve it manually.');
        }
        const previous = existsSync(target);
        // lstat also catches dangling symlinks, which existsSync deliberately
        // treats as absent. Never replace a dotfile-managed plugin directory.
        const targetEntry = lstatSync(target, { throwIfNoEntry: false });
        if (targetEntry && !targetEntry.isDirectory()) {
            throw new Error('The companion target is symlinked or is not a directory; resolve it manually.');
        }
        if (previous) {
            mkdirSync(dirname(backup), { recursive: true });
            renameSync(target, backup);
        }
        try {
            // Unlike shell mv, rename fails rather than copying a partial
            // package across filesystems into the watched discovery tree.
            renameSync(staged, target);
        } catch (error) {
            if (previous) {
                renameSync(backup, target);
            }
            throw error;
        }
        return;
    }
    if (!['install', 'remove'].includes(operation)) {
        throw new Error('Unsupported settings operation.');
    }
    if ((savedTitle !== '-' || savedTerminal !== '-') &&
        (!['absent', 'true', 'false'].includes(savedTitle) || !['absent', 'present'].includes(savedTerminal))) {
        throw new Error('Invalid prior CLI title ownership; restore the settings manually.');
    }
    const before = fingerprint(cli);
    let original;
    try {
        original = readFileSync(cli, 'utf8');
    } catch (error) {
        if (error.code !== 'ENOENT') {
            throw error;
        }
    }
    if (original === undefined) {
        return;
    }
    const ownPaths = [runtime, plugin];
    // Discovery needs no CLI preferences. Parse/validate only when our known
    // legacy strings or ownership record could require a settings migration.
    const hasLegacyEntry = [...original.matchAll(/"(?:[^"\\]|\\.)*"/g)].some(([token]) => {
        try {
            const entry = JSON.parse(token);
            return ownsPackage(entry, ownPaths) || (operation === 'install' && entry === '-rex-recover.opencode');
        } catch {
            return false;
        }
    });
    if (!hasLegacyEntry && savedTitle === '-') {
        return;
    }
    let config;
    try {
        config = JSON.parse(original);
    } catch {
        throw new Error('cli.json must be strict JSON; resolve malformed JSON or JSONC manually before setup.');
    }
    rejectDuplicateKeys(original);
    if (!object(config) || (config.terminal !== undefined && !object(config.terminal))) {
        throw new Error('Unsupported CLI settings shape; configure the companion manually.');
    }
    if (config.terminal?.title !== undefined && typeof config.terminal.title !== 'boolean') {
        throw new Error('terminal.title must be boolean; configure the companion manually.');
    }
    if (config.plugins !== undefined) {
        if (!Array.isArray(config.plugins)) {
            throw new Error('plugins must be an array; configure the companion manually.');
        }
        config.plugins = config.plugins.filter(entry => {
            if (typeof entry === 'string') {
                return !ownsPackage(entry, ownPaths) && !(operation === 'install' && entry === '-rex-recover.opencode');
            }
            if (!object(entry) || typeof entry.package !== 'string') {
                throw new Error('Unsupported plugins entry; configure the companion manually.');
            }
            if (ownsPackage(entry.package, ownPaths)) {
                throw new Error('An existing companion object entry may contain custom options; migrate it manually.');
            }
            return true;
        });
    }
    // Only older installers owned a title override. Fresh discovery needs none.
    if (savedTitle !== '-' && config.terminal?.title === false) {
        if (savedTitle === 'absent') {
            delete config.terminal.title;
            if (savedTerminal === 'absent' && Object.keys(config.terminal).length === 0) {
                delete config.terminal;
            }
        } else {
            config.terminal.title = savedTitle === 'true';
        }
    }
    if (JSON.stringify(JSON.parse(original)) === JSON.stringify(config)) {
        return;
    }
    writeFileSync(output, `${JSON.stringify(config, null, 2)}\n`);
    if (JSON.stringify(fingerprint(cli)) !== JSON.stringify(before)) {
        throw new Error('CLI settings changed during planning; no changes made. Run setup again.');
    }
    writeFileSync(snapshot, JSON.stringify(before));
}

try {
    plan();
} catch (error) {
    console.error(`Rex Recover: ${error.message}`);
    process.exitCode = 1;
}
