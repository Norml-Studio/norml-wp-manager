#requires -Version 5.1
<#
.SYNOPSIS
  norml-wp-manager — portable / FLOOR-tier setup on Windows.

.DESCRIPTION
  The Windows-console floor fallback for when Windows Credential Manager is not
  usable (the P/Invoke CredRead/CredWrite round-trip fails — locked-down host,
  non-interactive context, etc.), and the cross-platform floor for a Windows
  host running the desktop app / Cowork sandbox.

  Windows mirror of setup-portable.sh. Writes everything into ONE user-named
  site folder:
    {site_folder}\
    ├── README.md  project-notes.md  changelog.md      (curated, top level)
    └── .wpm\
        ├── config.json   (schema 4, no secret)
        ├── credential     (raw AP string, ACL-locked to the current user)
        ├── .gitignore     (one line: credential)
        └── docs\00–04.md  (written by scan-site.ps1)

  POSIX chmod 600 is a no-op on NTFS, so the credential file is ACL-locked with
  `icacls` (inheritance removed, only the current user granted Read) BEFORE any
  content is written — the Windows analogue of bash's born-`umask 077` write.

  On a desktop/Cowork host the sandbox is behind a default-deny egress allowlist,
  so this script runs an ANONYMOUS reachability gate BEFORE asking for any
  credential.

.PARAMETER SiteFolder
  Optional. The site folder to create / use. Defaults to .\<site-name>.
#>

[CmdletBinding()]
param(
  [string]$SiteFolder = ""
)

$ErrorActionPreference = "Stop"
$APP_SLUG = "norml-wp-manager"   # brand-pinned. .wpm/ stays brand-neutral.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Shared SecureString / Basic-auth helpers (also used for the auth test below).
. (Join-Path $ScriptDir "lib\credman.ps1")

# ---- Helpers ---------------------------------------------------------------

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

# ---- Egress probe — separates real Console from a sandbox ------------------
# Neutral host (NOT anthropic.com — that's allowlisted in sandboxes).
# 200/30x → network open (Windows console floor). Blocked/000 → default-deny
# allowlist → desktop/Cowork sandbox. Drives the env value + 403 disambiguation.
function Test-EgressOpen {
  try {
    $resp = Invoke-WebRequest -Uri "https://example.com" -Method Head -TimeoutSec 8 `
      -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
    return ([int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 400)
  } catch {
    # A 30x is surfaced as an error with MaximumRedirection 0 — treat as open.
    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
      try {
        $c = [int]$_.Exception.Response.StatusCode.value__
        if ($c -ge 200 -and $c -lt 400) { return $true }
      } catch { }
    }
    return $false
  }
}

# ---- Guard: refuse dangerous / cloud-synced site-folder locations ----------
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
  # Never inside the skill's own directory (skill updates would wipe it).
  $skillRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
  if (($f.TrimEnd('\') + '\') -like ($skillRoot.TrimEnd('\') + '\*') -or
      ($f.TrimEnd('\') -ieq $skillRoot.TrimEnd('\'))) {
    Write-Err "Refusing to place the site folder inside the skill directory ($skillRoot)."
    Write-Err "Skill updates would erase it. Pick a folder elsewhere."
    return $false
  }
  # Cloud-sync trees — warn loudly, let the user choose.
  $cloudPatterns = @('*\Dropbox\*','*\OneDrive*','*\Google Drive\*','*\iCloudDrive\*','*\Box\*','*CloudStorage*')
  foreach ($pat in $cloudPatterns) {
    if ($f -like $pat) {
      Write-Warn "This folder is inside a cloud-sync tree."
      Write-Warn "Your password file could be uploaded to a third-party cloud and to anyone"
      Write-Warn "you share the folder with. .gitignore does NOT stop cloud sync."
      Write-Warn "Prefer a non-synced folder, or accept the risk and rotate the AP weekly."
      $yn = Ask "Use this cloud-synced folder anyway? (y/N)" "N"
      if ($yn -notmatch '^[Yy]$') { Write-Err "Aborted — pick a non-synced folder."; return $false }
      break
    }
  }
  return $true
}

# ---- Anonymous reachability gate (NO credentials) --------------------------
# Loops until /wp-json returns 200 with real REST JSON. On a blocked probe in a
# sandbox, shows the egress-allowlist fix. Returns $true on pass, $false on abort.
function Invoke-NetworkGate([string]$url) {
  while ($true) {
    $code = 0; $body = ""
    try {
      $resp = Invoke-WebRequest -Uri "$url/wp-json" -Method Get -MaximumRedirection 0 `
        -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
      $code = [int]$resp.StatusCode
      $body = if ($null -ne $resp.Content) { [string]$resp.Content } else { "" }
    } catch {
      if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
        try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { $code = 0 }
      }
    }

    if ($code -eq 200 -and ($body -match '"namespaces"' -or $body -match '"routes"')) {
      Write-Info "Reachability gate PASSED (200, REST alive)."
      return $true
    }

    Write-Host ""
    if ($code -eq 200) {
      Write-Err "Got 200 from $url/wp-json but the body is not REST JSON."
      Write-Err "  The URL may be wrong, or a security plugin disabled the REST API."
      Write-Err "  This is NOT an egress problem."
    } else {
      Write-Err "Could not reach $url/wp-json (HTTP $code)."
      Write-Err "  On the Claude desktop app this is almost always the EGRESS ALLOWLIST:"
      Write-Err "    Settings -> Capabilities -> 'Allow network egress'"
      Write-Err "    Leave the dropdown on 'Package managers only'."
      Write-Err "    In 'Additional allowed domains' add your site's domain (e.g. acme.com,"
      Write-Err "    or *.acme.com for staging). Do NOT switch to 'All domains'."
      Write-Err "  (Team/Enterprise: this list may be admin-locked — ask an admin, or run"
      Write-Err "   from Claude Code on your own machine.)"
    }
    Write-Host ""
    $again = Ask "Re-check reachability now? (Y/n — n aborts setup)" "Y"
    if ($again -match '^[Nn]$') { Write-Err "Aborted before any credential was requested."; return $false }
  }
}

# ---- Banner ----------------------------------------------------------------

Write-Bold "$APP_SLUG setup — portable / floor tier (Windows)"
Write-Host ""
Write-Host "All state for this site goes into ONE folder you name. The Application"
Write-Host "Password is stored as a plaintext file inside that folder's .wpm\ —"
Write-Host "ACL-locked to your Windows user and git-ignored."
Write-Host ""
Write-Warn "Floor tier means the AP lives in a file, not Windows Credential Manager."
Write-Warn "Use an editor-role AP, and rotate it (revoke + regenerate) at the end of"
Write-Warn "the session — it costs nothing and closes the exposure."
Write-Host ""
Read-Host "Press Enter to continue, Ctrl-C to cancel"

# Decide env from the egress probe (open → console-windows floor; blocked → desktop).
$EgressOpen = Test-EgressOpen
$EnvVal = if ($EgressOpen) { "console-windows" } else { "desktop" }

# ---- Site basics (NO secret yet) -------------------------------------------

Write-Host ""
Write-Bold "Site info"
$SiteName = Ask "Short site name (kebab-case, e.g. acme-marketing)"
if ($SiteName -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
  Write-Err "Site name must be kebab-case (lowercase letters / digits / hyphens)."
  exit 1
}

$ProdUrl = Ask "Production URL (https://...)"
$ProdUrl = $ProdUrl.TrimEnd('/')
if ($ProdUrl -match '^http://localhost' -or $ProdUrl -match '^http://127\.0\.0\.1') {
  Write-Warn "Using plaintext http:// for localhost dev — allowed, but never for a live site."
} elseif ($ProdUrl -notmatch '^https://') {
  Write-Err "Production URL must start with https:// (got '$ProdUrl')."
  Write-Err "An Application Password sent over http:// can be intercepted."
  exit 1
}

$WpUser = Ask "WordPress username (login slug — not display name / email)"
if ([string]::IsNullOrWhiteSpace($WpUser)) {
  Write-Err "WordPress username is required."
  exit 1
}

# ---- Site folder (with guard) ----------------------------------------------

Write-Host ""
Write-Bold "Site folder"
Write-Host "All state lives in one folder you name. Pick something memorable."
$DefaultFolder = if ($SiteFolder) { $SiteFolder } else { Join-Path (Get-Location).Path $SiteName }
$SiteFolderIn = Ask "Site folder path" $DefaultFolder
if ($SiteFolderIn.StartsWith('~')) { $SiteFolderIn = $SiteFolderIn -replace '^~', $env:USERPROFILE }
if ([System.IO.Path]::IsPathRooted($SiteFolderIn)) {
  $SiteFolderResolved = $SiteFolderIn
} else {
  $SiteFolderResolved = Join-Path (Get-Location).Path $SiteFolderIn
}
$SiteFolderResolved = $SiteFolderResolved.TrimEnd('\')

if (-not (Test-SiteFolderGuard $SiteFolderResolved)) { exit 1 }

$WpmDir     = Join-Path $SiteFolderResolved ".wpm"
$DocsDir    = Join-Path $WpmDir "docs"
$ConfigFile = Join-Path $WpmDir "config.json"
$CredFile   = Join-Path $WpmDir "credential"
$GitIgnore  = Join-Path $WpmDir ".gitignore"

# Track whether WE created .wpm\ so we can clean up debris on abort.
$WpmPreexisted = Test-Path $WpmDir

# No-half-written-debris cleanup: remove a half-written .wpm\ ONLY if we created
# it AND no credential landed. Registered as a script-scope flag the catch uses.
$script:CredLanded = $false
function Invoke-AbortCleanup {
  if (-not $WpmPreexisted -and (Test-Path $WpmDir) -and -not $script:CredLanded) {
    Remove-Item -Recurse -Force $WpmDir -ErrorAction SilentlyContinue
    # Remove the site folder too if it's now empty and we just made it.
    if ((Test-Path $SiteFolderResolved) -and -not (Get-ChildItem -Force $SiteFolderResolved -ErrorAction SilentlyContinue)) {
      Remove-Item -Force $SiteFolderResolved -ErrorAction SilentlyContinue
    }
  }
}

try {
  New-Item -ItemType Directory -Force -Path $DocsDir | Out-Null

  # ---- NETWORK GATE — before any credential --------------------------------
  Write-Host ""
  Write-Bold "Checking reachability (anonymous — no password involved)..."
  if (-not (Invoke-NetworkGate $ProdUrl)) { Invoke-AbortCleanup; exit 1 }

  # ---- Connector: one-click authorize deep link ----------------------------
  Write-Host ""
  Write-Bold "WordPress Application Password"
  Write-Host ""
  Write-Host "Open this one-click authorize link (log in to WordPress if asked):"
  Write-Host ""
  Write-Host "  $ProdUrl/wp-admin/authorize-application.php?app_name=$APP_SLUG-$SiteName"
  Write-Host ""
  Write-Host "  -> Approve 'Authorize $APP_SLUG-$SiteName?'"
  Write-Host "  -> Copy the 24-character password (shown ONCE)."
  Write-Host ""
  Write-Host "  (Fallback: $ProdUrl/wp-admin/profile.php -> Application Passwords.)"
  Write-Host ""
  Write-Warn "Heads-up: pasting it here saves the password in this conversation's"
  Write-Warn "history (on Claude's servers) for as long as the conversation is kept."
  Write-Warn "That's why we recommend an editor-role AP and revoking it at session end."
  Write-Host ""
  Read-Host "Press Enter when ready to paste the Application Password"

  # ---- Capture the AP as a SecureString ------------------------------------
  Write-Host ""
  Write-Bold "Paste the Application Password (input hidden, characters do not echo)"
  $secureIn = Read-Host "Application Password" -AsSecureString

  # Strip whitespace via a BSTR round-trip, re-wrap into a clean SecureString.
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureIn)
  $SecurePass = $null
  $apForFile  = $null
  try {
    $plain    = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    $stripped = ($plain -replace '\s', '')
    $plain    = $null
    if ([string]::IsNullOrWhiteSpace($stripped)) {
      Write-Err "Empty Application Password. Aborting."
      Invoke-AbortCleanup; exit 1
    }
    $SecurePass = New-Object System.Security.SecureString
    foreach ($c in $stripped.ToCharArray()) { $SecurePass.AppendChar($c) }
    $SecurePass.MakeReadOnly()
    $apForFile = $stripped   # held briefly; written to the ACL-locked file below
    $stripped = $null
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }

  # ---- Authenticated check BEFORE persisting the credential ----------------
  # Gate credential creation on gate-200 (passed) AND auth-200, so no half-written
  # secret debris if the AP is wrong. Secret stays a SecureString (off-argv).
  Write-Host ""
  Write-Bold "Verifying the Application Password..."
  $auth = Invoke-WpRest -Url $ProdUrl -Path "/wp-json/wp/v2/users/me?_fields=id,name,roles" `
            -WpUser $WpUser -SecurePassword $SecurePass
  switch ($auth.Code) {
    200 {
      Write-Info "Authentication OK."
      if ($auth.Body) {
        Write-Info "  id=$($auth.Body.id), name=$($auth.Body.name), roles=$($auth.Body.roles -join ',')"
      }
    }
    401 {
      Write-Err "401 Unauthorized — the username or Application Password is wrong."
      Write-Err "  The username must be your WP login slug (check $ProdUrl/wp-admin/profile.php)."
      $apForFile = $null; Invoke-AbortCleanup; exit 1
    }
    403 {
      # Anon gate already passed (network reachable) → this is a WP capability 403.
      Write-Err "403 Forbidden — the WordPress user lacks the capability for this endpoint."
      Write-Err "  Use an account with at least Editor role."
      $apForFile = $null; Invoke-AbortCleanup; exit 1
    }
    default {
      Write-Err "Unexpected HTTP $($auth.Code) during authentication."
      if ($auth.Raw) { Write-Err ("  " + $auth.Raw) }
      $apForFile = $null; Invoke-AbortCleanup; exit 1
    }
  }

  # ---- Write the credential — ACL-LOCKED BEFORE content --------------------
  # NTFS has no umask; chmod is a no-op. So: create an EMPTY file, strip
  # inheritance + grant ONLY the current user Modify, THEN write the secret. The
  # bytes never exist on disk under an inherited (possibly broad) ACL.
  New-Item -ItemType File -Force -Path $CredFile | Out-Null
  & icacls "$CredFile" /inheritance:r /grant:r "$($env:USERNAME):M" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "icacls could not lock the credential ACL (exit $LASTEXITCODE)."
    Write-Warn "The file may be readable by other accounts on this PC — rotate the AP weekly."
  }
  # Write content with no trailing newline (matches the bash `printf '%s'`).
  [System.IO.File]::WriteAllText($CredFile, $apForFile, (New-Object System.Text.UTF8Encoding($false)))
  $apForFile = $null
  $script:CredLanded = $true
  Write-Info "Wrote $CredFile (ACL-locked to $($env:USERNAME))"

  # ---- .gitignore beside the secret + ASSERTIVE git check-ignore gate ------
  Set-Content -Path $GitIgnore -Value "credential" -Encoding ascii -NoNewline
  Add-Content -Path $GitIgnore -Value "`n" -NoNewline   # one trailing newline

  $gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
  if ($gitAvailable) {
    $insideRepo = $false
    try {
      $r = & git -C $WpmDir rev-parse --is-inside-work-tree 2>$null
      if ($LASTEXITCODE -eq 0 -and $r -match 'true') { $insideRepo = $true }
    } catch { }
    if ($insideRepo) {
      $ignored = ""
      try { $ignored = (& git -C $WpmDir check-ignore "$CredFile" 2>$null) } catch { }
      if ([string]::IsNullOrWhiteSpace($ignored)) {
        Write-Err "SECURITY ABORT: git does NOT ignore the credential file."
        Write-Err "  Backing the credential out so it cannot be committed."
        Remove-Item -Force $CredFile -ErrorAction SilentlyContinue
        $script:CredLanded = $false
        Write-Err "  Fix the repo's .gitignore handling, then re-run setup."
        Invoke-AbortCleanup
        exit 1
      }
      Write-Info "Verified: git ignores the credential file."
    } else {
      Write-Info "Not inside a git work tree — .gitignore written for if one is added later."
    }
  } else {
    Write-Info "git not installed — .gitignore written for if the folder is later put in a repo."
  }

  # ---- Write config (schema 4, no secret) ----------------------------------
  $NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $configObj = [ordered]@{
    schema_version = 4
    site_name      = $SiteName
    production_url = $ProdUrl
    wp_user        = $WpUser
    env            = $EnvVal
    secret_store   = [ordered]@{
      kind = "portable-file"
      ref  = "credential"
    }
    created_at     = $NowUtc
    last_scan_at   = $NowUtc
  }
  ($configObj | ConvertTo-Json -Depth 10) | Set-Content -Path $ConfigFile -Encoding UTF8
  Write-Info "Wrote $ConfigFile"

  # ---- Scaffold curated docs at the site-folder TOP LEVEL ------------------
  $TemplatesDir = $null
  $maybeTpl = Join-Path $ScriptDir "..\templates"
  if (Test-Path $maybeTpl) { $TemplatesDir = (Resolve-Path $maybeTpl).Path }
  $Today = Get-Date -Format "yyyy-MM-dd"
  $Time  = Get-Date -Format "HH:mm"

  $ReadmePath = Join-Path $SiteFolderResolved "README.md"
  if (-not (Test-Path $ReadmePath)) {
    if ($TemplatesDir -and (Test-Path (Join-Path $TemplatesDir "readme-template.md"))) {
      $t = Get-Content (Join-Path $TemplatesDir "readme-template.md") -Raw
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

  $NotesPath = Join-Path $SiteFolderResolved "project-notes.md"
  if ($TemplatesDir -and (Test-Path (Join-Path $TemplatesDir "project-notes-template.md")) -and -not (Test-Path $NotesPath)) {
    $t = Get-Content (Join-Path $TemplatesDir "project-notes-template.md") -Raw
    $t = $t -replace '\{SITE_NAME\}', $SiteName
    Set-Content -Path $NotesPath -Value $t -Encoding UTF8
    Write-Info "Scaffolded $NotesPath"
  }

  $ChlogPath = Join-Path $SiteFolderResolved "changelog.md"
  if ($TemplatesDir -and (Test-Path (Join-Path $TemplatesDir "changelog-template.md")) -and -not (Test-Path $ChlogPath)) {
    $t = Get-Content (Join-Path $TemplatesDir "changelog-template.md") -Raw
    $t = $t -replace '\{SITE_NAME\}', $SiteName
    $t = $t -replace '\{TODAY\}', $Today
    $t = $t -replace '\{TIME\}', $Time
    Set-Content -Path $ChlogPath -Value $t -Encoding UTF8
    Write-Info "Scaffolded $ChlogPath"
  }

  # Credential is on disk + verified — drop the SecureString reference.
  $SecurePass = $null

  # ---- Scan (00→04) --------------------------------------------------------
  $scanScript = Join-Path $ScriptDir "scan-site.ps1"
  if (Test-Path $scanScript) {
    Write-Host ""
    Write-Bold "Scanning site architecture..."
    try {
      & $scanScript -SiteFolder $SiteFolderResolved -Stage all
    } catch {
      Write-Warn "Scan failed — you can run scan-site.ps1 later. ($($_.Exception.Message))"
    }
  }
}
catch {
  Invoke-AbortCleanup
  Write-Err "Setup failed: $($_.Exception.Message)"
  exit 1
}

# ---- Done + SECURITY FLAGS -------------------------------------------------
Write-Host ""
Write-Bold "Portable-mode setup complete."
Write-Info "Site folder:  $SiteFolderResolved"
Write-Info "Config:       $ConfigFile"
Write-Info "Credential:   $CredFile  (ACL-locked, gitignored)"
Write-Info "Docs:         $DocsDir\  (00–04)"
Write-Host ""
Write-Bold "SECURITY FLAGS"
Write-Warn "1. The Application Password is plaintext on disk in .wpm\credential."
Write-Warn "   It is ACL-locked to your Windows user, but anyone who can log in to"
Write-Warn "   this PC as you (or an admin) can read it. Rotate it monthly while this"
Write-Warn "   floor setup is in use, and ideally revoke + regenerate at session end."

$arch04 = Join-Path $DocsDir "04-rest-capabilities.md"
if (Test-Path $arch04) {
  $adminLine = Select-String -Path $arch04 -Pattern 'Administrator users' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($adminLine) {
    $m = [regex]::Match($adminLine.Line, '\d+')
    if ($m.Success -and [int]$m.Value -gt 3) {
      Write-Warn "2. $($m.Value) administrators is a lot for one site — consider trimming."
    }
  }
}
$arch03 = Join-Path $DocsDir "03-plugins-theme.md"
if (Test-Path $arch03) {
  $hasAgents = Select-String -Path $arch03 -Pattern 'Detected third-party admin agents' -ErrorAction SilentlyContinue
  $noneDet   = Select-String -Path $arch03 -Pattern 'none detected' -ErrorAction SilentlyContinue
  if ($hasAgents -and -not $noneDet) {
    Write-Warn "3. A third-party admin-level agent plugin is active — see 03-plugins-theme.md."
  }
}
Write-Host ""
Write-Host "You can now ask Claude things like:"
Write-Info '"What plugins are installed on my site?"'
Write-Info '"Show me my last 10 posts."'
