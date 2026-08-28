#!/usr/bin/env bash
# norml-wp-manager — scan the configured WordPress site via REST API and write
# the five numbered docs into {site_folder}/.wpm/docs/. Read-only — safe to run
# any time the user changes plugins/themes/CPTs/ACF groups.
#
# Usage:
#   scan-site.sh [--site-folder <path>] [--stage 0|1|2|3|4|all]
#
#   --site-folder   skip the ancestor-walk; use this folder's .wpm/config.json
#   --stage         which stage(s) to (re)run. Stage 0 (reachability + identity)
#                   is ALWAYS run first as a gate; the listed stage(s) then run.
#                   Default: all.
#
# Reads config from {site_folder}/.wpm/config.json (schema 4). The credential
# is NEVER assigned to a shell variable and NEVER placed on argv — it is piped
# to curl over a process-substitution FD via restcall().

set -euo pipefail
set +x   # xtrace guard — the credential must never render in a trace

APP_SLUG="norml-wp-manager"   # brand-pinned. Drives the OS-vault service name.

# ---- Args ------------------------------------------------------------------

SITE_FOLDER_ARG=""
STAGE="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-folder)
      SITE_FOLDER_ARG="${2:-}"; shift 2 ;;
    --site-folder=*)
      SITE_FOLDER_ARG="${1#*=}"; shift ;;
    --stage)
      STAGE="${2:-}"; shift 2 ;;
    --stage=*)
      STAGE="${1#*=}"; shift ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$STAGE" in
  0|1|2|3|4|all) ;;
  *) echo "ERROR: --stage must be one of 0 1 2 3 4 all (got '$STAGE')" >&2; exit 2 ;;
esac

# ---- Locate config: ancestor-walk for */.wpm/config.json -------------------

CONFIG_FILE=""
WPM_DIR=""
SITE_FOLDER=""

resolve_from_folder() {
  local folder="$1"
  folder="${folder%/}"
  if [[ -r "$folder/.wpm/config.json" ]]; then
    CONFIG_FILE="$folder/.wpm/config.json"
    WPM_DIR="$folder/.wpm"
    SITE_FOLDER="$folder"
    return 0
  fi
  return 1
}

if [[ -n "$SITE_FOLDER_ARG" ]]; then
  if ! resolve_from_folder "$SITE_FOLDER_ARG"; then
    echo "ERROR: no .wpm/config.json under --site-folder: $SITE_FOLDER_ARG" >&2
    exit 1
  fi
else
  d="$(pwd)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    if resolve_from_folder "$d"; then break; fi
    d="$(dirname "$d")"
  done
  # Also check filesystem root once.
  [[ -z "$CONFIG_FILE" ]] && resolve_from_folder "/" || true
fi

if [[ -z "$CONFIG_FILE" ]]; then
  echo "ERROR: no norml-wp-manager config found." >&2
  echo "  Walked up from $(pwd) looking for */.wpm/config.json" >&2
  echo "  Pass --site-folder <path>, or run setup first" >&2
  echo "  (scripts/setup-macos.sh on Console / scripts/setup-portable.sh on Desktop)." >&2
  exit 1
fi

DOCS_DIR="$WPM_DIR/docs"
mkdir -p "$DOCS_DIR"

# ---- Config parsing: jq if present, else python3 ---------------------------

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
HAS_PY=0; command -v python3 >/dev/null 2>&1 && HAS_PY=1
if [[ $HAS_JQ -eq 0 && $HAS_PY -eq 0 ]]; then
  echo "ERROR: neither jq nor python3 found. Install one to parse config.json." >&2
  exit 1
fi
# python3 is a hard prerequisite for the scan body (all the table builders).
if [[ $HAS_PY -eq 0 ]]; then
  echo "ERROR: python3 is required for the site scan (REST JSON parsing)." >&2
  echo "  Install python3 and re-run." >&2
  exit 1
fi

parse() {
  local path="$1"
  if [[ $HAS_JQ -eq 1 ]]; then
    jq -r "$path" "$CONFIG_FILE"
  else
    CONFIG_FILE="$CONFIG_FILE" python3 -c "
import json, os
d = json.load(open(os.environ['CONFIG_FILE']))
keys = '$path'.lstrip('.').split('.')
for k in keys:
    d = d.get(k) if isinstance(d, dict) else None
    if d is None: break
print(d if d is not None else '')
"
  fi
}

SITE_NAME="$(parse .site_name)"
PROD_URL="$(parse .production_url)"
WP_USER="$(parse .wp_user)"
SECRET_KIND="$(parse .secret_store.kind)"
SECRET_REF="$(parse .secret_store.ref)"
ENV_VAL="$(parse .env)"
[[ -z "$ENV_VAL" || "$ENV_VAL" == "null" ]] && ENV_VAL="unknown"

PROD_URL="${PROD_URL%/}"

if [[ -z "$PROD_URL" || "$PROD_URL" == "null" ]]; then
  echo "ERROR: config.json has no production_url. Re-run setup." >&2
  exit 1
fi
if [[ "$PROD_URL" != https://* && "$PROD_URL" != "http://localhost"* && "$PROD_URL" != "http://127.0.0.1"* ]]; then
  echo "ERROR: production_url must be https:// (got '$PROD_URL')." >&2
  exit 1
fi

# ---- Secret reader (off-argv, off-trace) -----------------------------------
# portable-file → raw cat (no jq/python). macos-keychain → security. linux → secret-tool.
get_password() {
  case "$SECRET_KIND" in
    portable-file|"")
      local cred="$WPM_DIR/credential"
      if [[ ! -r "$cred" ]]; then
        echo "ERROR: credential file unreadable: $cred" >&2
        exit 1
      fi
      cat "$cred"
      ;;
    macos-keychain)
      security find-generic-password -s "$SECRET_REF" -w
      ;;
    linux-libsecret)
      secret-tool lookup service "$SECRET_REF"
      ;;
    windows-credential-manager)
      echo "ERROR: windows-credential-manager is not readable from bash; use the PowerShell scripts." >&2
      exit 1
      ;;
    *)
      echo "ERROR: unknown secret_store.kind '$SECRET_KIND'." >&2
      exit 1
      ;;
  esac
}

# ---- THE sanctioned authenticated call (credential never on argv) ----------
restcall() {  # $1 = endpoint path, $2.. = extra curl args
  local ep="$1"; shift
  curl -sS --proto '=https' --max-redirs 0 \
    --config <(printf 'user = "%s:%s"\n' "$WP_USER" "$(get_password)") \
    -H "Accept: application/json" "$@" "${PROD_URL}${ep}"
}

# Anonymous probe — no credentials. Used by the Stage-0 gate.
# curl's -w already prints 000 on transport failure; we only default to 000
# when curl produced no output at all (so we never get a doubled "000000").
anon_code() {  # $1 = endpoint; echoes HTTP code (000 on transport failure)
  local c
  c="$(curl -sS -o /dev/null -w "%{http_code}" --proto '=https' --max-redirs 0 \
    --max-time 12 "${PROD_URL}$1" 2>/dev/null)" || true
  printf '%s' "${c:-000}"
}

# JSON value extractor (stdin → value). python3-only by design.
jget() {
  python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(''); sys.exit(0)
path = '$1'.lstrip('.').split('.') if '$1' else []
for k in path:
    if isinstance(d, dict) and k in d:
        d = d[k]
    elif isinstance(d, list):
        try: d = d[int(k)]
        except Exception: d = ''; break
    else:
        d = ''; break
print(json.dumps(d) if isinstance(d, (dict, list)) else (d if d is not None else ''))
"
}

# Header fetch via authenticated HEAD; echoes the X-WP-Total count or "?".
wp_total() {  # $1 = endpoint
  local headers
  headers="$(restcall "$1" -I 2>/dev/null || echo "")"
  local n
  n="$(printf '%s' "$headers" | grep -i '^x-wp-total:' | awk '{print $2}' | tr -d '\r' || true)"
  [[ -z "$n" ]] && n="?"
  printf '%s' "$n"
}

SCANNED_AT="$(date -u +%FT%TZ)"
NOW_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---- Template helper -------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_ROOT_DIR="$(cd "$SCRIPT_DIR/../templates" 2>/dev/null && pwd || echo "")"
TPL_DOCS_DIR="$(cd "$SCRIPT_DIR/../templates/docs" 2>/dev/null && pwd || echo "")"

# Write a doc from its template if present, else from a minimal inline fallback.
# $1 = doc filename (e.g. 00-connection.md); $2 = inline fallback body.
# Token substitution is done by the caller (we read the template, the caller
# pipes content through sed). Here we just resolve template-or-fallback text.
tpl_or_inline() {  # $1 = template basename (00-connection-template.md); $2 = fallback text
  local tpl="$TPL_DOCS_DIR/$1"
  if [[ -n "$TPL_DOCS_DIR" && -f "$tpl" ]]; then
    cat "$tpl"
  else
    printf '%s' "$2"
  fi
}

root_tpl_or_inline() {  # $1 = template basename; $2 = fallback text
  local tpl="$TPL_ROOT_DIR/$1"
  if [[ -n "$TPL_ROOT_DIR" && -f "$tpl" ]]; then
    cat "$tpl"
  else
    printf '%s' "$2"
  fi
}

# Pure-bash token substitution (no python stdin collision). Replaces every
# {KEY} in $1 with VALUE for each KEY=VALUE pair in $2.. — echoes the result.
subst_tokens() {  # $1 = body, $2.. = KEY=VALUE pairs
  local body="$1"; shift
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"; val="${pair#*=}"
    body="${body//\{$key\}/$val}"
  done
  printf '%s' "$body"
}

# ---- Diff-before-overwrite -------------------------------------------------
# Writes $2 (content) to $DOCS_DIR/$1 only if changed; prints a one-line delta.
DELTAS=()
write_doc() {  # $1 = filename, $2 = content
  local name="$1" new="$2" path="$DOCS_DIR/$1"
  if [[ -f "$path" ]]; then
    if [[ "$(cat "$path")" == "$new" ]]; then
      DELTAS+=("$name: unchanged")
      return 0
    fi
  fi
  printf '%s' "$new" > "$path"
  DELTAS+=("$name: written")
  echo "Wrote $path"
}

write_site_doc() {  # $1 = filename, $2 = content
  local name="$1" new="$2" path="$SITE_FOLDER/$1"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$new" ]]; then
    DELTAS+=("$name: unchanged")
    return 0
  fi
  printf '%s' "$new" > "$path"
  DELTAS+=("$name: written")
  echo "Wrote $path"
}

GENERATED_HDR="<!-- GENERATED by norml-wp-manager scan-site — DO NOT EDIT BY HAND. Rescan overwrites this file. -->"

###############################################################################
# STAGE 0 — Reachability + identity (GATE; always first)
###############################################################################

echo "Scanning $SITE_NAME ($PROD_URL) — stage=$STAGE, env=$ENV_VAL"
echo
echo "Stage 0 — reachability + identity (gate)..."

GATE_ABORT=""   # set to a reason string on failure

# 0a — anonymous reachability probe of the REST root (capture code + timing).
ANON_PROBE_RAW="$(curl -sS -o "${TMPDIR:-/tmp}/wpm_root.$$" -w '%{http_code}|%{time_total}' \
  --proto '=https' --max-redirs 0 --max-time 12 "${PROD_URL}/wp-json" 2>/dev/null)" || true
ANON_CODE="${ANON_PROBE_RAW%%|*}"; ANON_CODE="${ANON_CODE:-000}"
ANON_TIME="${ANON_PROBE_RAW#*|}"; [[ "$ANON_TIME" == "$ANON_PROBE_RAW" ]] && ANON_TIME=""
ROOT_JSON="$(cat "${TMPDIR:-/tmp}/wpm_root.$$" 2>/dev/null || echo "")"
rm -f "${TMPDIR:-/tmp}/wpm_root.$$"

if [[ "$ANON_CODE" == "200" ]]; then
  # Confirm it is real WP REST JSON, not an HTML page returned with 200.
  if [[ -z "$(printf '%s' "$ROOT_JSON" | jget .namespaces)" && -z "$(printf '%s' "$ROOT_JSON" | jget .routes)" ]]; then
    GATE_ABORT="unreachable"
    echo "  Anon GET /wp-json returned 200 but not REST JSON (wrong URL or REST disabled)." >&2
  fi
else
  # Distinguish egress (Desktop) from a plain-down site.
  if [[ "$ENV_VAL" == "desktop" ]]; then
    GATE_ABORT="egress-blocked"
    echo "  Anon GET /wp-json failed ($ANON_CODE)." >&2
    echo "  On the desktop app this is almost always the EGRESS ALLOWLIST, not WordPress." >&2
    echo "  Fix: Settings → Capabilities → add your site domain to the allowlist, then re-run." >&2
  else
    GATE_ABORT="unreachable"
    echo "  Anon GET /wp-json failed ($ANON_CODE) — site down or production_url wrong." >&2
  fi
fi

# 0b — authenticated identity (only if reachable).
ME_JSON=""; WP_DISPLAY_NAME=""; CONNECTED_ROLES=""; WP_USER_ID=""
if [[ -z "$GATE_ABORT" ]]; then
  ME_JSON="$(restcall '/wp/v2/users/me?_fields=id,name,roles' 2>/dev/null || echo "")"
  WP_DISPLAY_NAME="$(printf '%s' "$ME_JSON" | jget .name)"
  WP_USER_ID="$(printf '%s' "$ME_JSON" | jget .id)"
  CONNECTED_ROLES="$(printf '%s' "$ME_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read()); print(','.join(d.get('roles',[]) or []))
except Exception:
    print('')
")"
  if [[ -z "$WP_DISPLAY_NAME" && -z "$WP_USER_ID" ]]; then
    # Reachable anon, but auth call returned no identity. In Console an open
    # network means this is a real auth/capability failure.
    GATE_ABORT="auth-failed"
    echo "  Authenticated GET /wp/v2/users/me returned no identity." >&2
    if [[ "$ENV_VAL" == "desktop" ]]; then
      echo "  Anon probe passed, so this is a WordPress auth issue (not egress):" >&2
    fi
    echo "  Check the username (login slug) and the Application Password; re-run setup if needed." >&2
  fi
fi

# Tier label (defaults to portable-file when unset).
TIER="$SECRET_KIND"
[[ -z "$TIER" || "$TIER" == "null" ]] && TIER="portable-file"
# {ROLES} display value used across every doc's header line.
ROLES_DISP="${CONNECTED_ROLES:-—}"

# Compose the per-field display strings the template expects.
ANON_PROBE_STATUS="HTTP $ANON_CODE"
[[ "$ANON_CODE" == "200" ]] && ANON_PROBE_STATUS="200"
ANON_PROBE_TIME="${ANON_TIME:-n/a}s"
case "${GATE_ABORT:-}" in
  egress-blocked) ANON_PROBE_RESULT="BLOCKED — egress allowlist (Settings → Capabilities)"; AUTH_RESULT="not attempted — egress blocked" ;;
  unreachable)    ANON_PROBE_RESULT="UNREACHABLE — site down or wrong URL / REST disabled"; AUTH_RESULT="not attempted — unreachable" ;;
  auth-failed)    ANON_PROBE_RESULT="reachable (REST alive)"; AUTH_RESULT="FAILED — no identity returned" ;;
  *)              ANON_PROBE_RESULT="reachable (REST alive)"; AUTH_RESULT="OK (200)" ;;
esac

# Minimal token-complete inline fallback (used only if the template is absent).
CONN_INLINE="$GENERATED_HDR
# 00 — Connection — {SITE_NAME}

_Scanned: {SCANNED_AT} · Connected as: {WP_USER} ({ROLES}) · Tier: {SECRET_KIND} · env: {ENV}_

| Field | Value |
|---|---|
| Production URL | {PROD_URL} |
| Environment | {ENV} |
| Secret tier | {SECRET_KIND} |
| Secret pointer | {SECRET_REF} |
| Anon /wp-json status | {ANON_PROBE_STATUS} |
| Anon round-trip | {ANON_PROBE_TIME} |
| Anon result | {ANON_PROBE_RESULT} |
| Connected user (login) | {WP_USER} |
| Display name | {WP_DISPLAY_NAME} |
| User ID | {WP_USER_ID} |
| Roles | {ROLES} |
| Auth check | {AUTH_RESULT} |

### What REST cannot see here
- The Application Password value (held in {SECRET_KIND}; never written to these docs).
- Whether other Application Passwords exist for this user.
"

CONN_BODY="$(tpl_or_inline 00-connection-template.md "$CONN_INLINE")"
CONN_OUT="$(subst_tokens "$CONN_BODY" \
  "SITE_NAME=$SITE_NAME" \
  "SCANNED_AT=$SCANNED_AT" \
  "PROD_URL=$PROD_URL" \
  "ENV=$ENV_VAL" \
  "SECRET_KIND=$TIER" \
  "SECRET_REF=$SECRET_REF" \
  "ANON_PROBE_STATUS=$ANON_PROBE_STATUS" \
  "ANON_PROBE_TIME=$ANON_PROBE_TIME" \
  "ANON_PROBE_RESULT=$ANON_PROBE_RESULT" \
  "WP_USER=$WP_USER" \
  "WP_DISPLAY_NAME=${WP_DISPLAY_NAME:-—}" \
  "WP_USER_ID=${WP_USER_ID:-—}" \
  "ROLES=$ROLES_DISP" \
  "AUTH_RESULT=$AUTH_RESULT")"
write_doc 00-connection.md "$CONN_OUT"

# ---- changelog append + last_scan_at (shared helpers) ----------------------
CHLOG="$SITE_FOLDER/changelog.md"

append_changelog() {  # $1 = the full "[TAG] ..." line body (without the leading "- HH:MM — ")
  [[ -f "$CHLOG" ]] || return 0
  local today time line
  today="$(date '+%Y-%m-%d')"; time="$(date '+%H:%M')"
  line="- $time — $1"
  python3 - "$CHLOG" "$today" "$line" <<'PYEOF'
import sys, re, pathlib
path, today, line = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); content = p.read_text()
hp = re.compile(r'^## ' + re.escape(today) + r'(?: .*)?$', re.MULTILINE)
m = hp.search(content)
if m:
    at = m.end()
    while at < len(content) and content[at] == '\n':
        at += 1
    content = content[:at] + line + '\n' + content[at:]
else:
    first = re.search(r'^## ', content, re.MULTILINE)
    block = f"## {today} — Session\n\n{line}\n\n"
    content = (content[:first.start()] + block + content[first.start():]) if first else (content.rstrip() + '\n\n' + block)
p.write_text(content)
PYEOF
  echo "Logged changelog entry to $CHLOG"
}

set_last_scan_at() {
  local ts="$1"
  python3 - "$CONFIG_FILE" "$ts" <<'PYEOF'
import json, sys
path, ts = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d['last_scan_at'] = ts
json.dump(d, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
PYEOF
}

print_deltas() {
  echo
  echo "Per-doc deltas:"
  local x
  for x in "${DELTAS[@]}"; do echo "  - $x"; done
}

# Hard-stop on a Stage-0 gate failure — never run 1–4, never swallow the 403.
if [[ -n "$GATE_ABORT" ]]; then
  print_deltas
  append_changelog "[SCAN] Scan ABORTED at gate: $GATE_ABORT. See \`.wpm/docs/00-connection.md\`."
  set_last_scan_at "$SCANNED_AT" || true
  echo
  echo "Scan ABORTED at Stage-0 gate: $GATE_ABORT" >&2
  case "$GATE_ABORT" in
    egress-blocked) echo "Resolve the egress allowlist (Settings → Capabilities), then re-run." >&2 ;;
    unreachable)    echo "Verify the site is up and production_url is correct, then re-run." >&2 ;;
    auth-failed)    echo "Verify the username + Application Password, then re-run." >&2 ;;
  esac
  exit 1
fi

echo "  Gate OK — connected as ${WP_DISPLAY_NAME:-$WP_USER} (${CONNECTED_ROLES:-no roles reported})."

# Helper: should we run stage N? (Stage 0 already ran above.)
run_stage() {  # $1 = stage number
  [[ "$STAGE" == "all" || "$STAGE" == "$1" ]]
}

# The five header tokens every generated doc shares (same italic line).
HDR_PAIRS=(
  "SITE_NAME=$SITE_NAME"
  "SCANNED_AT=$SCANNED_AT"
  "WP_USER=$WP_USER"
  "ROLES=$ROLES_DISP"
  "SECRET_KIND=$TIER"
  "ENV=$ENV_VAL"
)

# Track which CPTs are REST-exposed (filled in Stage 2, consumed by Stage 4).
REST_CPTS=""   # space-separated rest_base values

###############################################################################
# STAGE 1 — Site basics
###############################################################################
if run_stage 1; then
  echo "Stage 1 — site basics..."
  SETTINGS_JSON="$(restcall '/wp/v2/settings' 2>/dev/null || echo "")"
  SITE_TITLE="$(printf '%s' "$SETTINGS_JSON" | jget .title)"
  SITE_DESC="$(printf '%s' "$SETTINGS_JSON" | jget .description)"
  SITE_LANG="$(printf '%s' "$SETTINGS_JSON" | jget .language)"
  PPP="$(printf '%s' "$SETTINGS_JSON" | jget .posts_per_page)"
  SOW="$(printf '%s' "$SETTINGS_JSON" | jget .start_of_week)"
  DPF="$(printf '%s' "$SETTINGS_JSON" | jget .default_post_format)"
  # Fall back to anon root description / name when settings are admin-gated.
  [[ -z "$SITE_TITLE" ]] && SITE_TITLE="$(printf '%s' "$ROOT_JSON" | jget .name)"
  [[ -z "$SITE_DESC" ]] && SITE_DESC="$(printf '%s' "$ROOT_JSON" | jget .description)"
  GMT_OFFSET="$(printf '%s' "$ROOT_JSON" | jget .gmt_offset)"
  NAMESPACES="$(printf '%s' "$ROOT_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    print('\n'.join(d.get('namespaces',[]) or []))
except Exception:
    pass
")"
  # WP version best-effort: the REST root rarely carries it; mark approximate.
  WP_VERSION="$(printf '%s' "$ROOT_JSON" | jget .description)"
  if [[ -n "$WP_VERSION" ]]; then WP_VERSION_SOURCE="REST root description (approximate)"; else WP_VERSION="unknown (not exposed over REST)"; WP_VERSION_SOURCE="not detectable via REST"; fi
  # Multisite hint: a /wp/v2/sites namespace or ms- routes would hint at it.
  if printf '%s' "$NAMESPACES" | grep -qi 'wp-site-health\|wp/v2/sites'; then MULTISITE_HINT="possible (network routes present)"; else MULTISITE_HINT="single-site (no network routes seen)"; fi
  if [[ -z "$SITE_LANG" ]]; then SETTINGS_NOTE="GET /wp/v2/settings not visible at this role — admin-only fields fall back to the anonymous subset."; else SETTINGS_NOTE="Settings read from /wp/v2/settings (admin)."; fi

  S1_INLINE="$GENERATED_HDR
# 01 — Site basics — {SITE_NAME}

_Scanned: {SCANNED_AT} · Connected as: {WP_USER} ({ROLES}) · Tier: {SECRET_KIND} · env: {ENV}_

| Field | Value |
|---|---|
| Site title | {SITE_TITLE} |
| Tagline | {SITE_DESC} |
| Language | {SITE_LANG} |
| GMT offset | {GMT_OFFSET} |
| Posts per page | {POSTS_PER_PAGE} |
| Start of week | {START_OF_WEEK} |
| Default post format | {DEFAULT_POST_FORMAT} |
| WP version (best-effort) | {WP_VERSION} ({WP_VERSION_SOURCE}) |
| Multisite | {MULTISITE_HINT} |

> {SETTINGS_NOTE}

## Registered REST namespaces

\`\`\`
{NAMESPACES}
\`\`\`

### What REST cannot see here
- Exact WordPress core version; PHP / MySQL / server stack.
- \`wp-config.php\` constants; most of \`wp_options\`.
"
  S1_BODY="$(tpl_or_inline 01-site-template.md "$S1_INLINE")"
  S1_OUT="$(subst_tokens "$S1_BODY" "${HDR_PAIRS[@]}" \
    "SITE_TITLE=${SITE_TITLE:-?}" \
    "SITE_DESC=${SITE_DESC:-?}" \
    "SITE_LANG=${SITE_LANG:-not visible at this role}" \
    "GMT_OFFSET=${GMT_OFFSET:-?}" \
    "POSTS_PER_PAGE=${PPP:-?}" \
    "START_OF_WEEK=${SOW:-?}" \
    "DEFAULT_POST_FORMAT=${DPF:-standard}" \
    "WP_VERSION=$WP_VERSION" \
    "WP_VERSION_SOURCE=$WP_VERSION_SOURCE" \
    "MULTISITE_HINT=$MULTISITE_HINT" \
    "SETTINGS_NOTE=$SETTINGS_NOTE" \
    "NAMESPACES=${NAMESPACES:-(none reported)}")"
  write_doc 01-site.md "$S1_OUT"
fi

###############################################################################
# STAGE 2 — Content model
###############################################################################
if run_stage 2; then
  echo "Stage 2 — content model..."
  TYPES_JSON="$(restcall '/wp/v2/types' 2>/dev/null || echo "")"
  TAX_JSON="$(restcall '/wp/v2/taxonomies' 2>/dev/null || echo "")"

  POST_TYPE_ROWS="$(printf '%s' "$TYPES_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    for slug,info in (d or {}).items():
        rb=info.get('rest_base','') or ''
        print(f\"{slug},{info.get('name','')},{rb},{'yes' if rb else 'no'},{'yes' if info.get('hierarchical') else 'no'},{'yes' if info.get('viewable') else 'no'}\")
except Exception:
    pass
")"
  TAXONOMY_ROWS="$(printf '%s' "$TAX_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    for slug,info in (d or {}).items():
        rb=info.get('rest_base','') or ''
        types=','.join(info.get('types',[]) or [])
        print(f'{slug},{info.get(\"name\",\"\")},{rb},{\"yes\" if rb else \"no\"},{\"yes\" if info.get(\"hierarchical\") else \"no\"},\"{types}\"')
except Exception:
    pass
")"
  # Collect REST-exposed non-core CPT rest_bases for Stage 4's capability probe.
  REST_CPTS="$(printf '%s' "$TYPES_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    out=[]
    for slug,info in (d or {}).items():
        rb=info.get('rest_base','') or ''
        if rb and rb not in ('posts','pages','media','blocks','navigation','wp_template','wp_template_part','menu-items'):
            out.append(rb)
    print(' '.join(out))
except Exception:
    pass
")"
  [[ -z "$POST_TYPE_ROWS" ]] && { POST_TYPE_ROWS="(not visible at this role)"; POST_TYPE_NOTE="Type list not visible at this role."; } || POST_TYPE_NOTE="Types with rest_exposed=no cannot be touched over REST."
  [[ -z "$TAXONOMY_ROWS" ]] && { TAXONOMY_ROWS="(not visible at this role)"; TAXONOMY_NOTE="Taxonomy list not visible at this role."; } || TAXONOMY_NOTE="Taxonomies with rest_exposed=no cannot be touched over REST."
  POST_COUNT="$(wp_total '/wp/v2/posts?per_page=1&status=publish')"
  PAGE_COUNT="$(wp_total '/wp/v2/pages?per_page=1&status=publish')"
  # Per-CPT counts for any REST-exposed custom type.
  CPT_COUNT_ROWS=""
  for rb in $REST_CPTS; do
    c="$(wp_total "/wp/v2/${rb}?per_page=1&status=publish")"
    CPT_COUNT_ROWS="${CPT_COUNT_ROWS}| ${rb} | ${c} |"$'\n'
  done
  [[ -z "$CPT_COUNT_ROWS" ]] && CPT_COUNT_ROWS="| (no REST-exposed CPTs) | — |"

  S2_INLINE="$GENERATED_HDR
# 02 — Content model — {SITE_NAME}

_Scanned: {SCANNED_AT} · Connected as: {WP_USER} ({ROLES}) · Tier: {SECRET_KIND} · env: {ENV}_

## Post types
\`\`\`csv
slug,name,rest_base,rest_exposed,hierarchical,viewable
{POST_TYPE_ROWS}
\`\`\`
> {POST_TYPE_NOTE}

## Taxonomies
\`\`\`csv
slug,name,rest_base,rest_exposed,hierarchical,attached_to
{TAXONOMY_ROWS}
\`\`\`
> {TAXONOMY_NOTE}

## Content counts
| Type | Published |
|---|---|
| Posts | {POST_COUNT} |
| Pages | {PAGE_COUNT} |
{CPT_COUNT_ROWS}

### What REST cannot see here
- CPTs / taxonomies with \`show_in_rest:false\` are invisible to REST entirely.
"
  S2_BODY="$(tpl_or_inline 02-content-model-template.md "$S2_INLINE")"
  S2_OUT="$(subst_tokens "$S2_BODY" "${HDR_PAIRS[@]}" \
    "POST_TYPE_ROWS=$POST_TYPE_ROWS" \
    "POST_TYPE_NOTE=$POST_TYPE_NOTE" \
    "TAXONOMY_ROWS=$TAXONOMY_ROWS" \
    "TAXONOMY_NOTE=$TAXONOMY_NOTE" \
    "POST_COUNT=$POST_COUNT" \
    "PAGE_COUNT=$PAGE_COUNT" \
    "CPT_COUNT_ROWS=$CPT_COUNT_ROWS")"
  write_doc 02-content-model.md "$S2_OUT"
fi

###############################################################################
# STAGE 3 — Plugins + theme
###############################################################################
if run_stage 3; then
  echo "Stage 3 — plugins + theme..."
  PLUGINS_RAW="$(restcall '/wp/v2/plugins?_fields=plugin,name,status,version' 2>/dev/null || echo "")"
  THEMES_RAW="$(restcall '/wp/v2/themes' 2>/dev/null || echo "")"
  # Namespaces from the cached root (presence signal that works without admin).
  NS_ALL="$(printf '%s' "$ROOT_JSON" | python3 -c "
import json,sys
try:
    print('\n'.join(json.loads(sys.stdin.read()).get('namespaces',[]) or []))
except Exception:
    pass
")"

  PLUGIN_ROWS="$(printf '%s' "$PLUGINS_RAW" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    if isinstance(d,list):
        for p in d:
            print(f\"{p.get('plugin','')},{p.get('name','')},{p.get('status','')},{p.get('version','')}\")
except Exception:
    pass
")"
  ACTIVE_THEME="$(printf '%s' "$THEMES_RAW" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    if isinstance(d,list):
        for t in d:
            if t.get('status')=='active':
                nm=t.get('name'); nm=nm.get('rendered','?') if isinstance(nm,dict) else (nm or '?')
                print(f\"{t.get('stylesheet','?')}|{t.get('version','?')}|{nm}\"); break
except Exception:
    pass
")"
  ATHEME_SLUG="${ACTIVE_THEME%%|*}"; ATHEME_REST="${ACTIVE_THEME#*|}"; ATHEME_VER="${ATHEME_REST%%|*}"; ATHEME_NAME="${ACTIVE_THEME##*|}"
  if [[ -n "$ACTIVE_THEME" ]]; then ACTIVE_THEME_DISP="${ATHEME_NAME} (${ATHEME_SLUG})"; ACTIVE_THEME_VERSION_DISP="$ATHEME_VER"; THEME_NOTE="From GET /wp/v2/themes (admin)."; else ACTIVE_THEME_DISP="not visible at this role"; ACTIVE_THEME_VERSION_DISP="—"; THEME_NOTE="Theme inventory needs admin; only namespace hints remain."; fi

  PLUGINS_COUNT=$(printf '%s' "$PLUGIN_ROWS" | awk -F, '$1 != "" {n++} END {print n+0}')
  if [[ "$PLUGINS_COUNT" -le 0 ]]; then PLUGIN_ROWS="(not visible at this role)"; PLUGINS_NOTE="Plugin list needs admin. Detected key plugins below are inferred from REST namespaces."; else PLUGINS_NOTE="From GET /wp/v2/plugins (admin)."; fi

  # Key-plugin detection: prefer the plugin inventory, fall back to namespaces.
  detect() {  # $1 = inventory regex, $2 = namespace regex
    local hit
    hit="$(printf '%s' "$PLUGIN_ROWS" | awk -F, '$3=="active"{print $1}' | grep -oE "$1" | head -1 || true)"
    [[ -z "$hit" && -n "${2:-}" ]] && hit="$(printf '%s' "$NS_ALL" | grep -oiE "$2" | head -1 || true)"
    printf '%s' "$hit"
  }
  PAGE_BUILDER="$(detect 'elementor|bricks|beaver-builder-lite-version|bb-plugin|js_composer|divi-builder' 'elementor|bricks|beaver')"
  SEO_PLUGIN="$(detect 'wordpress-seo|seo-by-rank-math|wp-seopress|all-in-one-seo-pack' 'rankmath|yoast|seopress')"
  CACHE_PLUGIN="$(detect 'wp-rocket|w3-total-cache|litespeed-cache|wp-super-cache|wp-fastest-cache' 'litespeed')"
  ACF_STATUS="$(detect 'advanced-custom-fields' 'acf')"
  ECOMMERCE_PLUGIN="$(detect 'woocommerce|easy-digital-downloads' 'wc/|edd')"
  MULTILINGUAL_PLUGIN="$(detect 'sitepress-multilingual-cms|polylang|weglot' 'wpml|pll')"
  AGENTS="$(printf '%s' "$PLUGIN_ROWS" | awk -F, '$3=="active"{print $1}' | grep -oE 'worker|jetpack|ithemes-sync|managewp|mainwp-child|wpremote' | sort -u | paste -sd ',' - || true)"
  for v in PAGE_BUILDER SEO_PLUGIN CACHE_PLUGIN ECOMMERCE_PLUGIN MULTILINGUAL_PLUGIN; do
    [[ -z "${!v}" ]] && printf -v "$v" '%s' "none detected"
  done
  [[ -z "$ACF_STATUS" ]] && ACF_STATUS="not detected"
  [[ -z "$AGENTS" ]] && AGENTS="none detected"

  S3_INLINE="$GENERATED_HDR
# 03 — Plugins & theme — {SITE_NAME}

_Scanned: {SCANNED_AT} · Connected as: {WP_USER} ({ROLES}) · Tier: {SECRET_KIND} · env: {ENV}_

## Active theme
| Field | Value |
|---|---|
| Theme | {ACTIVE_THEME} |
| Version | {ACTIVE_THEME_VERSION} |
> {THEME_NOTE}

## Plugins
> {PLUGINS_NOTE}
\`\`\`csv
plugin,name,status,version
{PLUGIN_ROWS}
\`\`\`

### Detected key plugins
| Role | Plugin |
|---|---|
| Page builder | {PAGE_BUILDER} |
| SEO | {SEO_PLUGIN} |
| Cache | {CACHE_PLUGIN} |
| ACF | {ACF_STATUS} |
| E-commerce | {ECOMMERCE_PLUGIN} |
| Multilingual | {MULTILINGUAL_PLUGIN} |

### Detected third-party admin agents
\`\`\`
{THIRD_PARTY_AGENTS}
\`\`\`

### What REST cannot see here
- Theme file tree, plugin settings in \`wp_options\`, mu-plugins / dropins.
"
  S3_BODY="$(tpl_or_inline 03-plugins-theme-template.md "$S3_INLINE")"
  S3_OUT="$(subst_tokens "$S3_BODY" "${HDR_PAIRS[@]}" \
    "ACTIVE_THEME=$ACTIVE_THEME_DISP" \
    "ACTIVE_THEME_VERSION=$ACTIVE_THEME_VERSION_DISP" \
    "THEME_NOTE=$THEME_NOTE" \
    "PLUGINS_NOTE=$PLUGINS_NOTE" \
    "PLUGIN_ROWS=$PLUGIN_ROWS" \
    "PAGE_BUILDER=$PAGE_BUILDER" \
    "SEO_PLUGIN=$SEO_PLUGIN" \
    "CACHE_PLUGIN=$CACHE_PLUGIN" \
    "ACF_STATUS=$ACF_STATUS" \
    "ECOMMERCE_PLUGIN=$ECOMMERCE_PLUGIN" \
    "MULTILINGUAL_PLUGIN=$MULTILINGUAL_PLUGIN" \
    "THIRD_PARTY_AGENTS=$AGENTS")"
  write_doc 03-plugins-theme.md "$S3_OUT"
fi

###############################################################################
# STAGE 4 — REST capability map (derived)
###############################################################################
if run_stage 4; then
  echo "Stage 4 — REST capability map..."
  options_allow() {  # $1 = endpoint; echoes the Allow methods, or "?"
    local h a
    h="$(restcall "$1" -X OPTIONS -I 2>/dev/null || echo "")"
    a="$(printf '%s' "$h" | grep -i '^allow:' | sed 's/^[Aa]llow:[[:space:]]*//' | tr -d '\r' | head -1 || true)"
    [[ -z "$a" ]] && a="?"
    printf '%s' "$a"
  }
  # Emit one CSV row: surface,rest_base,read,create,update,delete
  cap_row() {  # $1 = surface label, $2 = rest_base
    local allow; allow="$(options_allow "/wp/v2/$2")"
    local read="no" create="no" update="no" delete="no"
    case "$allow" in *GET*) read="yes";; esac
    case "$allow" in *POST*) create="yes";; esac
    case "$allow" in *PUT*|*PATCH*) update="yes";; esac
    case "$allow" in *DELETE*) delete="yes";; esac
    [[ "$allow" == "?" ]] && { read="?"; create="?"; update="?"; delete="?"; }
    printf '%s,%s,%s,%s,%s,%s' "$1" "$2" "$read" "$create" "$update" "$delete"
  }
  CAPABILITY_ROWS="$(cap_row posts posts)"$'\n'"$(cap_row pages pages)"$'\n'"$(cap_row media media)"
  for rb in ${REST_CPTS:-}; do
    CAPABILITY_ROWS="${CAPABILITY_ROWS}"$'\n'"$(cap_row "$rb" "$rb")"
  done
  ADMIN_COUNT="$(wp_total '/wp/v2/users?per_page=1&roles=administrator')"
  if [[ "$ADMIN_COUNT" == "?" ]]; then ADMIN_COUNT_NOTE="Administrator count not visible at this role (need admin)."
  elif [[ "$ADMIN_COUNT" =~ ^[0-9]+$ && "$ADMIN_COUNT" -gt 3 ]]; then ADMIN_COUNT_NOTE="$ADMIN_COUNT administrators is a lot for one site — consider trimming."
  else ADMIN_COUNT_NOTE="From HEAD /wp/v2/users?roles=administrator (X-WP-Total)."; fi

  KNOWN_BLOCKERS="- Plugin install / update / activate is disabled on most managed hosts over REST.
- ACF field values are writable over REST only if the field group has \`show_in_rest:true\`.
- RankMath per-post meta is REST-writable only if registered with \`show_in_rest:true\`.
- WordPress core updates are out of REST scope.
- Any surface with \`rest_exposed=no\` in 02-content-model.md is unreachable here."

  S4_INLINE="$GENERATED_HDR
# 04 — REST capabilities — {SITE_NAME}

_Scanned: {SCANNED_AT} · Connected as: {WP_USER} ({ROLES}) · Tier: {SECRET_KIND} · env: {ENV}_

## Writability matrix (at the connected role: {ROLES})
\`\`\`csv
surface,rest_base,read,create,update,delete
{CAPABILITY_ROWS}
\`\`\`

## Administrator count
| Field | Value |
|---|---|
| Administrator users | {ADMIN_COUNT} |
> {ADMIN_COUNT_NOTE}

## Known blockers
{KNOWN_BLOCKERS}

## What REST cannot see (master list)
- Exact WP core version; PHP/MySQL/server stack; \`wp-config.php\` constants; cron.
- Theme internals; ACF field-group definitions; page-builder blobs; plugin settings.
- **CPTs / taxonomies with \`show_in_rest:false\` are invisible to REST entirely.**
"
  S4_BODY="$(tpl_or_inline 04-rest-capabilities-template.md "$S4_INLINE")"
  S4_OUT="$(subst_tokens "$S4_BODY" "${HDR_PAIRS[@]}" \
    "CAPABILITY_ROWS=$CAPABILITY_ROWS" \
    "ADMIN_COUNT=$ADMIN_COUNT" \
    "ADMIN_COUNT_NOTE=$ADMIN_COUNT_NOTE" \
    "KNOWN_BLOCKERS=$KNOWN_BLOCKERS")"
  write_doc 04-rest-capabilities.md "$S4_OUT"

  PUBLIC_CAPABILITIES_BODY="$(root_tpl_or_inline capabilities-template.md "$S4_INLINE")"
  PUBLIC_CAPABILITIES_OUT="$(subst_tokens "$PUBLIC_CAPABILITIES_BODY" "${HDR_PAIRS[@]}" \
    "CAPABILITY_ROWS=$CAPABILITY_ROWS" \
    "ADMIN_COUNT=$ADMIN_COUNT" \
    "ADMIN_COUNT_NOTE=$ADMIN_COUNT_NOTE" \
    "KNOWN_BLOCKERS=$KNOWN_BLOCKERS")"
  write_site_doc capabilities.md "$PUBLIC_CAPABILITIES_OUT"
fi

###############################################################################
# docs/README.md — index (only on a full scan)
###############################################################################
if [[ "$STAGE" == "all" ]]; then
  README_INLINE="$GENERATED_HDR
# .wpm/docs — generated site scan

Auto-written by \`scripts/scan-site.sh\`. **Do not hand-edit** — rescans overwrite these.
Curated, hand-editable knowledge lives one level up in \`../../project-notes.md\` and \`../../changelog.md\`.

| File | Contents |
|---|---|
| 00-connection.md | env, network-gate result, auth, user + roles, secret pointer, last scan |
| 01-site.md | WP version (best-effort), settings, REST namespaces |
| 02-content-model.md | post types (per-type show_in_rest), taxonomies, counts |
| 03-plugins-theme.md | active theme, plugin inventory, 3rd-party agents |
| 04-rest-capabilities.md | writability matrix + blockers + \"What REST cannot see\" |

## Rescan map (\`scan-site.sh --site-folder {path} --stage N\`)

Stage 0 always re-runs first as a reachability gate.

| You say | Stage |
|---|---|
| rescan my site / refresh architecture | all |
| recheck connection / is my site reachable | 0 |
| refresh site basics | 1 |
| redo content model / I added a CPT | 2 |
| rescan plugins / re-check the theme | 3 |
| recheck what I can edit over REST | 4 |
"
  README_BODY="$(tpl_or_inline readme-template.md "$README_INLINE")"
  # Substitute only safe per-site tokens (a real template may carry these);
  # literal {path}/{N} in the rescan map are left untouched.
  README_BODY="$(subst_tokens "$README_BODY" "SITE_NAME=$SITE_NAME" "SCANNED_AT=$SCANNED_AT")"
  write_doc README.md "$README_BODY"
fi

###############################################################################
# Finalize — deltas, changelog, last_scan_at
###############################################################################
print_deltas

# Build a concise summary line for the changelog.
SUMMARY="stage=$STAGE"
if [[ "$STAGE" == "all" || "$STAGE" == "3" ]] && [[ -n "${ATHEME_SLUG:-}" ]]; then
  SUMMARY="$SUMMARY, theme=$ATHEME_SLUG"
fi
append_changelog "[SCAN] Architecture scan completed ($SUMMARY). Docs in \`.wpm/docs/\`."
set_last_scan_at "$SCANNED_AT"

echo
echo "Scan complete."
echo "Config: $CONFIG_FILE"
echo "Tier:   $TIER"
echo "Docs:   $DOCS_DIR/"
echo "Capabilities: $SITE_FOLDER/capabilities.md"
