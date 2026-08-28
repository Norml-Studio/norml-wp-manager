#!/usr/bin/env bash
# norml-wp-manager — portable / FLOOR-tier setup (Desktop, Cowork, WSL,
# Docker, Linux server without a keyring — any env without an OS secret
# vault but with a writable folder).
#
# Writes everything into ONE user-named site folder:
#   {site_folder}/
#   ├── README.md  project-notes.md  changelog.md      (curated, top level)
#   └── .wpm/
#       ├── config.json   (schema 4, no secret)
#       ├── credential     (raw AP string, born chmod 600, gitignored)
#       ├── .gitignore     (one line: credential)
#       └── docs/00–04.md  (written by scan-site.sh)
#
# On Desktop the sandbox is behind a default-deny egress allowlist, so this
# script runs an ANONYMOUS reachability gate BEFORE asking for any credential.
#
# Usage:
#   setup-portable.sh [site-folder]
#       site-folder defaults to ./<site-name> created in the cwd.

set -euo pipefail
set +x   # xtrace guard — the credential must never render in a trace

APP_SLUG="norml-wp-manager"   # brand-pinned. .wpm/ stays brand-neutral.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  %s\033[0m\n' "$*"; }
err()  { printf '\033[31m  %s\033[0m\n' "$*" >&2; }

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

ask_secret() {
  local prompt="$1" val
  read -rsp "$prompt: " val
  echo >&2
  printf '%s' "$val"
}

# ---- Guard: refuse dangerous / cloud-synced site-folder locations ----------
# $1 = the resolved absolute path of the prospective site folder.
guard_site_folder() {
  local f="$1"
  local home_real="$HOME"
  # Forbidden exact roots.
  case "$f" in
    "$home_real"|"/"|"/tmp"|"/usr"|"/etc"|"$home_real/.config"|"$home_real/.claude")
      err "Refusing to use '$f' as a site folder (system / home / config location)."
      return 1 ;;
  esac
  # Never inside the skill's own directory (skill updates would wipe it).
  local skill_root
  skill_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  case "$f/" in
    "$skill_root"/*)
      err "Refusing to place the site folder inside the skill directory ($skill_root)."
      err "Skill updates would erase it. Pick a folder elsewhere."
      return 1 ;;
  esac
  # Cloud-sync trees — warn loudly, let the user choose.
  case "$f" in
    */Dropbox/*|*/Library/CloudStorage/*|*/OneDrive/*|*"/Google Drive/"*|*/iCloud*|*"/Mobile Documents/"*)
      warn "This folder is inside a cloud-sync tree."
      warn "Your password file could be uploaded to a third-party cloud and to anyone"
      warn "you share the folder with. .gitignore does NOT stop cloud sync."
      warn "Prefer a non-synced folder, or accept the risk and rotate the AP weekly."
      local yn
      yn="$(ask "Use this cloud-synced folder anyway? (y/N)" "N")"
      [[ "$yn" =~ ^[Yy]$ ]] || { err "Aborted — pick a non-synced folder."; return 1; }
      ;;
  esac
  return 0
}

# ---- Anonymous reachability gate (NO credentials) --------------------------
# Loops until /wp-json returns 200 with real REST JSON. On a blocked probe in
# a sandbox, shows the egress-allowlist fix. Echoes nothing; returns 0 on pass.
network_gate() {
  local url="$1" code body tmp
  while true; do
    tmp="$(mktemp "${TMPDIR:-/tmp}/wpm-probe.XXXXXX")"
    code="$(curl -sS -o "$tmp" -w "%{http_code}" --proto '=https' --max-redirs 0 \
      --max-time 12 "${url}/wp-json" 2>/dev/null)" || true
    code="${code:-000}"
    body="$(cat "$tmp" 2>/dev/null || echo "")"; rm -f "$tmp"

    if [[ "$code" == "200" ]] && printf '%s' "$body" | grep -q '"namespaces"\|"routes"'; then
      info "Reachability gate PASSED (200, REST alive)."
      return 0
    fi

    echo
    if [[ "$code" == "200" ]]; then
      err "Got 200 from ${url}/wp-json but the body is not REST JSON."
      err "  The URL may be wrong, or a security plugin disabled the REST API."
      err "  This is NOT an egress problem."
    else
      err "Could not reach ${url}/wp-json (HTTP $code)."
      err "  On the Claude desktop app this is almost always the EGRESS ALLOWLIST:"
      err "    Settings → Capabilities → 'Allow network egress'"
      err "    Leave the dropdown on 'Package managers only'."
      err "    In 'Additional allowed domains' add your site's domain (e.g. acme.com,"
      err "    or *.acme.com for staging). Do NOT switch to 'All domains'."
      err "  (Team/Enterprise: this list may be admin-locked — ask an admin, or run"
      err "   from Claude Code on your own machine.)"
    fi
    echo
    local again
    again="$(ask "Re-check reachability now? (Y/n — n aborts setup)" "Y")"
    [[ "$again" =~ ^[Nn]$ ]] && { err "Aborted before any credential was requested."; return 1; }
  done
}

# ---- Banner ----------------------------------------------------------------

bold "${APP_SLUG} setup — portable / floor tier"
echo
echo "All state for this site goes into ONE folder you name. The Application"
echo "Password is stored as a plaintext file inside that folder's .wpm/ —"
echo "born private (chmod 600) and git-ignored."
echo
warn "Floor tier means the AP lives in a file, not an OS vault. Use an"
warn "editor-role AP, and rotate it (revoke + regenerate) at the end of the"
warn "session — it costs nothing and closes the exposure."
echo
read -rp "Press Enter to continue, Ctrl-C to cancel..."

# ---- Site basics (NO secret yet) -------------------------------------------

echo
bold "Site info"
SITE_NAME="$(ask "Short site name (kebab-case, e.g. acme-marketing)")"
if [[ ! "$SITE_NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  err "Site name must be kebab-case (lowercase letters / digits / hyphens)."
  exit 1
fi

PROD_URL="$(ask "Production URL (https://...)")"
PROD_URL="${PROD_URL%/}"
# HTTPS-only (warn-and-allow only explicit localhost dev).
if [[ "$PROD_URL" == "http://localhost"* || "$PROD_URL" == "http://127.0.0.1"* ]]; then
  warn "Using plaintext http:// for localhost dev — allowed, but never for a live site."
elif [[ "$PROD_URL" != https://* ]]; then
  err "Production URL must start with https:// (got '$PROD_URL')."
  err "An Application Password sent over http:// can be intercepted."
  exit 1
fi

WP_USER="$(ask "WordPress username (login slug — not display name / email)")"
if [[ -z "$WP_USER" ]]; then
  err "WordPress username is required."
  exit 1
fi

# ---- Site folder (with guard) ----------------------------------------------

echo
bold "Site folder"
echo "All state lives in one folder you name. Pick something memorable."
DEFAULT_FOLDER="$(pwd)/$SITE_NAME"
SITE_FOLDER_IN="$(ask "Site folder path" "$DEFAULT_FOLDER")"
# Expand ~ and make absolute.
SITE_FOLDER_IN="${SITE_FOLDER_IN/#\~/$HOME}"
case "$SITE_FOLDER_IN" in
  /*) SITE_FOLDER="$SITE_FOLDER_IN" ;;
  *)  SITE_FOLDER="$(pwd)/$SITE_FOLDER_IN" ;;
esac
SITE_FOLDER="${SITE_FOLDER%/}"

if ! guard_site_folder "$SITE_FOLDER"; then
  exit 1
fi

WPM_DIR="$SITE_FOLDER/.wpm"
DOCS_DIR="$WPM_DIR/docs"
CONFIG_FILE="$WPM_DIR/config.json"
CRED_FILE="$WPM_DIR/credential"

# Track whether WE created .wpm/ so we can clean up debris on abort.
WPM_PREEXISTED=0
[[ -d "$WPM_DIR" ]] && WPM_PREEXISTED=1

cleanup_on_abort() {
  # Remove a half-written .wpm/ ONLY if we created it AND no credential landed.
  if [[ "$WPM_PREEXISTED" -eq 0 && -d "$WPM_DIR" && ! -s "$CRED_FILE" ]]; then
    rm -rf "$WPM_DIR"
    # Remove the site folder too if it's now empty and we just made it.
    rmdir "$SITE_FOLDER" 2>/dev/null || true
  fi
}
trap cleanup_on_abort EXIT

mkdir -p "$DOCS_DIR"

# ---- NETWORK GATE — before any credential ----------------------------------

echo
bold "Checking reachability (anonymous — no password involved)..."
if ! network_gate "$PROD_URL"; then
  exit 1
fi

# ---- Connector: one-click authorize deep link ------------------------------

echo
bold "WordPress Application Password"
echo
echo "Open this one-click authorize link (log in to WordPress if asked):"
echo
echo "  ${PROD_URL}/wp-admin/authorize-application.php?app_name=${APP_SLUG}-${SITE_NAME}"
echo
echo "  → Approve 'Authorize ${APP_SLUG}-${SITE_NAME}?'"
echo "  → Copy the 24-character password (shown ONCE)."
echo
echo "  (Fallback: ${PROD_URL}/wp-admin/profile.php → Application Passwords.)"
echo
warn "Heads-up: pasting it here saves the password in this conversation's"
warn "history (on Claude's servers) for as long as the conversation is kept."
warn "That's why we recommend an editor-role AP and revoking it at session end."
echo
read -rp "Press Enter when ready to paste the Application Password..."

# ---- Capture the AP --------------------------------------------------------

echo
bold "Paste the Application Password (input hidden, characters do not echo)"
WP_PASS_RAW="$(ask_secret "Application Password")"
WP_PASS="$(printf '%s' "$WP_PASS_RAW" | tr -d '[:space:]')"
WP_PASS_RAW=""

if [[ -z "$WP_PASS" ]]; then
  err "Empty Application Password. Aborting."
  exit 1
fi

# ---- Authenticated check BEFORE persisting the credential ------------------
# Gate credential creation on gate-200 (already passed) AND auth-200, so no
# half-written secret debris if the AP is wrong. We use a transient config FD
# here too — the password never hits argv.
echo
bold "Verifying the Application Password..."
AUTH_TMP="$(mktemp "${TMPDIR:-/tmp}/wpm-auth.XXXXXX")"
AUTH_CODE="$(curl -sS -o "$AUTH_TMP" -w "%{http_code}" --proto '=https' --max-redirs 0 \
  --config <(printf 'user = "%s:%s"\n' "$WP_USER" "$WP_PASS") \
  -H "Accept: application/json" \
  "${PROD_URL}/wp-json/wp/v2/users/me?_fields=id,name,roles" 2>/dev/null)" || true
AUTH_CODE="${AUTH_CODE:-000}"

case "$AUTH_CODE" in
  200)
    info "Authentication OK."
    sed 's/^/      /' "$AUTH_TMP"
    ;;
  401)
    err "401 Unauthorized — the username or Application Password is wrong."
    err "  The username must be your WP login slug (check ${PROD_URL}/wp-admin/profile.php)."
    rm -f "$AUTH_TMP"; WP_PASS=""; exit 1 ;;
  403)
    # Anon gate already passed (network reachable) → this is a WP capability 403.
    err "403 Forbidden — the WordPress user lacks the capability for this endpoint."
    err "  Use an account with at least Editor role."
    rm -f "$AUTH_TMP"; WP_PASS=""; exit 1 ;;
  *)
    err "Unexpected HTTP $AUTH_CODE during authentication."
    sed 's/^/      /' "$AUTH_TMP"
    rm -f "$AUTH_TMP"; WP_PASS=""; exit 1 ;;
esac
rm -f "$AUTH_TMP"

# ---- Write the credential BORN private -------------------------------------
# umask 077 in a subshell makes the temp file -rw------- at creation; never a
# world-readable window. Then atomic rename into place.
CRED_TMP="$(mktemp "${TMPDIR:-/tmp}/wpm-cred.XXXXXX")"
( umask 077; printf '%s' "$WP_PASS" > "$CRED_TMP" )
mv -f "$CRED_TMP" "$CRED_FILE"
WP_PASS=""
info "Wrote $CRED_FILE (born chmod 600)"

# ---- .gitignore beside the secret + ASSERTIVE git check-ignore gate --------
printf 'credential\n' > "$WPM_DIR/.gitignore"

if command -v git >/dev/null 2>&1; then
  if git -C "$WPM_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ "$(git -C "$WPM_DIR" check-ignore "$CRED_FILE" 2>/dev/null || true)" != "$CRED_FILE" ]]; then
      err "SECURITY ABORT: git does NOT ignore the credential file."
      err "  Backing the credential out so it cannot be committed."
      rm -f "$CRED_FILE"
      err "  Fix the repo's .gitignore handling, then re-run setup."
      exit 1
    fi
    info "Verified: git ignores the credential file."
  else
    info "Not inside a git work tree — .gitignore written for if one is added later."
  fi
else
  info "git not installed — .gitignore written for if the folder is later put in a repo."
fi

# ---- Write config (schema 4, no secret) ------------------------------------
NOW_UTC="$(date -u +%FT%TZ)"
cat > "$CONFIG_FILE" <<EOF
{
  "schema_version": 4,
  "site_name": "$SITE_NAME",
  "production_url": "$PROD_URL",
  "wp_user": "$WP_USER",
  "env": "desktop",
  "secret_store": {
    "kind": "portable-file",
    "ref": "credential"
  },
  "created_at": "$NOW_UTC",
  "last_scan_at": "$NOW_UTC"
}
EOF
chmod 600 "$CONFIG_FILE"
info "Wrote $CONFIG_FILE"

# ---- Scaffold curated docs at the site-folder TOP LEVEL --------------------
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" 2>/dev/null && pwd || echo "")"
TODAY="$(date '+%Y-%m-%d')"
TIME="$(date '+%H:%M')"

if [[ ! -f "$SITE_FOLDER/README.md" ]]; then
  if [[ -n "$TEMPLATES_DIR" && -f "$TEMPLATES_DIR/readme-template.md" ]]; then
    sed "s/{SITE_NAME}/$SITE_NAME/g" "$TEMPLATES_DIR/readme-template.md" > "$SITE_FOLDER/README.md"
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

if [[ -n "$TEMPLATES_DIR" && -f "$TEMPLATES_DIR/project-notes-template.md" && ! -f "$SITE_FOLDER/project-notes.md" ]]; then
  sed "s/{SITE_NAME}/$SITE_NAME/g" "$TEMPLATES_DIR/project-notes-template.md" > "$SITE_FOLDER/project-notes.md"
  info "Scaffolded $SITE_FOLDER/project-notes.md"
fi

if [[ -n "$TEMPLATES_DIR" && -f "$TEMPLATES_DIR/changelog-template.md" && ! -f "$SITE_FOLDER/changelog.md" ]]; then
  sed "s/{SITE_NAME}/$SITE_NAME/g; s/{TODAY}/$TODAY/g; s/{TIME}/$TIME/g" "$TEMPLATES_DIR/changelog-template.md" > "$SITE_FOLDER/changelog.md"
  info "Scaffolded $SITE_FOLDER/changelog.md"
fi

# Credential is on disk and verified — disarm the abort cleanup.
trap - EXIT

# ---- Scan (00→04) ----------------------------------------------------------
if [[ -f "$SCRIPT_DIR/scan-site.sh" ]]; then
  echo
  bold "Scanning site architecture..."
  bash "$SCRIPT_DIR/scan-site.sh" --site-folder "$SITE_FOLDER" --stage all \
    || warn "Scan failed — you can run scan-site.sh later."
fi

# ---- Done + SECURITY FLAGS -------------------------------------------------
echo
bold "Portable-mode setup complete."
info "Site folder:  $SITE_FOLDER"
info "Config:       $CONFIG_FILE"
info "Credential:   $CRED_FILE  (chmod 600, gitignored)"
info "Docs:         $DOCS_DIR/  (00–04)"
echo
bold "SECURITY FLAGS"
warn "1. The Application Password is plaintext on disk in .wpm/credential."
warn "   Rotate it monthly while this floor setup is in use, and ideally"
warn "   revoke + regenerate it at the end of this session."
ADMIN_COUNT="$(grep -i 'Administrator users' "$DOCS_DIR/04-rest-capabilities.md" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
if [[ -n "$ADMIN_COUNT" && "$ADMIN_COUNT" -gt 3 ]]; then
  warn "2. $ADMIN_COUNT administrators is a lot for one site — consider trimming."
fi
if grep -q 'Third-party admin-level agents' "$DOCS_DIR/03-plugins-theme.md" 2>/dev/null \
   && ! grep -q 'none detected' "$DOCS_DIR/03-plugins-theme.md" 2>/dev/null; then
  warn "3. A third-party admin-level agent plugin is active — see 03-plugins-theme.md."
fi
echo
echo "You can now ask Claude things like:"
info '"What plugins are installed on my site?"'
info '"Show me my last 10 posts."'
