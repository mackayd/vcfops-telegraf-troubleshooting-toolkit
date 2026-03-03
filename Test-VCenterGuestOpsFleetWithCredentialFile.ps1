[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$vCenterServer,
  [Parameter(Mandatory = $true)][string]$TargetsCsv,
  [Parameter(Mandatory = $true)][string]$CredentialFile,
  [string]$VMNameColumn = 'VMName',
  [switch]$CreateTestFile,
  [string]$OutDir = '.'
)
& (Join-Path $PSScriptRoot 'Test-VCenterGuestOpsFleetForTelegraf.ps1') -vCenterServer $vCenterServer -TargetsCsv $TargetsCsv -CredentialFile $CredentialFile -VMNameColumn $VMNameColumn -CreateTestFile:$CreateTestFile -OutDir $OutDir
