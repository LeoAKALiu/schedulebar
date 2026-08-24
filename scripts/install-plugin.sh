#!/bin/sh
set -eu

SCHEDULEBAR_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SCHEDULEBAR_USER_HOME=$(CDPATH= cd -- && pwd -P)
SCHEDULEBAR_CODEX_DIR="$SCHEDULEBAR_USER_HOME/.codex"
SCHEDULEBAR_BACKUP_ROOT="$SCHEDULEBAR_USER_HOME/Library/Application Support/ScheduleBar/install-backups"
SCHEDULEBAR_BACKUP_DIR="$SCHEDULEBAR_BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
SCHEDULEBAR_EXPECTED_MARKETPLACE_ROOT="$SCHEDULEBAR_REPO_ROOT/Plugins"

case "$SCHEDULEBAR_USER_HOME" in
    ""|/) echo "Could not resolve a safe user home directory." >&2; exit 1 ;;
esac

mkdir -p "$SCHEDULEBAR_BACKUP_DIR"
chmod 700 "$SCHEDULEBAR_BACKUP_ROOT" "$SCHEDULEBAR_BACKUP_DIR"
for SCHEDULEBAR_CONFIG_NAME in config.toml hooks.json; do
    if [ -f "$SCHEDULEBAR_CODEX_DIR/$SCHEDULEBAR_CONFIG_NAME" ]; then
        cp -p "$SCHEDULEBAR_CODEX_DIR/$SCHEDULEBAR_CONFIG_NAME" "$SCHEDULEBAR_BACKUP_DIR/$SCHEDULEBAR_CONFIG_NAME"
    fi
done
codex plugin marketplace list > "$SCHEDULEBAR_BACKUP_DIR/marketplaces-before.txt"
codex plugin list --json > "$SCHEDULEBAR_BACKUP_DIR/plugins-before.json"

SCHEDULEBAR_REGISTERED_ROOT=$(codex plugin marketplace list | sed -n 's/^schedulebar-local[[:space:]][[:space:]]*//p')
if [ -n "$SCHEDULEBAR_REGISTERED_ROOT" ] && [ "$SCHEDULEBAR_REGISTERED_ROOT" != "$SCHEDULEBAR_EXPECTED_MARKETPLACE_ROOT" ]; then
    echo "Refusing to reuse marketplace schedulebar-local from a different path: $SCHEDULEBAR_REGISTERED_ROOT" >&2
    echo "No plugin registry change was made. Backup: $SCHEDULEBAR_BACKUP_DIR" >&2
    exit 1
fi
if [ -z "$SCHEDULEBAR_REGISTERED_ROOT" ]; then
    codex plugin marketplace add "$SCHEDULEBAR_REPO_ROOT/Plugins"
fi
codex plugin add schedulebar@schedulebar-local
codex plugin marketplace list > "$SCHEDULEBAR_BACKUP_DIR/marketplaces-after.txt"
codex plugin list --json > "$SCHEDULEBAR_BACKUP_DIR/plugins-after.json"
SCHEDULEBAR_INSTALLED_ROOT=$(sed -n 's/^schedulebar-local[[:space:]][[:space:]]*//p' "$SCHEDULEBAR_BACKUP_DIR/marketplaces-after.txt")
if [ "$SCHEDULEBAR_INSTALLED_ROOT" != "$SCHEDULEBAR_EXPECTED_MARKETPLACE_ROOT" ] || \
   ! grep -Fq 'schedulebar@schedulebar-local' "$SCHEDULEBAR_BACKUP_DIR/plugins-after.json"; then
    echo "ScheduleBar plugin verification failed; inspect $SCHEDULEBAR_BACKUP_DIR before rollback." >&2
    exit 1
fi

echo "Installed schedulebar@schedulebar-local."
echo "Pre/post state and any existing config files were saved to: $SCHEDULEBAR_BACKUP_DIR"
echo "Restart Codex, then complete the Desktop acceptance checklist in docs/INSTALL.md."
