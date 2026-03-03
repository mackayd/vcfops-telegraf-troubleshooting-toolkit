[CmdletBinding()]
param([string]$OutDir='C:\Temp\VcfOpsTelegrafDiag',[int]$LookbackHours=12)
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
