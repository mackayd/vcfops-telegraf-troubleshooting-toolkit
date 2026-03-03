[CmdletBinding(DefaultParameterSetName='Download')]
param(
  [Parameter(Mandatory=$true)][string]$CloudProxyFqdn,
  [Parameter(Mandatory=$true)][string]$BootstrapPath,
  [string]$OutDir='C:\Temp\VcfOpsTelegrafDiag',
  [Parameter(ParameterSetName='Download')][switch]$DownloadOnly,
  [Parameter(ParameterSetName='Execute')][switch]$ExecuteBootstrap,
  [switch]$SkipCertCheck,
  [int]$TailSeconds=20,
  [string]$BootstrapArguments='',
  [int]$PortTimeoutMs=3000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
  param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL')][string]$Level='INFO')
  $ts = (Get-Date).ToString('s')
  $line = "[$ts] [$Level] $Message"
  $script:LogLines.Add($line) | Out-Null
  $c = switch ($Level) { 'PASS'{'Green'} 'WARN'{'Yellow'} 'FAIL'{'Red'} default {'Cyan'} }
  Write-Host $line -ForegroundColor $c
}

function Test-Dir {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
}

function Test-TcpPortQuick {
  param([string]$HostName,[int]$Port,[int]$TimeoutMs=3000)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($HostName,$Port,$null,$null)
    $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)
    if (-not $ok) {
      return [pscustomobject]@{ Host=$HostName; Port=$Port; Success=$false; Result='TIMEOUT'; Error="No TCP connect response within ${TimeoutMs}ms" }
    }
    $null = $client.EndConnect($iar)
    return [pscustomobject]@{ Host=$HostName; Port=$Port; Success=$true; Result='CONNECTED'; Error=$null }
  } catch {
    return [pscustomobject]@{ Host=$HostName; Port=$Port; Success=$false; Result='FAILED'; Error=$_.Exception.Message }
  } finally {
    $client.Dispose()
  }
}

function Invoke-Download {
  param([string]$Uri,[string]$OutFile,[switch]$SkipCertificateCheck)

  try {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
      # Windows PowerShell 5.1 path (no -SkipCertificateCheck support)
      if ($SkipCertificateCheck) {
        Write-Log "-SkipCertificateCheck is not supported in Windows PowerShell 5.1; using legacy callback bypass if configured." 'WARN'
      }

      $resp = Invoke-WebRequest `
        -Uri $Uri `
        -OutFile $OutFile `
        -TimeoutSec 30 `
        -UseBasicParsing `
        -ErrorAction Stop
    }
    else {
      # PowerShell 6+/7 path
      if ($SkipCertificateCheck) {
        Write-Log "Invoke-WebRequest will use -SkipCertificateCheck (explicit switch syntax)" 'WARN'

        $resp = Invoke-WebRequest `
          -Uri $Uri `
          -OutFile $OutFile `
          -TimeoutSec 30 `
          -SkipCertificateCheck `
          -ErrorAction Stop
      }
      else {
        $resp = Invoke-WebRequest `
          -Uri $Uri `
          -OutFile $OutFile `
          -TimeoutSec 30 `
          -ErrorAction Stop
      }
    }
$statusCode = $null
if ($null -ne $resp) {
  $statusProp = $resp.PSObject.Properties['StatusCode']
  if ($null -ne $statusProp) {
    $statusCode = [int]$statusProp.Value
  }
}

[pscustomobject]@{
  Success    = $true
  StatusCode = $statusCode
  Error      = $null
  OutFile    = $OutFile
}
  }
  catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}

    [pscustomobject]@{
      Success    = $false
      StatusCode = $status
      Error      = $_.Exception.Message
      OutFile    = $OutFile
    }
  }
}

function Get-FileKind {
  param([string]$Path)
  switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.ps1' {'PowerShell'}
    '.bat' {'Batch'}
    '.cmd' {'Batch'}
    '.exe' {'Executable'}
    '.msi' {'Msi'}
    default {'Unknown'}
  }
}

function Invoke-BootstrapFile {
  param([string]$Path,[string]$Arguments='')
  $kind = Get-FileKind -Path $Path
  try {
    switch ($kind) {
      'PowerShell' {
        $procArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $Path)
        if ($Arguments) { $procArgs += $Arguments }
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $procArgs -Wait -PassThru -WindowStyle Hidden
      }
      'Batch' {
        $cmdArgs = '/c "' + $Path + '"'
        if ($Arguments) { $cmdArgs += ' ' + $Arguments }
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -Wait -PassThru -WindowStyle Hidden
      }
      'Executable' {
        $procArgs = @()
        if ($Arguments) { $procArgs += $Arguments }
        $p = Start-Process -FilePath $Path -ArgumentList $procArgs -Wait -PassThru -WindowStyle Hidden
      }
      'Msi' {
        $procArgs = @('/i', "`"$Path`"")
        if ($Arguments) { $procArgs += $Arguments }
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $procArgs -Wait -PassThru -WindowStyle Hidden
      }
      default { throw "Unsupported bootstrap file type: $kind" }
    }
    [pscustomobject]@{ Kind=$kind; ExitCode=$p.ExitCode; Error=$null; Path=$Path }
  } catch {
    [pscustomobject]@{ Kind=$kind; ExitCode=$null; Error=$_.Exception.Message; Path=$Path }
  }
}

function Get-RelatedServiceSummary {
  try {
    @(Get-Service | Where-Object { $_.Name -match 'telegraf|salt|ucp|vmware' -or $_.DisplayName -match 'telegraf|salt|ucp|vmware' } |
      Select-Object Name,DisplayName,Status,StartType)
  } catch { @() }
}

$script:LogLines = New-Object System.Collections.Generic.List[string]
$result = [ordered]@{
  Timestamp=(Get-Date).ToString('s'); ComputerName=$env:COMPUTERNAME; User=[Security.Principal.WindowsIdentity]::GetCurrent().Name
  CloudProxyFqdn=$CloudProxyFqdn; BootstrapPath=$BootstrapPath; PortTimeoutMs=$PortTimeoutMs
  PortChecks=@(); Download=$null; Execution=$null
}

Test-Dir -Path $OutDir
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionDir = Join-Path $OutDir "BootstrapProbe-$env:COMPUTERNAME-$stamp"
$downloadDir = Join-Path $sessionDir 'downloads'
Test-Dir -Path $sessionDir
Test-Dir -Path $downloadDir
$result.SessionDir = $sessionDir

if (-not $BootstrapPath.StartsWith('/')) { $BootstrapPath = '/' + $BootstrapPath }
$uri = "https://$CloudProxyFqdn$BootstrapPath"
$result.Uri = $uri

Write-Log "Starting probe for $uri"

if ($SkipCertCheck) {
  Write-Log "SkipCertCheck enabled (diagnostic only)" 'WARN'
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } } catch {}
  }
}
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

try {
  $dns = Resolve-DnsName -Name $CloudProxyFqdn -ErrorAction Stop
  $ips = @($dns | Where-Object {$_.IPAddress} | Select-Object -ExpandProperty IPAddress)
  if ($ips.Count -gt 0) { Write-Log ("DNS resolved to: " + ($ips -join ', ')) 'PASS'; $result.DnsAddresses = $ips }
  else { Write-Log "DNS query returned no addresses" 'WARN'; $result.DnsAddresses = @() }
} catch {
  Write-Log "DNS resolution failed: $($_.Exception.Message)" 'FAIL'
  $result.DnsAddresses = @()
}

foreach ($p in 443,8443,4505,4506) {
  Write-Log "Testing TCP $CloudProxyFqdn on port $p (timeout ${PortTimeoutMs}ms)"
  $r = Test-TcpPortQuick -HostName $CloudProxyFqdn -Port $p -TimeoutMs $PortTimeoutMs
  $result.PortChecks += $r
  if ($r.Success) { Write-Log "TCP $p CONNECTED" 'PASS' }
  elseif ($r.Result -eq 'TIMEOUT') { Write-Log "TCP $p TIMEOUT (likely filtered/blackholed)" 'WARN' }
  else { Write-Log "TCP $p FAILED: $($r.Error)" 'FAIL' }
}

$result.PreServices = @(Get-RelatedServiceSummary)
$fileName = Split-Path -Leaf $BootstrapPath
if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = 'bootstrap.bin' }
$outFile = Join-Path $downloadDir $fileName

Write-Log "Downloading to $outFile"
$dl = Invoke-Download -Uri $uri -OutFile $outFile -SkipCertificateCheck:$SkipCertCheck
$result.Download = $dl
if ($dl.Success) {
  try {
    $fi = Get-Item -LiteralPath $outFile -ErrorAction Stop
    $hash = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash
    $result.Download | Add-Member NoteProperty SizeBytes $fi.Length -Force
    $result.Download | Add-Member NoteProperty Sha256 $hash -Force
    Write-Log "Download succeeded. Size=$($fi.Length) SHA256=$hash" 'PASS'
  } catch {
    Write-Log "Download succeeded but file inspection failed: $($_.Exception.Message)" 'WARN'
  }
} else {
  $statusText = if ($dl.StatusCode) { " (HTTP $($dl.StatusCode))" } else { "" }
  Write-Log ("Download failed{0}: {1}" -f $statusText, $dl.Error) 'FAIL'
}

if ($ExecuteBootstrap) {
  if (-not $dl.Success) {
    Write-Log "ExecuteBootstrap requested but download failed; skipping execution." 'FAIL'
  } else {
    Write-Log "Executing bootstrap payload (diagnostic)" 'WARN'
    $exec = Invoke-BootstrapFile -Path $outFile -Arguments $BootstrapArguments
    $result.Execution = $exec
    if ($exec.Error) { Write-Log "Execution error: $($exec.Error)" 'FAIL' }
    elseif ($exec.ExitCode -eq 0) { Write-Log "Execution completed with ExitCode=0" 'PASS' }
    else { Write-Log "Execution completed with ExitCode=$($exec.ExitCode)" 'WARN' }
    Start-Sleep -Seconds ([Math]::Max(1,[Math]::Min($TailSeconds,600)))
    $result.PostServices = @(Get-RelatedServiceSummary)
  }
}

$logPath = Join-Path $sessionDir 'BootstrapProbe.log'
$jsonPath = Join-Path $sessionDir 'BootstrapProbe.json'
$summaryPath = Join-Path $sessionDir 'BootstrapProbe-Summary.txt'

$script:LogLines | Out-File -FilePath $logPath -Encoding utf8
($result | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding utf8

$summary = @()
$summary += "Bootstrap Probe Summary"
$summary += "Computer    : $($result.ComputerName)"
$summary += "Cloud Proxy : $($result.CloudProxyFqdn)"
$summary += "URI         : $($result.Uri)"
$summary += "Session Dir : $sessionDir"
$summary += "Port Checks :"
foreach ($pc in $result.PortChecks) {
  $extra = if ($pc.Error) { " ($($pc.Error))" } else { "" }
  $summary += "  - $($pc.Port): $($pc.Result)$extra"
}
if ($result.Download) { $summary += "Download    : " + ($(if($result.Download.Success){'SUCCESS'}else{'FAIL'})) }
if ($result.Execution) { $summary += "Execution   : ExitCode=$($result.Execution.ExitCode)" }
$summary | Out-File -FilePath $summaryPath -Encoding utf8

Write-Host "`nArtifacts written to:" -ForegroundColor Cyan
Write-Host "  $logPath"
Write-Host "  $jsonPath"
Write-Host "  $summaryPath"

if (@($result.PortChecks | Where-Object { $_.Port -in 4505,4506 -and $_.Result -eq 'TIMEOUT' }).Count -gt 0) {
  Write-Log "Hint: 4505/4506 timeout usually indicates a filtered/blackholed firewall path between endpoint and Cloud Proxy." 'WARN'
}
