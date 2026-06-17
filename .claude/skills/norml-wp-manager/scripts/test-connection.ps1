#requires -Version 5.1
<#
.SYNOPSIS
  norml-wp-manager — verify the configured REST API connection and confirm the
  credentials work. Read-only; safe to run any time.

.DESCRIPTION
  Windows mirror of test-connection.sh. Resolves {site_folder}\.wpm\config.json
  by ancestor-walk from the cwd, or use -SiteFolder to skip the walk. Reads
  secret_store.kind, does an anonymous reachability check, then a PSCredential-
  Basic authenticated call. A 403 is split into egress-allowlist (Desktop) vs
  WordPress-capability by env + where the response came from. The credential
  stays a SecureString — never on argv, never a curl.exe -u.

.PARAMETER SiteFolder
  Skip the ancestor-walk; use this folder's .wpm\config.json.
#>

[CmdletBinding()]
param(
  [string]$SiteFolder = ""
)

$ErrorActionPreference = "Stop"
$APP_SLUG = "norml-wp-manager"   # brand-pinned.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- Locate config by ancestor-walk for */.wpm/config.json -----------------
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
  Walked up from $((Get-Location).Path) for */.wpm/config.json
  Pass -SiteFolder <path>, or run setup first.
"@
  exit 1
}

# Credential Manager + shared SecureString / Basic-auth helpers.
. (Join-Path $ScriptDir "lib\credman.ps1")

# ---- Parse config ----------------------------------------------------------
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$Site       = $cfg.site_name
$Url        = ([string]$cfg.production_url).TrimEnd('/')
$WpUser     = $cfg.wp_user
$SecretKind = if ($cfg.secret_store -and $cfg.secret_store.kind) { $cfg.secret_store.kind } else { "" }
$SecretRef  = if ($cfg.secret_store -and $cfg.secret_store.ref)  { $cfg.secret_store.ref }  else { "" }
$EnvVal     = if ($cfg.env) { $cfg.env } else { "unknown" }
$Tier       = if ([string]::IsNullOrWhiteSpace($SecretKind)) { "portable-file" } else { $SecretKind }

Write-Host "Site:           $Site"
Write-Host "URL:            $Url"
Write-Host "Username:       $WpUser"
Write-Host "Environment:    $EnvVal"
Write-Host "Secret source:  $Tier ($SecretRef)"
Write-Host ""

# ---- 1. Anonymous REST root reachable? -------------------------------------
Write-Host "1. REST root reachable (anonymous)?"
$rootCode = 0
try {
  $resp = Invoke-WebRequest -Uri "$Url/wp-json" -Method Get -MaximumRedirection 0 `
    -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
  $rootCode = [int]$resp.StatusCode
} catch {
  if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
    try { $rootCode = [int]$_.Exception.Response.StatusCode.value__ } catch { $rootCode = 0 }
  }
}
if ($rootCode -eq 200) {
  Write-Host "   OK ($rootCode)"
} else {
  Write-Host "   FAIL ($rootCode)" -ForegroundColor Red
  if ($EnvVal -eq "desktop") {
    Write-Host "   On the desktop app this is almost always the EGRESS ALLOWLIST, not WordPress:" -ForegroundColor Red
    Write-Host "     Settings -> Capabilities -> add your site domain to the allowlist." -ForegroundColor Red
  } else {
    Write-Host "   The REST root isn't responding — site down or production_url wrong." -ForegroundColor Red
  }
  exit 1
}

# ---- 2. Application Password works? ----------------------------------------
Write-Host "2. Application Password works?"

$SecurePass = $null
try {
  $SecurePass = Get-WpSecret -Kind $Tier -Ref $SecretRef -WpmDir $WpmDir
} catch {
  Write-Host "   FAIL — could not read the stored credential: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

$me = Invoke-WpRest -Url $Url -Path "/wp-json/wp/v2/users/me?_fields=id,name,roles" `
        -WpUser $WpUser -SecurePassword $SecurePass
$SecurePass = $null

switch ($me.Code) {
  200 {
    Write-Host "   OK ($($me.Code))"
    if ($me.Body) {
      Write-Host "   Identity: id=$($me.Body.id), name=$($me.Body.name), roles=$($me.Body.roles -join ',')"
    }
  }
  401 {
    Write-Host "   FAIL (401 Unauthorized)" -ForegroundColor Red
    Write-Host "   - Check the username in config.json matches your WP login slug." -ForegroundColor Red
    Write-Host "   - The Application Password may be revoked or wrong. Re-run setup." -ForegroundColor Red
    exit 1
  }
  403 {
    # Anon root returned 200 above (network reachable), so a 403 here is a
    # WordPress capability problem — never an egress/allowlist issue.
    Write-Host "   FAIL (403 Forbidden) — the WordPress user lacks the capability." -ForegroundColor Red
    Write-Host "   The anonymous REST root WAS reachable, so this is NOT an egress problem." -ForegroundColor Red
    Write-Host "   Use an account with at least Editor role for this endpoint." -ForegroundColor Red
    exit 1
  }
  default {
    Write-Host "   FAIL ($($me.Code))" -ForegroundColor Red
    if ($me.Raw) { Write-Host ("      " + $me.Raw) -ForegroundColor Red }
    exit 1
  }
}

Write-Host ""
Write-Host "OK. REST API connection working."
