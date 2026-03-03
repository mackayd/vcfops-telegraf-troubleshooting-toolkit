[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$CloudProxyFqdn,
  [Parameter(Mandatory=$true)][string]$BootstrapPath,
  [string]$OutDir='C:\Temp\VcfOpsTelegrafDiag',
  [switch]$DownloadOnly,
  [switch]$ExecuteBootstrap,
  [switch]$SkipCertCheck,
  [int]$TailSeconds=20,
  [string]$BootstrapArguments=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function W([string]$m,[string]$l='INFO'){ $c=@{INFO='Cyan';PASS='Green';WARN='Yellow';FAIL='Red'}[$l]; Write-Host "[$l] $m" -ForegroundColor $c }
if(-not (Test-Path $OutDir)){ New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$session=Join-Path $OutDir ("BootstrapProbe-{0}-{1}" -f $env:COMPUTERNAME,(Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item -ItemType Directory -Path $session -Force | Out-Null
$uri = if($BootstrapPath -match '^https?://'){ $BootstrapPath } else { "https://$CloudProxyFqdn/$($BootstrapPath.TrimStart('/'))" }
$downloadFile = Join-Path $session ([IO.Path]::GetFileName(($uri -split '\?')[0]))
if([string]::IsNullOrWhiteSpace([IO.Path]::GetExtension($downloadFile))){ $downloadFile += '.bin' }
$summary=[ordered]@{ ComputerName=$env:COMPUTERNAME; CloudProxyFqdn=$CloudProxyFqdn; Uri=$uri; DownloadFile=$downloadFile; Start=(Get-Date) }
W "Bootstrap probe session: $session"
W "Testing TCP reachability to Cloud Proxy ports"; foreach($p in 443,8443,4505,4506){ try { $r=Test-NetConnection -ComputerName $CloudProxyFqdn -Port $p -WarningAction SilentlyContinue; "$($r.ComputerName),$p,$($r.TcpTestSucceeded)" | Add-Content (Join-Path $session 'PortTests.csv'); W ("TCP {0}: {1}" -f $p,$r.TcpTestSucceeded) ($(if($r.TcpTestSucceeded){'PASS'}else{'FAIL'})) } catch { W ("TCP $p test failed: $($_.Exception.Message)") 'FAIL' } }
try {
  if($SkipCertCheck){
    Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy { public static bool Validate(object s, X509Certificate c, X509Chain ch, System.Net.Security.SslPolicyErrors e){ return true; } }
"@ -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    W 'SkipCertCheck enabled: TLS certificate validation bypassed for probe only' 'WARN'
  }
  W "Downloading bootstrap from $uri ..."
  Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $downloadFile -TimeoutSec 30
  $hash = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash
  $summary.Downloaded=$true; $summary.SHA256=$hash
  W ("Download succeeded: {0} (SHA256 {1})" -f $downloadFile,$hash) 'PASS'
} catch {
  $summary.Downloaded=$false; $summary.DownloadError=$_.Exception.Message
  W ("Download failed: " + $_.Exception.Message) 'FAIL'
  $summary | ConvertTo-Json -Depth 5 | Out-File (Join-Path $session 'Summary.json') -Encoding utf8
  return
}
if($DownloadOnly -or (-not $ExecuteBootstrap)){
  W 'Download complete; execution not requested. Use -ExecuteBootstrap to run probe.' 'INFO'
  $summary.Mode='DownloadOnly'
  $summary | ConvertTo-Json -Depth 5 | Out-File (Join-Path $session 'Summary.json') -Encoding utf8
  return
}

# Heuristic execution strategy based on file extension
$ext = [IO.Path]::GetExtension($downloadFile).ToLowerInvariant()
$cmd=''; $args='';
switch($ext){
  '.ps1' { $cmd='powershell.exe'; $args='-ExecutionPolicy Bypass -File "' + $downloadFile + '" ' + $BootstrapArguments }
  '.msi' { $cmd='msiexec.exe'; $args='/i "' + $downloadFile + '" /qn ' + $BootstrapArguments }
  '.exe' { $cmd=$downloadFile; $args=$BootstrapArguments }
  '.cmd' { $cmd='cmd.exe'; $args='/c ""' + $downloadFile + '" ' + $BootstrapArguments + '"' }
  '.bat' { $cmd='cmd.exe'; $args='/c ""' + $downloadFile + '" ' + $BootstrapArguments + '"' }
  default { $cmd=$downloadFile; $args=$BootstrapArguments }
}
$summary.ExecutionCommand=$cmd; $summary.ExecutionArguments=$args
W "Executing bootstrap probe: $cmd $args"
$procOut = Join-Path $session 'BootstrapProbe-stdout.txt'
$procErr = Join-Path $session 'BootstrapProbe-stderr.txt'
try {
  $p = Start-Process -FilePath $cmd -ArgumentList $args -PassThru -Wait -NoNewWindow -RedirectStandardOutput $procOut -RedirectStandardError $procErr
  $summary.ExitCode=$p.ExitCode
  W ("Bootstrap probe process exited with code {0}" -f $p.ExitCode) ($(if($p.ExitCode -eq 0){'PASS'}else{'WARN'}))
} catch {
  $summary.ExecutionError=$_.Exception.Message
  W ("Bootstrap execution failed to start: " + $_.Exception.Message) 'FAIL'
}

# Collect immediate post-run evidence
try { Get-Service | ? { $_.Name -match 'telegraf|salt|ucp|vmware' -or $_.DisplayName -match 'telegraf|salt|ucp|vmware' } | select Name,DisplayName,Status,StartType | Export-Csv -NoTypeInformation -Path (Join-Path $session 'Services-Filtered.csv') -Encoding utf8 } catch {}
try { Get-Process -ea SilentlyContinue | ? { $_.ProcessName -match 'telegraf|salt|minion|ucp|vmware' } | select ProcessName,Id,Path,StartTime | Export-Csv -NoTypeInformation -Path (Join-Path $session 'Processes-Filtered.csv') -Encoding utf8 } catch {}
try { Get-NetTCPConnection -ea SilentlyContinue | ? { $_.RemoteAddress -and ($_.RemotePort -in 443,8443,4505,4506) } | select State,LocalAddress,LocalPort,RemoteAddress,RemotePort,OwningProcess | Export-Csv -NoTypeInformation -Path (Join-Path $session 'NetTCP-Interesting.csv') -Encoding utf8 } catch {}
foreach($candidate in 'C:\VMware\UCP','C:\ProgramData\VMware','C:\Program Files\VMware','C:\Program Files\InfluxData\telegraf','C:\Program Files\Telegraf','C:\Windows\Temp'){
  if(Test-Path $candidate){ try { Get-ChildItem $candidate -Recurse -ea SilentlyContinue | ? { -not $_.PSIsContainer -and ($_.Extension -in '.log','.txt','.conf','.json','.yaml','.yml' -or $_.Name -match 'bootstrap|telegraf|salt|minion|ucp') } | sort LastWriteTime -Descending | select -First 20 FullName,Length,LastWriteTime | Export-Csv -NoTypeInformation -Path (Join-Path $session (('RecentFiles-' + ($candidate -replace '[:\\]','_')) + '.csv')) -Encoding utf8 } catch {} }
}
if($TailSeconds -gt 0){
  W "Tailing likely recent logs for ~${TailSeconds}s (best effort) ..."
  $end=(Get-Date).AddSeconds($TailSeconds)
  while((Get-Date) -lt $end){
    Get-ChildItem 'C:\' -Include *.log,*.txt -Recurse -ea SilentlyContinue | ? { $_.FullName -match 'telegraf|salt|minion|ucp|bootstrap|vmware' } | sort LastWriteTime -Descending | select -First 5 FullName,LastWriteTime | Format-Table -AutoSize | Out-String | Add-Content (Join-Path $session 'LiveTailCandidates.txt')
    Start-Sleep -Seconds 5
  }
}
$summary.End=(Get-Date)
$summary | ConvertTo-Json -Depth 6 | Out-File (Join-Path $session 'Summary.json') -Encoding utf8
W "Probe output folder: $session" 'PASS'
