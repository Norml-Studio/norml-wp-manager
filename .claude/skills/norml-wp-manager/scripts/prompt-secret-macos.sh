#!/usr/bin/env bash
# norml-wp-manager — pop a native macOS dialog to capture the WordPress
# Application Password, then store it in Keychain (off-argv).
#
# Designed to be called from Claude (via the Bash tool) or from
# setup-macos.sh. The user never has to type the secret into a terminal
# prompt — a normal macOS dialog window opens in front of them.
#
# Usage:
#   bash prompt-secret-macos.sh <site-name> <wp-username>
#
# Exit codes:
#   0  stored OK
#   1  user cancelled the dialog or pasted an empty string
#   2  bad arguments

set -euo pipefail
set +x   # xtrace guard — never render the secret in a trace

APP_SLUG="norml-wp-manager"   # brand-pinned. Service name = ${APP_SLUG}-{site}.

SITE_NAME="${1:-}"
WP_USER="${2:-}"

if [[ -z "$SITE_NAME" || -z "$WP_USER" ]]; then
  echo "ERROR: usage: $0 <site-name> <wp-username>" >&2
  exit 2
fi

KEYCHAIN_SERVICE="${APP_SLUG}-${SITE_NAME}"

# Pop the dialog. `with hidden answer` masks input. We use a sentinel
# string for the cancel case so we can distinguish it from a real
# empty input. The placeholder is deliberately FAKE (all X's) so a
# confused user can't mistake it for a value to paste.
DIALOG_OUT=$(osascript <<APPLESCRIPT 2>/dev/null || true
on run
  try
    set theResult to display dialog "Paste the WordPress Application Password.

WordPress shows it as 6 groups of 4 characters, e.g. XXXX XXXX XXXX XXXX XXXX XXXX. Spaces are OK — they will be stripped." ¬
      default answer "" ¬
      with hidden answer ¬
      with title "${APP_SLUG} — $SITE_NAME" ¬
      buttons {"Cancel", "Store"} ¬
      default button "Store"
    return text returned of theResult
  on error
    return "__WPMGR_CANCELLED__"
  end try
end run
APPLESCRIPT
)

if [[ -z "$DIALOG_OUT" || "$DIALOG_OUT" == "__WPMGR_CANCELLED__" ]]; then
  echo "Cancelled." >&2
  exit 1
fi

# Strip whitespace. WordPress accepts both spaced and unspaced.
WP_PASS=$(printf '%s' "$DIALOG_OUT" | tr -d '[:space:]')
DIALOG_OUT=""

if [[ -z "$WP_PASS" ]]; then
  echo "Empty Application Password. Aborting." >&2
  exit 1
fi

# Replace any prior entry under the same service so re-runs are idempotent.
security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true

# Store OFF-ARGV. `security ... -w` with -w as the LAST option (no value)
# reads the password from stdin instead of argv — so the secret never lands
# in `ps` / `/proc/<pid>/cmdline`. `security` prompts twice (enter + retype),
# so we feed the value twice over the pipe. `printf` is a bash builtin, so
# "$WP_PASS" is never an argv of any external process.
printf '%s\n%s\n' "$WP_PASS" "$WP_PASS" | security add-generic-password \
  -s "$KEYCHAIN_SERVICE" \
  -a "$WP_USER" \
  -l "${APP_SLUG}: $SITE_NAME" \
  -D "${APP_SLUG} application password" \
  -U \
  -w >/dev/null

# Clear the local copy
WP_PASS=""

echo "Stored Application Password under Keychain service '$KEYCHAIN_SERVICE'."
