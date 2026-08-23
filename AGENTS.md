## Build

Use the Xcode already on disk. Do not change the global developer directory.

```
make test        # swift test via DEVELOPER_DIR
make xcode-test  # xcodebuild -scheme ScheduleBar-Package
make run         # package .build/ScheduleBar.app and open it
```

Default `DEVELOPER_DIR` is `/Applications/Xcode-beta.app/Contents/Developer`.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues for `LeoAKALiu/schedulebar`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five canonical triage labels defined for this repository. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository using root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.
