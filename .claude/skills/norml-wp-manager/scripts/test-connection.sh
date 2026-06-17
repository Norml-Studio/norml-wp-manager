#!/usr/bin/env bash
# norml-wp-manager — verify the configured REST API connection and confirm
# the credentials work. Read-only; safe to run any time.
#
# Usage: test-connection.sh [--site-folder <path>]
#   Resolves {site_folder}/.wpm/config.json by ancestor-walk from cwd, or
#   uses --site-folder to skip the walk.

set -euo pipefail
set +x   # xtrace guard — the credential must never render in a trace

APP_SLUG="norml-wp-manager"   # brand-pinned.

SITE_FOLDER_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-folder) SITE_FOLDER_ARG="${2:-}"; shift 2 ;;
    --site-folder=*) SITE_FOLDER_ARG="${1#*=}"; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---- Locate config by ancestor-walk for */.wpm/config.json -----------------
CONFIG_FILE=""; WPM_DIR=""; SITE_FOLDER=""
resolve_from_folder() {
  local folder="${1%/}"
  if [[ -r "$folder/.wpm/config.json" ]]; then
    CONFIG_FILE="$folder/.wpm/config.json"; WPM_DIR="$folder/.wpm"; SITE_FOLDER="$folder"
    return 0
  fi
  return 1
}

if [[ -n "$SITE_FOLDER_ARG" ]]; then
  resolve_from_folder "$SITE_FOLDER_ARG" || { echo "ERROR: no .wpm/config.json under --site-folder: $SITE_FOLDER_ARG" >&2; exit 1; }
else
  d="$(pwd)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    if resolve_from_folder "$d"; then break; fi
    d="$(dirname "$d")"
  done
  [[ -z "$CONFIG_FILE" ]] && resolve_from_folder "/" || true
fi

if [[ -z "$CONFIG_FILE" ]]; then
  echo "ERROR: no norml-wp-manager config found." >&2
  echo "  Walked up from $(pwd) for */.wpm/config.json" >&2
  echo "  Pass --site-folder <path>, or run setup first." >&2
  exit 1
fi

# ---- Config parse: jq if present, else python3 -----------------------------
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
HAS_PY=0; command -v python3 >/dev/null 2>&1 && HAS_PY=1
if [[ $HAS_JQ -eq 0 && $HAS_PY -eq 0 ]]; then
  echo "ERROR: neither jq nor python3 found. Install one to parse config.json." >&2
  exit 1
fi
parse() {
  if [[ $HAS_JQ -eq 1 ]]; then
    jq -r "$1" "$CONFIG_FILE"
  else
    CONFIG_FILE="$CONFIG_FILE" python3 -c "
import json, os
d = json.load(open(os.environ['CONFIG_FILE']))
keys = '$1'.lstrip('.').split('.')
for k in keys:
    d = d.get(k) if isinstance(d, dict) else None
    if d is None: break
print(d if d is not None else '')
"
  fi
}

SITE="$(parse .site_name)"
URL="$(parse .production_url)"; URL="${URL%/}"
WP_USER="$(parse .wp_user)"
SECRET_KIND="$(parse .secret_store.kind)"
SECRET_REF="$(parse .secret_store.ref)"
ENV_VAL="$(parse .env)"; [[ -z "$ENV_VAL" || "$ENV_VAL" == "null" ]] && ENV_VAL="unknown"

# ---- Secret reader (off-argv, off-trace) -----------------------------------
get_password() {
  case "$SECRET_KIND" in
    portable-file|"")
      local cred="$WPM_DIR/credential"
      [[ -r "$cred" ]] || { echo "ERROR: credential file unreadable: $cred" >&2; exit 1; }
      cat "$cred" ;;
    macos-keychain)  security find-generic-password -s "$SECRET_REF" -w ;;
    linux-libsecret) secret-tool lookup service "$SECRET_REF" ;;
    windows-credential-manager)
      echo "ERROR: windows-credential-manager is not readable from bash; use the PowerShell scripts." >&2
      exit 1 ;;
    *) echo "ERROR: unknown secret_store.kind '$SECRET_KIND'." >&2; exit 1 ;;
  esac
}

# ---- THE sanctioned authenticated call -------------------------------------
restcall() {  # $1 = endpoint path, $2.. = extra curl args
  local ep="$1"; shift
  curl -sS --proto '=https' --max-redirs 0 \
    --config <(printf 'user = "%s:%s"\n' "$WP_USER" "$(get_password)") \
    -H "Accept: application/json" "$@" "${URL}${ep}"
}

echo "Site:           $SITE"
echo "URL:            $URL"
echo "Username:       $WP_USER"
echo "Environment:    $ENV_VAL"
echo "Secret source:  $SECRET_KIND ($SECRET_REF)"
echo

# ---- 1. Anonymous REST root reachable? -------------------------------------
echo "1. REST root reachable (anonymous)?"
ROOT_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --proto '=https' --max-redirs 0 \
  --max-time 12 "${URL}/wp-json" 2>/dev/null) || true
ROOT_CODE="${ROOT_CODE:-000}"
if [[ "$ROOT_CODE" == "200" ]]; then
  echo "   OK ($ROOT_CODE)"
else
  echo "   FAIL ($ROOT_CODE)" >&2
  if [[ "$ENV_VAL" == "desktop" ]]; then
    echo "   On the desktop app this is almost always the EGRESS ALLOWLIST, not WordPress:" >&2
    echo "     Settings → Capabilities → add your site domain to the allowlist." >&2
  else
    echo "   The REST root isn't responding — site down or production_url wrong." >&2
  fi
  exit 1
fi

# ---- 2. Application Password works? ----------------------------------------
echo "2. Application Password works?"
ME_BODY=$(mktemp "${TMPDIR:-/tmp}/wpm-me.XXXXXX")
trap 'rm -f "$ME_BODY"' EXIT
# restcall appends the URL after extra args, so -o/-w land on the right request;
# curl prints the code to stdout via -w because -o captured the body.
ME_CODE=$(restcall '/wp/v2/users/me?_fields=id,name,roles' -o "$ME_BODY" -w "%{http_code}" 2>/dev/null) || true
ME_CODE="${ME_CODE:-000}"

case "$ME_CODE" in
  200)
    echo "   OK ($ME_CODE)"
    echo "   Identity:"
    sed 's/^/      /' "$ME_BODY"
    echo
    ;;
  401)
    echo "   FAIL (401 Unauthorized)" >&2
    echo "   - Check the username in config.json matches your WP login slug." >&2
    echo "   - The Application Password may be revoked or wrong. Re-run setup." >&2
    exit 1 ;;
  403)
    # Anon root returned 200 above (network reachable), so a 403 here is a
    # WordPress capability problem — never an egress/allowlist issue.
    echo "   FAIL (403 Forbidden) — the WordPress user lacks the capability." >&2
    echo "   The anonymous REST root WAS reachable, so this is NOT an egress problem." >&2
    echo "   Use an account with at least Editor role for this endpoint." >&2
    exit 1 ;;
  *)
    echo "   FAIL ($ME_CODE)" >&2
    sed 's/^/      /' "$ME_BODY" >&2
    exit 1 ;;
esac

echo "OK. REST API connection working."
