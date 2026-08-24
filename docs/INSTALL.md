# Personal installation and rollback

ScheduleBar is a personal, local-only app. Building does not change Codex or
install anything under the current user account.

## Build and verify

```sh
make test
make xcode-test
make verify-app
```

The generated app is `.build/ScheduleBar.app`. It contains the matching
ScheduleBar Codex plugin at `Contents/Plugins/schedulebar` and is ad-hoc signed
by default for local use. Set `SCHEDULEBAR_CODESIGN_IDENTITY` before `make app`
to use a specific local signing identity.

## Codex plugin install

Review `Plugins/schedulebar/` and run the read-only preview first:

```sh
make plugin-preview
```

The following command is the explicit user-level change; it is never run by
build or test targets. Before changing the registry it copies any existing
`~/.codex/config.toml` and `~/.codex/hooks.json`, plus pre/post marketplace and
plugin listings, to `~/Library/Application Support/ScheduleBar/install-backups/`:

```sh
make plugin-install
codex plugin list --json
```

Restart Codex after installation so the bundled lifecycle hooks and MCP server
are reloaded.

## Plugin rollback

```sh
make plugin-uninstall
codex plugin list --json
```

Rollback removes only the `schedulebar@schedulebar-local` installation and its
local marketplace registration. It does not rewrite unrelated Codex hooks or
configuration. The timestamped install snapshot remains available for manual
comparison; it is deliberately not restored over newer user configuration.

## Desktop acceptance boundary

Before closing T16, verify in the real Codex desktop process: successful
capture, duplicate capture, write failure reported as `未记录`, menu refresh,
candidate edit/confirm/reject, and a redacted diagnostics export. Automated
tests and an isolated binary smoke run do not substitute for that human
acceptance.
