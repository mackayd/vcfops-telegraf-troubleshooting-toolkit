<#
.SYNOPSIS
  Endpoint-side validation for VCF/Aria Operations product-managed Telegraf agent deployment.
.DESCRIPTION
  Tests common prerequisites and failure points for product-managed Telegraf installation from Windows or Linux endpoints.
#>
[CmdletBinding()]
param(
    [Alias('h','Help')][switch]$ShowHelp,
    [switch]$Full,
    [switch]$Examples,
    [string]$CloudProxyFqdn,
    [ValidateSet('Auto','Windows','Linux')][string]$TargetOs = 'Auto',
    [string]$OutDir,
    [ValidateRange(500, 30000)][int]$TimeoutMs = 3000,
    [switch]$UseSudo
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:BashAvailable = $null -ne (Get-Command bash -ErrorAction SilentlyContinue)

function Show-ShortHelp {
@"
NAME
  Test-VcfOpsTelegrafEndpoint.ps1

SYNOPSIS
  Runs endpoint-side validation checks for VCF Operations / Aria Operations product-managed Telegraf deployment.

USAGE
  .\Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn <fqdn> [-TargetOs Auto|Windows|Linux] [-OutDir <path>] [-TimeoutMs <ms>] [-UseSudo]
  .\Test-VcfOpsTelegrafEndpoint.ps1 -h
  .\Test-VcfOpsTelegrafEndpoint.ps1 -Full
  .\Test-VcfOpsTelegrafEndpoint.ps1 -Examples

DESCRIPTION
  This script is intended to run locally on an endpoint. It validates name resolution, ICMP reachability,
  TCP port connectivity, HTTPS reachability, and selected local indicators that help troubleshoot product-managed
  Telegraf deployment from VCF Operations / Aria Operations through a Cloud Proxy.

  The script can run Windows-specific checks when executed on Windows and Linux-specific checks when executed on Linux.
  If -TargetOs Auto is used, the script detects the local operating system.

KEY PARAMETERS
  -CloudProxyFqdn   Cloud Proxy FQDN to test, for example CloudProxy-01.devops.local
  -TargetOs         Auto, Windows, or Linux. Auto uses the local OS.
  -OutDir           Folder where JSON and text outputs are written.
  -TimeoutMs        TCP timeout in milliseconds.
  -UseSudo          Linux only. Attempts additional non-interactive checks with sudo where available.

RELATED SCRIPTS
  Invoke-VcfOpsFleetGuestOps.ps1
  Collect-VcfOpsTelegrafDeployDiag.ps1
  Invoke-VcfOpsTelegrafBootstrapProbe.ps1
  Save-VcfOpsTelegrafCredential.ps1
  New-VcfOpsTelegrafHtmlReport.ps1

Run -Full for detailed guidance or -Examples for worked examples.
"@ | Write-Host
}

function Show-FullHelp {
@"
NAME
  Test-VcfOpsTelegrafEndpoint.ps1

PURPOSE
  This script runs endpoint-side tests that help isolate common causes of product-managed Telegraf deployment failure.
  It is intended to execute directly on a Windows or Linux target and write local result files that can be reviewed later.

HOW IT WORKS
  1. Determines the effective target operating system.
  2. Creates an output folder and timestamped result files.
  3. Performs endpoint-to-Cloud Proxy validation including:
     - DNS resolution of the Cloud Proxy FQDN
     - ICMP reachability (where allowed)
     - TCP connectivity on ports 443, 8443, 4505, and 4506
     - HTTPS request/handshake checks
  4. Performs operating-system-specific local checks:
     - Windows service, process, file path, and firewall inspection
     - Linux service, process, file path, and package/tool inspection
  5. Writes JSON and text output that can be reviewed manually or collected as part of a wider troubleshooting workflow.

WHEN TO USE THIS SCRIPT
  - When you want to test a single endpoint directly.
  - When a deployment fails and you need local evidence from the target.
  - When you want to validate endpoint prerequisites before using Invoke-VcfOpsFleetGuestOps.ps1.
  - When directed by a fleet run that indicates a specific endpoint needs deeper inspection.

CLOUD PROXY INPUT
  You must supply -CloudProxyFqdn. This should be the FQDN presented by the Cloud Proxy certificate and the name that
  endpoints are expected to use for HTTPS and agent bootstrap access.

OPERATING SYSTEM MODE
  -TargetOs Auto
      Detects the local OS and selects Windows or Linux checks automatically.
  -TargetOs Windows
      Forces Windows checks.
  -TargetOs Linux
      Forces Linux checks.

OUTPUT FILES
  The script writes two files to -OutDir:
    - EndpointCheck-<hostname>-<timestamp>.json
    - EndpointCheck-<hostname>-<timestamp>.txt

  If -OutDir is not provided:
    - Windows defaults to a folder under %TEMP%
    - Linux defaults to /tmp/VcfOpsTelegrafDiag

LINUX SUDO BEHAVIOR
  -UseSudo does not prompt for a password. It only attempts additional checks if non-interactive sudo is already allowed.
  If sudo is unavailable, the script records that as informational or warning output and continues.

HOW THIS FITS WITH OTHER SCRIPTS
  - Invoke-VcfOpsFleetGuestOps.ps1
      Runs guest tests across multiple VMs through VMware Guest Operations and produces fleet JSON/CSV output.
  - Collect-VcfOpsTelegrafDeployDiag.ps1
      Collects supporting diagnostic artifacts from an endpoint after failure.
  - Invoke-VcfOpsTelegrafBootstrapProbe.ps1
      Focuses specifically on bootstrap/download path validation.
  - New-VcfOpsTelegrafHtmlReport.ps1
      Builds HTML summaries from fleet JSON output.
  - Save-VcfOpsTelegrafCredential.ps1
      Creates DPAPI-protected credential files used by fleet scripts. This endpoint script itself does not consume those files,
      because it runs locally on the endpoint rather than connecting into guests.

NOTES
  - ICMP may be blocked even when required TCP connectivity is working.
  - HTTPS checks may return WARN when the host is reachable but the application returns a status code.
  - Some local inventory checks may require elevated access to return full detail.

Run -Examples for practical command examples.
"@ | Write-Host
}

function Show-ExamplesHelp {
@"
EXAMPLES

1) Windows endpoint using automatic OS detection
  .\Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn CloudProxy-01.devops.local

2) Windows endpoint with explicit output folder
  .\Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn CloudProxy-01.devops.local -TargetOs Windows -OutDir C:\Temp\VcfOpsTelegrafDiag

3) Linux endpoint with automatic detection and sudo-enabled checks
  pwsh -File ./Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn CloudProxy-01.devops.local -UseSudo

4) Linux endpoint with explicit output folder and longer timeout
  pwsh -File ./Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn CloudProxy-01.devops.local -TargetOs Linux -OutDir /tmp/VcfOpsTelegrafDiag -TimeoutMs 5000 -UseSudo

5) Typical workflow after a failed fleet run
  - Run Invoke-VcfOpsFleetGuestOps.ps1 to identify failing endpoints.
  - Use Test-VcfOpsTelegrafEndpoint.ps1 on the affected endpoint for deeper local testing.
  - If needed, run Collect-VcfOpsTelegrafDeployDiag.ps1 to gather additional artifacts.

6) Show help
  .\Test-VcfOpsTelegrafEndpoint.ps1 -h
  .\Test-VcfOpsTelegrafEndpoint.ps1 -Full
  .\Test-VcfOpsTelegrafEndpoint.ps1 -Examples
"@ | Write-Host
}

if ($ShowHelp) { Show-ShortHelp; return }
if ($Full) { Show-FullHelp; return }
if ($Examples) { Show-ExamplesHelp; return }
if ([string]::IsNullOrWhiteSpace($CloudProxyFqdn)) { throw 'CloudProxyFqdn is required. Use -h for help.' }

function New-Result {
    param([string]$Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Message, [hashtable]$Data = @{})
    [pscustomobject]@{ Time = (Get-Date).ToString('s'); Check = $Check; Status = $Status; Message = $Message; Data = $Data }
}
function Write-StatusLine {
    param([pscustomobject]$Result)
    $c = switch ($Result.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Cyan' } }
    Write-Host ('[{0}] {1} - {2}' -f $Result.Status, $Result.Check, $Result.Message) -ForegroundColor $c
}
function Test-TcpPortRaw {
    param([string]$HostName, [int]$Port, [int]$Timeout = 3000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($Timeout, $false)) {
            return @{ Success = $false; Error = "Timeout after ${Timeout}ms" }
        }
        $client.EndConnect($iar)
        @{ Success = $true; Error = $null }
    }
    catch {
        @{ Success = $false; Error = $_.Exception.Message }
    }
    finally {
        $client.Dispose()
    }
}
function Test-HttpsHandshake {
    param([string]$Uri)
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
        catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
        $r = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 10
        @{ Success = $true; StatusCode = [int]$r.StatusCode; Error = $null }
    }
    catch {
        $sc = $null
        try { $sc = [int]$_.Exception.Response.StatusCode } catch {}
        @{ Success = $false; StatusCode = $sc; Error = $_.Exception.Message }
    }
}
function Resolve-HostAddresses {
    param([string]$HostName)
    try {
        @([System.Net.Dns]::GetHostAddresses($HostName) |
            Where-Object { $_.AddressFamily -in 'InterNetwork','InterNetworkV6' } |
            ForEach-Object { $_.IPAddressToString } |
            Sort-Object -Unique)
    }
    catch {
        @()
    }
}
function Invoke-CommandCapture {
    param([string]$Command)
    if (-not $script:BashAvailable) { return @() }
    try {
        @(& bash -lc $Command 2>&1)
    }
    catch {
        @($_.Exception.Message)
    }
}

$effectiveTargetOs = switch ($TargetOs) {
    'Windows' { 'Windows' }
    'Linux' { 'Linux' }
    default {
        if ($IsLinux) { 'Linux' }
        elseif ($IsWindows) { 'Windows' }
        else { throw 'Unable to auto-detect target OS. Use -TargetOs Windows or -TargetOs Linux.' }
    }
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = if ($effectiveTargetOs -eq 'Linux') { '/tmp/VcfOpsTelegrafDiag' } else { (Join-Path $env:TEMP 'VcfOpsTelegrafDiag') }
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -Path $OutDir -ItemType Directory -Force | Out-Null }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $OutDir "EndpointCheck-$env:COMPUTERNAME-$ts.json"
$txtPath = Join-Path $OutDir "EndpointCheck-$env:COMPUTERNAME-$ts.txt"
$results = [System.Collections.Generic.List[object]]::new()
$results.Add((New-Result 'Target OS Mode' 'INFO' "Using $effectiveTargetOs checks" @{ TargetOs = $effectiveTargetOs }))

if ($effectiveTargetOs -eq 'Windows') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $osCaption = $null
    $osVersion = $null
    $osBuild = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osCaption = $os.Caption
        $osVersion = $os.Version
        $osBuild = $os.BuildNumber
    }
    catch {
        $osVersion = [System.Environment]::OSVersion.Version.ToString()
        $osBuild = [System.Environment]::OSVersion.Version.Build
    }
    $results.Add((New-Result 'Execution Context' ($(if ($isAdmin) { 'PASS' } else { 'WARN' })) ($(if ($isAdmin) { 'Running elevated' } else { 'Not elevated - some checks may fail' })) @{ User = [Security.Principal.WindowsIdentity]::GetCurrent().Name; PowerShell = $PSVersionTable.PSVersion.ToString() }))
    $osMessage = if ($osCaption) { "$osCaption build $osBuild" } else { "Windows build $osBuild" }
    $results.Add((New-Result 'OS Info' 'INFO' $osMessage @{ Version = $osVersion; Build = $osBuild; Caption = $osCaption }))
} else {
    if (-not $script:BashAvailable) {
        $results.Add((New-Result 'Execution Context' 'WARN' 'bash is not available on this host, so Linux local introspection is limited' @{ PowerShell = $PSVersionTable.PSVersion.ToString(); UseSudo = [bool]$UseSudo }))
        $results.Add((New-Result 'OS Info' 'WARN' 'Linux-specific local OS inspection was skipped because bash is unavailable' @{}))
    } else {
        $who = @((Invoke-CommandCapture -Command 'whoami') | Select-Object -First 1)[0]
        $uname = @((Invoke-CommandCapture -Command 'uname -sr') | Select-Object -First 1)[0]
        $osRelease = @(Invoke-CommandCapture -Command 'if [ -r /etc/os-release ]; then cat /etc/os-release; fi')
        $prettyName = ($osRelease | Where-Object { $_ -match '^PRETTY_NAME=' } | Select-Object -First 1) -replace '^PRETTY_NAME="?','' -replace '"$',''
        $results.Add((New-Result 'Execution Context' 'INFO' "Running as $who" @{ User = $who; PowerShell = $PSVersionTable.PSVersion.ToString(); UseSudo = [bool]$UseSudo }))
        $results.Add((New-Result 'OS Info' 'INFO' ($(if ($prettyName) { $prettyName } else { $uname })) @{ PrettyName = $prettyName; Kernel = $uname; OsRelease = @($osRelease) }))
        if ($UseSudo) {
            $sudoState = @((Invoke-CommandCapture -Command 'if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then echo PASS; elif command -v sudo >/dev/null 2>&1; then echo UNAVAILABLE; else echo MISSING; fi') | Select-Object -First 1)[0]
            if ($sudoState -eq 'PASS') {
                $results.Add((New-Result 'Sudo Availability' 'PASS' 'sudo is available for non-interactive checks' @{}))
            } else {
                $results.Add((New-Result 'Sudo Availability' 'WARN' "sudo is not available for non-interactive checks ($sudoState)" @{}))
            }
        }
    }
}

$ips = @(Resolve-HostAddresses -HostName $CloudProxyFqdn)
if ($ips.Count -gt 0) {
    $results.Add((New-Result 'DNS Resolution' 'PASS' "Resolved $CloudProxyFqdn to: $($ips -join ', ')" @{ Addresses = $ips }))
} else {
    $results.Add((New-Result 'DNS Resolution' 'FAIL' "Failed to resolve $CloudProxyFqdn" @{}))
}

try {
    $p = Test-Connection -ComputerName $CloudProxyFqdn -Count 2 -ErrorAction Stop
    $avg = [math]::Round((($p | Measure-Object Latency -Average).Average), 2)
    $results.Add((New-Result 'ICMP Ping' 'PASS' "ICMP reachable, avg ${avg}ms" @{ AvgMs = $avg }))
}
catch {
    $results.Add((New-Result 'ICMP Ping' 'WARN' 'ICMP failed/blocked (not always required)' @{ Error = $_.Exception.Message }))
}

foreach ($port in 443, 8443, 4505, 4506) {
    $t = Test-TcpPortRaw -HostName $CloudProxyFqdn -Port $port -Timeout $TimeoutMs
    if ($t.Success) { $results.Add((New-Result "TCP $port" 'PASS' "Connected to $CloudProxyFqdn on $port" @{ Port = $port })) }
    else { $results.Add((New-Result "TCP $port" 'FAIL' "Cannot connect to $CloudProxyFqdn on $port" @{ Port = $port; Error = $t.Error })) }
}
foreach ($port in 443, 8443) {
    $u = if ($effectiveTargetOs -eq 'Linux') { "https://$CloudProxyFqdn`:$port/" } else { "https://$CloudProxyFqdn`:$port/downloads/salt/config-utils.bat" }
    $h = Test-HttpsHandshake -Uri $u
    if ($h.Success) { $results.Add((New-Result "HTTPS $port" 'PASS' "HTTPS handshake succeeded ($($h.StatusCode))" @{ Uri = $u; StatusCode = $h.StatusCode })) }
    else {
        $status = if ($h.StatusCode) { 'WARN' } else { 'FAIL' }
        $msg = if ($h.StatusCode) { "HTTPS reachable but returned status $($h.StatusCode)" } else { 'HTTPS handshake/request failed' }
        $results.Add((New-Result "HTTPS $port" $status $msg @{ Uri = $u; StatusCode = $h.StatusCode; Error = $h.Error }))
    }
}

if ($effectiveTargetOs -eq 'Windows') {
    try {
        $svcErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $svcs = Get-Service 2>$null | Select-Object Name, DisplayName, Status, StartType
        $patterns = 'telegraf', 'salt', 'ucp', 'vmware.*agent'
        $matched = foreach ($pat in $patterns) { $svcs | Where-Object { $_.Name -match $pat -or $_.DisplayName -match $pat } }
        $matched = $matched | Sort-Object Name -Unique
        if ($matched) { $results.Add((New-Result 'Service Inventory' 'INFO' "Found $($matched.Count) related services" @{ Services = @($matched) })) }
        else { $results.Add((New-Result 'Service Inventory' 'INFO' 'No obvious Telegraf/UCP/Salt services found' @{})) }
    }
    catch {
        $results.Add((New-Result 'Service Inventory' 'WARN' 'Unable to enumerate all Windows services in the current security context' @{ Error = $_.Exception.Message }))
    }
    finally {
        $ErrorActionPreference = $svcErrorPreference
    }

    try {
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'telegraf|salt|minion|ucp' } | Select-Object ProcessName, Id, Path
        if ($procs) { $results.Add((New-Result 'Process Inventory' 'INFO' "Found $($procs.Count) related processes" @{ Processes = @($procs) })) }
        else { $results.Add((New-Result 'Process Inventory' 'INFO' 'No obvious Telegraf/UCP/Salt processes running' @{})) }
    }
    catch {
        $results.Add((New-Result 'Process Inventory' 'WARN' 'Unable to enumerate related processes in the current security context' @{ Error = $_.Exception.Message }))
    }

    foreach ($p in @('C:
VMware
garbage')) {}
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
        $ports = 443,8443,4505,4506
        $fwRules = Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction SilentlyContinue 2>$null |
        ForEach-Object {
            $rule = $_
            $portFilters = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            foreach ($pf in $portFilters) {
                if ($pf.Protocol -eq 'TCP' -and (($pf.LocalPort -in $ports) -or ($pf.RemotePort -in $ports))) {
                    [pscustomobject]@{
                        DisplayName = $rule.DisplayName
                        Name        = $rule.Name
                        Enabled     = $rule.Enabled
                        Direction   = $rule.Direction
                        Action      = $rule.Action
                        Profile     = ($rule.Profile -join ',')
                        Protocol    = $pf.Protocol
                        LocalPort   = $pf.LocalPort
                        RemotePort  = $pf.RemotePort
                    }
                }
            }
        } | Sort-Object Direction, Action, LocalPort, RemotePort, DisplayName
        $results.Add((New-Result 'Firewall Port Rule Matches' 'INFO' 'Captured firewall rules matching required ports (TCP 443/8443/4505/4506)' @{ Rules = @($fwRules) }))
    }
    catch {
        $results.Add((New-Result 'Firewall Port Rule Matches' 'WARN' 'Unable to query firewall rules matching required ports' @{ Error = $_.Exception.Message }))
    }
} else {
    if (-not $script:BashAvailable) {
        $results.Add((New-Result 'Service Status' 'WARN' 'Linux local service checks were skipped because bash is unavailable on this host' @{}))
        $results.Add((New-Result 'Process Inventory' 'WARN' 'Linux local process checks were skipped because bash is unavailable on this host' @{}))
        $results.Add((New-Result 'Package Status' 'WARN' 'Linux package validation was skipped because bash is unavailable on this host' @{}))
        $results.Add((New-Result 'Firewall Tooling' 'WARN' 'Linux firewall tooling inspection was skipped because bash is unavailable on this host' @{}))
    } else {
        $sudoPrefix = if ($UseSudo) { 'sudo -n ' } else { '' }
        $serviceState = @((Invoke-CommandCapture -Command "if command -v systemctl >/dev/null 2>&1; then ${sudoPrefix}systemctl is-active telegraf 2>/dev/null || true; else echo SYSTEMCTL_MISSING; fi") | Select-Object -First 1)
        $serviceValue = $serviceState[0]
        if ($serviceValue -eq 'active') {
            $results.Add((New-Result 'Service Status' 'PASS' 'telegraf service is active' @{ State = $serviceValue }))
        } elseif ($serviceValue -eq 'SYSTEMCTL_MISSING') {
            $results.Add((New-Result 'Service Status' 'WARN' 'systemctl is not available on this Linux host' @{}))
        } else {
            $results.Add((New-Result 'Service Status' 'FAIL' 'telegraf service is not active' @{ State = $serviceValue }))
        }

        $processLines = @(@(Invoke-CommandCapture -Command 'pgrep -a telegraf 2>/dev/null || true') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($processLines.Count -gt 0) { $results.Add((New-Result 'Process Inventory' 'INFO' "Found $($processLines.Count) telegraf process entries" @{ Processes = @($processLines) })) }
        else { $results.Add((New-Result 'Process Inventory' 'WARN' 'No telegraf process found' @{})) }

        foreach ($p in @('/etc/telegraf/telegraf.conf', '/etc/telegraf', '/var/log/telegraf')) {
            $exists = @((Invoke-CommandCapture -Command "if [ -e '$p' ]; then echo PASS; else echo FAIL; fi") | Select-Object -First 1)
            if ($exists[0] -eq 'PASS') {
                $listing = @(Invoke-CommandCapture -Command "if [ -d '$p' ]; then ls -la '$p' | head -n 10; else ls -l '$p'; fi")
                $results.Add((New-Result 'Path Exists' 'INFO' "$p exists" @{ Path = $p; SampleItems = @($listing) }))
            }
        }

        $packageState = @((Invoke-CommandCapture -Command "if command -v rpm >/dev/null 2>&1; then if ${sudoPrefix}rpm -q telegraf >/dev/null 2>&1; then echo 'rpm:installed'; else echo 'rpm:missing'; fi; elif command -v dpkg >/dev/null 2>&1; then if ${sudoPrefix}dpkg -s telegraf >/dev/null 2>&1; then echo 'dpkg:installed'; else echo 'dpkg:missing'; fi; else echo 'unknown'; fi") | Select-Object -First 1)
        switch ($packageState[0]) {
            'rpm:installed' { $results.Add((New-Result 'Package Status' 'PASS' 'rpm reports telegraf installed' @{ PackageManager = 'rpm' })) }
            'dpkg:installed' { $results.Add((New-Result 'Package Status' 'PASS' 'dpkg reports telegraf installed' @{ PackageManager = 'dpkg' })) }
            'rpm:missing' { $results.Add((New-Result 'Package Status' 'FAIL' 'rpm did not report a telegraf package' @{ PackageManager = 'rpm' })) }
            'dpkg:missing' { $results.Add((New-Result 'Package Status' 'FAIL' 'dpkg did not report a telegraf package' @{ PackageManager = 'dpkg' })) }
            default { $results.Add((New-Result 'Package Status' 'WARN' 'Could not determine the Linux package manager for telegraf validation' @{})) }
        }

        $firewallProbe = @(Invoke-CommandCapture -Command 'if command -v ufw >/dev/null 2>&1; then ufw status; elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --state; else echo NONE; fi')
        $firewallFirst = @($firewallProbe | Select-Object -First 1)[0]
        if ($firewallFirst -and $firewallFirst -ne 'NONE') {
            $results.Add((New-Result 'Firewall Tooling' 'INFO' 'Collected Linux firewall tool output' @{ Output = @($firewallProbe) }))
        } else {
            $results.Add((New-Result 'Firewall Tooling' 'WARN' 'No ufw or firewall-cmd tooling detected for firewall inspection' @{}))
        }
    }
}

$dnsFail = $results | Where-Object { $_.Check -eq 'DNS Resolution' -and $_.Status -eq 'FAIL' }
$tcpFail = $results | Where-Object { $_.Check -like 'TCP *' -and $_.Status -eq 'FAIL' }
$httpsFail = $results | Where-Object { $_.Check -like 'HTTPS *' -and $_.Status -eq 'FAIL' }
$serviceFail = $results | Where-Object { $_.Check -in 'Service Status','Package Status' -and $_.Status -eq 'FAIL' }
$summary = if ($dnsFail) { 'Most likely failing stage: Endpoint DNS/name resolution to Cloud Proxy.' }
elseif ($tcpFail) { 'Most likely failing stage: Endpoint-to-Cloud Proxy network/firewall path (required TCP ports blocked).' }
elseif ($httpsFail) { 'Most likely failing stage: TLS/certificate trust or HTTPS service reachability on Cloud Proxy.' }
elseif ($serviceFail -and $effectiveTargetOs -eq 'Linux') { 'Connectivity looks healthier than the local Telegraf state. Focus next on Linux package/service health, supported distro/version, and guest user/sudo prerequisites.' }
else { 'Endpoint network/TLS prechecks look broadly healthy. Next isolate vCenter Guest Operations and bootstrap execution.' }
$results.Add((New-Result 'Heuristic Summary' 'INFO' $summary @{}))

$results | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8
$results | ForEach-Object { '[{0}] {1} - {2}' -f $_.Status, $_.Check, $_.Message } | Out-File -FilePath $txtPath -Encoding utf8
$results | ForEach-Object { Write-StatusLine $_ }
Write-Host "`nReports written to:`n  $jsonPath`n  $txtPath" -ForegroundColor Cyan

