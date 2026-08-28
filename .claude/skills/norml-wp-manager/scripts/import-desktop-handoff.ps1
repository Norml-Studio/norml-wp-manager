#requires -Version 5.1
param([Parameter(Mandatory=$true, Position=0)][string]$SiteFolder)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SiteFolder = (Resolve-Path $SiteFolder).Path
$WpmDir = Join-Path $SiteFolder '.wpm'
$ConfigFile = Join-Path $WpmDir 'config.json'
$HandoffFile = Join-Path $WpmDir 'credential.handoff'
$CredentialFile = Join-Path $WpmDir 'credential'
$TemplatesDir = Join-Path (Split-Path -Parent $ScriptDir) 'templates'

if (-not (Test-Path $ConfigFile)) { throw "$ConfigFile is missing. Run connect.html first." }
if (-not (Test-Path $HandoffFile)) { throw "$HandoffFile is missing. Run connect.html first." }

if (Get-Command git -ErrorAction SilentlyContinue) {
  & git -C $WpmDir rev-parse --is-inside-work-tree 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    & git -C $WpmDir check-ignore $HandoffFile 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'SECURITY ABORT: Git does not ignore credential.handoff. Nothing was imported.' }
  }
}

foreach ($privatePath in @($HandoffFile, $ConfigFile)) {
  & icacls $privatePath /inheritance:r /grant:r "$($env:USERNAME):M" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not lock $privatePath to the current Windows user." }
}

$secret = ([IO.File]::ReadAllText($HandoffFile) -replace '\s','')
if ([string]::IsNullOrWhiteSpace($secret)) { throw 'The handoff is empty.' }
New-Item -ItemType File -Force -Path $CredentialFile | Out-Null
& icacls $CredentialFile /inheritance:r /grant:r "$($env:USERNAME):M" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not lock the credential file to the current Windows user.' }
[IO.File]::WriteAllText($CredentialFile, $secret, (New-Object Text.UTF8Encoding($false)))
$secret = $null

try {
  & (Join-Path $ScriptDir 'test-connection.ps1') -SiteFolder $SiteFolder
  if ($LASTEXITCODE -ne 0) { throw 'Authentication failed.' }
} catch {
  Remove-Item -Force $CredentialFile -ErrorAction SilentlyContinue
  throw 'Authentication failed. The handoff remains so you can correct the site details and retry.'
}

$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$siteName = $cfg.site_name
$today = Get-Date -Format 'yyyy-MM-dd'
$time = Get-Date -Format 'HH:mm'
function Write-TemplateIfMissing([string]$template, [string]$target) {
  if (Test-Path $target) { return }
  $content = Get-Content (Join-Path $TemplatesDir $template) -Raw
  $content = $content.Replace('{SITE_NAME}', [string]$siteName).Replace('{TODAY}', $today).Replace('{TIME}', $time)
  Set-Content -Path $target -Value $content -Encoding UTF8
}
Write-TemplateIfMissing 'readme-template.md' (Join-Path $SiteFolder 'README.md')
Write-TemplateIfMissing 'project-notes-template.md' (Join-Path $SiteFolder 'project-notes.md')
Write-TemplateIfMissing 'changelog-template.md' (Join-Path $SiteFolder 'changelog.md')

Remove-Item -Force $HandoffFile
$cfg | Add-Member -NotePropertyName connection_state -NotePropertyValue 'connected' -Force
$cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
& (Join-Path $ScriptDir 'scan-site.ps1') -SiteFolder $SiteFolder -Stage all
Write-Host 'Connection imported. The short-lived handoff was deleted.'
Write-Host "Capabilities: $(Join-Path $SiteFolder 'capabilities.md')"
