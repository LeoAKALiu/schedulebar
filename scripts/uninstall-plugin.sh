#!/bin/sh
set -eu

SCHEDULEBAR_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SCHEDULEBAR_EXPECTED_MARKETPLACE_ROOT="$SCHEDULEBAR_REPO_ROOT/Plugins"
SCHEDULEBAR_REGISTERED_ROOT=$(codex plugin marketplace list | sed -n 's/^schedulebar-local[[:space:]][[:space:]]*//p')

if [ -n "$SCHEDULEBAR_REGISTERED_ROOT" ] && [ "$SCHEDULEBAR_REGISTERED_ROOT" != "$SCHEDULEBAR_EXPECTED_MARKETPLACE_ROOT" ]; then
    echo "Refusing to remove marketplace schedulebar-local owned by a different path: $SCHEDULEBAR_REGISTERED_ROOT" >&2
    exit 1
fi

SCHEDULEBAR_PLUGIN_PRESENT=false
if codex plugin list --json | grep -Fq 'schedulebar@schedulebar-local'; then
    SCHEDULEBAR_PLUGIN_PRESENT=true
    codex plugin remove schedulebar@schedulebar-local
fi
if [ -n "$SCHEDULEBAR_REGISTERED_ROOT" ]; then
    codex plugin marketplace remove schedulebar-local
fi

if [ "$SCHEDULEBAR_PLUGIN_PRESENT" = true ] || [ -n "$SCHEDULEBAR_REGISTERED_ROOT" ]; then
    echo "Removed the ScheduleBar plugin and its owned local marketplace registration."
else
    echo "ScheduleBar was not installed; no registry change was needed."
fi
echo "No unrelated Codex configuration was restored or overwritten."
