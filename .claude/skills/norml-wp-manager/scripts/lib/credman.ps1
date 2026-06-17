<#
.SYNOPSIS
  Inline Win32 wrapper for Windows Credential Manager + the shared SecureString
  / Basic-auth model the whole PowerShell side reuses.

  The Credential Manager half lets PowerShell read, write, and delete generic
  credentials without any external module (no CredentialManager from PSGallery,
  no SecretManagement). Works on Windows 10+ with stock PowerShell 5.1.

  The auth half is the Windows analogue of the bash `--config <(...)` trick:
  the secret stays a SecureString end-to-end and is turned into an HTTP Basic
  header only at the last moment via a BSTR that is zeroed immediately. The
  password is NEVER assigned to a plain `$pass` variable, NEVER placed on argv,
  and `curl.exe -u` is NEVER shelled out to.

.USAGE
  . "$PSScriptRoot\lib\credman.ps1"

  # Credential Manager (target = norml-wp-manager-{site}):
  Write-StoredCredential -Target "norml-wp-manager-acme" -Username "acme-admin" -SecurePassword $secure
  $secure = Read-StoredSecret -Target "norml-wp-manager-acme"   # -> SecureString
  Remove-StoredCredential -Target "norml-wp-manager-acme"

  # Tier-agnostic secret read (Credential Manager OR floor file):
  $secure = Get-WpSecret -Kind "windows-credential-manager" -Ref "norml-wp-manager-acme"
  $secure = Get-WpSecret -Kind "portable-file" -Ref "credential" -WpmDir "C:\Sites\acme\.wpm"

  # The sanctioned authenticated call (secret off-argv, https-only):
  $r = Invoke-WpRest -Url "https://acme.com" -Path "/wp-json/wp/v2/users/me" `
         -WpUser "acme-admin" -SecurePassword $secure
#>

# ---------------------------------------------------------------------------
# Win32 P/Invoke surface (CredReadW / CredWriteW / CredDeleteW / CredFree)
# ---------------------------------------------------------------------------

if (-not ("WpManagerCredMan" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class WpManagerCredMan
{
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL
    {
        public uint   Flags;
        public uint   Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint   CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint   Persist;
        public uint   AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("Advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CredReadW")]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credentialPtr);

    [DllImport("Advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CredWriteW")]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("Advapi32.dll", SetLastError=true)]
    public static extern void CredFree(IntPtr credential);

    [DllImport("Advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CredDeleteW")]
    public static extern bool CredDelete(string target, uint type, uint flags);
}
"@
}

# Cred type constants
$script:CRED_TYPE_GENERIC        = 1
$script:CRED_PERSIST_LOCAL_MACH  = 2

# ---------------------------------------------------------------------------
# Credential Manager: write / read (as SecureString) / delete
# ---------------------------------------------------------------------------

function Write-StoredCredential {
  param(
    [Parameter(Mandatory=$true)][string]$Target,
    [Parameter(Mandatory=$true)][string]$Username,
    [Parameter(Mandatory=$true)][System.Security.SecureString]$SecurePassword
  )

  # SecureString -> Unicode byte array, via BSTR. Discard plaintext immediately
  # after writing into the Credential struct.
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
  try {
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    $blob  = [System.Text.Encoding]::Unicode.GetBytes($plain)
    $plain = $null
    $cred  = New-Object WpManagerCredMan+CREDENTIAL
    $cred.Type               = $script:CRED_TYPE_GENERIC
    $cred.TargetName         = $Target
    $cred.UserName           = $Username
    $cred.Persist            = $script:CRED_PERSIST_LOCAL_MACH
    $cred.AttributeCount     = 0
    $cred.Attributes         = [IntPtr]::Zero
    $cred.CredentialBlobSize = [uint32]$blob.Length
    $cred.CredentialBlob     = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($blob.Length)
    [System.Runtime.InteropServices.Marshal]::Copy($blob, 0, $cred.CredentialBlob, $blob.Length)
    try {
      $ok = [WpManagerCredMan]::CredWrite([ref]$cred, 0)
      if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "CredWrite failed for target '$Target' (Win32 error $err)"
      }
    } finally {
      [System.Runtime.InteropServices.Marshal]::FreeHGlobal($cred.CredentialBlob)
      # Zero the local byte array to reduce in-memory residue.
      for ($i = 0; $i -lt $blob.Length; $i++) { $blob[$i] = 0 }
    }
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

# Read a stored credential and return it as a SecureString (NEVER a plain
# string). The blob is copied into a managed byte[], converted char-by-char
# into a SecureString, then the byte[] is zeroed.
function Read-StoredSecret {
  param([Parameter(Mandatory=$true)][string]$Target)

  $ptr = [IntPtr]::Zero
  $ok = [WpManagerCredMan]::CredRead($Target, $script:CRED_TYPE_GENERIC, 0, [ref]$ptr)
  if (-not $ok) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -eq 1168) {
      throw "Credential '$Target' not found in Windows Credential Manager. Re-run scripts\setup-windows.ps1."
    }
    throw "CredRead failed for '$Target' (Win32 error $err)"
  }
  try {
    $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][WpManagerCredMan+CREDENTIAL])
    $size = [int]$cred.CredentialBlobSize
    $secure = New-Object System.Security.SecureString
    if ($size -gt 0) {
      $buf = New-Object byte[] $size
      [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $buf, 0, $size)
      try {
        # Blob is UTF-16LE (we wrote it as Encoding.Unicode); 2 bytes per char.
        for ($i = 0; $i -lt $size; $i += 2) {
          $ch = [char]([int]$buf[$i] -bor ([int]$buf[$i + 1] -shl 8))
          $secure.AppendChar($ch)
        }
      } finally {
        for ($i = 0; $i -lt $buf.Length; $i++) { $buf[$i] = 0 }
      }
    }
    $secure.MakeReadOnly()
    return $secure
  } finally {
    [WpManagerCredMan]::CredFree($ptr)
  }
}

function Remove-StoredCredential {
  param([Parameter(Mandatory=$true)][string]$Target)
  $ok = [WpManagerCredMan]::CredDelete($Target, $script:CRED_TYPE_GENERIC, 0)
  if (-not $ok) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -eq 1168) { return $false }  # not found is fine
    throw "CredDelete failed for '$Target' (Win32 error $err)"
  }
  return $true
}

# Probe whether the Credential Manager P/Invoke surface actually works on this
# host (PROBE-K for Windows). Round-trip a throwaway entry: write -> read ->
# delete. Returns $true only if all three succeed. Never throws.
function Test-CredManAvailable {
  $probeTarget = "norml-wp-manager-__probe__"
  $secure = $null
  try {
    $secure = New-Object System.Security.SecureString
    foreach ($c in "wpm-probe".ToCharArray()) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    Write-StoredCredential -Target $probeTarget -Username "probe" -SecurePassword $secure
    $back = Read-StoredSecret -Target $probeTarget
    $ok = ($null -ne $back)
    return $ok
  } catch {
    return $false
  } finally {
    try { Remove-StoredCredential -Target $probeTarget | Out-Null } catch { }
  }
}

# ---------------------------------------------------------------------------
# Tier-agnostic secret reader → SecureString
# ---------------------------------------------------------------------------
# Mirrors the bash get_password() router. Returns a SecureString for any tier.
#   windows-credential-manager → Credential Manager (Read-StoredSecret)
#   portable-file (or empty)    → read {WpmDir}\credential (raw AP), wrap, done
# macOS/Linux tiers are not readable from PowerShell (use the .sh scripts).
function Get-WpSecret {
  param(
    [Parameter(Mandatory=$true)][string]$Kind,
    [string]$Ref,
    [string]$WpmDir
  )
  switch ($Kind) {
    'windows-credential-manager' {
      if ([string]::IsNullOrWhiteSpace($Ref)) {
        throw "secret_store.ref is empty for a windows-credential-manager config."
      }
      return (Read-StoredSecret -Target $Ref)
    }
    { $_ -eq 'portable-file' -or [string]::IsNullOrWhiteSpace($_) } {
      if ([string]::IsNullOrWhiteSpace($WpmDir)) {
        throw "portable-file tier needs the .wpm directory path (WpmDir)."
      }
      $credFile = Join-Path $WpmDir "credential"
      if (-not (Test-Path $credFile)) {
        throw "Credential file unreadable: $credFile"
      }
      # Read the raw AP as text, wrap into a SecureString, zero the plain copy.
      $raw = [System.IO.File]::ReadAllText($credFile)
      $raw = $raw.Trim()
      $secure = New-Object System.Security.SecureString
      foreach ($c in $raw.ToCharArray()) { $secure.AppendChar($c) }
      $secure.MakeReadOnly()
      $raw = $null
      return $secure
    }
    'macos-keychain' {
      throw "macos-keychain is not readable from PowerShell; use the macOS .sh scripts."
    }
    'linux-libsecret' {
      throw "linux-libsecret is not readable from PowerShell; use the Linux .sh scripts."
    }
    default {
      throw "Unknown secret_store.kind '$Kind'."
    }
  }
}

# ---------------------------------------------------------------------------
# Basic-auth header built from a SecureString (the off-argv analogue)
# ---------------------------------------------------------------------------
# Turns "{user}:{secret}" into a base64 Basic header. The secret is materialised
# only inside this function via a BSTR that is zeroed in `finally`; the caller
# gets a header string, never the password. There is no curl.exe, no -u, no
# process argument carrying the secret.
function New-WpBasicAuthHeader {
  param(
    [Parameter(Mandatory=$true)][string]$WpUser,
    [Parameter(Mandatory=$true)][System.Security.SecureString]$SecurePassword
  )
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
  try {
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    $pair  = "{0}:{1}" -f $WpUser, $plain
    $plain = $null
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $pair  = $null
    $b64   = [Convert]::ToBase64String($bytes)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0 }
    return "Basic $b64"
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

# ---------------------------------------------------------------------------
# The sanctioned authenticated REST call (https-only, secret off-argv)
# ---------------------------------------------------------------------------
# Windows analogue of bash restcall(): credential never on argv, https enforced
# (the bash `--proto '=https'`), redirects disabled (`--max-redirs 0`).
#
# Auth strategy by PowerShell edition:
#   PS 7+  → Invoke-RestMethod -Authentication Basic -Credential $cred
#            -AllowUnencryptedAuthentication:$false  (preemptive Basic, native)
#   PS 5.1 → -Credential does NOT send Basic preemptively (WordPress needs it on
#            the first request), so we splat an Authorization header built from
#            the SecureString. Same secret hygiene, 5.1-compatible.
#
# Returns a hashtable: @{ Code = <int>; Body = <parsed or raw>; Raw = <string>;
#                         Headers = <dict>; Ok = <bool> }.
function Invoke-WpRest {
  param(
    [Parameter(Mandatory=$true)][string]$Url,          # base, e.g. https://acme.com
    [Parameter(Mandatory=$true)][string]$Path,         # e.g. /wp-json/wp/v2/users/me
    [Parameter(Mandatory=$true)][string]$WpUser,
    [Parameter(Mandatory=$true)][System.Security.SecureString]$SecurePassword,
    [string]$Method = 'Get',
    [object]$Body = $null,
    [switch]$Head,                                     # use HEAD (for X-WP-Total)
    [switch]$Options                                   # use OPTIONS (capabilities)
  )

  $full = "$Url$Path"
  if ($full -notmatch '^https://' -and
      $full -notmatch '^http://localhost' -and
      $full -notmatch '^http://127\.0\.0\.1') {
    throw "Refusing a non-https authenticated call to '$full'. An Application Password must travel over TLS."
  }

  $isCore = $PSVersionTable.PSVersion.Major -ge 6
  $verb = if ($Head) { 'Head' } elseif ($Options) { 'Options' } else { $Method }

  $result = @{ Code = 0; Body = $null; Raw = ""; Headers = $null; Ok = $false }

  # Common Invoke-WebRequest args.
  $iwrArgs = @{
    Uri             = $full
    Method          = $verb
    MaximumRedirection = 0
    ErrorAction     = 'Stop'
    UseBasicParsing = $true
  }
  if ($null -ne $Body) {
    $iwrArgs['Body']        = $Body
    $iwrArgs['ContentType'] = 'application/json'
  }

  if ($isCore) {
    # PS7+: native preemptive Basic, TLS enforced.
    $cred = New-Object System.Management.Automation.PSCredential($WpUser, $SecurePassword)
    $iwrArgs['Authentication']               = 'Basic'
    $iwrArgs['Credential']                   = $cred
    $iwrArgs['AllowUnencryptedAuthentication'] = $false
    $iwrArgs['Headers']                      = @{ Accept = 'application/json' }
  } else {
    # PS5.1: build the header from the SecureString (off-argv) and splat it.
    $authHeader = New-WpBasicAuthHeader -WpUser $WpUser -SecurePassword $SecurePassword
    $iwrArgs['Headers'] = @{ Authorization = $authHeader; Accept = 'application/json' }
  }

  try {
    $resp = Invoke-WebRequest @iwrArgs
    $result.Code    = [int]$resp.StatusCode
    $result.Raw     = if ($null -ne $resp.Content) { [string]$resp.Content } else { "" }
    $result.Headers = $resp.Headers
    $result.Ok      = $true
    if ($result.Raw -and -not $Head -and -not $Options) {
      try { $result.Body = $result.Raw | ConvertFrom-Json } catch { $result.Body = $null }
    }
  } catch {
    # Extract the HTTP status from the exception if there was a response.
    $code = 0
    $resp = $null
    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
      $resp = $_.Exception.Response
      try {
        if ($resp.PSObject.Properties['StatusCode'] -and $null -ne $resp.StatusCode) {
          $code = [int]$resp.StatusCode.value__
        }
      } catch { $code = 0 }
      # PS7 carries the body on the exception for non-2xx.
      try {
        if ($_.PSObject.Properties['ErrorDetails'] -and $_.ErrorDetails -and $_.ErrorDetails.Message) {
          $result.Raw = [string]$_.ErrorDetails.Message
        }
      } catch { }
    }
    $result.Code    = $code
    $result.Ok      = $false
    $result.Headers = if ($resp -and $resp.PSObject.Properties['Headers']) { $resp.Headers } else { $null }
    if ($result.Raw -and -not $Head -and -not $Options) {
      try { $result.Body = $result.Raw | ConvertFrom-Json } catch { $result.Body = $null }
    }
  }
  return $result
}

# Convenience: extract the X-WP-Total header from a HEAD response, or "?".
function Get-WpTotal {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$WpUser,
    [Parameter(Mandatory=$true)][System.Security.SecureString]$SecurePassword
  )
  try {
    $r = Invoke-WpRest -Url $Url -Path $Path -WpUser $WpUser -SecurePassword $SecurePassword -Head
    if ($r.Ok -and $r.Headers) {
      $h = $r.Headers
      # Headers can be a Hashtable (PS5.1) or a header dictionary (PS7).
      $val = $null
      if ($h -is [System.Collections.IDictionary]) {
        if ($h.Contains('X-WP-Total')) { $val = $h['X-WP-Total'] }
      } else {
        try { $val = $h['X-WP-Total'] } catch { }
      }
      if ($val) {
        if ($val -is [array]) { $val = $val[0] }
        return [string]$val
      }
    }
  } catch { }
  return "?"
}

# Convenience: OPTIONS → the advertised Allow methods (string), or "?".
function Get-WpAllow {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$WpUser,
    [Parameter(Mandatory=$true)][System.Security.SecureString]$SecurePassword
  )
  try {
    $r = Invoke-WpRest -Url $Url -Path $Path -WpUser $WpUser -SecurePassword $SecurePassword -Options
    if ($r.Headers) {
      $h = $r.Headers
      $val = $null
      if ($h -is [System.Collections.IDictionary]) {
        if ($h.Contains('Allow')) { $val = $h['Allow'] }
      } else {
        try { $val = $h['Allow'] } catch { }
      }
      if ($val) {
        if ($val -is [array]) { $val = ($val -join ',') }
        return [string]$val
      }
    }
  } catch { }
  return "?"
}
