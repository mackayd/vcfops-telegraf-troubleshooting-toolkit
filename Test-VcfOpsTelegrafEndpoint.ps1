[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CloudProxyFqdn,
    [string]$OutDir = 'C:\Temp\VcfOpsTelegrafDiag',
    [int]$TimeoutMs = 3000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Result { param([string]$Check,[string]$Status,[string]$Message,$Data=@{}) [pscustomobject]@{Time=(Get-Date).ToString('s');Check=$Check;Status=$Status;Message=$Message;Data=$Data} }
function Write-StatusLine { param($r) $c=@{PASS='Green';WARN='Yellow';FAIL='Red';INFO='Cyan'}[$r.Status]; if(-not $c){$c='White'}; Write-Host ("[{0}] {1} - {2}" -f $r.Status,$r.Check,$r.Message) -ForegroundColor $c }
function Test-TcpPortRaw { param([string]$HostName,[int]$Port,[int]$Timeout=3000)
  $client=[System.Net.Sockets.TcpClient]::new(); try { $iar=$client.BeginConnect($HostName,$Port,$null,$null); if(-not $iar.AsyncWaitHandle.WaitOne($Timeout,$false)){ return @{Success=$false;Error="Timeout ${Timeout}ms"} }; $client.EndConnect($iar); @{Success=$true;Error=$null} } catch { @{Success=$false;Error=$_.Exception.Message} } finally { $client.Dispose() } }
function Test-HttpsHandshake { param([string]$Uri)
  try { try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 }
    $r=Invoke-WebRequest -Uri $Uri -UseBasicParsing -Method Get -TimeoutSec 10; @{Success=$true;StatusCode=[int]$r.StatusCode;Error=$null}
  } catch { $sc=$null; try { $sc=[int]$_.Exception.Response.StatusCode } catch {}; @{Success=$false;StatusCode=$sc;Error=$_.Exception.Message} } }

if(-not (Test-Path $OutDir)){ New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$ts=Get-Date -Format 'yyyyMMdd-HHmmss'; $json=Join-Path $OutDir "EndpointCheck-$env:COMPUTERNAME-$ts.json"; $txt=Join-Path $OutDir "EndpointCheck-$env:COMPUTERNAME-$ts.txt"
$results=[System.Collections.Generic.List[object]]::new()
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os=Get-CimInstance Win32_OperatingSystem
$results.Add((New-Result 'Execution Context' ($(if($isAdmin){'PASS'}else{'WARN'})) ($(if($isAdmin){'Running elevated'}else{'Not elevated'})) @{User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;PowerShell=$PSVersionTable.PSVersion.ToString()}))
$results.Add((New-Result 'OS Info' 'INFO' "$($os.Caption) build $($os.BuildNumber)" @{Version=$os.Version;Build=$os.BuildNumber}))
try { $dns=Resolve-DnsName -Name $CloudProxyFqdn -ErrorAction Stop; $ips=@($dns|? IPAddress|% IPAddress); if($ips){$results.Add((New-Result 'DNS Resolution' 'PASS' "Resolved $CloudProxyFqdn to: $($ips -join ', ')" @{Addresses=$ips}))} else {$results.Add((New-Result 'DNS Resolution' 'WARN' 'Resolved but no addresses parsed' @{}))} } catch { $results.Add((New-Result 'DNS Resolution' 'FAIL' "Failed to resolve $CloudProxyFqdn" @{Error=$_.Exception.Message})) }
try { $p=Test-Connection -ComputerName $CloudProxyFqdn -Count 2 -ErrorAction Stop; $avg=[math]::Round((($p|Measure-Object ResponseTime -Average).Average),2); $results.Add((New-Result 'ICMP Ping' 'PASS' "ICMP reachable avg ${avg}ms" @{AvgMs=$avg})) } catch { $results.Add((New-Result 'ICMP Ping' 'WARN' 'ICMP failed/blocked (informational)' @{Error=$_.Exception.Message})) }
foreach($port in 443,8443,4505,4506){ $t=Test-TcpPortRaw -HostName $CloudProxyFqdn -Port $port -Timeout $TimeoutMs; $results.Add((New-Result "TCP $port" ($(if($t.Success){'PASS'}else{'FAIL'})) ($(if($t.Success){"Connected to $CloudProxyFqdn:$port"}else{"Cannot connect to $CloudProxyFqdn:$port"})) @{Host=$CloudProxyFqdn;Port=$port;Error=$t.Error})) }
foreach($hp in 443,8443){ $uri="https://$CloudProxyFqdn`:$hp/"; $h=Test-HttpsHandshake -Uri $uri; $status= if($h.Success){'PASS'} elseif($h.StatusCode){'WARN'} else {'FAIL'}; $msg = if($h.Success){"HTTPS handshake succeeded ($($h.StatusCode))"} elseif($h.StatusCode){"HTTPS reachable but returned status $($h.StatusCode)"} else {'HTTPS handshake/request failed'}; $results.Add((New-Result "HTTPS $hp" $status $msg @{Uri=$uri;StatusCode=$h.StatusCode;Error=$h.Error})) }
$svcs=Get-Service | ? { $_.Name -match 'telegraf|salt|ucp|vmware' -or $_.DisplayName -match 'telegraf|salt|ucp|vmware' } | select Name,DisplayName,Status,StartType
$results.Add((New-Result 'Service Inventory' 'INFO' (if($svcs){"Found $($svcs.Count) related services"} else {'No obvious related services found'}) @{Services=@($svcs)}))
$procs=Get-Process -ea SilentlyContinue | ? { $_.ProcessName -match 'telegraf|salt|minion|ucp|vmtools|vmware' } | select ProcessName,Id,Path
$results.Add((New-Result 'Process Inventory' 'INFO' (if($procs){"Found $($procs.Count) related processes"} else {'No obvious related processes running'}) @{Processes=@($procs)}))
foreach($path in 'C:\VMware\UCP','C:\ProgramData\VMware','C:\Program Files\VMware','C:\Program Files\InfluxData\telegraf','C:\Program Files\Telegraf'){ if(Test-Path $path){ try { $items=Get-ChildItem $path -Force | select -First 10 Name,Length,LastWriteTime; $results.Add((New-Result 'Path Exists' 'INFO' "$path exists" @{Path=$path;SampleItems=@($items)})) } catch { $results.Add((New-Result 'Path Exists' 'WARN' "$path exists but enumeration failed" @{Path=$path;Error=$_.Exception.Message})) } } }
try { $fw=Get-NetFirewallProfile | select Name,Enabled,DefaultInboundAction,DefaultOutboundAction; $results.Add((New-Result 'Firewall Profiles' 'INFO' 'Captured firewall profile settings' @{Profiles=@($fw)})) } catch { $results.Add((New-Result 'Firewall Profiles' 'WARN' 'Unable to read firewall profiles' @{Error=$_.Exception.Message})) }
$dnsFail=$results|?{$_.Check -eq 'DNS Resolution' -and $_.Status -eq 'FAIL'}; $tcpFail=$results|?{$_.Check -like 'TCP *' -and $_.Status -eq 'FAIL'}; $httpsFail=$results|?{$_.Check -like 'HTTPS *' -and $_.Status -eq 'FAIL'}
$summary = if($dnsFail){'Most likely failing stage: DNS/name resolution to Cloud Proxy.'} elseif($tcpFail){'Most likely failing stage: Endpoint-to-Cloud Proxy network/firewall path.'} elseif($httpsFail){'Most likely failing stage: TLS/certificate trust or HTTPS reachability.'} else {'Endpoint network/TLS prechecks broadly healthy. Next isolate Guest Operations and bootstrap execution.'}
$results.Add((New-Result 'Heuristic Summary' 'INFO' $summary @{}))
$results | ConvertTo-Json -Depth 8 | Out-File $json -Encoding utf8
$results | % { "[{0}] {1} - {2}" -f $_.Status,$_.Check,$_.Message } | Out-File $txt -Encoding utf8
$results | % { Write-StatusLine $_ }
Write-Host "`nReports written to:`n  $json`n  $txt" -ForegroundColor Cyan
