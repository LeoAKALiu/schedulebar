#!/bin/sh
set -eu

SCHEDULEBAR_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

echo "ScheduleBar plugin install preview (read-only)"
echo "Marketplace source: $SCHEDULEBAR_REPO_ROOT/Plugins"
echo "Plugin: schedulebar@schedulebar-local"
echo "Current marketplaces:"
codex plugin marketplace list
echo "Current installed plugins:"
codex plugin list --json
echo "No user configuration was changed. Run 'make plugin-install' only after reviewing this output."
