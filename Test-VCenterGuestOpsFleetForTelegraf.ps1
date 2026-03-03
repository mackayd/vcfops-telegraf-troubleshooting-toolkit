[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$vCenterServer,
  [Parameter(Mandatory = $true)][string]$TargetsCsv,
  [string]$VMNameColumn = 'VMName',
  [string]$GuestUserColumn = 'GuestUser',
  [string]$GuestPasswordColumn = 'GuestPassword',
  [switch]$PromptForGuestCredential,
  [string]$CredentialFile,
  [switch]$CreateTestFile,
  [string]$OutDir = '.'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $TargetsCsv)) { throw "Targets CSV not found: $TargetsCsv" }
$targets = Import-Csv $TargetsCsv
if (-not $PromptForGuestCredential -and -not $CredentialFile) { Write-Host 'WARNING: CSV-supplied guest passwords are handled as plaintext input. Prefer -CredentialFile or -PromptForGuestCredential where possible.' -ForegroundColor Yellow }
$globalCred = $null
if ($CredentialFile) { if (-not (Test-Path $CredentialFile)) { throw "Credential file not found: $CredentialFile" }; $globalCred = Import-Clixml -Path $CredentialFile }
elseif ($PromptForGuestCredential) { $globalCred = Get-Credential -Message 'Enter guest OS credential to use for all VMs' }
$scriptPath = Join-Path $PSScriptRoot 'Test-VCenterGuestOpsForTelegraf.ps1'
if (-not (Test-Path $scriptPath)) { throw "Missing script: $scriptPath" }
$results = New-Object System.Collections.Generic.List[object]
foreach ($t in $targets) {
  $vmName = $t.$VMNameColumn
  if ([string]::IsNullOrWhiteSpace($vmName)) { continue }
  Write-Host "=== GuestOps fleet test: $vmName ===" -ForegroundColor Cyan
  try {
    if ($globalCred) {
      $user = $globalCred.UserName; $pw = $globalCred.Password
    }
    else {
      $user = $t.$GuestUserColumn
      if ([string]::IsNullOrWhiteSpace($user)) { throw "Missing $GuestUserColumn for $vmName" }
      $pwPlain = $t.$GuestPasswordColumn
      if ([string]::IsNullOrWhiteSpace($pwPlain)) { throw "Missing $GuestPasswordColumn for $vmName (or use -PromptForGuestCredential)" }
      try {
        $pw = ConvertTo-SecureString $pwPlain -AsPlainText -Force
      }
      finally {
        $pwPlain = $null
      }
    }
    & $scriptPath -vCenterServer $vCenterServer -VMName $vmName -GuestUser $user -GuestPassword $pw -CreateTestFile:$CreateTestFile *>&1 | Tee-Object -Variable out | Out-Host
    $text = ($out | Out-String)
    $status = if ($text -match '\[FAIL\]') { 'FAIL' } elseif ($text -match '\[WARN\]') { 'WARN' } else { 'PASS' }
    $results.Add([pscustomobject]@{ VMName = $vmName; Status = $status; GuestUser = $user; Output = $text })
  }
  catch {
    $results.Add([pscustomobject]@{ VMName = $vmName; Status = 'FAIL'; GuestUser = $user; Output = $_.Exception.Message })
    Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
  }
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv = Join-Path $OutDir "GuestOpsFleetSummary-$stamp.csv"
$json = Join-Path $OutDir "GuestOpsFleetSummary-$stamp.json"
$results | Select-Object VMName, Status, GuestUser | Export-Csv -NoTypeInformation -Path $csv -Encoding utf8
$results | ConvertTo-Json -Depth 5 | Out-File $json -Encoding utf8
Write-Host "Guest Ops fleet summary written to: $csv and $json" -ForegroundColor Green
