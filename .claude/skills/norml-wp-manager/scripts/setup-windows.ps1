#requires -Version 5.1
<#
.SYNOPSIS
  norml-wp-manager — first-time setup on Windows Console (Claude Code).

.DESCRIPTION
  Windows mirror of setup-macos.sh. Collects WordPress site details + a chosen
  site folder, walks the user through generating an Application Password, stores
  it in Windows Credential Manager via inline Win32 P/Invoke (NO PowerShell
  modules — see lib\credman.ps1), tests the REST API, and runs the initial scan.

  All per-site state lives in ONE site folder:
    {site_folder}\  → README.md + project-notes.md + changelog.md + .wpm\
  NOTHING is written to ~/.config (or %USERPROFILE%\.config) — ever. The config
  JSON holds no secrets; the Credential Manager target is norml-wp-manager-{site}.

  If Windows Credential Manager is not usable on this host (P/Invoke round-trip
  fails), or the network is behind a default-deny egress allowlist (the desktop
  sandbox), this script hands off to setup-portable.ps1 (the floor tier).

.PARAMETER SiteFolder
  Optional. The site folder to create / use. Defaults to %USERPROFILE%\Sites\<site>.
#>

[CmdletBinding()]
param(
  [string]$SiteFolder = ""
)

$ErrorActionPreference = "Stop"
$APP_SLUG = "norml-wp-manager"   # brand-pinned. Cred Manager target = $APP_SLUG-{site}.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ----- Helpers -------------------------------------------------------------

function Write-Bold($text) { Write-Host $text -ForegroundColor White }
function Write-Info($text) { Write-Host "  $text" }
function Write-Warn($text) { Write-Host "  $text" -ForegroundColor Yellow }
function Write-Err($text)  { Write-Host "  $text" -ForegroundColor Red }

function Ask($prompt, $default = $null) {
  if ($default) {
    $val = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $default }
    return $val
  } else {
    return (Read-Host $prompt)
  }
}

# Windows Credential Manager helpers + shared SecureString / Basic-auth model.
. (Join-Path $ScriptDir "lib\credman.ps1")

# ----- Egress probe — separates real Console from a sandbox ----------------
# Neutral host (NOT anthropic.com — allowlisted in sandboxes). 200/30x → open.
function Test-EgressOpen {
  try {
    $resp = Invoke-WebRequest -Uri "https://example.com" -Method Head -TimeoutSec 8 `
      -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
    return ([int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 400)
  } catch {
    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
      try {
        $c = [int]$_.Exception.Response.StatusCode.value__
        if ($c -ge 200 -and $c -lt 400) { return $true }
      } catch { }
    }
    return $false
  }
}

# ----- Guard: refuse dangerous / cloud-synced site-folder locations --------
function Test-SiteFolderGuard([string]$f) {
  $userHome = $env:USERPROFILE
  $forbidden = @(
    $userHome, $env:SystemDrive + "\", "C:\", $env:windir,
    (Join-Path $userHome ".config"), (Join-Path $userHome ".claude"),
    (Join-Path $userHome "AppData")
  )
  foreach ($bad in $forbidden) {
    if ($bad -and ($f.TrimEnd('\') -ieq $bad.TrimEnd('\'))) {
      Write-Err "Refusing to use '$f' as a site folder (system / home / config location)."
      return $false
    }
  }
  $skillRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
  if (($f.TrimEnd('\') + '\') -like ($skillRoot.TrimEnd('\') + '\*') -or
      ($f.TrimEnd('\') -ieq $skillRoot.TrimEnd('\'))) {
    Write-Err "Refusing to place the site folder inside the skill directory ($skillRoot)."
    Write-Err "Skill updates would erase it. Pick a folder elsewhere."
    return $false
  }
  $cloudPatterns = @('*\Dropbox\*','*\OneDrive*','*\Google Drive\*','*\iCloudDrive\*','*\Box\*','*CloudStorage*')
  foreach ($pat in $cloudPatterns) {
    if ($f -like $pat) {
      Write-Warn "This folder is inside a cloud-sync tree."
      Write-Warn "Your password is in Windows Credential Manager (not synced), but the docs"
      Write-Warn "folder will be. That's fine — just know the folder's contents may upload"
      Write-Warn "to a third-party cloud."
      $yn = Ask "Use this cloud-synced folder anyway? (Y/n)" "Y"
      if ($yn -match '^[Nn]$') { Write-Err "Aborted — pick a non-synced folder."; return $false }
      break
    }
  }
  return $true
}

# ----- Banner --------------------------------------------------------------

Write-Bold "$APP_SLUG setup — Windows Console"
Write-Host ""
Write-Host "This will:"
Write-Info "1. Ask where to keep this site's folder"
Write-Info "2. Collect your WordPress site URL and admin/editor username"
Write-Info "3. Pause while you generate an Application Password in wp-admin"
Write-Info "4. Store that password in Windows Credential Manager (via a dialog)"
Write-Info "5. Test the REST API connection"
Write-Info "6. Scan your WordPress install into {site_folder}\.wpm\docs\"
Write-Host ""
Read-Host "Press Enter to continue, Ctrl-C to cancel"

# Environment check — replaces the old "is ~/.config writable?" probe.
# If the network is behind a default-deny allowlist, this is the desktop
# sandbox → use the portable/floor path (no Credential Manager there either).
if (-not (Test-EgressOpen)) {
  Write-Err "Outbound network looks restricted (default-deny egress allowlist)."
  Write-Err "This looks like the Claude desktop app / Cowork sandbox. Use the"
  Write-Err "portable-mode setup instead:"
  Write-Err "  powershell -File `"$ScriptDir\setup-portable.ps1`""
  exit 1
}

# Confirm Credential Manager actually works here (PROBE-K). If the P/Invoke
# round-trip fails, fall through to the floor rather than stranding the user.
if (-not (Test-CredManAvailable)) {
  Write-Err "Windows Credential Manager isn't usable on this host (the CredRead/CredWrite"
  Write-Err "round-trip failed). Falling back to the portable / floor tier, which stores"
  Write-Err "the Application Password in an ACL-locked file instead:"
  Write-Err "  powershell -File `"$ScriptDir\setup-portable.ps1`""
  exit 1
}

# ----- Site info -----------------------------------------------------------

Write-Host ""
Write-Bold "Site info"
$SiteName = Ask "Short site name (kebab-case, e.g. acme-marketing)"
if ($SiteName -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
  Write-Err "Site name must be lowercase letters/numbers separated by single dashes."
  exit 1
}

$ProdUrl = Ask "Production URL (e.g. https://acme.com)"
$ProdUrl = $ProdUrl.TrimEnd('/')
if ($ProdUrl -match '^http://localhost' -or $ProdUrl -match '^http://127\.0\.0\.1') {
  Write-Warn "Using plaintext http:// for localhost dev — allowed, but never for a live site."
} elseif ($ProdUrl -notmatch '^https://') {
  Write-Err "Production URL must start with https:// (got '$ProdUrl')."
  exit 1
}

$WpUser = Ask "WordPress admin/editor username (the login slug)"
if ([string]::IsNullOrWhiteSpace($WpUser)) {
  Write-Err "WordPress username is required."
  exit 1
}

# ----- Site folder (with guard) --------------------------------------------

Write-Host ""
Write-Bold "Site folder"
Write-Host "All state for this site lives in one folder you name. Pick something"
Write-Host "memorable — e.g. $env:USERPROFILE\Sites\$SiteName. Created if it doesn't exist."
$DefaultFolder = if ($SiteFolder) { $SiteFolder } else { Join-Path (Join-Path $env:USERPROFILE "Sites") $SiteName }
$SiteFolderIn = Ask "Site folder path" $DefaultFolder
if ($SiteFolderIn.StartsWith('~')) { $SiteFolderIn = $SiteFolderIn -replace '^~', $env:USERPROFILE }
if ([System.IO.Path]::IsPathRooted($SiteFolderIn)) {
  $SiteFolderResolved = $SiteFolderIn
} else {
  $SiteFolderResolved = Join-Path (Get-Location).Path $SiteFolderIn
}
$SiteFolderResolved = $SiteFolderResolved.TrimEnd('\')

if (-not (Test-SiteFolderGuard $SiteFolderResolved)) { exit 1 }

if (-not (Test-Path $SiteFolderResolved)) {
  New-Item -ItemType Directory -Force -Path $SiteFolderResolved | Out-Null
  Write-Info "Created $SiteFolderResolved"
} else {
  Write-Info "Using existing $SiteFolderResolved"
}

$WpmDir     = Join-Path $SiteFolderResolved ".wpm"
$DocsDir    = Join-Path $WpmDir "docs"
$ConfigFile = Join-Path $WpmDir "config.json"
New-Item -ItemType Directory -Force -Path $DocsDir | Out-Null

$CredTarget = "$APP_SLUG-$SiteName"

# ----- Scaffold curated docs at the site-folder TOP LEVEL ------------------
$TemplatesDir = $null
$maybeTpl = Join-Path $ScriptDir "..\templates"
if (Test-Path $maybeTpl) { $TemplatesDir = (Resolve-Path $maybeTpl).Path }
$Today = Get-Date -Format "yyyy-MM-dd"
$Time  = Get-Date -Format "HH:mm"

$ReadmePath = Join-Path $SiteFolderResolved "README.md"
if (-not (Test-Path $ReadmePath)) {
  if ($TemplatesDir -and (Test-Path (Join-Path $TemplatesDir "README.template.md"))) {
    $t = Get-Content (Join-Path $TemplatesDir "README.template.md") -Raw
    $t = $t -replace '\{SITE_NAME\}', $SiteName
    Set-Content -Path $ReadmePath -Value $t -Encoding UTF8
  } else {
    @"
# $SiteName — WordPress management folder

This folder is everything $APP_SLUG knows about this site.

- Move it anywhere — it keeps working (paths are relative).
- Delete it to make the skill forget this site (then revoke the AP in wp-admin).
- Don't hand-edit ``.wpm\`` — that's the tool's machinery.
"@ | Set-Content -Path $ReadmePath -Encoding UTF8
  }
  Write-Info "Scaffolded $ReadmePath"
}

# project-notes.md — written from the template ((Get-Content) -replace | Set-Content).
$NotesPath = Join-Path $SiteFolderResolved "project-notes.md"
if (-not (Test-Path $NotesPath) -and $TemplatesDir -and (Test-Path (Join-Path $TemplatesDir "project-notes.template.md"))) {
  $t = Get-Content (Join-Path $TemplatesDir "project-notes.template.md") -Raw
  $t = $t -replace '\{SITE_NAME\}', $SiteName
  Set-Content -Path $NotesPath -Value $t -Encoding UTF8
  Write-Info "Scaffolded $NotesPath"
}

# changelog.md — written from the template.
$ChlogPath = Join-Path $SiteFolderResolved "changelog.md"
if (-not (Test-Path $ChlogPath) -and $TemplatesDir -and (Test-Path (Join-Path $TemplatesDir "changelog.template.md"))) {
  $t = Get-Content (Join-Path $TemplatesDir "changelog.template.md") -Raw
  $t = $t -replace '\{SITE_NAME\}', $SiteName
  $t = $t -replace '\{TODAY\}', $Today
  $t = $t -replace '\{TIME\}', $Time
  Set-Content -Path $ChlogPath -Value $t -Encoding UTF8
  Write-Info "Scaffolded $ChlogPath"
}

# ----- Application Password generation --------------------------------------

Write-Host ""
Write-Bold "WordPress Application Password"
Write-Host ""
Write-Host "Generate an Application Password using the one-click authorize link"
Write-Host "(log in to WordPress if asked):"
Write-Host ""
Write-Host "  $ProdUrl/wp-admin/authorize-application.php?app_name=$CredTarget"
Write-Host ""
Write-Host "  -> Approve 'Authorize $CredTarget?'"
Write-Host "  -> Copy the 24-character password (shown ONCE)."
Write-Host ""
Write-Host "  (Fallback: $ProdUrl/wp-admin/profile.php -> Application Passwords.)"
Write-Host ""
Read-Host "Press Enter once you have the Application Password copied"

# ----- Capture the password via the native Windows credential dialog --------
# A native Windows credential dialog opens; the user pastes the AP into the
# masked field. prompt-secret-windows.ps1 writes it into Credential Manager.
# The user never types the secret into this terminal.

Write-Host ""
Write-Bold "Opening a dialog to capture the Application Password..."
Write-Host ""

& "$ScriptDir\prompt-secret-windows.ps1" $SiteName $WpUser
if ($LASTEXITCODE -ne 0) {
  Write-Err "Did not store the Application Password. Re-run this script."
  exit 1
}

# ----- Write config (schema 4, no secret) -----------------------------------
$NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$configObj = [ordered]@{
  schema_version = 4
  site_name      = $SiteName
  production_url = $ProdUrl
  wp_user        = $WpUser
  env            = "console-windows"
  secret_store   = [ordered]@{
    kind = "windows-credential-manager"
    ref  = $CredTarget
  }
  created_at     = $NowUtc
  last_scan_at   = $NowUtc
}
($configObj | ConvertTo-Json -Depth 10) | Set-Content -Path $ConfigFile -Encoding UTF8
Write-Host ""
Write-Info "Wrote $ConfigFile"

# ----- Test connection (PSCredential-Basic; secret off-argv) ----------------
Write-Host ""
Write-Bold "Testing REST API connection..."

$SecurePass = $null
try {
  $SecurePass = Get-WpSecret -Kind "windows-credential-manager" -Ref $CredTarget
} catch {
  Write-Err "Could not read back the stored credential: $($_.Exception.Message)"
  exit 1
}

$test = Invoke-WpRest -Url $ProdUrl -Path "/wp-json/wp/v2/users/me?_fields=id,name,roles" `
          -WpUser $WpUser -SecurePassword $SecurePass

switch ($test.Code) {
  200 {
    Write-Info "REST API connection OK."
    if ($test.Body) {
      Write-Info "Identity: id=$($test.Body.id), name=$($test.Body.name), roles=$($test.Body.roles -join ',')"
    }
  }
  401 {
    Write-Err "Got 401 Unauthorized."
    Write-Err "  - Verify the WordPress username matches your login slug exactly"
    Write-Err "    (visit $ProdUrl/wp-admin/profile.php to check)."
    Write-Err "  - Re-run setup and generate a fresh Application Password."
    $SecurePass = $null; exit 1
  }
  403 {
    # Console network is open (egress probe passed at start), so a 403 here is a
    # WordPress capability problem — not an egress/allowlist issue.
    Write-Err "Got 403 Forbidden — the WordPress user lacks the capability."
    Write-Err "  Use an account with at least Editor role for this endpoint."
    $SecurePass = $null; exit 1
  }
  404 {
    Write-Err "Got 404 — the REST API endpoint isn't reachable."
    Write-Err "  - Is the site URL correct? $ProdUrl"
    Write-Err "  - A security plugin may be blocking the REST API."
    $SecurePass = $null; exit 1
  }
  000 {
    Write-Err "Could not reach the site. Verify $ProdUrl opens in a browser."
    $SecurePass = $null; exit 1
  }
  default {
    Write-Err "Unexpected HTTP $($test.Code) from $ProdUrl/wp-json/wp/v2/users/me"
    if ($test.Raw) { Write-Err ("  " + $test.Raw) }
    $SecurePass = $null; exit 1
  }
}
$SecurePass = $null

# ----- First scan -----------------------------------------------------------
Write-Host ""
Write-Bold "Scanning site architecture..."
& "$ScriptDir\scan-site.ps1" -SiteFolder $SiteFolderResolved -Stage all

# ----- Self-containment assertion: NO ~/.config was created -----------------
$legacyConfig = Join-Path $env:USERPROFILE ".config\norml-wp-manager"
if (Test-Path $legacyConfig) {
  Write-Err "ASSERTION: $legacyConfig exists — this script must never create it."
  Write-Err "If this setup created it, please report; the folder is safe to delete."
}

Write-Host ""
Write-Bold "Setup complete."
Write-Info "Site folder:    $SiteFolderResolved"
Write-Info "Config:         $ConfigFile   (no secrets)"
Write-Info "Docs:           $DocsDir\   (00–04)"
Write-Info "Cred Manager:   $CredTarget"
Write-Host ""
Write-Bold "SECURITY FLAGS"
$arch04 = Join-Path $DocsDir "04-rest-capabilities.md"
if (Test-Path $arch04) {
  $adminLine = Select-String -Path $arch04 -Pattern 'Administrator users' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($adminLine) {
    $m = [regex]::Match($adminLine.Line, '\d+')
    if ($m.Success -and [int]$m.Value -gt 3) {
      Write-Warn "- $($m.Value) administrators is a lot for one site — consider trimming."
    }
  }
}
$arch03 = Join-Path $DocsDir "03-plugins-theme.md"
if (Test-Path $arch03) {
  $hasAgents = Select-String -Path $arch03 -Pattern 'Detected third-party admin agents' -ErrorAction SilentlyContinue
  $noneDet   = Select-String -Path $arch03 -Pattern 'none detected' -ErrorAction SilentlyContinue
  if ($hasAgents -and -not $noneDet) {
    Write-Warn "- A third-party admin-level agent plugin is active — see 03-plugins-theme.md."
  }
}
Write-Info "(Credential Manager tier: the AP is not on disk. Still, revoke unused APs in wp-admin.)"
Write-Host ""
Write-Host "You can now ask Claude things like:"
Write-Info '"What plugins are installed on my site?"'
Write-Info '"Show me my last 10 posts."'
Write-Info '"List my custom post types."'
