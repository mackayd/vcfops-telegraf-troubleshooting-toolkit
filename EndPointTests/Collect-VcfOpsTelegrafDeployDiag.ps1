[CmdletBinding()]
param(
    [string]$OutDir='C:\Temp\VcfOpsTelegrafDiag',
    [int]$LookbackHours=12,
    [Alias('h')]
    [switch]$Help,
    [switch]$Full,
    [switch]$Examples
)

function Show-ShortHelp {
@"
Collect-VcfOpsTelegrafDeployDiag.ps1

Collects a local Windows diagnostic bundle to help troubleshoot VCF Operations / Aria Operations
Telegraf agent deployment and guest-side execution issues.

Usage:
  .\Collect-VcfOpsTelegrafDeployDiag.ps1 [-OutDir <path>] [-LookbackHours <int>]
  .\Collect-VcfOpsTelegrafDeployDiag.ps1 -h
  .\Collect-VcfOpsTelegrafDeployDiag.ps1 -Full
  .\Collect-VcfOpsTelegrafDeployDiag.ps1 -Examples

Quick summary:
- Runs locally on a Windows endpoint.
- Collects OS, network, firewall, services, processes, event logs, and selected file samples.
- Writes a timestamped evidence folder and attempts to create a ZIP archive.
- Often used after Test-VcfOpsTelegrafEndpoint.ps1 reports a failure or warning.

Help switches:
  -h / -Help   Show this short help.
  -Full        Show detailed help and workflow guidance.
  -Examples    Show worked command examples.
"@
}

function Show-FullHelp {
@"
Collect-VcfOpsTelegrafDeployDiag.ps1
====================================

Purpose
-------
Collect-VcfOpsTelegrafDeployDiag.ps1 gathers a local evidence bundle from a Windows endpoint to support
troubleshooting of VCF Operations / Aria Operations Telegraf deployment problems.

It is intended for situations where a target endpoint has already been tested and you want to capture
supporting data such as:
- operating system and PowerShell details
- IP configuration, routes, ARP, DNS cache, proxy settings, and firewall profile state
- service and process state relevant to Telegraf, Salt, VMware Tools, and UCP-style components
- network socket information
- Windows event logs for the selected lookback period
- selected log and configuration file samples from common installation paths

How it works
------------
1. Creates a timestamped collection folder under the chosen output directory.
2. Runs a series of local commands and writes their output to text or CSV files.
3. Exports selected Windows event logs for the requested lookback period.
4. Copies selected file samples from common VMware / Telegraf / Windows temp locations.
5. Writes a short summary file.
6. Attempts to compress the evidence into a ZIP archive.

When to use it
--------------
Use this script when:
- Test-VcfOpsTelegrafEndpoint.ps1 reports a failure or warning on a Windows endpoint.
- Invoke-VcfOpsFleetGuestOps.ps1 indicates a Windows guest has deployment issues and you want deeper evidence.
- you want a support bundle before raising an internal escalation or Broadcom support case.

Output
------
By default, the script writes to:
  C:\Temp\VcfOpsTelegrafDiag

Within that folder it creates a timestamped session directory such as:
  Collect-SERVER01-20260314-001500

It then attempts to create:
  Collect-SERVER01-20260314-001500.zip

Important notes
---------------
- This script is designed for Windows endpoints.
- It runs locally on the endpoint being investigated.
- It does not require vCenter connectivity itself.
- If ZIP creation fails, the raw collected files remain in the session directory.
- Some commands may return no data depending on the endpoint configuration and installed components.

How this fits the wider toolkit workflow
----------------------------------------
A common workflow is:
1. Run Test-VcfOpsTelegrafEndpoint.ps1 locally, or run Invoke-VcfOpsFleetGuestOps.ps1 from the admin workstation.
2. Identify the failing or warning endpoint.
3. Run Collect-VcfOpsTelegrafDeployDiag.ps1 on that endpoint.
4. Review the resulting ZIP or folder contents.
5. Use New-VcfOpsTelegrafHtmlReport.ps1 for fleet-level HTML reporting when relevant.

Parameters
----------
-OutDir
  Root folder for the diagnostic output.

-LookbackHours
  Number of hours of event log history to export.

-h / -Help
  Show short help.

-Full
  Show this detailed help.

-Examples
  Show worked examples.

Related scripts
---------------
- Test-VcfOpsTelegrafEndpoint.ps1
- Invoke-VcfOpsFleetGuestOps.ps1
- New-VcfOpsTelegrafHtmlReport.ps1
- Save-VcfOpsTelegrafCredential.ps1

Example environment naming used in this help
--------------------------------------------
- vCenter: vCenter-01.devops.local
- Cloud Proxy VM name: CloudProxy-01
- Cloud Proxy FQDN: CloudProxy-01.devops.local
- Example domain admin: devops\DomainAdmin
- Example password text: P@ssw0rd123!
- Example ESXi host: ESXi-01
"@
}

function Show-Examples {
@"
Examples
========

1. Run a standard collection to the default folder
--------------------------------------------------
.\Collect-VcfOpsTelegrafDeployDiag.ps1

2. Collect 24 hours of logs into a custom folder
------------------------------------------------
.\Collect-VcfOpsTelegrafDeployDiag.ps1 -OutDir C:\Temp\Diag -LookbackHours 24

3. Run after endpoint testing reports a Windows-side issue
----------------------------------------------------------
# First test the endpoint:
.\Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn CloudProxy-01.devops.local -OutDir C:\Temp\EndpointTest

# Then collect deeper diagnostics on the affected endpoint:
.\Collect-VcfOpsTelegrafDeployDiag.ps1 -OutDir C:\Temp\Diag -LookbackHours 12

4. Example Guest Ops style workflow
-----------------------------------
# Run from the admin workstation to identify failures or warnings:
.\Invoke-VcfOpsFleetGuestOps.ps1 `
  -vCenterServer 'vCenter-01.devops.local' `
  -TargetsCsv '.\targets.csv' `
  -vCenterUser 'administrator@vsphere.local' `
  -vCenterPassword 'P@ssw0rd123!' `
  -CloudProxyVmName 'CloudProxy-01' `
  -CloudProxyGuestUser 'root' `
  -CloudProxyGuestPassword 'P@ssw0rd123!' `
  -OutDir '.'

# After identifying a Windows endpoint with issues, run local diagnostics on that endpoint:
.\Collect-VcfOpsTelegrafDeployDiag.ps1 -OutDir C:\Temp\Diag -LookbackHours 12

5. Show help
------------
.\Collect-VcfOpsTelegrafDeployDiag.ps1 -h
.\Collect-VcfOpsTelegrafDeployDiag.ps1 -Full
.\Collect-VcfOpsTelegrafDeployDiag.ps1 -Examples
"@
}

if ($Help -or $Full -or $Examples) {
    if ($Full) { Show-FullHelp; return }
    if ($Examples) { Show-Examples; return }
    Show-ShortHelp; return
}

Set-StrictMode -Version Latest
$ErrorActionPreference='Continue'
function Test-Dir([string]$p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Save-Cmd([string]$Name,[scriptblock]$Script){ $f=Join-Path $global:SessionDir "$Name.txt"; try { & $Script 2>&1 | Out-File $f -Encoding utf8 -Width 5000 } catch { "ERROR: $($_.Exception.Message)" | Out-File $f -Encoding utf8 } }
function Export-Log([string]$LogName,[datetime]$Start){ $safe=$LogName -replace '[\\/:*?"<>| ]','_'; $f=Join-Path $global:SessionDir "EventLog-$safe.csv"; try { Get-WinEvent -FilterHashtable @{LogName=$LogName;StartTime=$Start} -ErrorAction Stop | select TimeCreated,Id,LevelDisplayName,ProviderName,MachineName,Message | Export-Csv -NoTypeInformation -Encoding utf8 -Path $f } catch { "ERROR: $($_.Exception.Message)" | Out-File ($f+'.error.txt') -Encoding utf8 } }
Test-Dir $OutDir; $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'; $global:SessionDir=Join-Path $OutDir "Collect-$env:COMPUTERNAME-$stamp"; Test-Dir $global:SessionDir; $start=(Get-Date).AddHours(-1*$LookbackHours)
Save-Cmd 'SystemInfo' { systeminfo }
Save-Cmd 'OS-CIM' { Get-CimInstance Win32_OperatingSystem | fl * }
Save-Cmd 'PSVersion' { $PSVersionTable | fl * }
Save-Cmd 'IpConfig-All' { ipconfig /all }
Save-Cmd 'RoutePrint' { route print }
Save-Cmd 'Arp' { arp -a }
Save-Cmd 'DnsClientCache' { Get-DnsClientCache | sort Entry | ft -AutoSize }
Save-Cmd 'FirewallProfiles' { Get-NetFirewallProfile | ft -AutoSize }
Save-Cmd 'WinHttpProxy' { netsh winhttp show proxy }
Save-Cmd 'EnvProxyVars' { Get-ChildItem Env: | ? Name -match 'proxy' | ft -AutoSize }
try { Copy-Item "$env:windir\System32\drivers\etc\hosts" (Join-Path $SessionDir 'hosts') -Force } catch {}
Save-Cmd 'Services-All' { Get-Service | sort Name | ft -AutoSize }
Save-Cmd 'Services-Filtered' { Get-Service | ? { $_.Name -match 'telegraf|salt|ucp|vmware' -or $_.DisplayName -match 'telegraf|salt|ucp|vmware' } | sort Name | ft -AutoSize }
Save-Cmd 'Processes-Filtered' { Get-Process -ea SilentlyContinue | ? ProcessName -match 'telegraf|salt|minion|ucp|vmtools|vmware' | select ProcessName,Id,StartTime,Path | ft -AutoSize }
Save-Cmd 'NetTCPConnection' { Get-NetTCPConnection -ea SilentlyContinue | sort State,LocalPort,RemotePort | ft -AutoSize }
Save-Cmd 'Netstat-ano' { netstat -ano }
Save-Cmd 'ScheduledTasks-Filtered' { Get-ScheduledTask -ea SilentlyContinue | ? { $_.TaskName -match 'telegraf|ucp|vmware|salt' } | ft TaskName,TaskPath,State -AutoSize }
Export-Log 'Application' $start; Export-Log 'System' $start; Export-Log 'Microsoft-Windows-PowerShell/Operational' $start; Export-Log 'Windows PowerShell' $start
Save-Cmd 'DefenderStatus' { Get-MpComputerStatus }
Save-Cmd 'DefenderThreats' { Get-MpThreatDetection }
$paths='C:\VMware\UCP','C:\ProgramData\VMware','C:\Program Files\VMware','C:\Program Files\InfluxData\telegraf','C:\Program Files\Telegraf','C:\Windows\Temp'
$copyRoot=Join-Path $SessionDir 'FileSamples'; Test-Dir $copyRoot
foreach($p in $paths){ if(Test-Path $p){ $safe=$p -replace '[:\\]','_'; $dest=Join-Path $copyRoot $safe; Test-Dir $dest; try { Get-ChildItem $p -Recurse -ea SilentlyContinue | ? { -not $_.PSIsContainer } | ? { $_.Extension -in '.log','.txt','.conf','.json','.yaml','.yml','.cfg' -or $_.Name -match 'bootstrap|telegraf|salt|minion|ucp' } | select -First 200 | % { Copy-Item $_.FullName (Join-Path $dest $_.Name) -Force -ea SilentlyContinue }; Get-ChildItem $p -Recurse -ea SilentlyContinue | select FullName,Length,LastWriteTime | Export-Csv -NoTypeInformation -Encoding utf8 -Path (Join-Path $dest '_listing.csv') } catch { "ERROR: $($_.Exception.Message)" | Out-File (Join-Path $dest '_copy_error.txt') -Encoding utf8 } } }
@"
VCF Ops Telegraf Deploy Diagnostic Collection
ComputerName: $env:COMPUTERNAME
Timestamp: $(Get-Date)
LookbackHours: $LookbackHours
"@ | Out-File (Join-Path $SessionDir 'Summary.txt') -Encoding utf8
$zip="$SessionDir.zip"; try { Compress-Archive -Path (Join-Path $SessionDir '*') -DestinationPath $zip -Force; Write-Host "Evidence bundle created: $zip" -ForegroundColor Green } catch { Write-Host "ZIP creation failed: $($_.Exception.Message)" -ForegroundColor Yellow; Write-Host "Files remain in: $SessionDir" }
