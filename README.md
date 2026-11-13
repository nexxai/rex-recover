# Rex Recover

Get back to work after a Rex server restart without rebuilding your terminal
workflow by hand.

## Why it exists

Rex can bring back your sessions and terminal layout, but the commands you were
running still need to be launched again. If your work spans several projects
and panes, that means remembering which tool belonged where, which folder you
started it in, and which arguments you used.

Rex Recover remembers the commands you choose to monitor and relaunches those
last seen running in their original terminals, from their original folders,
with their original arguments. Commands with no arguments work the same way.

It is useful when restarting a collection of editors, development servers, or
other terminal tools takes you out of your work. You choose what is eligible;
there are no built-in monitored apps.

This relaunches commands, not their in-memory state or unsaved work. It uses
the last observed active commands, not your terminal history. There is a small
observation gap if a command starts or finishes just before Rex stops.

## Why a watcher and a shell integration?

Each solves a different part of the problem:

- **The shell integration remembers how you started a command.** Rex's process
  information does not include its arguments. Capturing them at launch also
  preserves the starting folder, even if the app changes folders later.
- **The background watcher remembers what was still running.** It lives outside
  Rex so it can survive a server shutdown, wait for Rex to return, and restore
  the last observed active commands instead of replaying old ones.

The watcher never starts Rex for you. It waits until you bring Rex back.

## Get started

Requires Rex, macOS or Linux, and zsh or bash for automatic launch capture.
See the [manual](docs/manual.md) for prerequisites and other-shell options.

From this checkout, in a terminal **outside Rex**, run:

```sh
sh install.sh
```

The installer asks which commands to monitor and whether to set up shell
capture and a background user service. It explains its changes and asks before
applying them. No `sudo` is needed; changed files are backed up.

Stop any manually running watcher first. After installation, open new terminals
and launch your chosen commands once so their launch details can be recorded.

To change the monitored commands, rerun the installer. The app list is a plain
text file, normally `~/.config/rex-recover/apps.conf`, with one executable name
per line.

**Only monitor commands you are comfortable running again.** Recorded arguments
may contain secrets. The [manual](docs/manual.md) explains storage, capture
limits, troubleshooting options, and manual setup.

## Uninstall

```sh
~/.local/bin/rex-recover-uninstall
```

Or run `sh uninstall.sh` from this checkout.

This stops the watcher service and removes its managed shell setup and installed
files. Unrelated settings and backups stay in place. Config, recovery state,
and logs are kept unless you separately agree to delete them.

## Contribute

Contributions are welcome, especially integrations for shells beyond zsh and
bash. Every logic change must include a corresponding test. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to get involved.

## License

[MIT](LICENSE).
