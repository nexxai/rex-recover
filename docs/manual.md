# Rex Recover manual

App-agnostic recovery for Rex terminals. A Lua watcher checkpoints configured
commands while they are running and relaunches them in their original panes
after Rex returns.

**There are no built-in monitored apps.** Every configured executable uses the
same launch recording and recovery path, with or without arguments.

## Interactive installation and removal

From this checkout, in a terminal outside Rex, run `sh install.sh`. Stop any
manual watcher first. The installer detects macOS or Linux, asks for executable
names without preselecting any, and separately offers shell and service setup.
Its final confirmation happens before installation files are changed.

The runtime is copied into your user application-data directory, so the
checkout does not need to stay in place:

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
service and removes its shell block and unchanged installer-owned files.
Modified installed files and edited managed blocks require further approval.
Unrelated settings, files, and backups are preserved.

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
must already exist and be valid. To get these commands in an older installation,
rerun `sh install.sh` from the updated checkout and approve service setup.

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

That is the entire format. There are no per-app adapters, modes, modifiers,
or arguments to put in this file. Blank lines and comments are ignored.
An empty file monitors nothing. Duplicates, paths, and extra fields are errors.

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

The watcher must survive a Rex shutdown. Running it inside a Rex terminal is
not reliable. Do not load `watch.lua` through Rex's `init.lua`, which cannot
receive these events and timers.

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
- `--interval` controls fallback scans in seconds. Process-change events also
  trigger scans.
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

### Capture limits

Direct absolute-path invocation, `command my-server`, `sudo`, and commands
inside scripts can bypass the shell functions. Existing functions are preserved
with a warning instead of being overwritten. Aliases remain intact, but an
alias pointing to an absolute path or an unwrapped command can bypass capture.

Arguments containing terminal control characters, including newlines and tabs,
cannot be recovered. The original command still runs unchanged, with a warning.
Pipelines, redirections, background job state, and per-invocation environment
assignments are not captured.

Only launch commands are restored—not process memory or application-internal
session state.

## Recovery and safety

- Only configured, recorded commands found in the terminal's foreground
  process tree are checkpointed. Matching includes process ID **and start time**,
  including when an interpreter or foreground child is involved.
- Recovery uses the recorded executable, arguments, and original folder. It
  passes through the recorder again so subsequent restarts work the same way.
- Normal completed commands and closed terminals are removed on the next
  successful observation. History and stale launch files are not replayed.
- Recovery uses the **last observed** state. A command starting or finishing
  immediately before a crash can race with checkpointing. Events and a
  two-second fallback scan minimize, but do not eliminate, this gap.
- All invocations of configured names are eligible—including one-off or
  destructive commands that were still active when last observed. Only
  configure commands you are comfortable rerunning.
- Rex's own persistence restores sessions, windows, splits, and terminal IDs
  (`--restore=true`, the default). This plugin does not reconstruct missing
  layouts.
- The server's instance ID distinguishes server restarts from watcher
  reconnections. Existing apps are not duplicated.
- Recovery targets the original session/block on the same host. Unlisted,
  missing, remote, busy, or completed terminals are skipped.
- Commands are only typed into recognized shells, without an unrelated
  reported ancestor. Recovery waits through Rex's root bootstrap and login
  processes until the shell is ready; real commands inside a shell remain busy.
  The foreground process is checked again immediately
  before typing. This is not an atomic idle guarantee: shell builtins,
  unsubmitted input, and last-moment process changes remain possible.
- Checkpoints are validated and atomically renamed into place. Failed saves
  prevent relaunches; corrupt checkpoints are left untouched. A scan only
  replaces the checkpoint if the same server still responds after local
  process checks, so a disconnect cannot turn a partial scan into completed
  commands. Atomic rename
  is not an `fsync` guarantee against power loss.
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

## Tests

```sh
sh tests/run.sh
```

Tests use invented executable names and harmless local stand-ins, never real
projects or application services. They cover shared config parsing, dynamic
shell wrappers, exact argument bytes, zero-argument launches, original launch
folders, process identity, completed commands, storage failures, safe targeting,
and duplicate prevention. Menu tests cover incremental additions, numbered
removals, validation, cancellation, backups, symlinks, and conflicting edits.

End-to-end tests run a **separate Rex server and socket** and exercise repeated
graceful shutdowns, `SIGKILL`, watcher/supervisor restarts, and original panes
and launch folders after the fixture apps change directory. Your live server
is left alone. The suite requires zsh and retains test artifacts at the printed
paths.

Installer and service-restart tests use temporary homes and fake service
commands for both macOS and Linux, never real service installation. Socket and
process-ID checks guard the private server before stop or kill operations. CI
runs the full suite on macOS 15, Ubuntu 24.04, and Ubuntu 26.04. Linux service
generation remains fixture-tested, not verified against a real Linux service
manager.

## Rex references

- [Lua API](https://www.superlogical.com/rex/docs/reference/lua.md)
- [Lua events](https://www.superlogical.com/rex/docs/automate/lua-events.md)
- [Server API discovery](https://www.superlogical.com/rex/docs/automate/server-api.md)
