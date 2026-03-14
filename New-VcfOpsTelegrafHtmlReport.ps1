[CmdletBinding()]
param(
  [string]$InputPath,
  [string]$OutputHtml,
  [Alias('h','Help')][switch]$ShowHelp,
  [switch]$Full,
  [switch]$Examples
)


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-UsageHelp {
@"
VCF Operations Telegraf HTML Report Generator

Usage
  .\New-VcfOpsTelegrafHtmlReport.ps1 -InputPath <path> [-OutputHtml <file>]
  .\New-VcfOpsTelegrafHtmlReport.ps1 -h
  .\New-VcfOpsTelegrafHtmlReport.ps1 -Full
  .\New-VcfOpsTelegrafHtmlReport.ps1 -Examples

What it does
  Reads one fleet summary file or a folder of compatible JSON/CSV outputs and builds a consolidated HTML report.
  The report groups results by computer/VM and shows status summary counts.

Supported inputs
  - FleetSummary-*.json / FleetSummary-*.csv
  - GuestOpsFleetSummary-*.json / GuestOpsFleetSummary-*.csv
  - EndpointCheck-*.json
  - A folder containing those files

Output
  - If -OutputHtml is specified, the report is written there.
  - If -OutputHtml is omitted, the script creates a timestamped HTML file in the same folder as InputPath.

Run -Full for detailed help or -Examples for sample commands.
"@ | Write-Host
}

function Show-FullHelp {
@"
VCF Operations Telegraf HTML Report Generator - Detailed Help

Overview
  This script converts supported Telegraf toolkit CSV/JSON outputs into a single HTML report.
  It can process either:
    - a single input file, or
    - a folder containing multiple supported result files

How it works
  1. Reads the supplied file or scans the supplied folder recursively.
  2. Loads compatible fleet summary or endpoint result files.
  3. Normalises the data into report rows.
  4. Groups results by computer/VM.
  5. Produces an HTML report with:
       - overall status counts
       - per-computer result sections
       - check, status, message, and source columns

InputPath
  Supply either:
    - a single JSON or CSV result file, or
    - a folder containing supported result files

Supported file naming patterns
  - FleetSummary-*.json
  - FleetSummary-*.csv
  - GuestOpsFleetSummary-*.json
  - GuestOpsFleetSummary-*.csv
  - EndpointCheck-*.json

OutputHtml
  Optional.
  If omitted, a file named like the following is created in the same folder as InputPath:
    VcfOps-Telegraf-Report-YYYYMMDD-HHMMSS.html

Guest Ops and vCenter fleet compatibility
  This report writer is intended to work with both:
    - vCenter fleet summary outputs
    - Guest Ops fleet summary outputs

  For Guest Ops JSON produced by the current fleet runner, the report expects the JSON Output field
  to contain the legacy-style Validation Summary block so that checks can be parsed line-by-line.

Typical workflow
  1. Run the fleet validation script and generate JSON/CSV.
  2. Run this report script against the JSON file or the containing folder.
  3. Open the resulting HTML report in a browser.

Notes
  - This script only reads and reports on existing results; it does not perform endpoint testing itself.
  - If a folder is supplied, unsupported files are ignored.
  - If no compatible rows can be derived from the input, the script stops with an error.

Help switches
  -h or -Help
      Show short usage help.
  -Full
      Show this detailed help.
  -Examples
      Show practical examples.

Examples
  Run -Examples to display sample commands.
"@ | Write-Host
}

function Show-ExamplesHelp {
@"
Examples

1. Build a report from a single Guest Ops JSON file
  .\New-VcfOpsTelegrafHtmlReport.ps1 `
    -InputPath .\GuestOpsFleetSummary-20260313-204315.json `
    -OutputHtml .\GuestFleetReport.html

2. Build a report from a single vCenter fleet JSON file
  .\New-VcfOpsTelegrafHtmlReport.ps1 `
    -InputPath .\FleetSummary-20260313-181057.json `
    -OutputHtml .\vCenterFleetReport.html

3. Build a report from a folder of result files
  .\New-VcfOpsTelegrafHtmlReport.ps1 `
    -InputPath .\Results `
    -OutputHtml .\CombinedFleetReport.html

4. Let the script choose the output HTML filename automatically
  .\New-VcfOpsTelegrafHtmlReport.ps1 `
    -InputPath .\Results

5. Show short help
  .\New-VcfOpsTelegrafHtmlReport.ps1 -h

6. Show full help
  .\New-VcfOpsTelegrafHtmlReport.ps1 -Full

7. Show examples
  .\New-VcfOpsTelegrafHtmlReport.ps1 -Examples
"@ | Write-Host
}

if ($ShowHelp -or $Full -or $Examples) {
  if ($Full) {
    Show-FullHelp
  }
  elseif ($Examples) {
    Show-ExamplesHelp
  }
  else {
    Show-UsageHelp
  }
  return
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
  throw 'InputPath is required. Use -h, -Full, or -Examples for help.'
}

if (-not (Test-Path $InputPath)) {
  throw "InputPath not found: $InputPath"
}

function Encode-Html {
  param([AllowNull()][object]$Value)
  return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-Slug {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return 'item-unknown' }
  $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-|-$)', ''
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'item-unknown' }
  return $slug
}

function Get-ItemPropertyValue {
  param(
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $property = $Item.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function New-ReportRow {
  param(
    [string]$Source,
    [string]$ComputerName,
    [string]$Check,
    [string]$Status,
    [string]$Message
  )

  return [pscustomobject]@{
    Source       = $Source
    ComputerName = $ComputerName
    Check        = $Check
    Status       = $Status
    Message      = $Message
  }
}

function Add-EndpointResultItem {
  param(
    [System.Collections.Generic.List[object]]$Rows,
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$SourceName,
    [string]$DefaultComputerName
  )

  $Rows.Add((New-ReportRow -Source $SourceName -ComputerName $DefaultComputerName -Check ([string](Get-ItemPropertyValue -Item $Item -Name 'Check')) -Status ([string](Get-ItemPropertyValue -Item $Item -Name 'Status')) -Message ([string](Get-ItemPropertyValue -Item $Item -Name 'Message')))) | Out-Null
}

function Ensure-VmSummary {
  param(
    [hashtable]$VmMap,
    [string]$VmName,
    [string]$SourceName
  )

  if ([string]::IsNullOrWhiteSpace($VmName)) { $VmName = 'Unknown' }
  if (-not $VmMap.ContainsKey($VmName)) {
    $VmMap[$VmName] = [ordered]@{
      VMName                  = $VmName
      Status                  = 'INFO'
      GuestUser               = ''
      CredentialSource        = ''
      CredentialSourceDetail  = ''
      RequestedTargetOs       = ''
      DetectedTargetOs        = ''
      OsDetectionSource       = ''
      GuestFullName           = ''
      UseSudo                 = ''
      CloudProxy              = ''
      AltCredentialFile       = ''
      Output                  = ''
      Source                  = $SourceName
      Rows                    = New-Object System.Collections.Generic.List[object]
      Suggestions             = New-Object System.Collections.Generic.List[string]
    }
  }
  return $VmMap[$VmName]
}

function Add-FleetSummaryItem {
  param(
    [System.Collections.Generic.List[object]]$Rows,
    [hashtable]$VmMap,
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$SourceName
  )

  $vmName = [string](Get-ItemPropertyValue -Item $Item -Name 'VMName')
  if ([string]::IsNullOrWhiteSpace($vmName)) { $vmName = 'Unknown' }

  $vmSummary = Ensure-VmSummary -VmMap $VmMap -VmName $vmName -SourceName $SourceName
  $vmSummary.Status                 = [string](Get-ItemPropertyValue -Item $Item -Name 'Status')
  $vmSummary.GuestUser              = [string](Get-ItemPropertyValue -Item $Item -Name 'GuestUser')
  $vmSummary.CredentialSource       = [string](Get-ItemPropertyValue -Item $Item -Name 'CredentialSource')
  $vmSummary.CredentialSourceDetail = [string](Get-ItemPropertyValue -Item $Item -Name 'CredentialSourceDetail')
  $vmSummary.RequestedTargetOs      = [string](Get-ItemPropertyValue -Item $Item -Name 'RequestedTargetOs')
  $vmSummary.DetectedTargetOs       = [string](Get-ItemPropertyValue -Item $Item -Name 'DetectedTargetOs')
  $vmSummary.OsDetectionSource      = [string](Get-ItemPropertyValue -Item $Item -Name 'OsDetectionSource')
  $vmSummary.GuestFullName          = [string](Get-ItemPropertyValue -Item $Item -Name 'GuestFullName')
  $vmSummary.UseSudo                = [string](Get-ItemPropertyValue -Item $Item -Name 'UseSudo')
  $vmSummary.CloudProxy             = [string](Get-ItemPropertyValue -Item $Item -Name 'CloudProxy')
  $vmSummary.AltCredentialFile      = [string](Get-ItemPropertyValue -Item $Item -Name 'AltCredentialFile')
  $vmSummary.Output                 = [string](Get-ItemPropertyValue -Item $Item -Name 'Output')

  $overviewParts = New-Object System.Collections.Generic.List[string]
  if ($vmSummary.GuestUser)              { $overviewParts.Add("Guest user: $($vmSummary.GuestUser)") }
  if ($vmSummary.RequestedTargetOs)      { $overviewParts.Add("Requested OS: $($vmSummary.RequestedTargetOs)") }
  if ($vmSummary.DetectedTargetOs)       { $overviewParts.Add("Detected OS: $($vmSummary.DetectedTargetOs)") }
  if ($vmSummary.UseSudo -ne '')         { $overviewParts.Add("Use sudo: $($vmSummary.UseSudo)") }
  if ($vmSummary.CloudProxy)             { $overviewParts.Add("Cloud Proxy: $($vmSummary.CloudProxy)") }
  if ($vmSummary.CredentialSource)       { $overviewParts.Add("Credential source: $($vmSummary.CredentialSource)") }
  if ($vmSummary.CredentialSourceDetail) { $overviewParts.Add("Credential detail: $($vmSummary.CredentialSourceDetail)") }

  $fleetRow = New-ReportRow -Source $SourceName -ComputerName $vmName -Check 'Fleet summary' -Status $vmSummary.Status -Message ($overviewParts -join ' | ')
  $Rows.Add($fleetRow) | Out-Null
  $vmSummary.Rows.Add($fleetRow) | Out-Null

  $outputText = $vmSummary.Output
  if ([string]::IsNullOrWhiteSpace($outputText)) {
    return
  }

  $currentComputer = $vmName
  $lastRow = $null
  $inSuggestions = $false

  foreach ($rawLine in ($outputText -split "`r?`n")) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    if ($line -eq 'Suggestions:') {
      $inSuggestions = $true
      continue
    }

    if ($inSuggestions) {
      if ($currentComputer -eq $vmName) {
        $vmSummary.Suggestions.Add($line) | Out-Null
      }
      continue
    }

    if ($line -match '^(Telegraf VM target|Cloud Proxy) : (.+)$') {
      $currentComputer = $Matches[2].Trim()
      if ($currentComputer -eq $vmName) {
        $lastRow = $null
      }
      continue
    }

    if ($line -match '^(PASS|WARN|FAIL|INFO) : (.+)$') {
      $newRow = New-ReportRow -Source $SourceName -ComputerName $currentComputer -Check $Matches[2].Trim() -Status $Matches[1].Trim() -Message ''
      $Rows.Add($newRow) | Out-Null
      $targetSummary = Ensure-VmSummary -VmMap $VmMap -VmName $currentComputer -SourceName $SourceName
      $targetSummary.Rows.Add($newRow) | Out-Null
      $lastRow = $newRow
      continue
    }

    if ($line -match '^Message: (.+)$' -and $null -ne $lastRow) {
      $lastRow.Message = $Matches[1].Trim()
    }
  }
}

function Add-InputItem {
  param(
    [System.Collections.Generic.List[object]]$Rows,
    [hashtable]$VmMap,
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$SourceName
  )

  $propertyNames = @($Item.PSObject.Properties.Name)
  if ($propertyNames -contains 'VMName' -and $propertyNames -contains 'Status') {
    Add-FleetSummaryItem -Rows $Rows -VmMap $VmMap -Item $Item -SourceName $SourceName
    return
  }

  if ($propertyNames -contains 'Check' -and $propertyNames -contains 'Status') {
    $defaultComputerName = if ($propertyNames -contains 'ComputerName') { [string](Get-ItemPropertyValue -Item $Item -Name 'ComputerName') } else { ($SourceName -replace '^EndpointCheck-([^\-]+).*', '$1') }
    $row = New-ReportRow -Source $SourceName -ComputerName $defaultComputerName -Check ([string](Get-ItemPropertyValue -Item $Item -Name 'Check')) -Status ([string](Get-ItemPropertyValue -Item $Item -Name 'Status')) -Message ([string](Get-ItemPropertyValue -Item $Item -Name 'Message'))
    $Rows.Add($row) | Out-Null
    $vmSummary = Ensure-VmSummary -VmMap $VmMap -VmName $defaultComputerName -SourceName $SourceName
    $vmSummary.Rows.Add($row) | Out-Null
  }
}

$files = @()
if ((Get-Item $InputPath).PSIsContainer) {
  $files += Get-ChildItem $InputPath -Recurse -File | Where-Object { $_.Name -match 'FleetSummary-.*\.(csv|json)$|GuestOpsFleetSummary-.*\.(csv|json)$|EndpointCheck-.*\.json$' }
}
else {
  $files += Get-Item $InputPath
}

if (-not $files) {
  throw 'No supported input files found.'
}

$rows = New-Object System.Collections.Generic.List[object]
$vmMap = @{}
$loadErrors = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
  if ($f.Extension -eq '.csv') {
    try {
      Import-Csv $f.FullName | ForEach-Object { Add-InputItem -Rows $rows -VmMap $vmMap -Item $_ -SourceName $f.Name }
    }
    catch {
      $loadErrors.Add("Failed to parse $($f.Name): $($_.Exception.Message)") | Out-Null
    }
  }
  elseif ($f.Extension -eq '.json') {
    try {
      $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
      if ($j -is [System.Collections.IEnumerable] -and -not ($j -is [string])) {
        foreach ($item in $j) {
          Add-InputItem -Rows $rows -VmMap $vmMap -Item $item -SourceName $f.Name
        }
      }
      else {
        Add-InputItem -Rows $rows -VmMap $vmMap -Item $j -SourceName $f.Name
      }
    }
    catch {
      $loadErrors.Add("Failed to parse $($f.Name): $($_.Exception.Message)") | Out-Null
    }
  }
}

if ($rows.Count -eq 0) {
  if ($loadErrors.Count -gt 0) {
    throw ("No compatible report rows could be derived from the supplied input files.`n" + ($loadErrors -join "`n"))
  }
  throw 'No compatible report rows could be derived from the supplied input files.'
}

if (-not $OutputHtml) {
  $targetFolder = Split-Path -Parent (Resolve-Path $InputPath)
  $OutputHtml = Join-Path $targetFolder ("VcfOps-Telegraf-Interactive-Report-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$vmSummaries = @($vmMap.GetEnumerator() | ForEach-Object { [pscustomobject]$_.Value } | Sort-Object VMName)

$statusOrder = @('PASS','WARN','FAIL','INFO')
$vmStatusCounts = @{}
$rowStatusCounts = @{}
foreach ($statusName in $statusOrder) {
  $vmStatusCounts[$statusName] = 0
  $rowStatusCounts[$statusName] = 0
}
foreach ($vm in $vmSummaries) {
  $status = ([string]$vm.Status).ToUpperInvariant()
  if (-not $vmStatusCounts.ContainsKey($status)) { $vmStatusCounts[$status] = 0 }
  $vmStatusCounts[$status]++
}
foreach ($row in $rows) {
  $status = ([string]$row.Status).ToUpperInvariant()
  if (-not $rowStatusCounts.ContainsKey($status)) { $rowStatusCounts[$status] = 0 }
  $rowStatusCounts[$status]++
}

$totalVms = [Math]::Max($vmSummaries.Count, 1)
$passPct = [math]::Round(($vmStatusCounts['PASS'] / $totalVms) * 100)
$warnPct = [math]::Round(($vmStatusCounts['WARN'] / $totalVms) * 100)
$failPct = [math]::Round(($vmStatusCounts['FAIL'] / $totalVms) * 100)
$infoPct = [math]::Round(($vmStatusCounts['INFO'] / $totalVms) * 100)

$stackSegments = foreach ($status in @('PASS','WARN','FAIL','INFO')) {
  $count = if ($vmStatusCounts.ContainsKey($status)) { [int]$vmStatusCounts[$status] } else { 0 }
  if ($count -le 0) { continue }
  $width = [math]::Round(($count / $totalVms) * 100, 2)
  "<div class='stack-segment $status' style='width:${width}%'><span>$status $count</span></div>"
}

$statusCards = foreach ($status in @('PASS','WARN','FAIL','INFO')) {
  $count = if ($vmStatusCounts.ContainsKey($status)) { [int]$vmStatusCounts[$status] } else { 0 }
  "<div class='stat-card $status'><div class='stat-label'>$status VMs</div><div class='stat-value'>$count</div></div>"
}

$vmNavItems = foreach ($vm in $vmSummaries) {
  $vmId = ConvertTo-Slug $vm.VMName
  $status = if ([string]::IsNullOrWhiteSpace([string]$vm.Status)) { 'INFO' } else { ([string]$vm.Status).ToUpperInvariant() }
  $detectedOs = if ($vm.DetectedTargetOs) { $vm.DetectedTargetOs } else { 'Unknown' }
  $credSource = if ($vm.CredentialSource) { $vm.CredentialSource } else { 'N/A' }
  @"
<button type='button' class='vm-nav-item $status' data-vm-id='$vmId' data-status='$status'>
  <span class='vm-nav-title'>$(Encode-Html $vm.VMName)</span>
  <span class='vm-nav-meta'>$(Encode-Html $detectedOs) · $(Encode-Html $status)</span>
  <span class='vm-nav-sub'>$(Encode-Html $credSource)</span>
</button>
"@
}


$allVmCards = foreach ($vm in $vmSummaries) {
  $vmId = ConvertTo-Slug $vm.VMName
  $status = if ([string]::IsNullOrWhiteSpace([string]$vm.Status)) { 'INFO' } else { ([string]$vm.Status).ToUpperInvariant() }
  $topChecks = @($vm.Rows | Where-Object { $_.Check -ne 'Fleet summary' } | Select-Object -First 4)
  $miniRows = foreach ($r in $topChecks) {
    $rowStatus = if ([string]::IsNullOrWhiteSpace([string]$r.Status)) { 'INFO' } else { ([string]$r.Status).ToUpperInvariant() }
    "<li><span class='mini-check-name'>$(Encode-Html $r.Check)</span><span class='badge $rowStatus'>$(Encode-Html $r.Status)</span></li>"
  }
  $detailLine = @()
  if ($vm.DetectedTargetOs) { $detailLine += "OS: $($vm.DetectedTargetOs)" }
  if ($vm.GuestUser) { $detailLine += "User: $($vm.GuestUser)" }
  if ($vm.CredentialSource) { $detailLine += "Creds: $($vm.CredentialSource)" }
  @"
<article class='vm-overview-card $status' data-status='$status'>
  <div class='vm-overview-top'>
    <div>
      <div class='eyebrow'>Virtual Machine</div>
      <h3>$(Encode-Html $vm.VMName)</h3>
      <p>$(Encode-Html (($detailLine -join ' · ')))</p>
    </div>
    <div class='overview-actions'>
      <span class='badge large $status'>$(Encode-Html $status)</span>
      <button type='button' class='view-vm-btn' data-vm-id='$vmId'>Open details</button>
    </div>
  </div>
  <ul class='mini-check-list'>
    $($miniRows -join "`n")
  </ul>
</article>
"@
}

$vmPanels = foreach ($vm in $vmSummaries) {
  $vmId = ConvertTo-Slug $vm.VMName
  $status = if ([string]::IsNullOrWhiteSpace([string]$vm.Status)) { 'INFO' } else { ([string]$vm.Status).ToUpperInvariant() }

  $detailCards = @(
    @{Label='Detected OS'; Value=if ($vm.DetectedTargetOs) { $vm.DetectedTargetOs } else { 'Unknown' } },
    @{Label='Guest'; Value=if ($vm.GuestFullName) { $vm.GuestFullName } else { 'Unknown' } },
    @{Label='Credential Source'; Value=if ($vm.CredentialSource) { $vm.CredentialSource } else { 'N/A' } },
    @{Label='Guest User'; Value=if ($vm.GuestUser) { $vm.GuestUser } else { 'N/A' } },
    @{Label='Cloud Proxy'; Value=if ($vm.CloudProxy) { $vm.CloudProxy } else { 'N/A' } },
    @{Label='Use Sudo'; Value=if ($vm.UseSudo -ne '') { [string]$vm.UseSudo } else { 'N/A' } }
  )

  $detailGrid = foreach ($card in $detailCards) {
    "<div class='detail-card'><div class='detail-label'>$(Encode-Html $card.Label)</div><div class='detail-value'>$(Encode-Html $card.Value)</div></div>"
  }

  $tableRows = foreach ($r in $vm.Rows) {
    $rowStatus = if ([string]::IsNullOrWhiteSpace([string]$r.Status)) { 'INFO' } else { ([string]$r.Status).ToUpperInvariant() }
    @"
<tr class='$rowStatus'>
  <td>$(Encode-Html $r.Check)</td>
  <td><span class='badge $rowStatus'>$(Encode-Html $r.Status)</span></td>
  <td>$(Encode-Html $r.Message)</td>
  <td>$(Encode-Html $r.Source)</td>
</tr>
"@
  }

  $suggestionsHtml = ''
  if ($vm.Suggestions.Count -gt 0) {
    $suggestionItems = foreach ($s in $vm.Suggestions) {
      "<li>$(Encode-Html $s)</li>"
    }
    $suggestionsHtml = @"
<div class='panel-card'>
  <h3>Suggestions</h3>
  <ul class='suggestion-list'>
    $($suggestionItems -join "`n")
  </ul>
</div>
"@
  }

  $rawOutputHtml = ''
  if (-not [string]::IsNullOrWhiteSpace([string]$vm.Output)) {
    $rawOutputHtml = @"
<div class='panel-card'>
  <button type='button' class='raw-toggle' data-target='raw-$vmId'>Show Raw Output</button>
  <pre id='raw-$vmId' class='raw-output hidden'>$(Encode-Html $vm.Output)</pre>
</div>
"@
  }

  @"
<section class='vm-panel' id='panel-$vmId' data-status='$status'>
  <div class='panel-header'>
    <div>
      <div class='eyebrow'>Virtual Machine</div>
      <h2>$(Encode-Html $vm.VMName)</h2>
      <p class='panel-subtitle'>$(Encode-Html $vm.OsDetectionSource)</p>
    </div>
    <span class='badge large $status'>$(Encode-Html $status)</span>
  </div>

  <div class='detail-grid'>
    $($detailGrid -join "`n")
  </div>

  <div class='panel-card'>
    <h3>Validation Checks</h3>
    <div class='table-wrap'>
      <table>
        <thead>
          <tr><th>Check</th><th>Status</th><th>Message</th><th>Source</th></tr>
        </thead>
        <tbody>
          $($tableRows -join "`n")
        </tbody>
      </table>
    </div>
  </div>

  $suggestionsHtml
  $rawOutputHtml
</section>
"@
}

$style = @"
<style>
:root{--bg:#0b1220;--panel:#111a2b;--panel2:#17233a;--text:#e8eef8;--muted:#9fb0c8;--border:#243650;--accent:#69b1ff;--pass:#2e7d32;--warn:#f9a825;--fail:#c62828;--info:#1565c0;--shadow:0 12px 40px rgba(0,0,0,.35)}
*{box-sizing:border-box}
body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:linear-gradient(180deg,#09101d,#0f1728 25%,#0d1321);color:var(--text)}
.container{max-width:1680px;margin:0 auto;padding:24px}
.hero{background:linear-gradient(135deg,#15315c,#101b31 55%,#113b34);border:1px solid var(--border);border-radius:24px;padding:28px;box-shadow:var(--shadow);margin-bottom:20px}
.hero-top{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;flex-wrap:wrap}
.hero h1{margin:0 0 8px;font-size:32px}
.hero p{margin:0;color:#d2def0}
.hero-note{font-size:13px;color:#aebfd6;margin-top:8px}
.badge{display:inline-flex;align-items:center;justify-content:center;min-width:70px;padding:6px 12px;border-radius:999px;font-weight:700;font-size:12px;letter-spacing:.4px;text-transform:uppercase}
.badge.PASS{background:#1b5e20;color:#d6ffd6}.badge.WARN{background:#7a5a00;color:#fff0b5}.badge.FAIL{background:#7f1d1d;color:#ffd6d6}.badge.INFO{background:#0d47a1;color:#dce9ff}
.badge.large{padding:10px 16px;font-size:13px}
.hero-grid{display:grid;grid-template-columns:2fr 1fr;gap:20px;margin-top:24px}
.stack-card,.score-card,.sidebar-card,.panel-card,.panel-header,.detail-card,.stat-card,.vm-overview-card{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:20px}
.stack-card,.score-card,.sidebar-card,.panel-card,.panel-header,.detail-card,.stat-card,.vm-overview-card{padding:20px}
.stack-bar{display:flex;height:54px;border-radius:18px;overflow:hidden;margin-top:18px;background:#0f1728;border:1px solid rgba(255,255,255,.1)}
.stack-segment{display:flex;align-items:center;justify-content:center;font-weight:700;font-size:13px;white-space:nowrap}.stack-segment span{padding:0 10px}
.stack-segment.PASS{background:var(--pass)}.stack-segment.WARN{background:var(--warn);color:#111}.stack-segment.FAIL{background:var(--fail)}.stack-segment.INFO{background:var(--info)}
.score-card{display:flex;align-items:center;justify-content:center}
.score-ring{width:180px;height:180px;border-radius:50%;background:conic-gradient(var(--pass) 0 $passPct%, var(--warn) $passPct% $([Math]::Min(100, $passPct + $warnPct))%, var(--fail) $([Math]::Min(100, $passPct + $warnPct))% $([Math]::Min(100, $passPct + $warnPct + $failPct))%, var(--info) $([Math]::Min(100, $passPct + $warnPct + $failPct))% 100%);display:flex;align-items:center;justify-content:center}
.score-ring-content{width:130px;height:130px;border-radius:50%;background:#0f1728;display:flex;flex-direction:column;align-items:center;justify-content:center}
.score-ring-value{font-size:44px;font-weight:800}.score-ring-label{color:var(--muted);font-size:13px;text-transform:uppercase;letter-spacing:.06em}
.stats{display:grid;grid-template-columns:repeat(5,1fr);gap:16px;margin:20px 0}
.stat-card{padding:18px}.stat-label{color:var(--muted);font-size:13px}.stat-value{font-size:34px;font-weight:800;margin-top:8px}
.main-grid{display:grid;grid-template-columns:340px 1fr;gap:20px;align-items:start}.sidebar,.content{min-width:0}
.sidebar-card{position:sticky;top:20px}
.section-title{margin:0 0 6px;font-size:18px}.section-subtitle{margin:0 0 16px;color:var(--muted);font-size:13px}
.filter-bar,.view-mode-toggle{display:flex;gap:10px;flex-wrap:wrap;margin:14px 0 18px}
button{cursor:pointer;border:none}.filter-btn,.view-btn,.open-btn,.view-vm-btn,.raw-toggle{padding:10px 14px;border-radius:12px;background:#18253b;color:var(--text);border:1px solid var(--border);font-weight:600}
.filter-btn.active,.view-btn.active{background:#1d4ed8;border-color:#3b82f6}
.vm-nav{display:flex;flex-direction:column;gap:10px;max-height:calc(100vh - 300px);overflow:auto;padding-right:4px}
.vm-nav-item{width:100%;text-align:left;padding:12px 14px;border-radius:14px;background:#141f33;border:1px solid var(--border);color:var(--text);display:flex;flex-direction:column;gap:4px}
.vm-nav-item:hover,.vm-overview-card:hover{box-shadow:0 8px 24px rgba(0,0,0,.22);transform:translateY(-1px)}
.vm-nav-item.active{outline:2px solid #3b82f6;background:#18253b}
.vm-nav-item.PASS{border-left:6px solid var(--pass)}.vm-nav-item.WARN{border-left:6px solid var(--warn)}.vm-nav-item.FAIL{border-left:6px solid var(--fail)}.vm-nav-item.INFO{border-left:6px solid var(--info)}
.vm-nav-title{font-weight:800}.vm-nav-meta,.vm-nav-sub{font-size:12px;color:var(--muted)}
.vm-panel{display:none;flex-direction:column;gap:18px}.vm-panel.active{display:flex}
.panel-header{display:flex;justify-content:space-between;align-items:flex-start;gap:14px}
.eyebrow{text-transform:uppercase;letter-spacing:.08em;font-size:11px;color:var(--muted);font-weight:700}.panel-header h2{margin:4px 0 6px;font-size:28px}.panel-subtitle{margin:0;color:var(--muted)}
.detail-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px}.detail-label{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin-bottom:8px}.detail-value{font-size:15px;font-weight:700;word-break:break-word}
.panel-card h3{margin:0 0 14px;font-size:18px}
.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse}th,td{padding:12px;border-bottom:1px solid var(--border);text-align:left;vertical-align:top}th{color:#c9d8ee;font-size:13px;background:#101a2d;position:sticky;top:0}td{font-size:14px;color:#e9f1fd}
tr.PASS td{background:rgba(46,125,50,.14)}tr.WARN td{background:rgba(249,168,37,.16);color:#fff2c2}tr.FAIL td{background:rgba(198,40,40,.16)}tr.INFO td{background:rgba(21,101,192,.14)}
.suggestion-list{margin:0;padding-left:18px}.suggestion-list li{margin:0 0 8px}
.raw-output{margin-top:14px;background:#0f172a;color:#dce9ff;padding:16px;border-radius:16px;overflow:auto;max-height:420px;font-size:12px;line-height:1.45;white-space:pre-wrap;border:1px solid var(--border)}
.hidden{display:none}.empty-state{background:rgba(255,255,255,.04);border:1px dashed var(--border);border-radius:22px;padding:50px;text-align:center;color:var(--muted)}.footer-note{margin-top:18px;font-size:12px;color:var(--muted)}
.overview-panel{display:none;flex-direction:column;gap:16px}.overview-panel.active{display:flex}.overview-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
.vm-overview-card{box-shadow:0 8px 24px rgba(0,0,0,.22)}.vm-overview-card.PASS{border-top:5px solid var(--pass)}.vm-overview-card.WARN{border-top:5px solid var(--warn)}.vm-overview-card.FAIL{border-top:5px solid var(--fail)}.vm-overview-card.INFO{border-top:5px solid var(--info)}
.vm-overview-top{display:flex;justify-content:space-between;gap:16px;align-items:flex-start}.vm-overview-top h3{margin:4px 0 6px;font-size:22px}.vm-overview-top p{margin:0;color:var(--muted);font-size:13px}
.overview-actions{display:flex;flex-direction:column;align-items:flex-end;gap:10px}
.mini-check-list{list-style:none;margin:16px 0 0;padding:0;display:flex;flex-direction:column;gap:10px}.mini-check-list li{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:10px 12px;background:#101a2d;border:1px solid var(--border);border-radius:12px}.mini-check-name{font-size:13px;font-weight:600}
@media (max-width:1180px){.hero-grid,.main-grid,.stats,.detail-grid{grid-template-columns:1fr}.sidebar-card{position:static}}
</style>
"@

$script = @"
<script>
(function(){
  const navItems = Array.from(document.querySelectorAll('.vm-nav-item'));
  const panels = Array.from(document.querySelectorAll('.vm-panel'));
  const filterButtons = Array.from(document.querySelectorAll('.filter-btn'));
  const viewButtons = Array.from(document.querySelectorAll('.view-btn'));
  const overviewPanel = document.getElementById('all-vms-panel');
  const overviewCards = Array.from(document.querySelectorAll('.vm-overview-card'));
  const openVmButtons = Array.from(document.querySelectorAll('.view-vm-btn'));

  function activateVm(vmId){
    navItems.forEach(btn => btn.classList.toggle('active', btn.dataset.vmId === vmId));
    panels.forEach(panel => panel.classList.toggle('active', panel.id === 'panel-' + vmId));
  }

  function setView(mode, preferredVmId){
    const showAll = mode === 'ALLVMS';
    if (overviewPanel) {
      overviewPanel.classList.toggle('active', showAll);
      overviewPanel.style.display = showAll ? 'flex' : 'none';
    }
    viewButtons.forEach(btn => btn.classList.toggle('active', btn.dataset.view === mode));
    if (!showAll) {
      const targetId = preferredVmId || (navItems.find(x => x.style.display !== 'none') || navItems[0])?.dataset.vmId;
      if (targetId) activateVm(targetId);
      panels.forEach(panel => {
        panel.style.display = panel.classList.contains('active') ? 'flex' : 'none';
      });
    }
    else {
      panels.forEach(panel => {
        panel.classList.remove('active');
        panel.style.display = 'none';
      });
    }
  }

  navItems.forEach(btn => {
    btn.addEventListener('click', () => {
      activateVm(btn.dataset.vmId);
      setView('DETAIL', btn.dataset.vmId);
    });
  });

  openVmButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      activateVm(btn.dataset.vmId);
      setView('DETAIL', btn.dataset.vmId);
      const activeNav = navItems.find(x => x.dataset.vmId === btn.dataset.vmId);
      if (activeNav) activeNav.scrollIntoView({block:'nearest'});
    });
  });

  filterButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      const wanted = btn.dataset.filter;
      filterButtons.forEach(x => x.classList.toggle('active', x === btn));
      let firstVisible = null;
      navItems.forEach(item => {
        const show = wanted === 'ALL' || item.dataset.status === wanted;
        item.style.display = show ? '' : 'none';
        if (show && !firstVisible) firstVisible = item;
      });
      overviewCards.forEach(card => {
        const show = wanted === 'ALL' || card.dataset.status === wanted;
        card.style.display = show ? '' : 'none';
      });
      if (document.querySelector('.view-btn.active')?.dataset.view !== 'ALLVMS') {
        if (firstVisible) {
          activateVm(firstVisible.dataset.vmId);
          setView('DETAIL', firstVisible.dataset.vmId);
        }
      }
    });
  });

  viewButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      setView(btn.dataset.view);
    });
  });

  document.querySelectorAll('.raw-toggle').forEach(btn => {
    btn.addEventListener('click', () => {
      const target = document.getElementById(btn.dataset.target);
      const hidden = target.classList.toggle('hidden');
      btn.textContent = hidden ? 'Show Raw Output' : 'Hide Raw Output';
    });
  });

  if (navItems.length > 0) {
    activateVm(navItems[0].dataset.vmId);
  }
  setView('ALLVMS');
})();
</script>
"@

$html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8' />
<meta name='viewport' content='width=device-width, initial-scale=1' />
<title>VCF Ops Telegraf Toolkit Report</title>
$style
</head>
<body>
  <div class='container'>
    <section class='hero'>
      <div class='hero-top'>
        <div>
          <h1>VCF Ops Telegraf Toolkit Report</h1>
          <p>Interactive validation summary for Telegraf guest operations and Cloud Proxy prerequisites.</p>
          <div class='hero-note'>Generated: $(Encode-Html (Get-Date))</div>
        </div>
        <div class='badge large INFO'>VCF Fleet</div>
      </div>
      <div class='hero-grid'>
        <div class='stack-card'>
          <div class='eyebrow'>Summary Graphic</div>
          <h2 style='margin:6px 0 0'>VM status distribution</h2>
          <p class='section-subtitle' style='color:rgba(255,255,255,.74);margin-top:8px'>Click a VM on the left to inspect its checks, suggestions, and raw execution output.</p>
          <div class='stack-bar'>
            $($stackSegments -join "`n")
          </div>
        </div>
        <div class='score-card'>
          <div class='score-ring'>
            <div class='score-ring-content'>
              <div class='score-ring-value'>$($vmStatusCounts['PASS'])</div>
              <div class='score-ring-label'>Passing VMs</div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section class='stats'>
      <div class='stat-card'>
        <div class='stat-label'>Total VMs</div>
        <div class='stat-value'>$($vmSummaries.Count)</div>
      </div>
      $($statusCards -join "`n")
    </section>

    <section class='main-grid'>
      <aside class='sidebar'>
        <div class='sidebar-card'>
          <h2 class='section-title'>Virtual Machines</h2>
          <p class='section-subtitle'>Select a VM to reveal its detailed validation results.</p>
          <div class='filter-bar'>
            <button type='button' class='filter-btn active' data-filter='ALL'>All</button>
            <button type='button' class='filter-btn' data-filter='PASS'>PASS</button>
            <button type='button' class='filter-btn' data-filter='WARN'>WARN</button>
            <button type='button' class='filter-btn' data-filter='FAIL'>FAIL</button>
            <button type='button' class='filter-btn' data-filter='INFO'>INFO</button>
          </div>
          <div class='vm-nav'>
            $($vmNavItems -join "`n")
          </div>
        </div>
      </aside>
      <main class='content'>
        <div class='view-mode-toggle'>
          <button type='button' class='view-btn active' data-view='ALLVMS'>Show All VMs</button>
          <button type='button' class='view-btn' data-view='DETAIL'>Single VM Detail</button>
        </div>
        <section class='overview-panel active' id='all-vms-panel'>
          <div class='panel-card'>
            <h3>All VMs tested</h3>
            <p class='section-subtitle'>This overview shows every VM currently visible under the selected status filter. Use Open details to jump into the full per-VM report.</p>
          </div>
          <div class='overview-grid'>
            $($allVmCards -join "`n")
          </div>
        </section>
        $($vmPanels -join "`n")
      </main>
    </section>

    <div class='footer-note'>Row-level checks are derived from the fleet summary JSON and the raw per-VM output block. Endpoint data sources are also supported when present.</div>
  </div>
  $script
</body>
</html>
"@

Set-Content -Path $OutputHtml -Value $html -Encoding utf8
Write-Host "HTML report written to: $OutputHtml" -ForegroundColor Green
