[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BaselineJson,
  [Parameter(Mandatory=$true)][string]$CandidateJson,
  [string]$OutputCsv
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not (Test-Path $BaselineJson)){ throw "Baseline JSON not found: $BaselineJson" }
if(-not (Test-Path $CandidateJson)){ throw "Candidate JSON not found: $CandidateJson" }
$b = Get-Content $BaselineJson -Raw | ConvertFrom-Json
$c = Get-Content $CandidateJson -Raw | ConvertFrom-Json
if(-not $OutputCsv){ $OutputCsv = Join-Path (Split-Path -Parent $CandidateJson) ("KnownGoodDiff-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$mapB=@{}; foreach($i in $b){ if($i.Check){ $mapB[$i.Check]=$i } }
$mapC=@{}; foreach($i in $c){ if($i.Check){ $mapC[$i.Check]=$i } }
$allChecks = ($mapB.Keys + $mapC.Keys | Sort-Object -Unique)
$diff = foreach($k in $allChecks){
  $bi=$mapB[$k]; $ci=$mapC[$k]
  [pscustomobject]@{
    Check = $k
    BaselineStatus = $bi.Status
    CandidateStatus = $ci.Status
    StatusChanged = (($bi.Status -ne $ci.Status))
    BaselineMessage = $bi.Message
    CandidateMessage = $ci.Message
  }
}
$diff | Export-Csv -NoTypeInformation -Path $OutputCsv -Encoding utf8
Write-Host "Diff CSV written to: $OutputCsv" -ForegroundColor Green
