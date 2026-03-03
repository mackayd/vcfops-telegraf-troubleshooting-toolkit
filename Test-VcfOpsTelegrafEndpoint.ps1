<#!
.SYNOPSIS
  Endpoint-side validation for VCF/Aria Operations product-managed Telegraf agent deployment.
.DESCRIPTION
  Tests common prerequisites and failure points for product-managed Telegraf installation from a Windows VM endpoint.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CloudProxyFqdn,
    [string]$OutDir = "C:\Temp\VcfOpsTelegrafDiag",
    [ValidateRange(500, 30000)][int]$TimeoutMs = 3000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Result {
    param([string]$Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Message, [hashtable]$Data = @{})
    [pscustomobject]@{ Time = (Get-Date).ToString('s'); Check = $Check; Status = $Status; Message = $Message; Data = $Data }
}
function Write-StatusLine {
    param([pscustomobject]$Result)
    $c = switch ($Result.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Cyan' } }
    Write-Host ("[{0}] {1} - {2}" -f $Result.Status, $Result.Check, $Result.Message) -ForegroundColor $c
}
function Test-TcpPortRaw {
    param([string]$HostName, [int]$Port, [int]$Timeout = 3000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($Timeout, $false)) { return @{ Success = $false; Error = "Timeout after ${Timeout}ms" } }
        $client.EndConnect($iar)
        @{ Success = $true; Error = $null }
    }
    catch { @{ Success = $false; Error = $_.Exception.Message } }
    finally { $client.Dispose() }
}
function Test-HttpsHandshake {
    param([string]$Uri)
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
        catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
        $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Method Get -TimeoutSec 10
        @{ Success = $true; StatusCode = [int]$r.StatusCode; Error = $null }
    }
    catch {
        $sc = $null; try { $sc = [int]$_.Exception.Response.StatusCode } catch {}
        @{ Success = $false; StatusCode = $sc; Error = $_.Exception.Message }
    }
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -Path $OutDir -ItemType Directory -Force | Out-Null }
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $OutDir "EndpointCheck-$env:COMPUTERNAME-$ts.json"
$txtPath = Join-Path $OutDir "EndpointCheck-$env:COMPUTERNAME-$ts.txt"
$results = [System.Collections.Generic.List[object]]::new()

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os = Get-CimInstance Win32_OperatingSystem
$results.Add((New-Result 'Execution Context' ($(if ($isAdmin) { 'PASS' }else { 'WARN' })) ($(if ($isAdmin) { 'Running elevated' }else { 'Not elevated - some checks may fail' })) @{ User = [Security.Principal.WindowsIdentity]::GetCurrent().Name; PowerShell = $PSVersionTable.PSVersion.ToString() }))
$results.Add((New-Result 'OS Info' 'INFO' "$($os.Caption) build $($os.BuildNumber)" @{ Version = $os.Version; Build = $os.BuildNumber }))

try {
    $dns = Resolve-DnsName -Name $CloudProxyFqdn -ErrorAction Stop
    $ips = @($dns | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
    if ($ips.Count -gt 0) { $results.Add((New-Result 'DNS Resolution' 'PASS' "Resolved $CloudProxyFqdn to: $($ips -join ', ')" @{ Addresses = $ips })) }
    else { $results.Add((New-Result 'DNS Resolution' 'WARN' 'Name resolved but no A/AAAA parsed' @{})) }
}
catch { $results.Add((New-Result 'DNS Resolution' 'FAIL' "Failed to resolve $CloudProxyFqdn" @{ Error = $_.Exception.Message })) }

try {
    $p = Test-Connection -ComputerName $CloudProxyFqdn -Count 2 -ErrorAction Stop
    $avg = [math]::Round((($p | Measure-Object Latency -Average).Average), 2)
    $results.Add((New-Result 'ICMP Ping' 'PASS' "ICMP reachable, avg ${avg}ms" @{ AvgMs = $avg }))
}
catch { $results.Add((New-Result 'ICMP Ping' 'WARN' 'ICMP failed/blocked (not always required)' @{ Error = $_.Exception.Message })) }

foreach ($port in 443, 8443, 4505, 4506) {
    $t = Test-TcpPortRaw -HostName $CloudProxyFqdn -Port $port -Timeout $TimeoutMs
    if ($t.Success) { $results.Add((New-Result "TCP $port" 'PASS' "Connected to $CloudProxyFqdn on $port" @{ Port = $port })) }
    else { $results.Add((New-Result "TCP $port" 'FAIL' "Cannot connect to $CloudProxyFqdn on $port" @{ Port = $port; Error = $t.Error })) }
}
foreach ($port in 443, 8443) {
    $u = "https://$CloudProxyFqdn`:$port/"
    $h = Test-HttpsHandshake -Uri $u
    if ($h.Success) { $results.Add((New-Result "HTTPS $port" 'PASS' "HTTPS handshake succeeded ($($h.StatusCode))" @{ Uri = $u; StatusCode = $h.StatusCode })) }
    else {
        $status = if ($h.StatusCode) { 'WARN' } else { 'FAIL' }
        $msg = if ($h.StatusCode) { "HTTPS reachable but returned status $($h.StatusCode)" } else { 'HTTPS handshake/request failed' }
        $results.Add((New-Result "HTTPS $port" $status $msg @{ Uri = $u; StatusCode = $h.StatusCode; Error = $h.Error }))
    }
}

$svcs = Get-Service | Select-Object Name, DisplayName, Status, StartType
$patterns = 'telegraf', 'salt', 'ucp', 'vmware.*agent'
$matched = foreach ($pat in $patterns) { $svcs | Where-Object { $_.Name -match $pat -or $_.DisplayName -match $pat } }
$matched = $matched | Sort-Object Name -Unique
if ($matched) { $results.Add((New-Result 'Service Inventory' 'INFO' "Found $($matched.Count) related services" @{ Services = @($matched) })) }
else { $results.Add((New-Result 'Service Inventory' 'INFO' 'No obvious Telegraf/UCP/Salt services found' @{})) }

$procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'telegraf|salt|minion|ucp' } | Select-Object ProcessName, Id, Path
if ($procs) { $results.Add((New-Result 'Process Inventory' 'INFO' "Found $($procs.Count) related processes" @{ Processes = @($procs) })) }
else { $results.Add((New-Result 'Process Inventory' 'INFO' 'No obvious Telegraf/UCP/Salt processes running' @{})) }

foreach ($p in @('C:\VMware\UCP', 'C:\Program Files\VMware', 'C:\ProgramData\VMware', 'C:\Program Files\InfluxData\telegraf', 'C:\Program Files\Telegraf')) {
    if (Test-Path -LiteralPath $p) {
        try {
            $items = Get-ChildItem -LiteralPath $p -Force | Select-Object -First 10 Name, Length, LastWriteTime
            $results.Add((New-Result 'Path Exists' 'INFO' "$p exists" @{ Path = $p; SampleItems = @($items) }))
        }
        catch { $results.Add((New-Result 'Path Exists' 'WARN' "$p exists but could not enumerate" @{ Path = $p; Error = $_.Exception.Message })) }
    }
}
try {
    $fw = Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
    $results.Add((New-Result 'Firewall Profiles' 'INFO' 'Captured firewall profile settings' @{ Profiles = @($fw) }))
}
catch { $results.Add((New-Result 'Firewall Profiles' 'WARN' 'Unable to read firewall profile settings' @{ Error = $_.Exception.Message })) }

$dnsFail = $results | Where-Object { $_.Check -eq 'DNS Resolution' -and $_.Status -eq 'FAIL' }
$tcpFail = $results | Where-Object { $_.Check -like 'TCP *' -and $_.Status -eq 'FAIL' }
$httpsFail = $results | Where-Object { $_.Check -like 'HTTPS *' -and $_.Status -eq 'FAIL' }
$summary = if ($dnsFail) { 'Most likely failing stage: Endpoint DNS/name resolution to Cloud Proxy.' }
elseif ($tcpFail) { 'Most likely failing stage: Endpoint-to-Cloud Proxy network/firewall path (required TCP ports blocked).' }
elseif ($httpsFail) { 'Most likely failing stage: TLS/certificate trust or HTTPS service reachability on Cloud Proxy.' }
else { 'Endpoint network/TLS prechecks look broadly healthy. Next isolate vCenter Guest Operations and bootstrap execution.' }
$results.Add((New-Result 'Heuristic Summary' 'INFO' $summary @{}))

$results | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8
$results | ForEach-Object { "[{0}] {1} - {2}" -f $_.Status, $_.Check, $_.Message } | Out-File -FilePath $txtPath -Encoding utf8
$results | ForEach-Object { Write-StatusLine $_ }
Write-Host "`nReports written to:`n  $jsonPath`n  $txtPath" -ForegroundColor Cyan
