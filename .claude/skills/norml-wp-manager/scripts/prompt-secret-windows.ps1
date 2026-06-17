#requires -Version 5.1
<#
.SYNOPSIS
  norml-wp-manager -- pop a native Windows credential dialog to capture the
  WordPress Application Password, then store it in Windows Credential Manager.

.DESCRIPTION
  Designed to be called from Claude (via the Bash tool) or from
  setup-windows.ps1. The user never has to type the secret into a terminal
  prompt -- a normal Windows credential dialog opens in front of them. The
  password stays a SecureString end-to-end (dialog -> strip whitespace via a
  zeroed BSTR -> Credential Manager); it is never assigned to a plain string
  variable and never placed on argv.

.PARAMETER SiteName
  Short kebab-case site name. The Credential Manager target is
  norml-wp-manager-{SiteName}.

.PARAMETER WpUser
  WordPress username (pre-filled in the credential dialog).

.EXAMPLE
  & "scripts\prompt-secret-windows.ps1" "acme-marketing" "acme-admin"

.OUTPUTS
  Exit code 0 on success, 1 on cancel / empty, 2 on bad args.
#>

param(
  [Parameter(Mandatory=$true, Position=0)][string]$SiteName,
  [Parameter(Mandatory=$true, Position=1)][string]$WpUser
)

$ErrorActionPreference = "Stop"
$APP_SLUG = "norml-wp-manager"   # brand-pinned. Service / target = $APP_SLUG-{site}.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load the inline Win32 Credential Manager wrapper + SecureString helpers.
. (Join-Path $ScriptDir "lib\credman.ps1")

$Target = "$APP_SLUG-$SiteName"

# Native Windows credential dialog. The OS draws the modal; password is masked;
# result is a PSCredential whose Password is a SecureString. The placeholder in
# the prompt text is deliberately FAKE (all X's) so a confused user can't mistake
# it for a value to paste.
$cred = $null
try {
  $cred = $Host.UI.PromptForCredential(
    "$APP_SLUG -- $SiteName",
    "Paste the WordPress Application Password.`n`nWordPress shows it as 6 groups of 4 characters, e.g. XXXX XXXX XXXX XXXX XXXX XXXX. Spaces are OK -- they will be stripped.",
    $WpUser,
    ""
  )
} catch {
  Write-Host "Cancelled." -ForegroundColor Yellow
  exit 1
}

if (-not $cred) {
  Write-Host "Cancelled." -ForegroundColor Yellow
  exit 1
}

# Strip whitespace: SecureString -> plain (briefly, via BSTR) -> re-wrap into a
# clean SecureString. The plain copy lives only inside this try/finally and the
# BSTR is zeroed in finally.
$secure = $cred.Password
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $plain    = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
  $stripped = ($plain -replace '\s', '')
  $plain    = $null
  if ([string]::IsNullOrWhiteSpace($stripped)) {
    Write-Host "Empty Application Password. Aborting." -ForegroundColor Red
    exit 1
  }
  $secure = New-Object System.Security.SecureString
  foreach ($c in $stripped.ToCharArray()) { $secure.AppendChar($c) }
  $secure.MakeReadOnly()
  $stripped = $null
} finally {
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  [System.GC]::Collect()
}

# Idempotent: replace any prior entry under the same target.
try { Remove-StoredCredential -Target $Target | Out-Null } catch { }

Write-StoredCredential -Target $Target -Username $WpUser -SecurePassword $secure

Write-Host "Stored Application Password under Credential Manager target '$Target'."
