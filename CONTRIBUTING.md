# Contributing to Rex Recover

Thanks for helping make getting back to work easier. Bug reports, clearer docs,
tests, fixes, and new shell integrations are all welcome. Small contributions
are useful; you do not need to tackle a big feature to get involved.

For a larger change, open an issue first so we can agree on the problem and
scope before you invest time in an implementation.

## Reporting a problem

Include your operating system, shell, Rex version, Rex Recover version
(`rex-recover --version`), what you expected, what happened, and the smallest
steps that reproduce it. Sanitized logs can help.
Do not share real recovery state or command arguments containing secrets.

## Making a change

1. Work in a branch and keep the change focused.
2. For a logic change, write a test first and confirm it fails for the intended
   reason. Make the smallest change that passes it, then refactor if needed.
3. Run the full test suite before submitting.
4. Explain the problem, why you chose the approach, and how you tested it.
   Update the docs when user-facing behavior changes.

All changes to `main` must go through a pull request, including maintainer
changes. GitHub Actions runs the full suite on macOS, Ubuntu 24.04, and Ubuntu
26.04 on every branch push. Reviewer approval is not mandatory, so maintainers
can merge their own PRs.

Rex download URLs live in the repository's Actions secrets, not in the workflow.
For fork contributions, a maintainer must review the changes and push them to a
branch in this repository before the full CI suite can run with those secrets.
Do not switch to `pull_request_target` to bypass that protection.

CI pins Rex to `0.1.0-preview.18` for reproducibility. Updating it requires
updating both private download secrets (`REX_LINUX_AMD64_URL` and
`REX_MACOS_ARM64_URL`) and the matching workflow checksums. Secrets keep the
URLs out of source and mask them in logs; they do not make a public download
endpoint access-controlled.

**Any contribution that changes logic must include a corresponding automated
test.** This applies to shell scripts, shell integrations, installer/removal
behavior, and Lua recovery code alike. Bug fixes need a regression test.
Documentation-only and comment-only changes do not need new behavior tests.

Tests should assert observable behavior against independently specified
expectations, not repeat the implementation. Do not skip or weaken existing
tests to make a change pass. If you cannot run a test, say what blocked it;
an unrun test is not a passing test.

### Running the tests

See the [test prerequisites](docs/manual.md#tests) before running the full suite:

```sh
sh tests/run.sh
```

The suite uses invented commands, temporary homes, and fake service-manager
commands. End-to-end tests deliberately stop and kill a **private Rex server**,
with socket and process-ID checks protecting the normal server. Preserve those
guards; never point destructive test operations at a working Rex server or
install real user services as part of a test.

Artifacts are retained at the printed paths to help diagnose failures.
Linux service generation is fixture-tested; distinguish that from testing
against an actual Linux service manager in your contribution notes.

## Bringing another shell

We would love integrations for shells beyond zsh and bash. Default recovery
does not need individual app support: every configured executable follows the
same generic contract.

- Use the existing shared config parser and launch recorder rather than
  inventing another app list, file format, or argument-recording path.
- Preserve the original launch folder and exact argument boundaries, including
  empty arguments and invocations with no arguments.
- Respect existing shell customizations. Capture should not change how the
  user's command runs, its exit status, or its permissions.
- Include tests for the integration's behavior and document how to enable it.

The existing integrations in [`shell/`](shell/) and their tests in
[`tests/`](tests/) are useful starting points. Explain any limitations of your
shell's approach so users know when capture can be bypassed.

## Adding a session driver

Use the [driver interface and AI starter prompt](drivers/README.md). The
[recovery design](docs/design.md) explains which responsibilities stay in the
app driver and which belong to the shared watcher.

Keep the default suite independent of the app being installed. Base mocks on
verified behavior or official documentation, and test observable capture and
resume behavior. Any real-app proof must be opt-in and isolated from user
sessions, configuration, credentials, and billable model requests. Distinguish
mock-only validation from live verification.

## Comments and license

Comments should explain **why** an approach is necessary: the risk it avoids,
the constraint it respects, or the tradeoff behind it. A description of the
next command is less helpful than the reason it cannot safely be simplified.

By submitting a contribution, you agree to make it available under the project's
[MIT license](LICENSE).
