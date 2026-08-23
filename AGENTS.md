## Build

Use the Xcode already on disk. Do not change the global developer directory.

```
make test        # swift test via DEVELOPER_DIR
make xcode-test  # xcodebuild -scheme ScheduleBar-Package
make run         # package .build/ScheduleBar.app and open it
make plugin      # copy schedulebar-mcp into Plugins/schedulebar/bin
```

Default `DEVELOPER_DIR` is `/Applications/Xcode-beta.app/Contents/Developer`.

## Chat / Work capture

Ordinary Chat/Work does **not** capture automatically. There is no clipboard, browser, or Accessibility listener.

To record from Chat/Work, the user must explicitly say “record as task” / “记录为任务” (or use Quick Add). The local handoff is:

```
schedulebar-mcp record --text "record as task File the weekly report" --key <idempotency-key> --cwd <dir>
```

or the MCP tool `record_as_task`. Success, duplicate, and failure receipts are explicit; failure reason is `未记录`. Codex lifecycle hooks remain the automatic path.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues for `LeoAKALiu/schedulebar`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five canonical triage labels defined for this repository. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository using root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.
