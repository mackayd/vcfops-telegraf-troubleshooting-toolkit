[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BaselineJson,
  [Parameter(Mandatory = $true)][string]$CandidateFolder,
  [string]$OutDir = '.'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $BaselineJson)) { throw "Baseline JSON not found: $BaselineJson" }
if (-not (Test-Path $CandidateFolder)) { throw "CandidateFolder not found: $CandidateFolder" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$diffScript = Join-Path $PSScriptRoot 'Export-VcfOpsTelegrafKnownGoodDiff.ps1'
$files = Get-ChildItem $CandidateFolder -Recurse -File -Filter 'EndpointCheck-*.json' | Where-Object { $_.FullName -ne (Resolve-Path $BaselineJson).Path }
foreach ($f in $files) {
  $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $out = Join-Path $OutDir ("$name-diff.csv")
  & $diffScript -BaselineJson $BaselineJson -CandidateJson $f.FullName -OutputCsv $out
}
Write-Host "Compare mode complete. Diff CSVs in: $OutDir" -ForegroundColor Green
