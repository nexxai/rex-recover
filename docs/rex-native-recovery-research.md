# What Rex exposes for recovery

Checked 2026-11-17 against Superlogical’s documentation, beta changelog and
feedback, installed CLI help and embedded skill, and an isolated mock test.
No real sessions or agent CLIs were used.

**Not with the documented Rex API alone.** Rex can identify a pane, observe
its terminal and launch a specified command. It does not document a way to
ask which conversation is selected inside OpenCode, Claude Code or Codex,
retrieve a guaranteed exact launch recipe for an arbitrary program started
inside a shell, or register an app-owned resume token for automatic restore.
Use Rex for pane identity and lifecycle; keep app-specific discovery and
resume only where the app has to supply that information.

## Where the responsibilities split

| Rex surface | What it gives Rex Recover | What it does not give |
| --- | --- | --- |
| **Server restore** | Rex [saves sessions across restarts](https://www.superlogical.com/rex/docs/reference/cli#rex-server-run). Stable pane IDs map saved commands to their panes. | Rex restores fresh shells, so the recorded commands still need to be relaunched. |
| **Process identity** | [`process` and terminal events](https://www.superlogical.com/rex/docs/reference/events#terminal-events) report the live foreground process, its ancestors, and its current directory. | The process API deliberately omits arguments beyond `argv[0]`. A conversation can change without a process change. |
| **Agent integration** | Rex's [agent skill and session-start hook](https://www.superlogical.com/rex/docs/automate/agent-skill#agent-setup) tell the app its Rex session and pane IDs. | The hook does not publish the app's conversation ID to Rex. [Program status](https://www.superlogical.com/rex/docs/build/program-status#keys) reports activity; its IDs name status records. |

## Isolated check on the installed build

Rex server and CLI `0.1.0-preview.19`, API revision `14`:

- `rex.on` received `terminal.process_changed` with Rex session/block IDs
  and the foreground process’s cwd, PID and `argv0`. A mock started with
  `rex run --shell=none --keep-open` received a marker argument, but neither
  `process` nor `session.describe_block` exposed it.
- From the same PID, OSC 7501 reports retained `app=mock-recovery` and
  `id=activity` but dropped the unrecognized `conversation` field, including
  when its value changed from `alpha` to `beta`.
- `rex __internal session-start --agent codex`, given mock hook input with a
  conversation UUID, returned prose naming the inherited Rex IDs (explicitly
  unverified), did not return the UUID and did not change terminal status.
- Restarting the private server brought back the original block ID and cwd in
  a new `zsh`, with no mock process or status record. The private server’s
  socket was confirmed gone after teardown.

Rex Recover therefore uses Rex for pane identity and process checks, records
launch details in the shell, and gets conversation IDs from the apps. See the
[recovery design](design.md) for how those pieces fit together.
