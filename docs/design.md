# Recovery design

For setup and supported launch modes, see the [manual](manual.md).
For the extension interface, see the [driver guide](../drivers/README.md).

## Rex owns the panes; apps own their state

Rex restores the layout and stable pane IDs. It reports which process is running
and its current directory, but intentionally omits full command arguments. The
shell integration records the exact arguments and initial directory at launch,
when both are known. See [what Rex exposes](rex-native-recovery-research.md).

The watcher runs outside the Rex server so it can tell when a new server
instance brings the same panes back. It checks the live process against the
recorded PID and start time, because PIDs can be reused. Bounded scans leave
unchanged checkpoints alone, and a failed scan keeps the previous checkpoint.
Restoration rechecks the destination shell and records an attempt before
queuing input: a missed restart is safer than running the same command twice.

Two panes in the same directory can use the same executable while displaying
different conversations. A driver must identify a saved conversation in the
recorded launch and store. Common code handles pane checks, persistence, and
safe command construction. The drivers supply only the app-specific evidence
and resume arguments, so a new integration doesn't need its own watcher.

## Codex local hook

In [Codex 0.169.0](https://github.com/openai/codex/releases/tag/rust-v0.169.0),
[`SessionStart`](https://developers.openai.com/codex/hooks#sessionstart)
reports the full conversation UUID but not the originating terminal client.
The [hook runtime][codex-env] takes its environment from the hosting process.
With a shared daemon, that can be the environment inherited from pane A even
when pane B starts the conversation. Local mode lets the helper verify that
its immediate host is the recorded foreground TUI.

The trusted hook checks for a saved root transcript and publishes only enough
metadata to confirm the conversation and launch. It stays silent because
[hook stdout][codex-output] can become model context. Recovery validates the
record and uses `codex resume UUID`, preserving the explicit flag if present.
The [daemon startup path][codex-daemon] can attach an existing daemon even
with auto-start disabled, so flagless recovery rechecks the setting and
socket. Neither check eliminates a startup race or project-level overrides.

## OpenCode pane and store

In [OpenCode 2.3.0][opencode-source], the [terminal plugin][opencode-tui]
observes the selected conversation, including a switch within the same
process. It uses [plugin RPC][opencode-rpc] through the existing connection
to verify the ID with the server the terminal actually uses. Selection and
eligibility changes publish a small record tied to the launch. A connection
change invalidates that proof so a result from the old server cannot certify
a new connection.

The shared server can use a different database from the one a client would
infer from its own environment. The server plugin confirms the actual file
by writing a short-lived value to its own storage and checking that exact key
in the candidate database, without reading conversation rows or credentials.
This check relies on [OpenCode's plugin storage][opencode-storage] and
[SQLite key-value schema][opencode-kv]. Restore rechecks the conversation in
that store and keeps the original shared or standalone launch mode.

## Claude Code native lookup

Claude's [live session listing][claude-agents] provides the information
directly. The driver matches an interactive process in the recorded launch,
checks for one nonempty transcript in the recorded store, and checks that the
selected ID hasn't changed before saving it. Recovery uses `--resume UUID`
so the user can continue a saved conversation without resubmitting a prompt.

## Verification

The full suite uses app stand-ins and an isolated Rex server. It exercises
repeated restarts with multiple panes and confirms that saved conversations
follow their original panes and stores. Codex and Claude Code have mock
coverage only. An isolated native OpenCode 2.3.0 smoke test verified selection,
eligibility checks, and that the selection record was unchanged while idle.

[codex-env]: https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/registry.rs#L74-L100
[codex-output]: https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/events/session_start.rs#L218-L249
[codex-daemon]: https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/tui/src/startup_orchestration.rs#L358-L375
[opencode-source]: https://github.com/anomalyco/opencode/tree/a6b15d33daf6ab7d35569f6d711fdb630b9f04e7
[opencode-tui]: https://opencode.ai/docs/build/plugins/cli
[opencode-rpc]: https://opencode.ai/docs/build/plugins/rpc
[opencode-storage]: https://github.com/anomalyco/opencode/blob/a6b15d33daf6ab7d35569f6d711fdb630b9f04e7/packages/core/src/plugin/host.ts#L663-L671
[opencode-kv]: https://github.com/anomalyco/opencode/blob/a6b15d33daf6ab7d35569f6d711fdb630b9f04e7/packages/core/src/kv/sql.ts
[claude-agents]: https://code.claude.com/docs/en/agent-view#list-sessions-as-json
