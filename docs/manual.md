# Rex Recover manual

Rex Recover relaunches the commands you choose to monitor in their original
panes after a Rex server restart. It uses the original folder and arguments
unless you opt in to [saved conversation recovery](#recover-saved-conversations).
Nothing is monitored by default.

[Install or uninstall](#interactive-installation-and-removal) ·
[Configure monitored commands](#configure) ·
[Recover saved conversations](#recover-saved-conversations) ·
[Troubleshoot](#troubleshooting)

## Interactive installation and removal

On macOS or Linux, in a terminal outside Rex, run `sh install.sh`. Stop any
manual watcher first. The installer detects macOS or Linux, asks for executable
names without preselecting any, and separately offers shell and service setup.
Its final confirmation happens before installation files are changed.

The installer copies the runtime into your user application-data directory, so
the checkout does not need to stay in place:

- macOS: `~/Library/Application Support/rex-recover`.
- Linux: `~/.local/share/rex-recover`.
- With `XDG_DATA_HOME` set: `$XDG_DATA_HOME/rex-recover` on either platform.

Command launchers are installed in `~/.local/bin`. The managed shell block adds
that directory to `PATH`, but loads capture only in Rex terminals. Existing
dotfile symlinks are preserved. Reinstalling updates rather than duplicates
the block, and backs up files whose contents change.

macOS service setup requires an available launchd GUI user domain. Linux
service setup requires an available systemd user manager. If no usable manager
is detected, installation can proceed without a service; run the watcher
manually outside Rex instead. The installer never starts or stops Rex.

Open new terminals afterward and launch newly monitored commands once to
capture their launch details.

To remove a managed installation, run `~/.local/bin/rex-recover-uninstall`, or
`sh uninstall.sh` from this checkout. Removal stops the installed watcher
service and removes its shell block and unchanged installer-owned files,
including the OpenCode companion. Modified installed files and edited managed
blocks require further approval. If a user-owned Codex hook still points to the
installed helper, uninstall asks you to remove or repoint that hook first.
Other settings, files, and backups stay in place. If the installer changed
Codex's daemon auto-start setting, uninstall explains how to undo it without
editing that setting.

App configuration, recovery state, and watcher logs are kept by default;
deleting them is a separate prompt. Even that cleanup leaves unrelated files
alone. Open new terminals after uninstalling to discard already-loaded shell
functions.

## Configure

For an installed setup, run:

```sh
rex-recover apps
```

The menu shows the current list with numbers. Choose **a** to add executable
names separated by spaces or commas, or **r** to remove one or more displayed
numbers. Existing names do not need to be retyped; adding an already monitored
name leaves it alone. Choose **s** to save or **q** to cancel. Nothing is written
until Save, and closed input cancels without saving.

Comments and unselected entries are preserved, changed files are backed up,
and config symlinks remain intact. Invalid input leaves the staged list unchanged.
If the file changes outside the menu before saving, Save refuses to overwrite
that edit; reopen the menu to work from the updated list.

Use `rex-recover apps --config /absolute/path/apps.conf` to edit another list.
From an uninstalled checkout, use `sh bin/rex-recover apps` instead. The config
must already exist and be valid.

After saving, restart the watcher and refresh capture as described below.
The menu does not automatically restart services or change your current shell.

### Plain-text configuration

Create a plain-text file at:

```text
~/.config/rex-recover/apps.conf
```

If `XDG_CONFIG_HOME` is set, use `$XDG_CONFIG_HOME/rex-recover/apps.conf`.
List one **bare executable name per line**:

```text
# Replace these illustrative names with your commands.
my-server
my-editor
another-tool  # inline comments are allowed
```

That is the entire format. There are no modes, modifiers, or arguments to put in
this file; session recovery is selected in the launching shell. Blank lines
and comments are ignored. An empty file monitors nothing. Duplicates, paths,
and extra fields are errors.

Start with the empty template at [`examples/apps.conf`](../examples/apps.conf).
For example, from this project's directory:

```sh
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rex-recover"
mkdir -p "$config_dir"
cp -n examples/apps.conf "$config_dir/apps.conf"
```

Edit the file to add your chosen commands. The copy command leaves an existing
configuration untouched. These manual steps do not edit shell startup files;
the interactive installer does so only with your approval.

Both the watcher and shell integration use **the same parser and file**:

- `REX_RECOVER_CONFIG=/absolute/path/apps.conf` selects another file for both.
- The watcher's `--config /absolute/path/apps.conf` overrides that environment
  variable. Set `REX_RECOVER_CONFIG` to the same path in your Rex shells.
- After editing the list, run `rex-recover service restart` for an installed
  watcher service. For a foreground watcher, stop it with Ctrl-C and start it
  again. Open new Rex terminals or re-source the shell integration.
  Re-sourcing removes obsolete wrappers without overwriting user-defined or
  user-modified functions. Launch newly monitored commands once to record them.

Missing or invalid config is reported with the file and, for invalid entries,
the line number. Invalid shell config leaves the existing wrappers unchanged.
The file is data, not executable Lua.

## Run the watcher

Requires **Rex 0.1.0-preview.14 or newer**, macOS or Linux, and `lockf` (built into
macOS) or `flock` (normally provided by util-linux on Linux). No separate Lua
installation or Lua packages are needed.

Run **outside Rex**, preferably as a user service:

```sh
sh /absolute/path/to/project/bin/rex-recover
```

The watcher runs outside Rex so it can survive a server shutdown and reconnect.
Running it inside a Rex terminal puts it under the server it is meant to watch.

Available options:

```sh
sh bin/rex-recover \
  --rex /absolute/path/to/rex \
  --config /absolute/path/to/apps.conf \
  --state-dir "$HOME/.local/state/rex-recover" \
  --interval 2
```

- The Rex CLI is selected from `--rex`, then `$REX_BIN`, then `rex` on `PATH`.
  On macOS the launcher also discovers Rex's bundled CLI at
  `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex`.
- State is selected from `--state-dir`, then `$REX_RECOVER_STATE_DIR`, then
  `$XDG_STATE_HOME/rex-recover`, or `~/.local/state/rex-recover`.
- `--interval` controls scans in seconds. Shorter intervals reduce the gap
  between an app change and a checkpoint. An unchanged scan doesn't rewrite
  the checkpoint.
- `--server unix:///absolute/path/rex.sock` selects a separate local server.
  Use a distinct state directory per server. Remote servers and Windows are
  not supported by this launcher.

The watcher **never starts Rex**. It waits while Rex is stopped and reconnects
when Rex returns. Ctrl-C stops the watcher, not Rex or its applications.

### Restart the watcher service

```sh
rex-recover service restart
```

This operates only on your user watcher service: `local.rex-recover` in the
macOS GUI user domain, or `rex-recover.service` in Linux's systemd user manager.
It does not restart Rex, relaunch apps, or change login-start settings. It can
also start an installed service that is currently stopped.

On macOS the job is unloaded and bootstrapped again, rather than force-killing
only its supervisor and potentially leaving a worker holding the watcher lock.
On Linux it uses `systemctl --user restart rex-recover.service`. A missing
service installation or service-manager error is reported as a failure.
Successful output confirms the restart request, not ongoing watcher health;
check the service logs if monitoring does not resume.

To upgrade an installed runtime, rerun the installer from the updated checkout;
restarting alone does not copy new code into the installation.

Check the installed version with `rex-recover --version`, or identify an
uninstalled checkout with `sh bin/rex-recover --version`. These commands do not
require a running Rex server or recovery configuration.

### Try a recovery

Use a disposable command you are comfortable relaunching. Enable capture in a
new Rex terminal and launch that monitored command once so its details are
recorded. Leave it running long enough for the watcher to observe it.

From a terminal **outside Rex**, stop the server:

```sh
rex --autostart=false server stop
```

**This ends every program running in the server's sessions**, not just the
monitored command. Save your work first. Do not add `--discard`: recovery needs
Rex's saved sessions and terminal IDs.

Start Rex again as usual. The watcher waits for you to do this, then restores
the last observed monitored commands in their original terminals.

### Start at login on macOS

Copy [`examples/launchd.plist`](../examples/launchd.plist) to
`~/Library/LaunchAgents/local.rex-recover.plist` and replace its `/ABSOLUTE/...`
placeholders. Use the stable `Versions/Current/.../rex` executable path.
Launchd does not expand `$HOME` or `~`. The default config file must exist.

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.rex-recover.plist"
```

To stop and unload:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.rex-recover.plist"
```

The template starts and supervises the watcher, not Rex. Its log paths must
have existing parent directories; configure log rotation for long-term use.
On Linux, run the same watcher command from a user service.

## Enable launch capture manually

In each Rex **zsh** terminal where you launch configured commands:

```zsh
source /absolute/path/to/project/shell/rex-recover.zsh
```

Add the same line to `~/.zshrc` for future shells. No command prefix is needed:
keep using your configured commands normally.

For **bash**, source `shell/rex-recover.bash` instead, from `~/.bashrc` on Linux
or `~/.bash_profile` for a login bash on macOS. The installer chooses the
appropriate file automatically.

Before execution, the wrapper records:

- The resolved executable and exact argument array, including empty arguments.
- The **original launch folder**, even if the app later changes directories.
- The Rex session/block IDs and process ID/start time.

A command with no arguments is recorded exactly the same way. The wrapper
preserves exit status, signal behavior, and the application's original `umask`.
It records nothing outside Rex.

For a custom watcher state directory, set the same location in your Rex shells:

```zsh
export REX_RECOVER_STATE_DIR=/absolute/path/to/state-directory
```

Configured commands already running must be launched again once after capture
is enabled. The watcher does not guess missing arguments from process names.

Other shells can explicitly use the same recorder:

```sh
/absolute/path/to/project/bin/rex-recover-run my-server --port 8000
```

## Recover saved conversations

First add the app to your [monitored list](#configure) and enable
[launch capture](#enable-launch-capture-manually). For Codex and OpenCode,
the installer offers the required hook or plugin separately, with a default
answer of no. If you also choose managed shell capture, new Rex shells enable
the integrations you installed when `REX_RECOVER_SESSIONS` is unset or empty.

To select integrations yourself, export `REX_RECOVER_SESSIONS` before launching
the app. Use a single name (`codex`, `opencode`, or `claude`), a comma-separated
list such as `opencode,codex`, or `1` for all drivers. To turn conversation
recovery off, run `export REX_RECOVER_SESSIONS=0`, then exit and relaunch the app.
Explicit values take precedence over installer defaults. Without session opt-in,
command recovery can replay the original prompt as part of the launch arguments.

### Resume a saved Codex conversation (opt-in)

The Codex **0.169.0** shared daemon runs hooks with its own environment, which
can contain a different Rex pane's identity. A local Codex launch without that
daemon can identify its own pane, so Rex can reopen the exact saved conversation
instead of replaying the original prompt.

Choose the Rex Recover `SessionStart` hook in the installer. To approve it in Codex, open
`/hooks`, choose `SessionStart`, select the Rex Recover command, and press
`t` to trust it. Setup requires Node.js or Bun. It uses `hooks.json` and,
if you approve a settings change, `config.toml` in `$CODEX_HOME` (default
`~/.codex`). Choose how to launch Codex:

- **Per launch:** run `codex --no-daemon` in Rex. The rest of your Codex
  launches can keep using the daemon, but you have to remember the flag.
- **Plain `codex`:** let the installer set `daemon_auto_start = false` under
  `[features]` in your Codex `config.toml`. This affects that Codex home even
  outside Rex. Daemon-dependent features, such as remote control and the
  queue, won't be available while the daemon is stopped. An existing daemon
  can still be used: finish or save any work it is hosting, then stop it
  yourself with `codex app-server daemon stop`. Neither script stops it.
  Flagless recovery supports a plain `[features]` table in a config up to
  64 KiB without multiline strings, and skips if it sees a daemon socket. If
  setup cannot verify your config format, decline the settings edit and use
  `--no-daemon`. Rex Recover does not override project settings or add the flag.

Recovery uses the last qualifying `SessionStart` with a saved transcript.
Codex can wait until the first turn to fire the hook, so a conversation you
only viewed may need to be reopened manually. The native Codex executable
must own the recorded launch. A wrapper that stays running as a separate
process, a remote server, and shared-daemon sessions are outside this
integration's scope. The driver has been tested with mocks, not live Codex.

Uninstall leaves your daemon setting alone. If Rex Recover changed it and
you want auto-start back, remove the `daemon_auto_start = false` entry it
reports (or restore its previous value), keeping the rest of `[features]`.
See the [Codex design rationale](design.md#codex-local-hook).

### Resume a saved Claude Code conversation (opt-in)

**Mock-tested only.** In a Rex terminal with launch capture enabled:

```sh
export REX_RECOVER_SESSIONS=claude
claude
```

Claude's live session listing supplies the ID, so setup does not need a hook
or Claude settings changes. The recorded store is `CLAUDE_CONFIG_DIR`, defaulting
to `~/.claude`.
For a custom store, export it before the captured launch:

```sh
export CLAUDE_CONFIG_DIR=/absolute/path/to/claude-config
claude
```

The driver targets the `claude agents --json` interface documented in **2.1.326**.
It needs a unique interactive process and a saved transcript under the recorded
store. It checks for the transcript without reading its conversation text.

Recovery runs the recorded executable with `--resume UUID`, retaining supported
model, permission-mode, agent, additional-directory, and permission/verbosity
options. It reopens the conversation without submitting the original prompt.

Headless, settings-override, worktree, remote, one-off subcommand (including
`agents`), and unknown-option launches are unsupported. If the driver can't
confirm a saved conversation, it skips that launch.

### Resume a saved OpenCode conversation (opt-in)

Conversation recovery requires the Rex Recover plugin package for the
**OpenCode 2.3.0 full-screen terminal UI**, with OpenCode's Bun-hosted plugin
runtime. The terminal part reports which conversation you selected; the server
part checks that it's saved in the database the pane is actually using. Normal
local shared-service and explicit `--standalone` launches are supported.

The installer uses Node.js or Bun to set up the plugin under
`$XDG_CONFIG_HOME/opencode/plugins/rex-recover` (default
`~/.config/opencode/plugins/rex-recover`). For manual setup, copy the
entire [`plugins/opencode-recover`](../plugins/opencode-recover) package to
that path. OpenCode discovers both parts there. Other settings and plugins
stay in place; setup doesn't require restarting the OpenCode service.

Start a new OpenCode terminal UI through launch capture after setup. For
manual opt-in:

```sh
export REX_RECOVER_SESSIONS=opencode
opencode
```

An already-running shared service keeps its own database even if you set a
different `OPENCODE_DB` in a new terminal. Recovery uses the verified server
store and rechecks it before resuming in the original launch mode. It preserves
the recorded `HOME` and XDG roots; the server and terminal roots must agree.
Explicit XDG roots must be absolute and already exist. For a positional project
directory, use `/absolute/project`, `./project`, or `-- project`.

Recovery follows saved selections. Home, plugin pages, unsaved sessions, and
child-agent views clear the selection. If the connection changes, capture
waits for a fresh plugin context rather than assuming the new connection uses
the same database. Relaunch the terminal UI if capture stays paused.

Explicit remote servers, Mini, `run`, in-memory databases, and alternate inline
or environment-based configuration selectors are unsupported. Other versions
and Node-hosted OpenCode are unverified. If a conversation is deleted between
the final check and startup, OpenCode can create a fresh session instead.
See the [OpenCode design rationale](design.md#opencode-pane-and-store).

## Capture limits

Direct absolute-path invocation, `command my-server`, `sudo`, and commands
inside scripts can bypass the shell functions. Existing functions are preserved
with a warning instead of being overwritten. Aliases remain intact, but an
alias pointing to an absolute path or an unwrapped command can bypass capture.

Arguments containing terminal control characters, including newlines and tabs,
cannot be recovered. The original command still runs unchanged, with a warning.
Pipelines, redirections, background job state, and arbitrary per-invocation
environment assignments are not captured. Opt-in session recovery additionally
preserves its recorded home variable and mode. The OpenCode companion also
captures its declared storage paths and explicit configuration exclusions.

Default recovery restores launch commands, not application-internal sessions.
Opt-in session recovery resumes saved conversation data. Neither restores process
memory or unsaved work.

## Recovery and safety

- Only configured, recorded commands found in the terminal's foreground
  process tree are checkpointed. Matching includes process ID **and start time**,
  including when an interpreter or foreground child is involved.
- Default recovery uses the recorded executable, exact arguments, and original
  folder. Opt-in session recovery replaces the prompt/selector with the verified
  saved session ID. Both pass through the recorder again for subsequent restarts.
- Normal completed commands and closed terminals are removed on the next
  successful observation. History and stale launch files are not replayed.
- Recovery uses the **last observed** state. A command starting or finishing
  immediately before a crash can race with the configured scan interval
  (two seconds by default). A conversation change must reach the checkpoint
  before the restart to be recoverable.
- In default mode, all invocations of configured names are eligible—including
  one-off or destructive commands still active when last observed. Opted-in
  session-driver launches must meet the supported interactive checks above.
  Only configure commands you are comfortable rerunning.
- Rex's own persistence restores sessions, windows, splits, and terminal IDs
  (`--restore=true`, the default). Rex Recover does not reconstruct missing
  layouts.
- The server's instance ID distinguishes server restarts from watcher
  reconnections. Existing apps are not duplicated.
- Recovery targets the original session/block on the same host. Unlisted,
  missing, remote, busy, or completed terminals are skipped.
- Restore lines of at least 1,024 bytes, including the terminator, are held
  pending while the terminal reports canonical input mode, which can truncate
  queued input before line editing is ready.
  The guard reads Rex's native `terminal.input_mode` API; it does not change
  terminal modes or add a sleep. A canonical-only shell can leave a long restore
  pending. Missing or failed input-mode checks preserve recovery rather than
  risking truncation. This requires the native API verified on Rex preview.19,
  API revision 14. The check and write are not atomic: a last-moment mode change
  is still possible, and noncanonical mode does not prove prompt readiness.
- Commands are only typed into recognized shells, without an unrelated
  reported ancestor. Recovery waits through Rex's root bootstrap and login
  processes until it sees a recognized shell. It checks the foreground again
  immediately before typing. Shell builtins, unsubmitted input, and last-moment
  process changes can still escape that check.
- Checkpoints are validated and atomically renamed into place. Failed saves
  prevent relaunches; corrupt checkpoints are left untouched. A scan only
  replaces the checkpoint if the same server still responds after local
  process checks, so a disconnect cannot turn a partial scan into completed
  commands. Atomic rename is not an `fsync` guarantee against power loss.
- A kernel lock prevents watchers from sharing a checkpoint. A leftover empty
  lock file does not imply a live lock.
- Recovery attempts are marked consumed before queuing terminal input,
  preferring a missed attempt over a duplicate command. A crash between those
  steps may require manual relaunch. Failed launches are not continually retried.

State lives in `checkpoint.json` and private NUL-delimited files in `launches/`.
The last launch file per pane remains until overwritten, even after completion;
only a matching live process makes it eligible for checkpointing. Arguments
can contain secrets: use a private local state directory and do not commit
state to Git.

## Troubleshooting

- **A command didn't return.** Check that it's on the monitored list and was
  launched in a Rex terminal after capture was enabled. If you edited the list,
  [restart the watcher and refresh capture](#configure).
- **A conversation didn't return.** Check the app's requirements under
  [Recover saved conversations](#recover-saved-conversations) and confirm
  that it saved the conversation before the restart.
- **The watcher isn't monitoring.** On macOS, check `watcher.log` and
  `watcher.error.log` in the log directory shown by the installer. On Linux,
  check `journalctl --user -u rex-recover.service`.

## Tests

```sh
sh tests/run.sh
```

The default suite uses invented executable names and harmless local stand-ins,
never real projects or application services. It covers shared config parsing,
dynamic shell wrappers, exact argument bytes, zero-argument launches, original launch
folders, process identity, completed commands, storage failures, safe targeting,
and duplicate prevention. Menu tests cover incremental additions, numbered
removals, validation, cancellation, backups, symlinks, and conflicting edits.

End-to-end tests run a **separate Rex server and socket** and exercise repeated
graceful shutdowns, `SIGKILL`, watcher/supervisor restarts, and original panes
and launch folders after the fixture apps change directory. Your live server
is left alone. The suite needs zsh, bash, the system `script` utility, a C
compiler (`cc`) for the mock Codex TUI, and Node.js 20 or newer for the hook
and plugin tests. You do not need npm packages or installed Codex, Claude Code,
or OpenCode. Test artifacts are retained at the printed paths.

Installer and service-restart tests use temporary homes and fake service
commands for both macOS and Linux, never real service installation. Socket and
process-ID checks guard the private server before stop or kill operations. CI
runs the full suite on macOS 15, Ubuntu 24.04, and Ubuntu 26.04. Linux service
generation remains fixture-tested, not verified against a real Linux service
manager.

## Adding a session driver

See the [driver interface and tests](../drivers/README.md) and the
[design rationale](design.md) for the current app integrations.

## Rex references

- [Lua API](https://www.superlogical.com/rex/docs/reference/lua.md)
- [Lua events](https://www.superlogical.com/rex/docs/automate/lua-events.md)
- [Server API discovery](https://www.superlogical.com/rex/docs/automate/server-api.md)
