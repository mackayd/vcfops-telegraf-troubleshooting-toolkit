#requires -Version 7.0
[CmdletBinding()]
param(
  [Alias('h')][switch]$Help,
  [switch]$Full,
  [switch]$Examples,
  [string]$vCenterServer,
  [string]$TargetsCsv,
  [string]$CloudProxyVmName,
  [string]$CloudProxyFqdn,
  [string]$CloudProxyGuestUser,
  [securestring]$CloudProxyGuestPassword,
  [string]$vCenterUser,
  [securestring]$vCenterPassword,
  [string]$VMNameColumn = 'VMName',
  [string]$ComputerNameColumn = 'ComputerName',
  [string]$GuestUserColumn = 'GuestUser',
  [string]$GuestPasswordColumn = 'GuestPassword',
  [string]$TargetOsColumn = 'TargetOs',
  [string]$UseSudoColumn = 'UseSudo',
  [string]$AltCredFileColumn = 'AltCredFile',
  [ValidateSet('Auto','Windows','Linux')][string]$TargetOs = 'Auto',
  [switch]$UseSudo,
  [switch]$PromptForGuestCredential,
  [string]$CredentialFile,
  [switch]$PromptForWindowsCredential,
  [switch]$PromptForLinuxCredential,
  [string]$WindowsCredentialFile,
  [string]$LinuxCredentialFile,
  [string]$OutDir = '.',
  [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function W {
  param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL')][string]$Level='INFO')
  $color = @{ INFO='Cyan'; PASS='Green'; WARN='Yellow'; FAIL='Red' }[$Level]
  Write-Host "[$Level] $Message" -ForegroundColor $color
}

function New-PlainTextCredential {
  param([Parameter(Mandatory=$true)][string]$UserName,[Parameter(Mandatory=$true)][securestring]$Password)
  [pscredential]::new($UserName,$Password)
}

function ConvertTo-SecureStringIfNeeded {
  param([AllowNull()]$Value)
  if ($Value -is [securestring]) { return $Value }
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  return (ConvertTo-SecureString ([string]$Value) -AsPlainText -Force)
}

function Escape-ForSingleQuotedPowerShell {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return '' }
  return ($Value -replace "'","''")
}

function Escape-ForSingleQuotedBash {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return '' }
  $bashSingleQuoteEscape = "'" + '"' + "'" + '"' + "'"
  return ($Value -replace "'",$bashSingleQuoteEscape)
}

function Resolve-TargetVmName {
  param($Row,[string]$PrimaryColumn,[string]$FallbackColumn)
  $name = $null
  if ($Row.PSObject.Properties.Name -contains $PrimaryColumn) { $name = [string]$Row.$PrimaryColumn }
  if ([string]::IsNullOrWhiteSpace($name) -and $Row.PSObject.Properties.Name -contains $FallbackColumn) {
    $name = [string]$Row.$FallbackColumn
  }
  return $name
}

function Resolve-RequestedTargetOs {
  param($Row,[string]$ColumnName,[string]$DefaultValue)
  $rowTargetOs = $DefaultValue
  if ($Row.PSObject.Properties.Name -contains $ColumnName) {
    $candidate = [string]$Row.$ColumnName
    if ($candidate -in @('Auto','Windows','Linux')) { $rowTargetOs = $candidate }
  }
  return $rowTargetOs
}

function Resolve-UseSudoValue {
  param($Row,[string]$ColumnName,[bool]$DefaultValue)
  $rowUseSudo = $DefaultValue
  if ($Row.PSObject.Properties.Name -contains $ColumnName) {
    $candidate = [string]$Row.$ColumnName
    if ($candidate -match '^(1|true|yes|y)$') { $rowUseSudo = $true }
    elseif ($candidate -match '^(0|false|no|n)$') { $rowUseSudo = $false }
  }
  return $rowUseSudo
}

function Resolve-DetectedTargetOs {
  param(
    [Parameter(Mandatory=$true)]$VM,
    [Parameter(Mandatory=$true)][string]$RequestedTargetOs
  )
  $guestFamily = [string]$VM.ExtensionData.Guest.GuestFamily
  $guestFullName = [string]$VM.ExtensionData.Config.GuestFullName
  $guestId = [string]$VM.ExtensionData.Config.GuestId
  if ($RequestedTargetOs -ne 'Auto') {
    return [pscustomobject]@{ DetectedTargetOs = $RequestedTargetOs; OsDetectionSource = 'CSV override'; GuestFullName = $guestFullName; GuestFamily = $guestFamily; GuestId = $guestId }
  }
  $detected = 'Windows'
  if ($guestFamily -match 'linux' -or $guestId -match 'linux|ubuntu|rhel|centos|rocky|suse|photon|oracle' -or $guestFullName -match 'Linux|Ubuntu|CentOS|Red Hat|Rocky|SUSE|Photon|Oracle') {
    $detected = 'Linux'
  }
  [pscustomobject]@{ DetectedTargetOs = $detected; OsDetectionSource = 'vCenter guest metadata'; GuestFullName = $guestFullName; GuestFamily = $guestFamily; GuestId = $guestId }
}


function Resolve-CloudProxyFqdn {
  param(
    [string]$CloudProxyFqdn,
    [string]$CloudProxyVmName,
    [Parameter(Mandatory=$true)]$CloudProxyVm,
    [Parameter(Mandatory=$true)]$CloudProxyGuestView
  )

  if (-not [string]::IsNullOrWhiteSpace($CloudProxyFqdn)) {
    return [pscustomobject]@{ CloudProxyFqdn = $CloudProxyFqdn; ResolutionSource = 'Parameter' }
  }

  $candidateNames = @(
    [string]$CloudProxyVm.ExtensionData.Guest.HostName,
    [string]$CloudProxyGuestView.HostName,
    [string]$CloudProxyGuestView.ExtensionData.HostName
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $candidateNames) {
    $trimmed = $candidate.Trim()
    if ($trimmed -match '\.') {
      return [pscustomobject]@{ CloudProxyFqdn = $trimmed; ResolutionSource = 'VMware Tools guest hostname' }
    }
  }

  foreach ($candidate in $candidateNames) {
    $trimmed = $candidate.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
      return [pscustomobject]@{ CloudProxyFqdn = $trimmed; ResolutionSource = 'VMware Tools guest hostname (short name)' }
    }
  }

  return [pscustomobject]@{ CloudProxyFqdn = $CloudProxyVmName; ResolutionSource = 'CloudProxyVmName fallback' }
}

function Import-CredentialFromFile {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Credential file not found: $Path" }
  $cred = Import-Clixml -LiteralPath $Path
  if ($cred -isnot [pscredential]) { throw "Credential file '$Path' did not contain a PSCredential object." }
  return $cred
}

function Resolve-RowCredential {
  param(
    [Parameter(Mandatory=$true)]$Row,
    [Parameter(Mandatory=$true)][string]$DetectedTargetOs,
    [Parameter(Mandatory=$true)][string]$GuestUserColumn,
    [Parameter(Mandatory=$true)][string]$GuestPasswordColumn,
    [Parameter(Mandatory=$true)][string]$AltCredFileColumn,
    [AllowNull()]$GlobalCredential,
    [AllowNull()]$WindowsCredential,
    [AllowNull()]$LinuxCredential
  )

  $altCredFile = $null
  if ($Row.PSObject.Properties.Name -contains $AltCredFileColumn) {
    $candidate = [string]$Row.$AltCredFileColumn
    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $altCredFile = $candidate }
  }

  if ($altCredFile) {
    $cred = Import-CredentialFromFile -Path $altCredFile
    return [pscustomobject]@{ Credential = $cred; GuestUser = $cred.UserName; CredentialSource = 'AlternateCredentialFile'; CredentialSourceDetail = $altCredFile; AltCredentialFile = $altCredFile }
  }

  if ($DetectedTargetOs -eq 'Windows' -and $WindowsCredential) {
    return [pscustomobject]@{ Credential = $WindowsCredential; GuestUser = $WindowsCredential.UserName; CredentialSource = 'DefaultWindowsCredentialFile'; CredentialSourceDetail = $WindowsCredentialFile; AltCredentialFile = $null }
  }
  if ($DetectedTargetOs -eq 'Linux' -and $LinuxCredential) {
    return [pscustomobject]@{ Credential = $LinuxCredential; GuestUser = $LinuxCredential.UserName; CredentialSource = 'DefaultLinuxCredentialFile'; CredentialSourceDetail = $LinuxCredentialFile; AltCredentialFile = $null }
  }
  if ($GlobalCredential) {
    return [pscustomobject]@{ Credential = $GlobalCredential; GuestUser = $GlobalCredential.UserName; CredentialSource = 'CredentialFile'; CredentialSourceDetail = $CredentialFile; AltCredentialFile = $null }
  }

  $guestUser = $null
  $guestPassword = $null
  if ($Row.PSObject.Properties.Name -contains $GuestUserColumn) { $guestUser = [string]$Row.$GuestUserColumn }
  if ($Row.PSObject.Properties.Name -contains $GuestPasswordColumn) { $guestPassword = [string]$Row.$GuestPasswordColumn }
  $rowVmName = if ($Row.PSObject.Properties.Name -contains 'VMName') { [string]$Row.VMName } elseif ($Row.PSObject.Properties.Name -contains 'ComputerName') { [string]$Row.ComputerName } else { '<row>' }
  if ([string]::IsNullOrWhiteSpace($guestUser)) { throw "Missing GuestUser for $rowVmName" }
  if ([string]::IsNullOrWhiteSpace($guestPassword)) { throw "Missing GuestPassword for $rowVmName" }
  $securePassword = ConvertTo-SecureString $guestPassword -AsPlainText -Force
  $cred = [pscredential]::new($guestUser,$securePassword)
  return [pscustomobject]@{ Credential = $cred; GuestUser = $guestUser; CredentialSource = 'CSV plaintext'; CredentialSourceDetail = $null; AltCredentialFile = $null }
}

function New-GuestTestScripts {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('Windows','Linux')][string]$TargetOs,
    [Parameter(Mandatory=$true)][string]$vCenterHost,
    [Parameter(Mandatory=$true)][string]$EsxiHost,
    [Parameter(Mandatory=$true)][string]$CloudProxyHost
  )

  if ($TargetOs -eq 'Windows') {
    $vc = Escape-ForSingleQuotedPowerShell $vCenterHost
    $esx = Escape-ForSingleQuotedPowerShell $EsxiHost
    $cp = Escape-ForSingleQuotedPowerShell $CloudProxyHost
    $bootstrap = "/downloads/salt/telegraf-utils.ps1"
    return [pscustomobject]@{
      ScriptType = 'PowerShell'
      BootstrapPath = $bootstrap
      ScriptText = @"
`$ErrorActionPreference='Stop'
function Emit([string]`$status,[string]`$label){ Write-Output ("RESULT {0} {1}" -f `$status,`$label) }
function Test-Tcp([string]`$label,[string]`$TargetHost,[int]`$port){
  try {
    `$client = [System.Net.Sockets.TcpClient]::new()
    `$iar = `$client.BeginConnect(`$TargetHost,`$port,`$null,`$null)
    if(-not `$iar.AsyncWaitHandle.WaitOne(5000)){ `$client.Close(); Emit 'FAIL' `$label; return }
    `$client.EndConnect(`$iar) | Out-Null
    `$client.Close()
    Emit 'PASS' `$label
  } catch { Emit 'FAIL' `$label }
}
function Test-Bootstrap([string]`$url){
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
  } catch {}
  `$tmp = Join-Path `$env:TEMP 'vcfops-bootstrap.ps1'
  `$regularOk = `$false
  `$insecureOk = `$false
  try {
    Invoke-WebRequest -UseBasicParsing -Uri `$url -TimeoutSec 20 -OutFile `$tmp | Out-Null
    `$regularOk = `$true
  } catch {
    Write-Output ('RESULT INFO TARGET>BOOTSTRAP:DETAIL:' + (`$_.Exception.Message -replace "`r?`n",' '))
  }
  if(-not `$regularOk){
    `$previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
      [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { `$true }
      Invoke-WebRequest -UseBasicParsing -Uri `$url -TimeoutSec 20 -OutFile `$tmp | Out-Null
      `$insecureOk = `$true
    } catch {
      Write-Output ('RESULT INFO TARGET>BOOTSTRAP:INSECURE_DETAIL:' + (`$_.Exception.Message -replace "`r?`n",' '))
    } finally {
      [System.Net.ServicePointManager]::ServerCertificateValidationCallback = `$previous
    }
  }
  if(Test-Path `$tmp){ Remove-Item `$tmp -Force -ErrorAction SilentlyContinue }
  if(`$regularOk){ Write-Output 'RESULT PASS TARGET>CLOUDPROXY:BOOTSTRAP' }
  elseif(`$insecureOk){ Write-Output 'RESULT WARN TARGET>CLOUDPROXY:BOOTSTRAP_INSECURE' }
  else { Write-Output 'RESULT FAIL TARGET>CLOUDPROXY:BOOTSTRAP' }
}
whoami
hostname
Get-Date -Format s
Test-Tcp 'TARGET>VCENTER:443' '$vc' 443
Test-Tcp 'TARGET>ESXI:443' '$esx' 443
Test-Tcp 'TARGET>CLOUDPROXY:443' '$cp' 443
Test-Bootstrap ('https://$cp$bootstrap')
"@
    }
  }

  $vc = Escape-ForSingleQuotedBash $vCenterHost
  $esx = Escape-ForSingleQuotedBash $EsxiHost
  $cp = Escape-ForSingleQuotedBash $CloudProxyHost
  $bootstrap = "/downloads/salt/telegraf-utils.sh"
  return [pscustomobject]@{
    ScriptType = 'Bash'
    BootstrapPath = $bootstrap
    ScriptText = @"
set -u

echo "RESULT INFO TARGETOS:LINUX"
whoami
hostname
date -Iseconds 2>/dev/null || date
if [ -r /etc/os-release ]; then . /etc/os-release; echo "RESULT INFO TARGETOS:`$PRETTY_NAME"; fi

test_tcp(){
  label="`$1"; host="`$2"; port="`$3"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "`$host" "`$port" >/dev/null 2>&1; rc=`$?
  elif command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -lc "cat < /dev/null > /dev/tcp/`$host/`$port" >/dev/null 2>&1; rc=`$?
  else
    echo 'RESULT WARN TARGET>TOOLING:CONNECTIVITY_HELPER_MISSING'; rc=1
  fi
  if [ `$rc -eq 0 ]; then echo "RESULT PASS `$label"; else echo "RESULT FAIL `$label"; fi
}

test_bootstrap(){
  url="`$1"
  tmp_file="/tmp/vcfops-telegraf-bootstrap.$$"
  if command -v curl >/dev/null 2>&1; then
    tool='curl'
    curl -fsS --max-time 20 "`$url" -o "`$tmp_file" >/dev/null 2>&1; rc=`$?
    if [ `$rc -ne 0 ]; then curl -kfsS --max-time 20 "`$url" -o "`$tmp_file" >/dev/null 2>&1; insecure_rc=`$?; else insecure_rc=`$rc; fi
  elif command -v wget >/dev/null 2>&1; then
    tool='wget'
    wget -q -T 20 -O "`$tmp_file" "`$url" >/dev/null 2>&1; rc=`$?
    if [ `$rc -ne 0 ]; then wget --no-check-certificate -q -T 20 -O "`$tmp_file" "`$url" >/dev/null 2>&1; insecure_rc=`$?; else insecure_rc=`$rc; fi
  else
    echo 'RESULT WARN TARGET>BOOTSTRAP:DOWNLOAD_TOOL_MISSING'
    rc=1
    insecure_rc=1
    tool='none'
  fi
  [ -f "`$tmp_file" ] && rm -f "`$tmp_file"
  echo "RESULT INFO TARGET>BOOTSTRAP:TOOL:`$tool"
  echo "RESULT INFO TARGET>BOOTSTRAP:EXITCODE:`$rc"
  echo "RESULT INFO TARGET>BOOTSTRAP:INSECURE_EXITCODE:`$insecure_rc"
  if [ `$rc -eq 0 ]; then
    echo 'RESULT PASS TARGET>CLOUDPROXY:BOOTSTRAP'
  elif [ `$insecure_rc -eq 0 ]; then
    echo 'RESULT WARN TARGET>CLOUDPROXY:BOOTSTRAP_INSECURE'
  else
    echo 'RESULT FAIL TARGET>CLOUDPROXY:BOOTSTRAP'
  fi
}

test_tcp 'TARGET>VCENTER:443' '$vc' 443
test_tcp 'TARGET>ESXI:443' '$esx' 443
test_tcp 'TARGET>CLOUDPROXY:443' '$cp' 443
test_bootstrap 'https://$cp$bootstrap'
"@
  }
}

function New-CloudProxyGuestScript {
  param([Parameter(Mandatory=$true)][string]$vCenterHost,[Parameter(Mandatory=$true)][string]$EsxiHost)
  $vc = Escape-ForSingleQuotedBash $vCenterHost
  $esx = Escape-ForSingleQuotedBash $EsxiHost
  $script = @'
echo "Testing from Cloud Proxy guest"
check_tcp(){
  host="$1"
  port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "$host" "$port" >/dev/null 2>&1
    rc=$?
  else
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1
    rc=$?
  fi
  if [ $rc -eq 0 ]; then
    echo "RESULT PASS ${host}:${port}"
  else
    echo "RESULT FAIL ${host}:${port}"
  fi
}
check_tcp '__VC__' 443
check_tcp '__ESX__' 443
'@
  $script = $script.Replace('__VC__', $vc).Replace('__ESX__', $esx)
  return $script
}


function Add-SummaryLine {
  param([System.Text.StringBuilder]$Builder,[string]$Line)
  [void]$Builder.AppendLine($Line)
}

function Add-ResultSummaryFromTargetOutput {
  param(
    [System.Text.StringBuilder]$Builder,
    [string]$VmName,
    [string]$OutputText,
    [string]$DetectedTargetOs,
    [string]$GuestFullName,
    [string]$CloudProxyFqdn,
    [string]$BootstrapPath,
    [string]$OwningHost,
    [int]$ExitCode
  )

  Add-SummaryLine -Builder $Builder -Line '==================== Validation Summary ===================='
  Add-SummaryLine -Builder $Builder -Line ''
  Add-SummaryLine -Builder $Builder -Line ("Telegraf VM target : {0}" -f $VmName)
  Add-SummaryLine -Builder $Builder -Line 'PASS : Admin workstation > vCenter on 443'
  Add-SummaryLine -Builder $Builder -Line ("INFO : Cloud Proxy target host : {0}" -f $CloudProxyFqdn)
  Add-SummaryLine -Builder $Builder -Line ("INFO : vCenter guest OS : {0}" -f $GuestFullName)
  Add-SummaryLine -Builder $Builder -Line ("INFO : Target OS mode selected : {0}" -f $DetectedTargetOs)
  Add-SummaryLine -Builder $Builder -Line ("INFO : Cloud Proxy bootstrap path : {0}" -f $BootstrapPath)
  Add-SummaryLine -Builder $Builder -Line ("PASS : Owning ESXi host discovered : {0}" -f $OwningHost)
  if ($ExitCode -eq 0) { Add-SummaryLine -Builder $Builder -Line 'PASS : Guest execution' }
  else { Add-SummaryLine -Builder $Builder -Line ("WARN : Guest execution (ExitCode={0})" -f $ExitCode) }

  foreach ($rawLine in ($OutputText -split "`r?`n")) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    switch -Regex ($line) {
      '^RESULT PASS TARGET>VCENTER:443$' { Add-SummaryLine -Builder $Builder -Line 'PASS : Telegraf VM target > vCenter on 443'; continue }
      '^RESULT FAIL TARGET>VCENTER:443$' { Add-SummaryLine -Builder $Builder -Line 'FAIL : Telegraf VM target > vCenter on 443'; continue }
      '^RESULT PASS TARGET>ESXI:443$' { Add-SummaryLine -Builder $Builder -Line 'PASS : Telegraf VM target > ESXi on 443'; continue }
      '^RESULT FAIL TARGET>ESXI:443$' { Add-SummaryLine -Builder $Builder -Line 'FAIL : Telegraf VM target > ESXi on 443'; continue }
      '^RESULT PASS TARGET>CLOUDPROXY:443$' { Add-SummaryLine -Builder $Builder -Line 'PASS : Telegraf VM target > Cloud Proxy on 443'; continue }
      '^RESULT FAIL TARGET>CLOUDPROXY:443$' { Add-SummaryLine -Builder $Builder -Line 'FAIL : Telegraf VM target > Cloud Proxy on 443'; continue }
      '^RESULT PASS TARGET>CLOUDPROXY:BOOTSTRAP$' { Add-SummaryLine -Builder $Builder -Line 'PASS : Telegraf VM target > Cloud Proxy bootstrap download'; continue }
      '^RESULT FAIL TARGET>CLOUDPROXY:BOOTSTRAP$' { Add-SummaryLine -Builder $Builder -Line 'FAIL : Telegraf VM target > Cloud Proxy bootstrap download'; continue }
      '^RESULT WARN TARGET>CLOUDPROXY:BOOTSTRAP_INSECURE$' {
        Add-SummaryLine -Builder $Builder -Line 'WARN : Telegraf VM target > Cloud Proxy bootstrap download (PASS+INSECURE)'
        Add-SummaryLine -Builder $Builder -Line 'Message: The Linux guest could download the bootstrap URL only when HTTPS certificate validation was bypassed.'
        continue
      }
      '^RESULT INFO TARGET>BOOTSTRAP:TOOL:(.+)$' {
        Add-SummaryLine -Builder $Builder -Line ("INFO : Linux bootstrap tool : {0}" -f $Matches[1].Trim())
        continue
      }
      '^RESULT INFO TARGET>BOOTSTRAP:EXITCODE:(.+)$' {
        Add-SummaryLine -Builder $Builder -Line ("INFO : Linux bootstrap exit code : {0}" -f $Matches[1].Trim())
        continue
      }
      '^RESULT INFO TARGET>BOOTSTRAP:INSECURE_EXITCODE:(.+)$' {
        Add-SummaryLine -Builder $Builder -Line ("INFO : Linux bootstrap insecure exit code : {0}" -f $Matches[1].Trim())
        continue
      }
      '^RESULT INFO TARGETOS:(.+)$' {
        $osValue = $Matches[1].Trim()
        if ($osValue -and $osValue -ne 'LINUX' -and $osValue -ne 'WINDOWS') {
          Add-SummaryLine -Builder $Builder -Line ("INFO : Linux guest reported OS : {0}" -f $osValue)
        }
        continue
      }
    }
  }
}

function Add-ResultSummaryFromCloudProxyOutput {
  param(
    [System.Text.StringBuilder]$Builder,
    [string]$CloudProxyVmName,
    [string]$OutputText,
    [string]$vCenterHost,
    [string]$EsxiHost
  )

  Add-SummaryLine -Builder $Builder -Line ''
  Add-SummaryLine -Builder $Builder -Line ("Cloud Proxy : {0}" -f $CloudProxyVmName)
  Add-SummaryLine -Builder $Builder -Line 'PASS : Guest execution'
  foreach ($rawLine in ($OutputText -split "`r?`n")) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -eq "RESULT PASS ${vCenterHost}:443") { Add-SummaryLine -Builder $Builder -Line 'PASS : Cloud Proxy > vCenter on 443'; continue }
    if ($line -eq "RESULT FAIL ${vCenterHost}:443") { Add-SummaryLine -Builder $Builder -Line 'FAIL : Cloud Proxy > vCenter on 443'; continue }
    if ($line -eq "RESULT PASS ${EsxiHost}:443") { Add-SummaryLine -Builder $Builder -Line 'PASS : Cloud Proxy > ESXi on 443'; continue }
    if ($line -eq "RESULT FAIL ${EsxiHost}:443") { Add-SummaryLine -Builder $Builder -Line 'FAIL : Cloud Proxy > ESXi on 443'; continue }
  }
}

function Get-OverallStatus {
  param([string[]]$Statuses)
  if ($Statuses -contains 'FAIL') { return 'FAIL' }
  if ($Statuses -contains 'WARN') { return 'WARN' }
  if ($Statuses -contains 'PASS') { return 'PASS' }
  return 'INFO'
}

function Show-ShortHelp {
  @"
Invoke-VcfOpsFleetGuestOps.ps1

Purpose
  Runs Telegraf Guest Ops connectivity/bootstrap validation across a fleet of VMs using VMware Tools Invoke-VMScript.
  The script auto-detects Windows vs Linux from vCenter guest metadata, runs PowerShell inside Windows guests and Bash inside Linux guests,
  and writes fleet CSV/JSON output suitable for the HTML report generator.

Quick usage
  .\Invoke-VcfOpsFleetGuestOps.ps1 -vCenterServer vCenter-01.devops.local -TargetsCsv .\targets.csv -CloudProxyVmName vrops-cp01 -CloudProxyGuestUser root -CloudProxyGuestPassword $cpPw -vCenterUser administrator@vsphere.local -vCenterPassword $vcPw

  Cloud Proxy hostname handling:
  - If -CloudProxyFqdn is omitted, the script queries VMware Tools guest metadata on the Cloud Proxy VM and uses the guest-reported hostname/FQDN.
  - If no guest hostname is reported, it falls back to CloudProxyVmName.

  If -CloudProxyFqdn is omitted, the script queries VMware Tools guest metadata on the Cloud Proxy VM and uses the guest-reported hostname/FQDN automatically.

Help switches
  -h or -Help   Show this summary
  -Full         Show detailed help including credential handling and CSV rules
  -Examples     Show worked examples

Credential methods
  1. Recommended: create DPAPI-protected credential files with Save-VcfOpsTelegrafCredential.ps1
  2. Per-row override: set AltCredFile in the CSV for a VM that needs a different account
  3. Fallback: store GuestUser and GuestPassword in plaintext in the CSV if you accept that risk

Credential precedence
  1. AltCredFile from the CSV row
  2. OS-specific default credential file (WindowsCredentialFile / LinuxCredentialFile)
  3. Global CredentialFile
  4. GuestUser and GuestPassword from the CSV

Run with -Full for full guidance or -Examples for sample commands.
"@ | Write-Host
}

function Show-FullHelp {
  @"
NAME
  Invoke-VcfOpsFleetGuestOps.ps1

SYNOPSIS
  Fleet Guest Operations validator for Telegraf prerequisites using VMware Tools / Invoke-VMScript.

HOW IT WORKS
  1. Reads the target CSV.
  2. Connects to vCenter.
  3. Resolves each VM by name.
  4. Detects the guest OS from vCenter metadata unless TargetOs is explicitly set.
  5. Selects credentials based on AltCredFile, default credential files, global credential file, or CSV GuestUser/GuestPassword.
  6. Runs the test script inside the guest using Invoke-VMScript:
       - PowerShell for Windows guests
       - Bash for Linux guests
  7. Runs Cloud Proxy guest-side TCP checks to vCenter and the owning ESXi host.
  8. Writes GuestOpsFleetSummary-<timestamp>.json and .csv for HTML reporting.

WHAT IS TESTED
  - Admin workstation > vCenter TCP 443
  - Target VM > vCenter TCP 443
  - Target VM > owning ESXi host TCP 443
  - Target VM > Cloud Proxy TCP 443
  - Target VM > Cloud Proxy bootstrap download over HTTPS
  - Cloud Proxy > vCenter TCP 443
  - Cloud Proxy > owning ESXi host TCP 443

  Cloud Proxy hostname / FQDN behavior:
  - If -CloudProxyFqdn is supplied, that value is used.
  - If -CloudProxyFqdn is omitted, the script queries VMware Tools guest metadata on the Cloud Proxy VM and uses the guest-reported hostname/FQDN.
  - If VMware Tools does not report a hostname, the script falls back to CloudProxyVmName.

  Linux bootstrap behavior:
  - First tries normal certificate validation.
  - If that fails, retries with certificate validation bypass.
  - If only the bypass succeeds, the VM is marked WARN rather than FAIL.

CSV FORMAT
  The script is designed to use a CSV example CSV in gitrepo Typical columns are:

    VMName,GuestUser,GuestPassword,TargetOs,UseSudo,AltCredFile

  Notes:
  - VMName is the preferred VM identifier.
  - ComputerName is also supported as a fallback if VMName is not present.
  - TargetOs may be Auto, Windows, or Linux.
  - UseSudo is relevant to Linux flows if you extend guest-side actions later.
  - AltCredFile allows a single VM to use a different credential file.

CREDENTIAL OPTIONS
  Option 1 - OS-specific default credential files (recommended for mixed fleets)
    -WindowsCredentialFile <path>
    -LinuxCredentialFile   <path>

    The script auto-detects the VM OS and picks the matching credential file.

  Option 2 - One global credential file for all VMs
    -CredentialFile <path>

  Option 3 - Prompt interactively
    -PromptForWindowsCredential
    -PromptForLinuxCredential
    or
    -PromptForGuestCredential

  Option 4 - Plaintext credentials in the CSV
    GuestUser and GuestPassword columns

    This is supported for convenience, but the password is stored in plaintext on disk. Only use this if you accept that security risk.

HOW TO CREATE CREDENTIAL FILES
  Use Save-VcfOpsTelegrafCredential.ps1 to create a DPAPI-protected PSCredential file.

  Example:
    .\Save-VcfOpsTelegrafCredential.ps1 -Path .\Windows.xml
    .\Save-VcfOpsTelegrafCredential.ps1 -Path .\Linux.xml
    .\Save-VcfOpsTelegrafCredential.ps1 -Path .\Telegraf-test03.xml

  Important:
  - These files are protected for the current Windows user on the current machine.
  - They are not intended to be portable across different users or computers.

ALTERNATE CREDENTIAL FILE PER VM
  If one VM needs a different account, populate AltCredFile in that VM's CSV row.

  Example CSV:
    VMName,GuestUser,GuestPassword,TargetOs,UseSudo,AltCredFile
    Telegraf-test01,devops\<adminUserName,MyPlaintextPassword,Auto,false,
    Telegraf-test02,user,MyLinuxPassword,Auto,false,
    Telegraf-test03,,,Auto,false,.\Telegraf-test03.xml

  In this example:
  - Telegraf-test01 uses GuestUser / GuestPassword from the CSV
  - Telegraf-test02 uses GuestUser / GuestPassword from the CSV
  - Telegraf-test03 ignores GuestUser / GuestPassword and uses Telegraf-test03.xml

CREDENTIAL PRECEDENCE
  Highest to lowest:
  1. AltCredFile in the CSV row
  2. WindowsCredentialFile or LinuxCredentialFile based on detected OS
  3. CredentialFile
  4. GuestUser and GuestPassword from the CSV

OUTPUT FILES
  - GuestOpsFleetSummary-<timestamp>.json
  - GuestOpsFleetSummary-<timestamp>.csv

  These outputs are intended to be consumed by your HTML report script.

REQUIREMENTS
  - PowerShell 7+
  - VMware PowerCLI
  - vCenter connectivity from the admin workstation
  - VMware Tools running in the target VMs
  - VMware Tools running in the Cloud Proxy VM
  - Valid guest OS credentials for each target VM and the Cloud Proxy VM
  - Permissions in vCenter for guest operations / Invoke-VMScript

COMMON NOTES
  - CloudProxyFqdn is optional. If omitted, the script queries VMware Tools guest metadata on the Cloud Proxy VM and uses the reported hostname/FQDN. If VMware Tools does not report a hostname, it falls back to CloudProxyVmName.
  - If vCenterUser is specified, vCenterPassword must also be supplied.
  - ContinueOnError keeps processing the remaining rows if one VM fails.
"@ | Write-Host
}

function Show-ExamplesHelp {
  @"
EXAMPLE 1 - Plaintext credentials in the CSV
  .\Invoke-VcfOpsFleetGuestOps.ps1 `
    -vCenterServer 'vCenter-01.devops.local' `
    -TargetsCsv '.\targets.csv' `
    -vCenterUser 'administrator@vsphere.local' `
    -vCenterPassword $vcPw `
    -CloudProxyVmName 'vrops-cp01' `
    -CloudProxyGuestUser 'root' `
    -CloudProxyGuestPassword $cpPw `
    -OutDir '.'

EXAMPLE 2 - Default Windows and Linux credential files
  .\Save-VcfOpsTelegrafCredential.ps1 -Path .\Windows.xml
  .\Save-VcfOpsTelegrafCredential.ps1 -Path .\Linux.xml

  .\Invoke-VcfOpsFleetGuestOps.ps1 `
    -vCenterServer 'vCenter-01.devops.local' `
    -TargetsCsv '.\targets.csv' `
    -vCenterUser 'administrator@vsphere.local' `
    -vCenterPassword $vcPw `
    -CloudProxyVmName 'vrops-cp01' `
    -CloudProxyGuestUser 'root' `
    -CloudProxyGuestPassword $cpPw `
    -WindowsCredentialFile '.\Windows.xml' `
    -LinuxCredentialFile '.\Linux.xml' `
    -OutDir '.'

EXAMPLE 3 - Per-VM alternate credential file
  .\Save-VcfOpsTelegrafCredential.ps1 -Path .\Telegraf-test03.xml

  CSV row example:
    Telegraf-test03,,,Auto,false,.\Telegraf-test03.xml

  When AltCredFile is populated, that credential file overrides GuestUser and GuestPassword for that VM.

EXAMPLE 4 - One global credential file for every VM
  .\Save-VcfOpsTelegrafCredential.ps1 -Path .\AllGuests.xml

  .\Invoke-VcfOpsFleetGuestOps.ps1 `
    -vCenterServer 'vCenter-01.devops.local' `
    -TargetsCsv '.\targets.csv' `
    -vCenterUser 'administrator@vsphere.local' `
    -vCenterPassword $vcPw `
    -CloudProxyVmName 'vrops-cp01' `
    -CloudProxyGuestUser 'root' `
    -CloudProxyGuestPassword $cpPw `
    -CredentialFile '.\AllGuests.xml' `
    -OutDir '.'

EXAMPLE 5 - Show help
  .\Invoke-VcfOpsFleetGuestOps.ps1 -h
  .\Invoke-VcfOpsFleetGuestOps.ps1 -Full
  .\Invoke-VcfOpsFleetGuestOps.ps1 -Examples
"@ | Write-Host
}

function Test-RequiredParameters {
  $missing = @()
  foreach ($name in 'vCenterServer','TargetsCsv','CloudProxyVmName','CloudProxyGuestUser','CloudProxyGuestPassword') {
    $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $value) { $missing += $name; continue }
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { $missing += $name; continue }
  }
  if ($missing.Count -gt 0) {
    throw ('Missing required parameters: ' + ($missing -join ', ') + '. Run with -h, -Full, or -Examples for usage guidance.')
  }
}

if ($Help) { Show-ShortHelp; return }
if ($Full) { Show-FullHelp; return }
if ($Examples) { Show-ExamplesHelp; return }

Test-RequiredParameters

if (-not (Test-Path -LiteralPath $TargetsCsv)) { throw "Targets CSV not found: $TargetsCsv" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -Path $OutDir -ItemType Directory -Force | Out-Null }

$targets = Import-Csv -LiteralPath $TargetsCsv
$summary = [System.Collections.Generic.List[object]]::new()

$globalCredential = $null
$windowsCredential = $null
$linuxCredential = $null

if ($CredentialFile) { $globalCredential = Import-CredentialFromFile -Path $CredentialFile }
elseif ($PromptForGuestCredential) { $globalCredential = Get-Credential -Message 'Enter guest credential for all VMs' }
if ($WindowsCredentialFile) { $windowsCredential = Import-CredentialFromFile -Path $WindowsCredentialFile }
elseif ($PromptForWindowsCredential) { $windowsCredential = Get-Credential -Message 'Enter default Windows guest credential' }
if ($LinuxCredentialFile) { $linuxCredential = Import-CredentialFromFile -Path $LinuxCredentialFile }
elseif ($PromptForLinuxCredential) { $linuxCredential = Get-Credential -Message 'Enter default Linux guest credential' }

if ($WindowsCredentialFile -or $LinuxCredentialFile -or $PromptForWindowsCredential -or $PromptForLinuxCredential) {
  Write-Host 'INFO: Default credential file mode enabled. GuestUser and GuestPassword will be read from the CSV only when no default or alternate credential file applies.' -ForegroundColor Cyan
} elseif ($CredentialFile -or $PromptForGuestCredential) {
  Write-Host 'INFO: Global credential mode enabled. GuestUser and GuestPassword columns in the CSV will be ignored unless AltCredFile is populated for a row.' -ForegroundColor Cyan
} else {
  Write-Host 'INFO: No default credential file mode enabled. GuestUser and GuestPassword will be read from the CSV unless AltCredFile is populated for a row.' -ForegroundColor Cyan
}

$vcCred = $null
if ($vCenterUser -and $vCenterPassword) { $vcCred = New-PlainTextCredential -UserName $vCenterUser -Password $vCenterPassword }
elseif ($vCenterUser) { throw 'vCenterUser was specified but vCenterPassword was not supplied.' }

$cpGuestCred = New-PlainTextCredential -UserName $CloudProxyGuestUser -Password $CloudProxyGuestPassword

foreach ($row in $targets) {
  $vmName = Resolve-TargetVmName -Row $row -PrimaryColumn $VMNameColumn -FallbackColumn $ComputerNameColumn
  if ([string]::IsNullOrWhiteSpace($vmName)) { continue }
  $requestedOs = Resolve-RequestedTargetOs -Row $row -ColumnName $TargetOsColumn -DefaultValue $TargetOs
  $useSudoValue = Resolve-UseSudoValue -Row $row -ColumnName $UseSudoColumn -DefaultValue ([bool]$UseSudo)

  Write-Host ''
  Write-Host '============================================================' -ForegroundColor DarkCyan
  Write-Host ("GuestOps fleet test : {0} (Requested={1})" -f $vmName,$requestedOs) -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor DarkCyan

  $fullOutput = New-Object System.Text.StringBuilder
  $vmResult = [ordered]@{
    VMName = $vmName
    Status = 'FAIL'
    GuestUser = $null
    CredentialSource = $null
    CredentialSourceDetail = $null
    RequestedTargetOs = $requestedOs
    DetectedTargetOs = 'Auto'
    OsDetectionSource = $null
    GuestFullName = $null
    UseSudo = $useSudoValue
    CloudProxy = $CloudProxyVmName
    AltCredentialFile = $null
    Output = $null
  }

  $statuses = [System.Collections.Generic.List[string]]::new()
  $vi = $null
  try {
    W "Testing workstation connectivity to vCenter $vCenterServer on TCP 443 ..."
    $tcp = Test-NetConnection -ComputerName $vCenterServer -Port 443 -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) { throw "Unable to reach $vCenterServer on TCP 443 from the workstation." }
    [void]$fullOutput.AppendLine("[PASS] Admin workstation > vCenter on 443")
    $statuses.Add('PASS')

    if ($vcCred) { $vi = Connect-VIServer -Server $vCenterServer -Credential $vcCred -ErrorAction Stop }
    else { $vi = Connect-VIServer -Server $vCenterServer -ErrorAction Stop }
    try {
      W "Connected to $vCenterServer as $($vi.User)" 'PASS'
      [void]$fullOutput.AppendLine("[PASS] Connected to $vCenterServer as $($vi.User)")

      $vm = Get-VM -Name $vmName -ErrorAction Stop
      $guestView = Get-VMGuest -VM $vm -ErrorAction Stop
      $owningHost = ($vm | Get-VMHost -ErrorAction Stop).Name
      $osInfo = Resolve-DetectedTargetOs -VM $vm -RequestedTargetOs $requestedOs
      $vmResult.DetectedTargetOs = $osInfo.DetectedTargetOs
      $vmResult.OsDetectionSource = $osInfo.OsDetectionSource
      $vmResult.GuestFullName = $osInfo.GuestFullName
      W ("Detected guest OS: {0} ({1}) via {2}" -f $osInfo.DetectedTargetOs,$osInfo.GuestFullName,$osInfo.OsDetectionSource)
      [void]$fullOutput.AppendLine("[INFO] VM found: $($vm.Name) (PowerState=$($vm.PowerState))")
      [void]$fullOutput.AppendLine("[INFO] VMware Tools status: $($vm.ExtensionData.Guest.ToolsRunningStatus) / $($vm.ExtensionData.Guest.ToolsVersionStatus2)")
      [void]$fullOutput.AppendLine("[PASS] Target VM is currently running on ESXi host: $owningHost")

      $credInfo = Resolve-RowCredential -Row $row -DetectedTargetOs $osInfo.DetectedTargetOs -GuestUserColumn $GuestUserColumn -GuestPasswordColumn $GuestPasswordColumn -AltCredFileColumn $AltCredFileColumn -GlobalCredential $globalCredential -WindowsCredential $windowsCredential -LinuxCredential $linuxCredential
      $vmResult.GuestUser = $credInfo.GuestUser
      $vmResult.CredentialSource = $credInfo.CredentialSource
      $vmResult.CredentialSourceDetail = $credInfo.CredentialSourceDetail
      $vmResult.AltCredentialFile = $credInfo.AltCredentialFile
      W ("Using credential source: {0}" -f $credInfo.CredentialSource)
      if ($credInfo.CredentialSourceDetail) { W ("Credential source detail: {0}" -f $credInfo.CredentialSourceDetail) }

      if ($vm.PowerState -ne 'PoweredOn') { throw "VM '$vmName' is not powered on." }
      if ($vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') { throw "VMware Tools is not running on '$vmName'." }

      $cpVm = Get-VM -Name $CloudProxyVmName -ErrorAction Stop
      $cpGuestView = Get-VMGuest -VM $cpVm -ErrorAction Stop
      $cpHostInfo = Resolve-CloudProxyFqdn -CloudProxyFqdn $CloudProxyFqdn -CloudProxyVmName $CloudProxyVmName -CloudProxyVm $cpVm -CloudProxyGuestView $cpGuestView
      $resolvedCloudProxyFqdn = $cpHostInfo.CloudProxyFqdn
      $testScripts = New-GuestTestScripts -TargetOs $osInfo.DetectedTargetOs -vCenterHost $vCenterServer -EsxiHost $owningHost -CloudProxyHost $resolvedCloudProxyFqdn
      W ("Invoking {0} guest script on target VM via Invoke-VMScript ..." -f ($testScripts.ScriptType))
      $targetRun = Invoke-VMScript -VM $vm -GuestCredential $credInfo.Credential -ScriptType $testScripts.ScriptType -ScriptText $testScripts.ScriptText -ErrorAction Stop
      if ($targetRun.ExitCode -ne 0 -and $osInfo.DetectedTargetOs -eq 'Windows') {
        [void]$fullOutput.AppendLine("[WARN] Invoke-VMScript completed with exit code $($targetRun.ExitCode)")
      } else {
        [void]$fullOutput.AppendLine("[PASS] Invoke-VMScript on target VM succeeded (ExitCode=$($targetRun.ExitCode))")
      }
      [void]$fullOutput.AppendLine('')
      [void]$fullOutput.AppendLine('--- Target Guest Script Output ---')
      [void]$fullOutput.AppendLine(($targetRun.ScriptOutput | Out-String).Trim())
      [void]$fullOutput.AppendLine('')
      [void]$fullOutput.AppendLine('----------------------------------')
      Write-Host ''
      Write-Host '--- Target Guest Script Output ---' -ForegroundColor DarkGray
      Write-Host (($targetRun.ScriptOutput | Out-String).Trim())
      Write-Host ''
      Write-Host '----------------------------------' -ForegroundColor DarkGray

      foreach ($line in (($targetRun.ScriptOutput | Out-String) -split "`r?`n")) {
        if ($line -match '^RESULT\s+(PASS|WARN|FAIL|INFO)\s+') { $statuses.Add($matches[1]) }
      }

      W ("Cloud Proxy VM found: {0} (PowerState={1})" -f $cpVm.Name,$cpVm.PowerState) 'PASS'
      W ("Cloud Proxy target host resolved as: {0} ({1})" -f $resolvedCloudProxyFqdn,$cpHostInfo.ResolutionSource)
      [void]$fullOutput.AppendLine(("[PASS] Cloud Proxy VM found: {0} (PowerState={1})" -f $cpVm.Name,$cpVm.PowerState))
      [void]$fullOutput.AppendLine(("[INFO] Cloud Proxy VMware Tools status: {0} / {1}" -f $cpVm.ExtensionData.Guest.ToolsRunningStatus,$cpVm.ExtensionData.Guest.ToolsVersionStatus2))
      [void]$fullOutput.AppendLine(("[INFO] Cloud Proxy target host resolved as: {0} ({1})" -f $resolvedCloudProxyFqdn,$cpHostInfo.ResolutionSource))
      W 'Running Cloud Proxy guest-side TCP 443 checks to vCenter and owning ESXi host ...'
      $cpScript = New-CloudProxyGuestScript -vCenterHost $vCenterServer -EsxiHost $owningHost
      $cpRun = Invoke-VMScript -VM $cpVm -GuestCredential $cpGuestCred -ScriptType Bash -ScriptText $cpScript -ErrorAction Stop
      [void]$fullOutput.AppendLine('')
      [void]$fullOutput.AppendLine('--- Cloud Proxy Guest Script Output ---')
      [void]$fullOutput.AppendLine(($cpRun.ScriptOutput | Out-String).Trim())
      [void]$fullOutput.AppendLine('')
      [void]$fullOutput.AppendLine('---------------------------------------')
      Write-Host ''
      Write-Host '--- Cloud Proxy Guest Script Output ---' -ForegroundColor DarkGray
      Write-Host (($cpRun.ScriptOutput | Out-String).Trim())
      Write-Host ''
      Write-Host '---------------------------------------' -ForegroundColor DarkGray
      foreach ($line in (($cpRun.ScriptOutput | Out-String) -split "`r?`n")) {
        if ($line -match '^RESULT\s+(PASS|WARN|FAIL|INFO)\s+') { $statuses.Add($matches[1]) }
      }

      [void]$fullOutput.AppendLine('')
      Add-ResultSummaryFromTargetOutput -Builder $fullOutput -VmName $vmName -OutputText (($targetRun.ScriptOutput | Out-String).Trim()) -DetectedTargetOs $osInfo.DetectedTargetOs -GuestFullName $osInfo.GuestFullName -CloudProxyFqdn $resolvedCloudProxyFqdn -BootstrapPath $testScripts.BootstrapPath -OwningHost $owningHost -ExitCode $targetRun.ExitCode
      Add-ResultSummaryFromCloudProxyOutput -Builder $fullOutput -CloudProxyVmName $CloudProxyVmName -OutputText (($cpRun.ScriptOutput | Out-String).Trim()) -vCenterHost $vCenterServer -EsxiHost $owningHost

      if ((($targetRun.ScriptOutput | Out-String) -match 'RESULT WARN TARGET>CLOUDPROXY:BOOTSTRAP_INSECURE')) {
        [void]$fullOutput.AppendLine('')
        [void]$fullOutput.AppendLine('Suggestions:')
        [void]$fullOutput.AppendLine('Telegraf VM target : ' + $vmName)
        [void]$fullOutput.AppendLine('Test: Telegraf VM target > Cloud Proxy bootstrap download (PASS+INSECURE)')
        [void]$fullOutput.AppendLine('The Linux guest could download the bootstrap URL only when HTTPS certificate validation was bypassed. Trust the Cloud Proxy certificate on the guest or replace it with a certificate chain the guest already trusts.')
      }

      $overall = Get-OverallStatus -Statuses $statuses
      $vmResult.Status = $overall
      W ("Completed {0} with status {1}" -f $vmName,$overall) $overall
    }
    finally {
      if ($vi) {
        Disconnect-VIServer -Server $vi -Confirm:$false | Out-Null
        [void]$fullOutput.AppendLine('[INFO] Disconnected from vCenter')
      }
    }
  }
  catch {
    $vmResult.Status = 'FAIL'
    $message = $_.Exception.Message
    W "Failed: $message" 'FAIL'
    [void]$fullOutput.AppendLine("[FAIL] $message")
    if (-not $ContinueOnError) {
      # Continue processing all rows by design.
    }
  }

  $vmResult.Output = $fullOutput.ToString().Trim()
  $summary.Add([pscustomobject]$vmResult)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $OutDir "GuestOpsFleetSummary-$stamp.json"
$csvPath = Join-Path $OutDir "GuestOpsFleetSummary-$stamp.csv"
$summary | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding utf8
$summary | Export-Csv -NoTypeInformation -LiteralPath $csvPath -Encoding utf8

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host 'Fleet Validation Summary' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor DarkCyan
foreach ($item in $summary) {
  $detail = "Requested=$($item.RequestedTargetOs); Detected=$($item.DetectedTargetOs); User=$($item.GuestUser); CredSource=$($item.CredentialSource)"
  Write-Host ("{0,-20} {1,-5} {2}" -f $item.VMName,$item.Status,$detail) -ForegroundColor @{ PASS='Green'; WARN='Yellow'; FAIL='Red'; INFO='Cyan' }[$item.Status]
}
Write-Host ''
Write-Host "Guest Ops fleet summary written to: $csvPath and $jsonPath" -ForegroundColor Green
