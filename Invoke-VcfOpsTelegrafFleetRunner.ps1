[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$TargetsCsv,
  [Parameter(Mandatory=$true)][string]$CloudProxyFqdn,
  [string]$ToolkitPath = $PSScriptRoot,
  [string]$OutDir = 'C:\Temp\VcfOpsTelegrafFleet',
  [switch]$CollectDiagOnFailure,
  [switch]$ContinueOnError
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not (Test-Path $TargetsCsv)){ throw "Targets CSV not found: $TargetsCsv" }
if(-not (Test-Path $OutDir)){ New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$targets = Import-Csv $TargetsCsv
$summary = New-Object System.Collections.Generic.List[object]
foreach($t in $targets){
  $computer = $t.ComputerName
  if([string]::IsNullOrWhiteSpace($computer)){ continue }
  Write-Host "=== $computer ===" -ForegroundColor Cyan
  $row=[ordered]@{ ComputerName=$computer; Reachable=$false; EndpointScript=$null; EndpointStatus=''; Notes='' }
  try {
    if(-not (Test-WSMan -ComputerName $computer -ErrorAction Stop)){ throw 'WinRM not available' }
    $row.Reachable = $true
    $remoteOut = if($t.OutDir){ $t.OutDir } else { 'C:\Temp\VcfOpsTelegrafDiag' }
    $scriptPath = Join-Path $ToolkitPath 'Test-VcfOpsTelegrafEndpoint.ps1'
    if(-not (Test-Path $scriptPath)){ throw "Missing script: $scriptPath" }
    $copyDest = "C:\Temp\Test-VcfOpsTelegrafEndpoint.ps1"
    $sess = New-PSSession -ComputerName $computer -ErrorAction Stop
    try {
      Copy-Item -ToSession $sess -Path $scriptPath -Destination $copyDest -Force
      $r = Invoke-Command -Session $sess -ScriptBlock {
        param($cp,$od)
        powershell.exe -ExecutionPolicy Bypass -File C:\Temp\Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn $cp -OutDir $od
        $LASTEXITCODE
      } -ArgumentList $CloudProxyFqdn,$remoteOut
      $row.EndpointScript = 'Executed'
      $row.EndpointStatus = 'Completed'
      $row.Notes = ($r | Out-String).Trim()
      if($CollectDiagOnFailure -and ($row.Notes -match '\[FAIL\]')){
        $diagScript = Join-Path $ToolkitPath 'Collect-VcfOpsTelegrafDeployDiag.ps1'
        Copy-Item -ToSession $sess -Path $diagScript -Destination C:\Temp\Collect-VcfOpsTelegrafDeployDiag.ps1 -Force
        Invoke-Command -Session $sess -ScriptBlock { powershell.exe -ExecutionPolicy Bypass -File C:\Temp\Collect-VcfOpsTelegrafDeployDiag.ps1 -LookbackHours 4 } | Out-Null
      }
    } finally { Remove-PSSession $sess }
  } catch {
    $row.EndpointStatus='Failed'; $row.Notes=$_.Exception.Message
    Write-Host "Failed: $($row.Notes)" -ForegroundColor Red
    if(-not $ContinueOnError){ }
  }
  $summary.Add([pscustomobject]$row)
}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'; $sumCsv=Join-Path $OutDir "FleetSummary-$stamp.csv"; $sumJson=Join-Path $OutDir "FleetSummary-$stamp.json"
$summary | Export-Csv -NoTypeInformation -Path $sumCsv -Encoding utf8
$summary | ConvertTo-Json -Depth 6 | Out-File $sumJson -Encoding utf8
Write-Host "Fleet summary written to: $sumCsv and $sumJson" -ForegroundColor Green
