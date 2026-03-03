[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [string]$OutputHtml
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $InputPath)) { throw "InputPath not found: $InputPath" }
$files = @()
if ((Get-Item $InputPath).PSIsContainer) {
  $files += Get-ChildItem $InputPath -Recurse -File | Where-Object { $_.Name -match 'FleetSummary-.*\.(csv|json)$|EndpointCheck-.*\.json$' }
}
else { $files += Get-Item $InputPath }
if (-not $files) { throw 'No supported input files found.' }
$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
  if ($f.Extension -eq '.csv') {
    try { Import-Csv $f.FullName | ForEach-Object { $rows.Add($_) } } catch {}
  }
  elseif ($f.Extension -eq '.json') {
    try {
      $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
      if ($j -is [System.Collections.IEnumerable]) {
        foreach ($item in $j) {
          if ($item.Check -and $item.Status) {
            $rows.Add([pscustomobject]@{ Source = $f.Name; ComputerName = ($f.Name -replace '^EndpointCheck-([^\-]+).*', '$1'); Check = $item.Check; Status = $item.Status; Message = $item.Message })
          }
          else { $rows.Add($item) }
        }
      }
      else { $rows.Add($j) }
    }
    catch {}
  }
}
if (-not $OutputHtml) { $OutputHtml = Join-Path (Split-Path -Parent (Resolve-Path $InputPath)) ("VcfOps-Telegraf-Report-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$style = @"
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:20px} table{border-collapse:collapse;width:100%} th,td{border:1px solid #ddd;padding:6px;font-size:12px} th{background:#f4f4f4} .PASS{background:#eaf7ea}.WARN{background:#fff8e1}.FAIL{background:#fdecea}.INFO{background:#eef5ff}
</style>
"@
$summaryCounts = ($rows | Group-Object Status | Sort-Object Name | ForEach-Object { "<li><b>$($_.Name)</b>: $($_.Count)</li>" }) -join "`n"
$tableRows = foreach ($r in $rows) {
  $status = if ($r.Status) { [string]$r.Status } else { '' }
  $cls = $status.ToUpper()
  "<tr class='$cls'><td>$([System.Web.HttpUtility]::HtmlEncode(($r.ComputerName)))</td><td>$([System.Web.HttpUtility]::HtmlEncode(($r.Check)))</td><td>$([System.Web.HttpUtility]::HtmlEncode(($r.Status)))</td><td>$([System.Web.HttpUtility]::HtmlEncode(($r.Message)))</td><td>$([System.Web.HttpUtility]::HtmlEncode(($r.Source)))</td></tr>"
}
$html = @"
<html><head><title>VCF Ops Telegraf Toolkit Report</title>$style</head><body>
<h1>VCF Ops Telegraf Toolkit Consolidated Report</h1>
<p>Generated: $(Get-Date)</p>
<h2>Status Summary</h2><ul>$summaryCounts</ul>
<h2>Results</h2>
<table><thead><tr><th>Computer</th><th>Check</th><th>Status</th><th>Message</th><th>Source</th></tr></thead><tbody>
$($tableRows -join "`n")
</tbody></table>
</body></html>
"@
Set-Content -Path $OutputHtml -Value $html -Encoding utf8
Write-Host "HTML report written to: $OutputHtml" -ForegroundColor Green
