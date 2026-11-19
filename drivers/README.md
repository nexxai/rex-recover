# Session drivers

Each app's implementation lives in its own provider-named Lua file.

Add one lowercase provider-named `.lua` file, such as `example-my-agent.lua`.
The loader discovers sibling files automatically when the watcher starts.
Files named `registry.lua` and underscore-prefixed shared helpers are reserved.

The installer automatically includes driver Lua files and records their
ownership; uninstall removes only manifest-owned files, not arbitrary additions.
For an installed setup, reinstall to copy a new driver and restart the watcher
before launching its app. Checkout users only need to restart the watcher.
Duplicate executable names and unsafe configuration are rejected.

Use a trustworthy native ID lookup when the app provides one. Add a companion
only when the app must publish selection changes itself. See the
[design rationale](../docs/design.md) for the current integrations.

## Interface

### What `capture(context)` returns

`capture` tells Rex Recover what to run **later**, after a Rex server restart.
It does not run the resume command itself. There are three possible returns:

| Return | What Rex Recover does |
| --- | --- |
| `{ argv = { "/usr/local/bin/my-agent", "resume", "session-123" } }` | Saves this command to reopen the confirmed conversation. |
| `nil` | Saves no command for this launch. A successful scan clears any previous capture for the pane. |
| `nil, "session lookup timed out"` | Keeps this pane's previous checkpoint and reports the error. Other panes are still saved and restored. Use this when the lookup failed, rather than when it found no match. |

In this example, `find_saved_session` stands for the app-specific lookup you
implement. It returns a verified session ID, `nil` for no match, or `nil, error`
if the lookup failed.

```lua
local M = {
  executable = "my-agent",
  home_env = "MY_AGENT_HOME",
  default_home = ".my-agent",
}

function M.capture(context)
  local session_id, err = find_saved_session(context)
  if err then return nil, err end       -- Lookup failed: keep the checkpoint.
  if not session_id then return nil end -- No saved session for this launch.

  return {
    argv = {
      context.launch.argv[1], -- Executable, e.g. "/usr/local/bin/my-agent".
      "resume",               -- First argument: this app's resume subcommand.
      session_id,             -- Second argument: the full ID, e.g. "session-123".
    },
  }
end

return M
```

`argv` is required on success. Put the executable first, then one string per
argument. Return an array, not a shell command string; Rex Recover handles
quoting. Leave out the original prompt so recovery won't submit it again.

Optional fields in the returned table:

- `cwd`: an absolute directory, if the app needs to resume somewhere other
  than the original launch directory.
- `env`: a table of additional variables declared in the driver's
  `environment` list. Set a value to an absolute path, or `false` to unset
  it in the recovered command. Rex Recover adds the recorded home and
  recovery opt-in itself.
- `proof`: evidence for `validate` to recheck before restart recovery. Use a
  nonempty string up to 8 KiB with no control characters. It's saved in the
  checkpoint and never passed to the shell.

### Driver configuration and context

Configuration belongs in the driver itself:

- `executable`: the bare command name used in `apps.conf`.
- `home_env`: the one storage-context environment variable to preserve.
- `default_home`: its default path relative to the caller's `HOME`, without
  parent-directory traversal. Use `HOME` and `.` for an app with no separate
  storage root.
- `capture(context)`: the only required behavior entry point.
- `environment` (optional): additional environment names permitted in a
  checkpoint. Values are absolute paths, or `false` to explicitly unset a
  variable in the recovered child. `PATH` and recovery-internal names are
  reserved. Capture only the context the app needs, never its whole environment.
- `validate(record, api)` (optional): recheck resumability before recovery is
  consumed or typed. Return `true` to allow, `nil`/`false` to skip, or
  `nil, message` to preserve the durable checkpoint on failure.

Driver definitions are loaded to read their configuration, including drivers for
apps that are not installed. Keep module initialization side-effect-free and
dependency-free; do app discovery only inside `capture`.

Rex's existing Lua runtime supplies descriptor metadata to the launch recorder.
The recorder resolves the home from **its caller's environment**, not the
watcher's or server's environment. No separate Lua installation is required.

- `api` provides Rex `call`, `exec`, `json`, and `log`.
- `launch` contains the immutable original `argv`, launch `cwd`, recorded
  `pid`/`started_at`, Rex `session_id`/`block_id`, driver ID, and canonical `home`.
  Driver launches also expose `selection_path`, a launch-qualified path for an
  optional companion's selection file. Native-discovery drivers do not need it.
- `processes` is the pane's observed foreground process and ancestors, ordered
  outward. The launch identity has already been checked. Any protocol-specific
  owner must still be inside that launch's subtree, not an unrelated ancestor.

Shared code applies the recorded storage environment, recovery opt-in, original
cwd by default, process checks, validation, quoting, checkpointing, and re-capture.
Drivers should not edit user config, bypass trust, start model requests, save
credentials/conversation text, or implement their own recovery checkpoints.
An optional companion may publish a small selection file at `selection_path`;
that artifact is input to capture, not another recovery manager.

Bind companion metadata to the launch that produced it. Publish selection
changes rather than idle updates, so a quiet pane doesn't keep writing files.

Use the public launch/discovery/checkpoint-to-resume boundaries for tests. Mock
external app interfaces from verified behavior or first-party documentation,
then assert actual recovery side effects against independent expected values.

## AI starter prompt

Replace the bracketed placeholders (use lowercase filename-safe provider/app
slugs), omit the optional docs URL if unknown, and paste this into your AI coding
assistant from the repository root:

```text
Add a session-recovery driver for [APP_NAME]: command [EXECUTABLE], provider
[PROVIDER]. Optional official docs: [DOCS_URL_OR_OMIT].

Read applicable AGENTS.md, drivers/README.md, drivers/registry.lua, existing
drivers and test patterns; preserve user edits. Agree public test seams first
if required.

Research official source/docs for an identified app version: supported
live-session discovery, canonical durable IDs, storage context and exact resume
syntax. Cite evidence, separating documentation, source findings and observations.
Respect closed-source boundaries; never fabricate internals, fixtures, test runs
or live verification. If ownership/resume is unprovable, report the blocker.

Implement one lowercase drivers/[PROVIDER]-[APP_SLUG].lua descriptor exporting
executable, home_env, default_home and capture(context), using context.api,
context.launch and context.processes. Sibling *.lua files load automatically
except registry.lua and underscore-prefixed helpers. Module loading must be
side-effect/dependency-free even without the app installed.

Identify the currently selected resumable session within the verified recorded
launch subtree/current pane, never newest history or cwd alone. Reject missing,
ambiguous, child-agent, foreign, ephemeral and stale IDs; recheck ownership/selection
against races. Return { argv = {...}, cwd = optional_path } on confirmation, nil
for unsupported/no match (clears previous capture), or nil, error_message for
discovery failure (preserves durable checkpoint).

Preserve launch cwd, recorded storage context and verified allowed option
spelling/scopes. Remove initial prompts, old selectors and fork behavior so
recovery cannot repeat a request. Reject unsupported arguments; leave common
validation, quoting, persistence and re-capture to core.

Use TDD: write a meaningful failing test and confirm intended RED before
implementing. Base mocks on actual behavior or first-party docs; independently
specify observable checkpoint and resumed argv/cwd/environment expectations.
Cover wrong pane, stale/missing/ambiguous IDs, API errors, changed selection and
repeated restart/re-capture without prompt replay.

Do not edit other drivers, core, user configuration or install hooks, or bypass
trust, unless necessary and explicitly approved. Optional live proof, only if
installed, must use disposable isolated storage/projects without user data,
billing, auth secrets or real projects. The default full suite must work without
this app. Run the full suite before claiming completion; report commands,
evidence and honest gaps.
```
