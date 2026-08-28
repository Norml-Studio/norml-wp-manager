#!/usr/bin/env bash
# Import the local connect.html handoff without printing the Application Password.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_FOLDER="${1:-$(pwd)}"
SITE_FOLDER="$(cd "$SITE_FOLDER" 2>/dev/null && pwd)" || { echo "ERROR: site folder not found." >&2; exit 1; }
WPM_DIR="$SITE_FOLDER/.wpm"
CONFIG_FILE="$WPM_DIR/config.json"
HANDOFF_FILE="$WPM_DIR/credential.handoff"
CREDENTIAL_FILE="$WPM_DIR/credential"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" 2>/dev/null && pwd || echo "")"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: $CONFIG_FILE is missing. Run connect.html first." >&2; exit 1; }
[[ -f "$HANDOFF_FILE" ]] || { echo "ERROR: $HANDOFF_FILE is missing. Run connect.html first." >&2; exit 1; }

if command -v git >/dev/null 2>&1 && git -C "$WPM_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$WPM_DIR" check-ignore "$HANDOFF_FILE" >/dev/null 2>&1 || {
    echo "SECURITY ABORT: Git does not ignore credential.handoff. Nothing was imported." >&2
    exit 1
  }
fi

chmod 600 "$HANDOFF_FILE" "$CONFIG_FILE" 2>/dev/null || {
  echo "SECURITY ABORT: could not restrict the handoff and config to the current user." >&2
  exit 1
}

TMP_CREDENTIAL="$WPM_DIR/.credential.tmp.$$"
trap 'rm -f "$TMP_CREDENTIAL"' EXIT
( umask 077; tr -d '[:space:]' < "$HANDOFF_FILE" > "$TMP_CREDENTIAL" )
[[ -s "$TMP_CREDENTIAL" ]] || { echo "ERROR: the handoff is empty." >&2; exit 1; }
mv -f "$TMP_CREDENTIAL" "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE" "$CONFIG_FILE" 2>/dev/null || true

if ! bash "$SCRIPT_DIR/test-connection.sh" --site-folder "$SITE_FOLDER"; then
  rm -f "$CREDENTIAL_FILE"
  echo "Authentication failed. The handoff remains so you can correct the site details and retry." >&2
  exit 1
fi

SITE_NAME="$(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8')).get('site_name', 'WordPress site'))
PY
)"
TODAY="$(date '+%Y-%m-%d')"
TIME="$(date '+%H:%M')"

if [[ -n "$TEMPLATES_DIR" ]]; then
  [[ -f "$SITE_FOLDER/README.md" ]] || sed "s/{SITE_NAME}/$SITE_NAME/g" "$TEMPLATES_DIR/readme-template.md" > "$SITE_FOLDER/README.md"
  [[ -f "$SITE_FOLDER/project-notes.md" ]] || sed "s/{SITE_NAME}/$SITE_NAME/g" "$TEMPLATES_DIR/project-notes-template.md" > "$SITE_FOLDER/project-notes.md"
  [[ -f "$SITE_FOLDER/changelog.md" ]] || sed "s/{SITE_NAME}/$SITE_NAME/g; s/{TODAY}/$TODAY/g; s/{TIME}/$TIME/g" "$TEMPLATES_DIR/changelog-template.md" > "$SITE_FOLDER/changelog.md"
fi

rm -f "$HANDOFF_FILE"
python3 - "$CONFIG_FILE" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f: d = json.load(f)
d['connection_state'] = 'connected'
with open(p, 'w', encoding='utf-8') as f: json.dump(d, f, indent=2); f.write('\n')
PY

bash "$SCRIPT_DIR/scan-site.sh" --site-folder "$SITE_FOLDER" --stage all
echo "Connection imported. The short-lived handoff was deleted."
echo "Capabilities: $SITE_FOLDER/capabilities.md"
