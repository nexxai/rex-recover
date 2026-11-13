# Rex Recover

Restore configured apps in their original Rex terminals after the server
returns. Every app uses the same capture path: original launch folder and exact
arguments, including none. No monitored apps are built in.

## Install

From a regular terminal **outside Rex**, run:

```sh
sh install.sh
```

The installer detects macOS or Linux and walks you through:

- Choosing app names, with real-life examples but no preselected apps.
- Copying the runtime into your user application-data directory.
- Adding a managed startup block for zsh or bash.
- Optionally installing a launchd or systemd **user** service.

It shows the locations and asks before making changes. Changed files are backed
up, existing dotfile symlinks are preserved, and rerunning it updates the setup
without duplicating shell entries. No `sudo` or checkout relocation is needed.
If a manual watcher is running, stop it with Ctrl-C first.

Open new terminals afterward and relaunch newly monitored apps once so their
launch arguments can be captured. The installer never starts or stops Rex.

## Uninstall

```sh
~/.local/bin/rex-recover-uninstall
```

Or run `sh uninstall.sh` from this checkout.

The uninstaller stops the installed watcher service, removes the managed shell
block, and removes installer-owned files. Unrelated settings and files are left
alone. Modified installed files and edited managed blocks require confirmation.
App config, recovery state, and logs are **kept by default**; deleting them is a
separate choice. Backups are retained.

## Configuration

Edit `~/.config/rex-recover/apps.conf` (or the selected XDG/custom location).
It contains one executable name per line, with optional `#` comments.

Rerun the installer to update the app list, or restart the watcher and re-source
the shell integration after editing it manually.

macOS uses launchd when a GUI user domain is available. Linux uses systemd when
the user manager is available; otherwise the installer skips service setup.
Automatic capture supports zsh and bash. Other shells can use the explicit
recorder. See the [manual](docs/manual.md) for advanced paths, manual setup,
service commands, and capture limits.

## Tests

```sh
sh tests/run.sh
```

Installer tests use temporary homes and fake service commands for both
platforms—never real service installation. Recovery tests use invented apps
and a separate Rex server, with socket/PID checks before stopping or killing it.
Linux service generation is fixture-tested; it has not been exercised on an
actual Linux service manager here.
