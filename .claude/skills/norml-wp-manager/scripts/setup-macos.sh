#!/usr/bin/env bash
# norml-wp-manager — first-time setup on macOS Console (Claude Code).
#
# Collects WordPress site details + a chosen site folder, walks the user
# through generating an Application Password, stores it in macOS Keychain
# (OFF-ARGV, via a native dialog), tests the REST API, and runs the initial
# scan. All per-site state lives in ONE site folder:
#   {site_folder}/  → README.md + project-notes.md + changelog.md + .wpm/
# NOTHING is written to ~/.config — ever. The config JSON holds no secrets.

set -euo pipefail
set +x   # xtrace guard — the credential must never render in a trace

APP_SLUG="norml-wp-manager"   # brand-pinned. Keychain service = ${APP_SLUG}-{site}.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[33m  %s\033[0m\n' "$*"; }
err()   { printf '\033[31m  %s\033[0m\n' "$*" >&2; }

ask() {
  local prompt="$1" default="${2:-}" val
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " val
    printf '%s' "${val:-$default}"
  else
    read -rp "$prompt: " val
    printf '%s' "$val"
  fi
}

# ---- Guard: refuse dangerous / cloud-synced site-folder locations ----------
guard_site_folder() {
  local f="$1"
  case "$f" in
    "$HOME"|"/"|"/tmp"|"/usr"|"/etc"|"$HOME/.config"|"$HOME/.claude")
      err "Refusing to use '$f' as a site folder (system / home / config location)."
      return 1 ;;
  esac
  local skill_root
  skill_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  case "$f/" in
    "$skill_root"/*)
      err "Refusing to place the site folder inside the skill directory ($skill_root)."
      err "Skill updates would erase it. Pick a folder elsewhere."
      return 1 ;;
  esac
  case "$f" in
    */Dropbox/*|*/Library/CloudStorage/*|*/OneDrive/*|*"/Google Drive/"*|*/iCloud*|*"/Mobile Documents/"*)
      warn "This folder is inside a cloud-sync tree."
      warn "Your password is in the OS Keychain (not synced), but the docs folder will be."
      warn "That's fine — just know the folder's contents may upload to a third-party cloud."
      local yn
      yn="$(ask "Use this cloud-synced folder anyway? (Y/n)" "Y")"
      [[ "$yn" =~ ^[Nn]$ ]] && { err "Aborted — pick a non-synced folder."; return 1; }
      ;;
  esac
  return 0
}

# ---- Egress probe — separates real Console from a sandbox ------------------
# A neutral host (NOT anthropic.com — that's allowlisted in sandboxes).
# 200/30x → network open (this is a real Console). Blocked/000/6/7/35/56 →
# default-deny allowlist → this is the desktop sandbox → point at setup-portable.sh.
egress_open() {
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 8 https://example.com 2>/dev/null)" || true
  code="${code:-000}"
  [[ "$code" =~ ^(200|30[0-9])$ ]]
}

# ---- Banner ----------------------------------------------------------------

bold "${APP_SLUG} setup — macOS Console"
echo
echo "This will:"
info "1. Ask where to keep this site's folder"
info "2. Collect your WordPress site URL and admin/editor username"
info "3. Pause while you generate an Application Password in wp-admin"
info "4. Store that password in macOS Keychain (via a dialog — never in a file)"
info "5. Test the REST API connection"
info "6. Scan your WordPress install into {site_folder}/.wpm/docs/"
echo
read -rp "Press Enter to continue, Ctrl-C to cancel..."

# Environment check — replaces the old "is ~/.config writable?" probe.
# If the network is behind a default-deny allowlist, this is the desktop
# sandbox, where there is no OS Keychain → use the portable/floor path.
if ! egress_open; then
  err "Outbound network looks restricted (default-deny egress allowlist)."
  err "This looks like the Claude desktop app / Cowork sandbox, which has no"
  err "macOS Keychain. Use the portable-mode setup instead:"
  err "  bash $SCRIPT_DIR/setup-portable.sh [site-folder]"
  exit 1
fi
if ! command -v security >/dev/null 2>&1; then
  err "macOS 'security' tool not found — cannot use the Keychain here."
  err "Use the portable-mode setup instead: bash $SCRIPT_DIR/setup-portable.sh"
  exit 1
fi

# ---- Site info -------------------------------------------------------------

echo
bold "Site info"
SITE_NAME="$(ask "Short site name (kebab-case, e.g. acme-marketing)")"
if [[ ! "$SITE_NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  err "Site name must be lowercase letters/numbers separated by single dashes."
  exit 1
fi

PROD_URL="$(ask "Production URL (e.g. https://acme.com)")"
PROD_URL="${PROD_URL%/}"
if [[ "$PROD_URL" == "http://localhost"* || "$PROD_URL" == "http://127.0.0.1"* ]]; then
  warn "Using plaintext http:// for localhost dev — allowed, but never for a live site."
elif [[ "$PROD_URL" != https://* ]]; then
  err "Production URL must start with https:// (got '$PROD_URL')."
  exit 1
fi

WP_USER="$(ask "WordPress admin/editor username (the login slug)")"
if [[ -z "$WP_USER" ]]; then
  err "WordPress username is required."
  exit 1
fi

# ---- Site folder (with guard) ----------------------------------------------

echo
bold "Site folder"
echo "All state for this site lives in one folder you name. Pick something"
echo "memorable — e.g. ~/Sites/$SITE_NAME. Created if it doesn't exist."
DEFAULT_FOLDER="$HOME/Sites/$SITE_NAME"
SITE_FOLDER_IN="$(ask "Site folder path" "$DEFAULT_FOLDER")"
SITE_FOLDER_IN="${SITE_FOLDER_IN/#\~/$HOME}"
case "$SITE_FOLDER_IN" in
  /*) SITE_FOLDER="$SITE_FOLDER_IN" ;;
  *)  SITE_FOLDER="$(pwd)/$SITE_FOLDER_IN" ;;
esac
SITE_FOLDER="${SITE_FOLDER%/}"

if ! guard_site_folder "$SITE_FOLDER"; then
  exit 1
fi

if [[ ! -d "$SITE_FOLDER" ]]; then
  mkdir -p "$SITE_FOLDER" || { err "Could not create $SITE_FOLDER"; exit 1; }
  info "Created $SITE_FOLDER"
else
  info "Using existing $SITE_FOLDER"
fi

WPM_DIR="$SITE_FOLDER/.wpm"
DOCS_DIR="$WPM_DIR/docs"
CONFIG_FILE="$WPM_DIR/config.json"
mkdir -p "$DOCS_DIR"

KEYCHAIN_SERVICE="${APP_SLUG}-${SITE_NAME}"

# ---- Scaffold curated docs at the site-folder TOP LEVEL --------------------
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" 2>/dev/null && pwd || echo "")"
TODAY=$(date '+%Y-%m-%d')
TIME=$(date '+%H:%M')

if [[ ! -f "$SITE_FOLDER/README.md" ]]; then
  if [[ -n "$TEMPLATES_DIR" && -f "$TEMPLATES_DIR/README.template.md" ]]; then
    sed "s/{SITE_NAME}/$SITE_NAME/g" "$TEMPLATES_DIR/README.template.md" > "$SITE_FOLDER/README.md"
  else
    cat > "$SITE_FOLDER/README.md" <<EOF
# $SITE_NAME — WordPress management folder

This folder is everything ${APP_SLUG} knows about this site.

- Move it anywhere — it keeps working (paths are relative).
- Delete it to make the skill forget this site (then revoke the AP in wp-admin).
- Don't hand-edit \`.wpm/\` — that's the tool's machinery.
EOF
  fi
  info "Scaffolded $SITE_FOLDER/README.md"
fi

# project-notes.md — written from the template (sed to a new file, NOT sed -i '').
if [[ ! -f "$SITE_FOLDER/project-notes.md" && -n "$TEMPLATES_DIR" && -f "$TEMPLATES_DIR/project-notes.template.md" ]]; then
  sed "s/{SITE_NAME}/$SITE_NAME/g" "$TEMPLATES_DIR/project-notes.template.md" > "$SITE_FOLDER/project-notes.md"
  info "Scaffolded $SITE_FOLDER/project-notes.md"
fi

# changelog.md — written from the template (sed to a new file).
if [[ ! -f "$SITE_FOLDER/changelog.md" && -n "$TEMPLATES_DIR" && -f "$TEMPLATES_DIR/changelog.template.md" ]]; then
  sed "s/{SITE_NAME}/$SITE_NAME/g; s/{TODAY}/$TODAY/g; s/{TIME}/$TIME/g" "$TEMPLATES_DIR/changelog.template.md" > "$SITE_FOLDER/changelog.md"
  info "Scaffolded $SITE_FOLDER/changelog.md"
fi

# ---- Application Password generation ---------------------------------------

echo
bold "WordPress Application Password"
echo
echo "Generate an Application Password using the one-click authorize link"
echo "(log in to WordPress if asked):"
echo
echo "  ${PROD_URL}/wp-admin/authorize-application.php?app_name=${KEYCHAIN_SERVICE}"
echo
echo "  → Approve 'Authorize ${KEYCHAIN_SERVICE}?'"
echo "  → Copy the 24-character password (shown ONCE)."
echo
echo "  (Fallback: ${PROD_URL}/wp-admin/profile.php → Application Passwords.)"
echo
read -rp "Press Enter once you have the Application Password copied..."

# ---- Store the password in Keychain (via macOS dialog, OFF-ARGV) -----------
# prompt-secret-macos.sh pops a native dialog and writes to Keychain reading
# the password from stdin (security ... -w with -w last) — never on argv.
echo
bold "Opening a dialog to capture the Application Password..."
echo
if ! bash "$SCRIPT_DIR/prompt-secret-macos.sh" "$SITE_NAME" "$WP_USER"; then
  err "Did not store the Application Password. Re-run this script."
  exit 1
fi

# ---- Write config (schema 4, no secret) ------------------------------------
NOW_UTC="$(date -u +%FT%TZ)"
cat > "$CONFIG_FILE" <<EOF
{
  "schema_version": 4,
  "site_name": "$SITE_NAME",
  "production_url": "$PROD_URL",
  "wp_user": "$WP_USER",
  "env": "console-macos",
  "secret_store": {
    "kind": "macos-keychain",
    "ref": "$KEYCHAIN_SERVICE"
  },
  "created_at": "$NOW_UTC",
  "last_scan_at": "$NOW_UTC"
}
EOF
chmod 600 "$CONFIG_FILE"
echo
info "Wrote $CONFIG_FILE"

# ---- Test connection (restcall form: credential off-argv) ------------------
echo
bold "Testing REST API connection..."

get_password() { security find-generic-password -s "$KEYCHAIN_SERVICE" -w; }

TEST_TMP="$(mktemp "${TMPDIR:-/tmp}/wpm-test.XXXXXX")"
HTTP_CODE=$(curl -sS -o "$TEST_TMP" -w "%{http_code}" --proto '=https' --max-redirs 0 \
  --config <(printf 'user = "%s:%s"\n' "$WP_USER" "$(get_password)") \
  -H "Accept: application/json" \
  "${PROD_URL}/wp-json/wp/v2/users/me?_fields=id,name,roles") || true
HTTP_CODE="${HTTP_CODE:-000}"

case "$HTTP_CODE" in
  200)
    info "REST API connection OK."
    info "Identity response:"
    sed 's/^/      /' "$TEST_TMP"
    echo
    ;;
  401)
    err "Got 401 Unauthorized."
    err "  - Verify the WordPress username matches your login slug exactly"
    err "    (visit ${PROD_URL}/wp-admin/profile.php to check)."
    err "  - Re-run setup and generate a fresh Application Password."
    rm -f "$TEST_TMP"; exit 1 ;;
  403)
    # Console network is open (egress probe passed at start), so a 403 here is
    # a WordPress capability problem — not an egress/allowlist issue.
    err "Got 403 Forbidden — the WordPress user lacks the capability."
    err "  Use an account with at least Editor role for this endpoint."
    rm -f "$TEST_TMP"; exit 1 ;;
  404)
    err "Got 404 — the REST API endpoint isn't reachable."
    err "  - Is the site URL correct? ${PROD_URL}"
    err "  - A security plugin may be blocking the REST API."
    rm -f "$TEST_TMP"; exit 1 ;;
  000)
    err "Could not reach the site. Verify ${PROD_URL} opens in a browser."
    rm -f "$TEST_TMP"; exit 1 ;;
  *)
    err "Unexpected HTTP $HTTP_CODE from ${PROD_URL}/wp-json/wp/v2/users/me"
    sed 's/^/      /' "$TEST_TMP"
    rm -f "$TEST_TMP"; exit 1 ;;
esac
rm -f "$TEST_TMP"

# ---- First scan ------------------------------------------------------------
echo
bold "Scanning site architecture..."
bash "$SCRIPT_DIR/scan-site.sh" --site-folder "$SITE_FOLDER" --stage all

# ---- Self-containment assertion: NO ~/.config was created ------------------
if [[ -e "$HOME/.config/norml-wp-manager" ]]; then
  err "ASSERTION FAILED: $HOME/.config/norml-wp-manager exists — this script must"
  err "never create it. Please report this; the folder is safe to delete."
fi

echo
bold "Setup complete."
info "Site folder:    $SITE_FOLDER"
info "Config:         $CONFIG_FILE   (no secrets)"
info "Docs:           $DOCS_DIR/   (00–04)"
info "Keychain entry: $KEYCHAIN_SERVICE"
echo
bold "SECURITY FLAGS"
ADMIN_COUNT="$(grep -i 'Administrator users' "$DOCS_DIR/04-rest-capabilities.md" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
if [[ -n "$ADMIN_COUNT" && "$ADMIN_COUNT" -gt 3 ]]; then
  warn "• $ADMIN_COUNT administrators is a lot for one site — consider trimming."
fi
if grep -q 'Third-party admin-level agents' "$DOCS_DIR/03-plugins-theme.md" 2>/dev/null \
   && ! grep -q 'none detected' "$DOCS_DIR/03-plugins-theme.md" 2>/dev/null; then
  warn "• A third-party admin-level agent plugin is active — see 03-plugins-theme.md."
fi
info "(Keychain tier: the AP is not on disk. Still, revoke unused APs in wp-admin.)"
echo
echo "You can now ask Claude things like:"
info '"What plugins are installed on my site?"'
info '"Show me my last 10 posts."'
info '"List my custom post types."'
