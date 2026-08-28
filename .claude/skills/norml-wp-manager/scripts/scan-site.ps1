#requires -Version 5.1
<#
.SYNOPSIS
  norml-wp-manager — scan the configured WordPress site via REST API on Windows
  and write the five numbered docs into {site_folder}\.wpm\docs\. Read-only —
  safe to run any time the user changes plugins / themes / CPTs / ACF groups.

.DESCRIPTION
  Windows mirror of scan-site.sh. Resolves config by walking up from the cwd for
  */.wpm/config.json (or use -SiteFolder to skip the walk). Stage 0 is always a
  reachability + identity GATE: if it fails, Stages 1–4 do not run and the
  failure is recorded in 00-connection.md + a [SCAN] … ABORTED line in the
  changelog. The credential stays a SecureString end-to-end — never on argv,
  never in a transcript (see lib\credman.ps1).

.PARAMETER SiteFolder
  Skip the ancestor-walk; use this folder's .wpm\config.json.

.PARAMETER Stage
  Which stage(s) to (re)run: 0 | 1 | 2 | 3 | 4 | all. Stage 0 always runs first
  as a gate; the listed stage then runs. Default: all.

.EXAMPLE
  scripts\scan-site.ps1 -SiteFolder C:\Sites\acme -Stage all
#>

[CmdletBinding()]
param(
  [string]$SiteFolder = "",
  [ValidateSet('0','1','2','3','4','all')]
  [string]$Stage = 'all'
)

$ErrorActionPreference = "Stop"
$APP_SLUG = "norml-wp-manager"   # brand-pinned. Drives the OS-vault service name.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- Locate config: ancestor-walk for */.wpm/config.json -------------------

$ConfigFile = $null
$WpmDir     = $null
$SiteFolderResolved = $null

function Resolve-FromFolder([string]$folder) {
  if ([string]::IsNullOrWhiteSpace($folder)) { return $false }
  $folder = $folder.TrimEnd('\', '/')
  $candidate = Join-Path $folder ".wpm\config.json"
  if (Test-Path $candidate) {
    $script:ConfigFile         = $candidate
    $script:WpmDir             = Join-Path $folder ".wpm"
    $script:SiteFolderResolved = $folder
    return $true
  }
  return $false
}

if (-not [string]::IsNullOrWhiteSpace($SiteFolder)) {
  if (-not (Resolve-FromFolder $SiteFolder)) {
    Write-Error "No .wpm\config.json under -SiteFolder: $SiteFolder"
    exit 1
  }
} else {
  $d = (Get-Location).Path
  while ($d) {
    if (Resolve-FromFolder $d) { break }
    $parent = Split-Path $d -Parent
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent
  }
}

if (-not $ConfigFile) {
  Write-Error @"
No norml-wp-manager config found.
  Walked up from $((Get-Location).Path) looking for */.wpm/config.json
  Pass -SiteFolder <path>, or run setup first
  (scripts\setup-windows.ps1 on Console / scripts\setup-portable.ps1 on Desktop/floor).
"@
  exit 1
}

$DocsDir = Join-Path $WpmDir "docs"
if (-not (Test-Path $DocsDir)) { New-Item -ItemType Directory -Force -Path $DocsDir | Out-Null }

# Credential Manager + shared SecureString / Basic-auth helpers.
. (Join-Path $ScriptDir "lib\credman.ps1")

# ---- Parse config ----------------------------------------------------------

$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$SiteName    = $cfg.site_name
$ProdUrl     = ([string]$cfg.production_url).TrimEnd('/')
$WpUser      = $cfg.wp_user
$SecretKind  = if ($cfg.secret_store -and $cfg.secret_store.kind) { $cfg.secret_store.kind } else { "" }
$SecretRef   = if ($cfg.secret_store -and $cfg.secret_store.ref)  { $cfg.secret_store.ref }  else { "" }
$EnvVal      = if ($cfg.env) { $cfg.env } else { "unknown" }

if ([string]::IsNullOrWhiteSpace($ProdUrl)) {
  Write-Error "config.json has no production_url. Re-run setup."
  exit 1
}
if ($ProdUrl -notmatch '^https://' -and
    $ProdUrl -notmatch '^http://localhost' -and
    $ProdUrl -notmatch '^http://127\.0\.0\.1') {
  Write-Error "production_url must be https:// (got '$ProdUrl')."
  exit 1
}

# Tier label (defaults to portable-file when unset).
$Tier = if ([string]::IsNullOrWhiteSpace($SecretKind)) { "portable-file" } else { $SecretKind }

# ---- Secret reader (SecureString; off-argv, off-trace) ---------------------
# Pulled once, reused for every authenticated call this run.
$SecurePass = $null
try {
  $SecurePass = Get-WpSecret -Kind $Tier -Ref $SecretRef -WpmDir $WpmDir
} catch {
  Write-Error "Could not read the stored credential: $($_.Exception.Message)"
  exit 1
}

# ---- Authenticated call wrappers (curry the per-run constants) -------------
function RestGet([string]$path) {
  $r = Invoke-WpRest -Url $ProdUrl -Path $path -WpUser $WpUser -SecurePassword $SecurePass
  if ($r.Ok) { return $r.Body }
  return $null
}
function RestTotal([string]$path) {
  return (Get-WpTotal -Url $ProdUrl -Path $path -WpUser $WpUser -SecurePassword $SecurePass)
}
function RestAllow([string]$path) {
  return (Get-WpAllow -Url $ProdUrl -Path $path -WpUser $WpUser -SecurePassword $SecurePass)
}

# Anonymous probe — no credentials. Returns @{ Code; Body(parsed or $null); Raw }.
function AnonProbe([string]$path) {
  $full = "$ProdUrl$path"
  $out = @{ Code = 0; Body = $null; Raw = ""; Time = $null }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = Invoke-WebRequest -Uri $full -Method Get -MaximumRedirection 0 `
      -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
    $sw.Stop()
    $out.Code = [int]$resp.StatusCode
    $out.Raw  = if ($null -ne $resp.Content) { [string]$resp.Content } else { "" }
    $out.Time = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    if ($out.Raw) { try { $out.Body = $out.Raw | ConvertFrom-Json } catch { $out.Body = $null } }
  } catch {
    $sw.Stop()
    $out.Time = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    $code = 0
    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
      try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { $code = 0 }
    }
    $out.Code = $code
  }
  if (-not $out.Code) { $out.Code = 0 }
  return $out
}

$ScannedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# ---- Template helper -------------------------------------------------------
$TplRootDir = $null
$rootMaybe = Join-Path $ScriptDir "..\templates"
if (Test-Path $rootMaybe) { $TplRootDir = (Resolve-Path $rootMaybe).Path }
$TplDocsDir = $null
$maybe = Join-Path $ScriptDir "..\templates\docs"
if (Test-Path $maybe) { $TplDocsDir = (Resolve-Path $maybe).Path }

# Read a doc template if present, else use the inline fallback body.
function Get-TplOrInline([string]$tplBasename, [string]$inline) {
  if ($TplDocsDir) {
    $tpl = Join-Path $TplDocsDir $tplBasename
    if (Test-Path $tpl) { return (Get-Content $tpl -Raw) }
  }
  return $inline
}

function Get-RootTplOrInline([string]$tplBasename, [string]$inline) {
  if ($TplRootDir) {
    $tpl = Join-Path $TplRootDir $tplBasename
    if (Test-Path $tpl) { return (Get-Content $tpl -Raw) }
  }
  return $inline
}

# Literal-token substitution (the PS analogue of bash subst_tokens): replace
# every "{KEY}" with VALUE. Uses .Replace (literal, no regex) so values that
# contain regex metacharacters or "$" are safe.
function Expand-Tokens([string]$body, [hashtable]$pairs) {
  foreach ($k in $pairs.Keys) {
    $v = [string]$pairs[$k]
    $body = $body.Replace("{$k}", $v)
  }
  return $body
}

# ---- Diff-before-overwrite -------------------------------------------------
$script:Deltas = New-Object System.Collections.Generic.List[string]
function Write-Doc([string]$name, [string]$content) {
  $path = Join-Path $DocsDir $name
  if (Test-Path $path) {
    $existing = Get-Content $path -Raw
    # Normalize trailing newline differences for the comparison only.
    if ($existing.TrimEnd("`r","`n") -eq $content.TrimEnd("`r","`n")) {
      $script:Deltas.Add("${name}: unchanged")
      return
    }
  }
  Set-Content -Path $path -Value $content -Encoding UTF8
  $script:Deltas.Add("${name}: written")
  Write-Host "Wrote $path"
}

function Write-SiteDoc([string]$name, [string]$content) {
  $path = Join-Path $SiteFolderResolved $name
  if (Test-Path $path) {
    $existing = Get-Content $path -Raw
    if ($existing.TrimEnd("`r","`n") -eq $content.TrimEnd("`r","`n")) {
      $script:Deltas.Add("${name}: unchanged")
      return
    }
  }
  Set-Content -Path $path -Value $content -Encoding UTF8
  $script:Deltas.Add("${name}: written")
  Write-Host "Wrote $path"
}

$GeneratedHdr = "<!-- GENERATED by norml-wp-manager scan-site — DO NOT EDIT BY HAND. Rescan overwrites this file. -->"

# ---- changelog append + last_scan_at ---------------------------------------
$Chlog = Join-Path $SiteFolderResolved "changelog.md"

function Add-ChangelogLine([string]$body) {
  if (-not (Test-Path $Chlog)) { return }
  $today = Get-Date -Format "yyyy-MM-dd"
  $time  = Get-Date -Format "HH:mm"
  $line  = "- $time — $body"
  $content = Get-Content $Chlog -Raw
  $headingPattern = "(?m)^## " + [regex]::Escape($today) + "(?: .*)?$"
  $m = [regex]::Match($content, $headingPattern)
  if ($m.Success) {
    # Insert right after the heading line and any blank lines following it.
    $at = $m.Index + $m.Length
    while ($at -lt $content.Length -and ($content[$at] -eq "`n" -or $content[$at] -eq "`r")) { $at++ }
    $content = $content.Substring(0, $at) + $line + "`n" + $content.Substring($at)
  } else {
    $first = [regex]::Match($content, "(?m)^## ")
    $block = "## $today — Session`n`n$line`n`n"
    if ($first.Success) {
      $content = $content.Substring(0, $first.Index) + $block + $content.Substring($first.Index)
    } else {
      $content = $content.TrimEnd() + "`n`n" + $block
    }
  }
  Set-Content -Path $Chlog -Value $content -Encoding UTF8
  Write-Host "Logged changelog entry to $Chlog"
}

function Set-LastScanAt([string]$ts) {
  try {
    $j = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if ($j.PSObject.Properties['last_scan_at']) {
      $j.last_scan_at = $ts
    } else {
      $j | Add-Member -NotePropertyName last_scan_at -NotePropertyValue $ts -Force
    }
    ($j | ConvertTo-Json -Depth 10) | Set-Content -Path $ConfigFile -Encoding UTF8
  } catch {
    Write-Warning "Could not update last_scan_at in config.json: $($_.Exception.Message)"
  }
}

function Show-Deltas {
  Write-Host ""
  Write-Host "Per-doc deltas:"
  foreach ($x in $script:Deltas) { Write-Host "  - $x" }
}

###############################################################################
# STAGE 0 — Reachability + identity (GATE; always first)
###############################################################################

Write-Host "Scanning $SiteName ($ProdUrl) — stage=$Stage, env=$EnvVal"
Write-Host ""
Write-Host "Stage 0 — reachability + identity (gate)..."

$GateAbort = ""   # set to a reason string on failure

# 0a — anonymous reachability probe of the REST root.
$rootProbe = AnonProbe "/wp-json"
$AnonCode  = $rootProbe.Code
$AnonTime  = $rootProbe.Time
$RootObj   = $rootProbe.Body

if ($AnonCode -eq 200) {
  # Confirm it is real WP REST JSON, not an HTML 200.
  $hasNs = $RootObj -and ($RootObj.PSObject.Properties['namespaces'] -or $RootObj.PSObject.Properties['routes'])
  if (-not $hasNs) {
    $GateAbort = "unreachable"
    Write-Host "  Anon GET /wp-json returned 200 but not REST JSON (wrong URL or REST disabled)." -ForegroundColor Red
  }
} else {
  if ($EnvVal -eq "desktop") {
    $GateAbort = "egress-blocked"
    Write-Host "  Anon GET /wp-json failed ($AnonCode)." -ForegroundColor Red
    Write-Host "  On the desktop app this is almost always the EGRESS ALLOWLIST, not WordPress." -ForegroundColor Red
    Write-Host "  Fix: Settings -> Capabilities -> add your site domain to the allowlist, then re-run." -ForegroundColor Red
  } else {
    $GateAbort = "unreachable"
    Write-Host "  Anon GET /wp-json failed ($AnonCode) — site down or production_url wrong." -ForegroundColor Red
  }
}

# 0b — authenticated identity (only if reachable).
$WpDisplayName = ""; $ConnectedRoles = ""; $WpUserId = ""
if (-not $GateAbort) {
  $me = RestGet "/wp-json/wp/v2/users/me?_fields=id,name,roles"
  if ($me) {
    $WpDisplayName = [string]$me.name
    $WpUserId      = [string]$me.id
    if ($me.roles) { $ConnectedRoles = ($me.roles -join ',') }
  }
  if ([string]::IsNullOrWhiteSpace($WpDisplayName) -and [string]::IsNullOrWhiteSpace($WpUserId)) {
    $GateAbort = "auth-failed"
    Write-Host "  Authenticated GET /wp/v2/users/me returned no identity." -ForegroundColor Red
    if ($EnvVal -eq "desktop") {
      Write-Host "  Anon probe passed, so this is a WordPress auth issue (not egress):" -ForegroundColor Red
    }
    Write-Host "  Check the username (login slug) and the Application Password; re-run setup if needed." -ForegroundColor Red
  }
}

$RolesDisp = if ($ConnectedRoles) { $ConnectedRoles } else { "—" }

# Per-field display strings the 00 template expects.
$AnonProbeStatus = if ($AnonCode -eq 200) { "200" } else { "HTTP $AnonCode" }
$AnonProbeTime   = if ($AnonTime) { "$($AnonTime)s" } else { "n/a" }
switch ($GateAbort) {
  "egress-blocked" { $AnonProbeResult = "BLOCKED — egress allowlist (Settings -> Capabilities)"; $AuthResult = "not attempted — egress blocked" }
  "unreachable"    { $AnonProbeResult = "UNREACHABLE — site down or wrong URL / REST disabled";   $AuthResult = "not attempted — unreachable" }
  "auth-failed"    { $AnonProbeResult = "reachable (REST alive)";                                  $AuthResult = "FAILED — no identity returned" }
  default          { $AnonProbeResult = "reachable (REST alive)";                                  $AuthResult = "OK (200)" }
}

# Minimal token-complete inline fallback (used only if the template is absent).
$connInline = @"
$GeneratedHdr
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
"@

$connBody = Get-TplOrInline "00-connection-template.md" $connInline
$connOut  = Expand-Tokens $connBody @{
  SITE_NAME         = $SiteName
  SCANNED_AT        = $ScannedAt
  PROD_URL          = $ProdUrl
  ENV               = $EnvVal
  SECRET_KIND       = $Tier
  SECRET_REF        = $SecretRef
  ANON_PROBE_STATUS = $AnonProbeStatus
  ANON_PROBE_TIME   = $AnonProbeTime
  ANON_PROBE_RESULT = $AnonProbeResult
  WP_USER           = $WpUser
  WP_DISPLAY_NAME   = $(if ($WpDisplayName) { $WpDisplayName } else { "—" })
  WP_USER_ID        = $(if ($WpUserId) { $WpUserId } else { "—" })
  ROLES             = $RolesDisp
  AUTH_RESULT       = $AuthResult
}
Write-Doc "00-connection.md" $connOut

# Hard-stop on a Stage-0 gate failure — never run 1–4, never swallow the 403.
if ($GateAbort) {
  Show-Deltas
  Add-ChangelogLine "[SCAN] Scan ABORTED at gate: $GateAbort. See ``.wpm/docs/00-connection.md``."
  try { Set-LastScanAt $ScannedAt } catch { }
  Write-Host ""
  Write-Host "Scan ABORTED at Stage-0 gate: $GateAbort" -ForegroundColor Red
  switch ($GateAbort) {
    "egress-blocked" { Write-Host "Resolve the egress allowlist (Settings -> Capabilities), then re-run." -ForegroundColor Red }
    "unreachable"    { Write-Host "Verify the site is up and production_url is correct, then re-run." -ForegroundColor Red }
    "auth-failed"    { Write-Host "Verify the username + Application Password, then re-run." -ForegroundColor Red }
  }
  exit 1
}

$rolesReport = if ($ConnectedRoles) { $ConnectedRoles } else { "no roles reported" }
$whoReport   = if ($WpDisplayName) { $WpDisplayName } else { $WpUser }
Write-Host "  Gate OK — connected as $whoReport ($rolesReport)."

# The shared header tokens every generated doc carries (same italic line).
$HdrPairs = @{
  SITE_NAME   = $SiteName
  SCANNED_AT  = $ScannedAt
  WP_USER     = $WpUser
  ROLES       = $RolesDisp
  SECRET_KIND = $Tier
  ENV         = $EnvVal
}

function Merge-Pairs([hashtable]$extra) {
  $out = @{}
  foreach ($k in $HdrPairs.Keys) { $out[$k] = $HdrPairs[$k] }
  foreach ($k in $extra.Keys)    { $out[$k] = $extra[$k] }
  return $out
}

function Test-RunStage([string]$n) { return ($Stage -eq 'all' -or $Stage -eq $n) }

# Track REST-exposed CPT rest_bases (filled in Stage 2, consumed by Stage 4).
$RestCpts = @()
# Track the active theme slug for the changelog summary line.
$AThemeSlug = ""

###############################################################################
# STAGE 1 — Site basics
###############################################################################
if (Test-RunStage '1') {
  Write-Host "Stage 1 — site basics..."
  $settings = RestGet "/wp-json/wp/v2/settings"
  $siteTitle = if ($settings) { [string]$settings.title } else { "" }
  $siteDesc  = if ($settings) { [string]$settings.description } else { "" }
  $siteLang  = if ($settings) { [string]$settings.language } else { "" }
  $ppp       = if ($settings) { [string]$settings.posts_per_page } else { "" }
  $sow       = if ($settings) { [string]$settings.start_of_week } else { "" }
  $dpf       = if ($settings) { [string]$settings.default_post_format } else { "" }

  # Fall back to anon root description / name when settings are admin-gated.
  if (-not $siteTitle -and $RootObj) { $siteTitle = [string]$RootObj.name }
  if (-not $siteDesc  -and $RootObj) { $siteDesc  = [string]$RootObj.description }
  $gmtOffset = if ($RootObj -and $RootObj.PSObject.Properties['gmt_offset']) { [string]$RootObj.gmt_offset } else { "" }

  $namespaces = ""
  if ($RootObj -and $RootObj.namespaces) { $namespaces = ($RootObj.namespaces -join "`n") }

  # WP version best-effort: the REST root rarely carries it; mark approximate.
  $wpVersion = if ($RootObj) { [string]$RootObj.description } else { "" }
  if ($wpVersion) {
    $wpVersionSource = "REST root description (approximate)"
  } else {
    $wpVersion = "unknown (not exposed over REST)"
    $wpVersionSource = "not detectable via REST"
  }

  # Multisite hint from namespace presence.
  if ($namespaces -match '(?i)wp-site-health|wp/v2/sites') {
    $multisiteHint = "possible (network routes present)"
  } else {
    $multisiteHint = "single-site (no network routes seen)"
  }

  if (-not $siteLang) {
    $settingsNote = "GET /wp/v2/settings not visible at this role — admin-only fields fall back to the anonymous subset."
  } else {
    $settingsNote = "Settings read from /wp/v2/settings (admin)."
  }

  $s1Inline = @"
$GeneratedHdr
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

``````
{NAMESPACES}
``````

### What REST cannot see here
- Exact WordPress core version; PHP / MySQL / server stack.
- ``wp-config.php`` constants; most of ``wp_options``.
"@
  $s1Body = Get-TplOrInline "01-site-template.md" $s1Inline
  $s1Out  = Expand-Tokens $s1Body (Merge-Pairs @{
    SITE_TITLE          = $(if ($siteTitle) { $siteTitle } else { "?" })
    SITE_DESC           = $(if ($siteDesc) { $siteDesc } else { "?" })
    SITE_LANG           = $(if ($siteLang) { $siteLang } else { "not visible at this role" })
    GMT_OFFSET          = $(if ($gmtOffset) { $gmtOffset } else { "?" })
    POSTS_PER_PAGE      = $(if ($ppp) { $ppp } else { "?" })
    START_OF_WEEK       = $(if ($sow) { $sow } else { "?" })
    DEFAULT_POST_FORMAT = $(if ($dpf) { $dpf } else { "standard" })
    WP_VERSION          = $wpVersion
    WP_VERSION_SOURCE   = $wpVersionSource
    MULTISITE_HINT      = $multisiteHint
    SETTINGS_NOTE       = $settingsNote
    NAMESPACES          = $(if ($namespaces) { $namespaces } else { "(none reported)" })
  })
  Write-Doc "01-site.md" $s1Out
}

###############################################################################
# STAGE 2 — Content model
###############################################################################
if (Test-RunStage '2') {
  Write-Host "Stage 2 — content model..."
  $types = RestGet "/wp-json/wp/v2/types"
  $taxes = RestGet "/wp-json/wp/v2/taxonomies"

  $coreBases = @('posts','pages','media','blocks','navigation','wp_template','wp_template_part','menu-items')

  $postTypeRows = ""
  if ($types) {
    foreach ($prop in $types.PSObject.Properties) {
      $slug = $prop.Name
      $info = $prop.Value
      $rb   = [string]$info.rest_base
      $rest = if ($rb) { "yes" } else { "no" }
      $hier = if ($info.hierarchical) { "yes" } else { "no" }
      $view = if ($info.viewable) { "yes" } else { "no" }
      $postTypeRows += "$slug,$($info.name),$rb,$rest,$hier,$view`n"
      if ($rb -and ($coreBases -notcontains $rb)) { $RestCpts += $rb }
    }
    $postTypeRows = $postTypeRows.TrimEnd("`n")
  }

  $taxonomyRows = ""
  if ($taxes) {
    foreach ($prop in $taxes.PSObject.Properties) {
      $slug = $prop.Name
      $info = $prop.Value
      $rb   = [string]$info.rest_base
      $rest = if ($rb) { "yes" } else { "no" }
      $hier = if ($info.hierarchical) { "yes" } else { "no" }
      $tt   = if ($info.types) { ($info.types -join ",") } else { "" }
      $taxonomyRows += "$slug,$($info.name),$rb,$rest,$hier,`"$tt`"`n"
    }
    $taxonomyRows = $taxonomyRows.TrimEnd("`n")
  }

  if (-not $postTypeRows) {
    $postTypeRows = "(not visible at this role)"
    $postTypeNote = "Type list not visible at this role."
  } else {
    $postTypeNote = "Types with rest_exposed=no cannot be touched over REST."
  }
  if (-not $taxonomyRows) {
    $taxonomyRows = "(not visible at this role)"
    $taxonomyNote = "Taxonomy list not visible at this role."
  } else {
    $taxonomyNote = "Taxonomies with rest_exposed=no cannot be touched over REST."
  }

  $postCount = RestTotal "/wp-json/wp/v2/posts?per_page=1&status=publish"
  $pageCount = RestTotal "/wp-json/wp/v2/pages?per_page=1&status=publish"

  $cptCountRows = ""
  foreach ($rb in $RestCpts) {
    $c = RestTotal "/wp-json/wp/v2/$rb`?per_page=1&status=publish"
    $cptCountRows += "| $rb | $c |`n"
  }
  if (-not $cptCountRows) {
    $cptCountRows = "| (no REST-exposed CPTs) | — |"
  } else {
    $cptCountRows = $cptCountRows.TrimEnd("`n")
  }

  $s2Inline = @"
$GeneratedHdr
# 02 — Content model — {SITE_NAME}

_Scanned: {SCANNED_AT} · Connected as: {WP_USER} ({ROLES}) · Tier: {SECRET_KIND} · env: {ENV}_

## Post types
``````csv
slug,name,rest_base,rest_exposed,hierarchical,viewable
{POST_TYPE_ROWS}
``````
> {POST_TYPE_NOTE}

## Taxonomies
``````csv
slug,name,rest_base,rest_exposed,hierarchical,attached_to
{TAXONOMY_ROWS}
``````
> {TAXONOMY_NOTE}

## Content counts
| Type | Published |
|---|---|
| Posts | {POST_COUNT} |
| Pages | {PAGE_COUNT} |
{CPT_COUNT_ROWS}

### What REST cannot see here
- CPTs / taxonomies with ``show_in_rest:false`` are invisible to REST entirely.
"@
  $s2Body = Get-TplOrInline "02-content-model-template.md" $s2Inline
  $s2Out  = Expand-Tokens $s2Body (Merge-Pairs @{
    POST_TYPE_ROWS = $postTypeRows
    POST_TYPE_NOTE = $postTypeNote
    TAXONOMY_ROWS  = $taxonomyRows
    TAXONOMY_NOTE  = $taxonomyNote
    POST_COUNT     = $postCount
    PAGE_COUNT     = $pageCount
    CPT_COUNT_ROWS = $cptCountRows
  })
  Write-Doc "02-content-model.md" $s2Out
}

###############################################################################
# STAGE 3 — Plugins + theme
###############################################################################
if (Test-RunStage '3') {
  Write-Host "Stage 3 — plugins + theme..."
  $plugins = RestGet "/wp-json/wp/v2/plugins?_fields=plugin,name,status,version"
  $themes  = RestGet "/wp-json/wp/v2/themes"

  $nsAll = ""
  if ($RootObj -and $RootObj.namespaces) { $nsAll = ($RootObj.namespaces -join "`n") }

  # Plugin rows + active-plugin slug list for detection.
  $pluginRows = ""
  $activeSlugs = @()
  $pluginCount = 0
  if ($plugins -is [array]) {
    foreach ($p in $plugins) {
      $pluginRows += "$($p.plugin),$($p.name),$($p.status),$($p.version)`n"
      $pluginCount++
      if ($p.status -eq "active") { $activeSlugs += [string]$p.plugin }
    }
    $pluginRows = $pluginRows.TrimEnd("`n")
  }

  # Active theme.
  $aThemeName = ""; $aThemeVer = ""
  if ($themes) {
    foreach ($t in @($themes)) {
      if ($t.status -eq "active") {
        $nm = $t.name
        if ($nm -is [pscustomobject] -and $nm.rendered) { $nm = $nm.rendered }
        $AThemeSlug = [string]$t.stylesheet
        $aThemeVer  = [string]$t.version
        $aThemeName = [string]$nm
        break
      }
    }
  }
  if ($AThemeSlug) {
    $activeThemeDisp = "$aThemeName ($AThemeSlug)"
    $activeThemeVerDisp = $(if ($aThemeVer) { $aThemeVer } else { "—" })
    $themeNote = "From GET /wp/v2/themes (admin)."
  } else {
    $activeThemeDisp = "not visible at this role"
    $activeThemeVerDisp = "—"
    $themeNote = "Theme inventory needs admin; only namespace hints remain."
  }

  if ($pluginCount -le 0) {
    $pluginRows = "(not visible at this role)"
    $pluginsNote = "Plugin list needs admin. Detected key plugins below are inferred from REST namespaces."
  } else {
    $pluginsNote = "From GET /wp/v2/plugins (admin)."
  }

  # Key-plugin detection: prefer the inventory's active slugs, fall back to namespaces.
  function Find-KeyPlugin([string]$invRegex, [string]$nsRegex) {
    $hit = ""
    foreach ($slug in $activeSlugs) {
      $m = [regex]::Match($slug, $invRegex)
      if ($m.Success) { $hit = $m.Value; break }
    }
    if (-not $hit -and $nsRegex) {
      $m = [regex]::Match($nsAll, "(?im)$nsRegex")
      if ($m.Success) { $hit = $m.Value }
    }
    return $hit
  }

  $pageBuilder = Find-KeyPlugin 'elementor|bricks|beaver-builder-lite-version|bb-plugin|js_composer|divi-builder' 'elementor|bricks|beaver'
  $seoPlugin   = Find-KeyPlugin 'wordpress-seo|seo-by-rank-math|wp-seopress|all-in-one-seo-pack' 'rankmath|yoast|seopress'
  $cachePlugin = Find-KeyPlugin 'wp-rocket|w3-total-cache|litespeed-cache|wp-super-cache|wp-fastest-cache' 'litespeed'
  $acfStatus   = Find-KeyPlugin 'advanced-custom-fields' 'acf'
  $ecommerce   = Find-KeyPlugin 'woocommerce|easy-digital-downloads' 'wc/|edd'
  $multilingual= Find-KeyPlugin 'sitepress-multilingual-cms|polylang|weglot' 'wpml|pll'

  # Third-party admin agents from active plugin slugs.
  $agentMatches = @()
  foreach ($slug in $activeSlugs) {
    $m = [regex]::Matches($slug, 'worker|jetpack|ithemes-sync|managewp|mainwp-child|wpremote')
    foreach ($mm in $m) { $agentMatches += $mm.Value }
  }
  $agents = if ($agentMatches.Count -gt 0) { (($agentMatches | Select-Object -Unique) -join ',') } else { "" }

  if (-not $pageBuilder)  { $pageBuilder  = "none detected" }
  if (-not $seoPlugin)    { $seoPlugin    = "none detected" }
  if (-not $cachePlugin)  { $cachePlugin  = "none detected" }
  if (-not $ecommerce)    { $ecommerce    = "none detected" }
  if (-not $multilingual) { $multilingual = "none detected" }
  if (-not $acfStatus)    { $acfStatus    = "not detected" }
  if (-not $agents)       { $agents       = "none detected" }

  $s3Inline = @"
$GeneratedHdr
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
``````csv
plugin,name,status,version
{PLUGIN_ROWS}
``````

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
``````
{THIRD_PARTY_AGENTS}
``````

### What REST cannot see here
- Theme file tree, plugin settings in ``wp_options``, mu-plugins / dropins.
"@
  $s3Body = Get-TplOrInline "03-plugins-theme-template.md" $s3Inline
  $s3Out  = Expand-Tokens $s3Body (Merge-Pairs @{
    ACTIVE_THEME         = $activeThemeDisp
    ACTIVE_THEME_VERSION = $activeThemeVerDisp
    THEME_NOTE           = $themeNote
    PLUGINS_NOTE         = $pluginsNote
    PLUGIN_ROWS          = $pluginRows
    PAGE_BUILDER         = $pageBuilder
    SEO_PLUGIN           = $seoPlugin
    CACHE_PLUGIN         = $cachePlugin
    ACF_STATUS           = $acfStatus
    ECOMMERCE_PLUGIN     = $ecommerce
    MULTILINGUAL_PLUGIN  = $multilingual
    THIRD_PARTY_AGENTS   = $agents
  })
  Write-Doc "03-plugins-theme.md" $s3Out
}

###############################################################################
# STAGE 4 — REST capability map (derived)
###############################################################################
if (Test-RunStage '4') {
  Write-Host "Stage 4 — REST capability map..."

  function Get-CapRow([string]$surface, [string]$restBase) {
    $allow = RestAllow "/wp-json/wp/v2/$restBase"
    $read = "no"; $create = "no"; $update = "no"; $delete = "no"
    if ($allow -eq "?") {
      $read = "?"; $create = "?"; $update = "?"; $delete = "?"
    } else {
      if ($allow -match 'GET')           { $read = "yes" }
      if ($allow -match 'POST')          { $create = "yes" }
      if ($allow -match 'PUT|PATCH')     { $update = "yes" }
      if ($allow -match 'DELETE')        { $delete = "yes" }
    }
    return "$surface,$restBase,$read,$create,$update,$delete"
  }

  $capRows = @()
  $capRows += Get-CapRow "posts" "posts"
  $capRows += Get-CapRow "pages" "pages"
  $capRows += Get-CapRow "media" "media"
  foreach ($rb in $RestCpts) { $capRows += Get-CapRow $rb $rb }
  $capabilityRows = ($capRows -join "`n")

  $adminCount = RestTotal "/wp-json/wp/v2/users?per_page=1&roles=administrator"
  if ($adminCount -eq "?") {
    $adminCountNote = "Administrator count not visible at this role (need admin)."
  } elseif ($adminCount -match '^\d+$' -and [int]$adminCount -gt 3) {
    $adminCountNote = "$adminCount administrators is a lot for one site — consider trimming."
  } else {
    $adminCountNote = "From HEAD /wp/v2/users?roles=administrator (X-WP-Total)."
  }

  $knownBlockers = @"
- Plugin install / update / activate is disabled on most managed hosts over REST.
- ACF field values are writable over REST only if the field group has ``show_in_rest:true``.
- RankMath per-post meta is REST-writable only if registered with ``show_in_rest:true``.
- WordPress core updates are out of REST scope.
- Any surface with ``rest_exposed=no`` in 02-content-model.md is unreachable here.
"@

  $s4Inline = @"
$GeneratedHdr
# 04 — REST capabilities — {SITE_NAME}

_Scanned: {SCANNED_AT} · Connected as: {WP_USER} ({ROLES}) · Tier: {SECRET_KIND} · env: {ENV}_

## Writability matrix (at the connected role: {ROLES})
``````csv
surface,rest_base,read,create,update,delete
{CAPABILITY_ROWS}
``````

## Administrator count
| Field | Value |
|---|---|
| Administrator users | {ADMIN_COUNT} |
> {ADMIN_COUNT_NOTE}

## Known blockers
{KNOWN_BLOCKERS}

## What REST cannot see (master list)
- Exact WP core version; PHP/MySQL/server stack; ``wp-config.php`` constants; cron.
- Theme internals; ACF field-group definitions; page-builder blobs; plugin settings.
- **CPTs / taxonomies with ``show_in_rest:false`` are invisible to REST entirely.**
"@
  $s4Body = Get-TplOrInline "04-rest-capabilities-template.md" $s4Inline
  $s4Out  = Expand-Tokens $s4Body (Merge-Pairs @{
    CAPABILITY_ROWS = $capabilityRows
    ADMIN_COUNT     = $adminCount
    ADMIN_COUNT_NOTE= $adminCountNote
    KNOWN_BLOCKERS  = $knownBlockers.TrimEnd("`r","`n")
  })
  Write-Doc "04-rest-capabilities.md" $s4Out

  $publicCapabilitiesBody = Get-RootTplOrInline "capabilities-template.md" $s4Inline
  $publicCapabilitiesOut = Expand-Tokens $publicCapabilitiesBody (Merge-Pairs @{
    CAPABILITY_ROWS = $capabilityRows
    ADMIN_COUNT = $adminCount
    ADMIN_COUNT_NOTE = $adminCountNote
    KNOWN_BLOCKERS = $knownBlockers.TrimEnd("`r","`n")
  })
  Write-SiteDoc "capabilities.md" $publicCapabilitiesOut
}

###############################################################################
# docs/README.md — index (only on a full scan)
###############################################################################
if ($Stage -eq 'all') {
  $readmeInline = @"
$GeneratedHdr
# .wpm/docs — generated site scan

Auto-written by ``scripts/scan-site.ps1``. **Do not hand-edit** — rescans overwrite these.
Curated, hand-editable knowledge lives one level up in ``../../project-notes.md`` and ``../../changelog.md``.

| File | Contents |
|---|---|
| 00-connection.md | env, network-gate result, auth, user + roles, secret pointer, last scan |
| 01-site.md | WP version (best-effort), settings, REST namespaces |
| 02-content-model.md | post types (per-type show_in_rest), taxonomies, counts |
| 03-plugins-theme.md | active theme, plugin inventory, 3rd-party agents |
| 04-rest-capabilities.md | writability matrix + blockers + "What REST cannot see" |

## Rescan map (``scan-site.ps1 -SiteFolder {path} -Stage N``)

Stage 0 always re-runs first as a reachability gate.

| You say | Stage |
|---|---|
| rescan my site / refresh architecture | all |
| recheck connection / is my site reachable | 0 |
| refresh site basics | 1 |
| redo content model / I added a CPT | 2 |
| rescan plugins / re-check the theme | 3 |
| recheck what I can edit over REST | 4 |
"@
  $readmeBody = Get-TplOrInline "readme-template.md" $readmeInline
  # Substitute only safe per-site tokens; literal {path}/{N} are left untouched.
  $readmeBody = Expand-Tokens $readmeBody @{ SITE_NAME = $SiteName; SCANNED_AT = $ScannedAt }
  Write-Doc "README.md" $readmeBody
}

###############################################################################
# Finalize — deltas, changelog, last_scan_at
###############################################################################
Show-Deltas

$summary = "stage=$Stage"
if (($Stage -eq 'all' -or $Stage -eq '3') -and $AThemeSlug) {
  $summary = "$summary, theme=$AThemeSlug"
}
Add-ChangelogLine "[SCAN] Architecture scan completed ($summary). Docs in ``.wpm/docs/``."
Set-LastScanAt $ScannedAt

# Best-effort: drop the in-memory SecureString reference.
$SecurePass = $null

Write-Host ""
Write-Host "Scan complete."
Write-Host "Config: $ConfigFile"
Write-Host "Tier:   $Tier"
Write-Host "Docs:   $DocsDir\"
Write-Host "Capabilities: $(Join-Path $SiteFolderResolved 'capabilities.md')"
