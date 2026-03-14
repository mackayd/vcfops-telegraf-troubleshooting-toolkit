#requires -Version 7.0
[CmdletBinding()]
param(
  [Alias('Help')][switch]$h,
  [switch]$Full,
  [switch]$Examples,
  [string]$vCenterServer,
  [string]$VMName,
  [string]$vCenterUser,
  [securestring]$vCenterPassword,
  [securestring]$GuestPassword,
  [string]$GuestUser,
  [ValidateSet('Auto','Windows','Linux')][string]$TargetOs = 'Auto',
  [switch]$CreateTestFile,
  [switch]$UseSudo,
  [switch]$IncludeAgentStateChecks,
  [ValidateRange(500,30000)][int]$vCenterConnectTimeoutMs = 5000,
  [string]$CloudProxyVmName,
  [string]$CloudProxyTargetHost,
  [string]$CloudProxyBootstrapPath,
  [string]$CloudProxyGuestUser,
  [securestring]$CloudProxyGuestPassword,
  [switch]$PromptForCloudProxyGuestPassword,
  [ValidateRange(1,30)][int]$CloudProxyPortTestTimeoutSec = 5,
  [switch]$UseEsxiManagementIpForCloudProxyTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-ShortHelp {
@'
NAME
    Test-VCenterGuestOpsForTelegraf.ps1

SYNOPSIS
    Runs a single-VM Telegraf Guest Operations validation against a Windows or Linux target.

USAGE
    .\Test-VCenterGuestOpsForTelegraf.ps1 -vCenterServer <server> -VMName <vm> -GuestUser <user> -GuestPassword <securestring> [options]
    .\Test-VCenterGuestOpsForTelegraf.ps1 -h
    .\Test-VCenterGuestOpsForTelegraf.ps1 -Full
    .\Test-VCenterGuestOpsForTelegraf.ps1 -Examples

DESCRIPTION
    This script connects to vCenter, detects whether the target VM is Windows or Linux, then uses VMware Guest Operations
    to run connectivity and bootstrap checks from inside the guest. It can also validate Cloud Proxy guest-side connectivity.

HELP MODES
    -h / -Help    Show concise usage
    -Full         Show detailed help and workflow guidance
    -Examples     Show example commands

NOTES
    Use a SecureString for -GuestPassword.
    If you also want Cloud Proxy guest-side checks, provide -CloudProxyVmName and Cloud Proxy guest credentials.

'@ | Write-Host
}

function Show-FullHelp {
@'
NAME
    Test-VCenterGuestOpsForTelegraf.ps1

PURPOSE
    Runs a detailed Guest Operations validation for one VM to confirm the prerequisite paths commonly used during
    product-managed Telegraf deployment from VCF Operations / Aria Operations.

HOW IT WORKS
    1. Tests workstation connectivity to vCenter on TCP 443.
    2. Connects to vCenter.
    3. Locates the target VM and reads VMware Tools guest metadata.
    4. Detects Windows or Linux automatically when -TargetOs Auto is used.
    5. Uses Invoke-VMScript to run the correct guest-side test logic:
       - PowerShell for Windows
       - Bash for Linux
    6. Optionally tests Cloud Proxy guest-side connectivity if Cloud Proxy guest credentials are supplied.
    7. Prints a grouped validation summary with PASS / WARN / FAIL results and guidance.

CLOUD PROXY HOSTNAME BEHAVIOUR
    -CloudProxyTargetHost takes priority if supplied.
    Otherwise the script uses the value supplied to -CloudProxyVmName.
    If you want a specific FQDN, pass it with -CloudProxyTargetHost.

CREDENTIALS
    This single-VM script accepts guest credentials directly as parameters:
        -GuestUser
        -GuestPassword

    For repeated use, you can use Save-VcfOpsTelegrafCredential.ps1 to generate DPAPI-protected credential files for the
    fleet runner script. That helper is mainly intended for fleet execution scenarios where you want to avoid storing
    guest passwords in plaintext CSV files.

    If you are comfortable with the security tradeoff, the fleet runner also supports plaintext GuestUser / GuestPassword
    values in CSV. For this single-VM script, credentials are passed directly at runtime rather than being read from CSV.

CLOUD PROXY GUEST CHECKS
    To perform Cloud Proxy guest-side checks, provide:
        -CloudProxyVmName
        -CloudProxyGuestUser
        -CloudProxyGuestPassword

    If you omit Cloud Proxy guest credentials, the script can still validate the target VM side of the path, but will
    skip Cloud Proxy guest execution checks.

IMPORTANT PARAMETERS
    -vCenterServer
        vCenter to connect to, for example vCenter-01.devops.local

    -VMName
        Target VM to test

    -GuestUser / -GuestPassword
        Guest OS credential used by Invoke-VMScript on the target VM

    -TargetOs
        Auto, Windows, or Linux. Auto uses VMware Tools guest metadata.

    -CloudProxyVmName
        Cloud Proxy VM inventory name

    -CloudProxyTargetHost
        Explicit Cloud Proxy hostname or FQDN to use for target-side checks. Use this if the DNS target should not be
        assumed from the Cloud Proxy VM name.

    -CloudProxyBootstrapPath
        Override bootstrap path if required.
        Defaults:
            Windows -> /downloads/salt/telegraf-utils.ps1
            Linux   -> /downloads/salt/telegraf-utils.sh

    -UseSudo
        Linux only. Use when later guest-side checks require sudo.

    -CreateTestFile
        Enables creation of a simple test file in the guest where supported by the script logic.

    -IncludeAgentStateChecks
        Includes additional installed-state checks where supported.

SAVE-VCFOPSTELEGRAFCREDENTIAL.PS1
    If you later move to the fleet runner, create credential files like this:

        .\Save-VcfOpsTelegrafCredential.ps1 -Path C:\Secure\Windows-Guest.xml
        .\Save-VcfOpsTelegrafCredential.ps1 -Path C:\Secure\Linux-Guest.xml
        .\Save-VcfOpsTelegrafCredential.ps1 -Path C:\Secure\CloudProxy-01.xml

    Those credential files can then be referenced by the fleet runner for default Windows/Linux credentials or by using
    AltCredFile for a specific VM row.

RELATION TO ALTCREDFILE
    This script does not read CSV input and therefore does not use AltCredFile directly.
    AltCredFile is part of the fleet runner workflow:
        Invoke-VcfOpsFleetGuestOps.ps1

    In that workflow, AltCredFile lets a particular VM use a different credential file than the default Windows or Linux
    credential file configured for the run.

OUTPUT
    The script writes:
        - live status lines
        - guest script output
        - Cloud Proxy guest output when applicable
        - grouped PASS / WARN / FAIL summary
        - related KB links for warning/failure conditions

'@ | Write-Host
}

function Show-ExamplesHelp {
@'
EXAMPLES

1) WINDOWS TARGET WITH DIRECT GUEST CREDENTIALS
   $vcPw    = ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force
   $guestPw = ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force
   $cpPw    = ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force

   .\Test-VCenterGuestOpsForTelegraf.ps1 `
     -vCenterServer 'vCenter-01.devops.local' `
     -VMName 'APP-WIN-01' `
     -vCenterUser 'administrator@vsphere.local' `
     -vCenterPassword $vcPw `
     -GuestUser 'devops\DomainAdmin' `
     -GuestPassword $guestPw `
     -CloudProxyVmName 'CloudProxy-01' `
     -CloudProxyTargetHost 'CloudProxy-01.devops.local' `
     -CloudProxyGuestUser 'root' `
     -CloudProxyGuestPassword $cpPw

2) LINUX TARGET WITH DIRECT GUEST CREDENTIALS
   $vcPw    = ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force
   $guestPw = ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force
   $cpPw    = ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force

   .\Test-VCenterGuestOpsForTelegraf.ps1 `
     -vCenterServer 'vCenter-01.devops.local' `
     -VMName 'APP-LIN-01' `
     -vCenterUser 'administrator@vsphere.local' `
     -vCenterPassword $vcPw `
     -GuestUser 'tester' `
     -GuestPassword $guestPw `
     -TargetOs Auto `
     -CloudProxyVmName 'CloudProxy-01' `
     -CloudProxyTargetHost 'CloudProxy-01.devops.local' `
     -CloudProxyGuestUser 'root' `
     -CloudProxyGuestPassword $cpPw `
     -UseSudo

3) OVERRIDE CLOUD PROXY TARGET HOST
   .\Test-VCenterGuestOpsForTelegraf.ps1 `
     -vCenterServer 'vCenter-01.devops.local' `
     -VMName 'APP-LIN-02' `
     -GuestUser 'tester' `
     -GuestPassword (ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force) `
     -CloudProxyVmName 'CloudProxy-01' `
     -CloudProxyTargetHost 'cloudproxy-alt.devops.local'

4) VIEW HELP
   .\Test-VCenterGuestOpsForTelegraf.ps1 -h
   .\Test-VCenterGuestOpsForTelegraf.ps1 -Full
   .\Test-VCenterGuestOpsForTelegraf.ps1 -Examples

5) FLEET RUNNER ALTCREDFILE EXAMPLE
   AltCredFile is not used by this single-VM script. In the fleet runner CSV you would use a row like:

   VMName,GuestUser,GuestPassword,TargetOs,UseSudo,AltCredFile
   APP-LIN-03,,,,True,C:\Secure\Linux-Alt.xml

   The fleet runner would then use Linux-Alt.xml for that VM instead of default Windows/Linux credentials or plaintext CSV.
'@ | Write-Host
}

if ($h -or $Full -or $Examples) {
  if ($Full) { Show-FullHelp; return }
  if ($Examples) { Show-ExamplesHelp; return }
  Show-ShortHelp
  return
}

$missing = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($vCenterServer)) { $missing.Add('vCenterServer') | Out-Null }
if ([string]::IsNullOrWhiteSpace($VMName)) { $missing.Add('VMName') | Out-Null }
if ([string]::IsNullOrWhiteSpace($GuestUser)) { $missing.Add('GuestUser') | Out-Null }
if ($null -eq $GuestPassword) { $missing.Add('GuestPassword') | Out-Null }
if ($missing.Count -gt 0) {
  throw ("Missing required parameter(s): {0}. Run with -h, -Full, or -Examples for usage." -f ($missing -join ', '))
}



$script:KbMap = @{
  CloudProxyPorts = @(
    'Broadcom KB 374807 - Telegraf agent install fails / required endpoint-to-Cloud Proxy ports: https://knowledge.broadcom.com/external/article/374807/telegraf-agent-install-fails-with-error.html'
  )
  WindowsExecutionPolicy = @(
    'Broadcom KB 428286 - Windows Telegraf install fails downloading config-utils.bat when PowerShell execution policy is Restricted: https://knowledge.broadcom.com/external/article/428286/telegraf-agent-installation-fails-on-win.html'
  )
  LinuxPlatformSupport = @(
    'Validate the Linux distro/version against the VCF Operations supported platforms matrix before retrying agent deployment.'
  )
  LinuxGuestExecution = @(
    'Confirm the Linux guest account is allowed for VMware Guest Operations and can run the required shell tooling.',
    'If later install/runtime checks require elevation, confirm sudo is available and configured for the account used by the toolkit.'
  )
  LinuxInstallGuidance = @(
    'Review the Linux install user/runtime user prerequisites for Aria Operations Telegraf deployments before retrying the product-managed install.'
  )
  CloudProxyCertificates = @(
    'Broadcom KB 405325 - Loading updated certs to Aria Operations / Cloud Proxy certificate guidance: https://knowledge.broadcom.com/external/article/405325/loading-updated-certs-to-aria-operations.html',
    'Broadcom KB 320343 - Configure a Certificate For Use With VCF Operations: https://knowledge.broadcom.com/external/article/320343/configure-a-certificate-for-use-with-vmw.html'
  )
  CloudProxySupportBundle = @(
    'Broadcom KB 342832 - Collect diagnostic information / generate Cloud Proxy support bundle: https://knowledge.broadcom.com/external/article/342832/collecting-diagnostic-information-from-v.html'
  )
}

function Resolve-CloudProxyTargetHost {
  param(
    [string]$ExplicitTargetHost,
    [string]$CloudProxyVm,
    [string]$vCenterHost
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitTargetHost)) {
    return $ExplicitTargetHost
  }

  if ([string]::IsNullOrWhiteSpace($CloudProxyVm)) {
    return $null
  }

  if ($CloudProxyVm.Contains('.')) {
    return $CloudProxyVm
  }

  $domainSuffix = $null
  if (-not [string]::IsNullOrWhiteSpace($vCenterHost) -and $vCenterHost.Contains('.')) {
    $parts = $vCenterHost.Split('.', 2)
    if ($parts.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
      $domainSuffix = $parts[1]
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($domainSuffix)) {
    return '{0}.{1}' -f $CloudProxyVm, $domainSuffix
  }

  return $CloudProxyVm
}

function Resolve-CloudProxyBootstrapPath {
  param(
    [ValidateSet('Windows','Linux')][string]$Os,
    [string]$ExplicitBootstrapPath
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitBootstrapPath)) {
    return $ExplicitBootstrapPath
  }

  switch ($Os) {
    'Linux' { return '/downloads/salt/telegraf-utils.sh' }
    'Windows' { return '/downloads/salt/telegraf-utils.ps1' }
    default { return $null }
  }
}

$effectiveCloudProxyTargetHost = Resolve-CloudProxyTargetHost -ExplicitTargetHost $CloudProxyTargetHost -CloudProxyVm $CloudProxyVmName -vCenterHost $vCenterServer
$requestedTargetOs = $TargetOs
$effectiveTargetOs = if ($TargetOs -eq 'Auto') { $null } else { $TargetOs }
$script:DeviceResults = @{
  TargetVm   = [ordered]@{ Label = 'Telegraf VM target'; Name = $VMName; Results = New-Object System.Collections.Generic.List[object] }
  CloudProxy = [ordered]@{ Label = 'Cloud Proxy'; Name = $CloudProxyVmName; Results = New-Object System.Collections.Generic.List[object] }
}

function W {
  param([string]$Message, [ValidateSet('INFO','PASS','WARN','FAIL')][string]$Level = 'INFO')
  $color = @{ INFO = 'Cyan'; PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Level]
  Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Add-DeviceResult {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('TargetVm','CloudProxy')][string]$Device,
    [Parameter(Mandatory = $true)][ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
    [Parameter(Mandatory = $true)][string]$Test,
    [string]$Suggestion = '',
    [string[]]$KbLinks = @()
  )
  $script:DeviceResults[$Device].Results.Add([pscustomobject]@{
    Status     = $Status
    Test       = $Test
    Suggestion = $Suggestion
    KbLinks    = @($KbLinks)
  }) | Out-Null
}

function Get-ShortResultMessage {
  param([string]$Suggestion)

  if ([string]::IsNullOrWhiteSpace($Suggestion)) {
    return $null
  }

  $normalized = ([regex]::Replace($Suggestion.Trim(), '\s+', ' ')).Trim()
  if ($normalized.Length -le 120) {
    return $normalized
  }

  $sentences = [regex]::Split($normalized, '(?<=[.!?])\s+')
  if ($sentences.Count -gt 0 -and $sentences[0].Length -le 120) {
    return $sentences[0]
  }

  return ($normalized.Substring(0, 117) + '...')
}

function Show-GroupedSummary {
  param([hashtable]$Summary)
  $deferredSuggestions = New-Object System.Collections.Generic.List[object]
  Write-Host ''
  Write-Host '==================== Validation Summary ====================' -ForegroundColor Cyan

  foreach ($key in @('TargetVm','CloudProxy')) {
    $section = $Summary[$key]
    if ($null -eq $section) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$section.Name) -and $section.Results.Count -eq 0) { continue }

    Write-Host ''
    Write-Host ("{0} : {1}" -f $section.Label, $section.Name) -ForegroundColor Cyan
    foreach ($item in $section.Results) {
      $color = switch ($item.Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Cyan' }
      }
      Write-Host ("{0} : {1}" -f $item.Status, $item.Test) -ForegroundColor $color
      if ($item.Status -in @('WARN','FAIL') -and -not [string]::IsNullOrWhiteSpace($item.Suggestion)) {
        $shortMessage = Get-ShortResultMessage -Suggestion $item.Suggestion
        Write-Host ''
        Write-Host ("Message: {0}" -f $shortMessage) -ForegroundColor Yellow
        $deferredSuggestions.Add([pscustomobject]@{
          DeviceLabel = $section.Label
          DeviceName  = $section.Name
          Test        = $item.Test
          Suggestion  = $item.Suggestion
          KbLinks     = @($item.KbLinks)
        }) | Out-Null
      }
    }
  }

  if ($deferredSuggestions.Count -gt 0) {
    Write-Host ''
    Write-Host 'Suggestions:' -ForegroundColor Yellow
    foreach ($entry in $deferredSuggestions) {
      Write-Host ''
      Write-Host ("{0} : {1}" -f $entry.DeviceLabel, $entry.DeviceName) -ForegroundColor Yellow
      Write-Host ("Test: {0}" -f $entry.Test) -ForegroundColor Yellow
      Write-Host $entry.Suggestion -ForegroundColor Yellow
      if ($entry.KbLinks.Count -gt 0) {
        Write-Host 'Related articles:' -ForegroundColor Yellow
        foreach ($kb in $entry.KbLinks) {
          Write-Host ("- {0}" -f $kb) -ForegroundColor Yellow
        }
      }
    }
  }

  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Cyan
}

function ConvertTo-PlainText {
  param([Parameter(Mandatory = $true)][securestring]$SecureValue)
  $bstr = [IntPtr]::Zero
  try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
}

function Test-TcpPortQuick {
  param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$TimeoutMs
  )
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $iar = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      return [pscustomobject]@{ Success = $false; Error = "Timed out after ${TimeoutMs}ms" }
    }
    $null = $client.EndConnect($iar)
    return [pscustomobject]@{ Success = $true; Error = $null }
  }
  catch {
    return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message }
  }
  finally {
    $client.Dispose()
  }
}

function Get-TargetGuestScript {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('Windows','Linux')][string]$Os,
    [Parameter(Mandatory = $true)][string]$vCenterServerName,
    [Parameter(Mandatory = $true)][string]$EsxiTarget,
    [string]$CloudProxyTarget,
    [string]$CloudProxyBootstrapPath,
    [switch]$CreateMarkerFile,
    [switch]$RequireSudo,
    [switch]$IncludeAgentStateChecks
  )

  if ($Os -eq 'Windows') {
    $scriptText = @"
`$ErrorActionPreference='Stop'
if(-not (Test-Path 'C:\Temp')){ New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null }
whoami
hostname
(Get-Date).ToString('s')

`$vcResult = Test-NetConnection -ComputerName '$vCenterServerName' -Port 443 -InformationLevel Quiet
if (`$vcResult) { Write-Output 'RESULT PASS TARGET>VCENTER:443' } else { Write-Output 'RESULT FAIL TARGET>VCENTER:443' }

`$esxiResult = Test-NetConnection -ComputerName '$EsxiTarget' -Port 443 -InformationLevel Quiet
if (`$esxiResult) { Write-Output 'RESULT PASS TARGET>ESXI:443' } else { Write-Output 'RESULT FAIL TARGET>ESXI:443' }
"@
    if (-not [string]::IsNullOrWhiteSpace($CloudProxyTarget)) {
      $scriptText += @"
`$cpResult = Test-NetConnection -ComputerName '$CloudProxyTarget' -Port 443 -InformationLevel Quiet
if (`$cpResult) { Write-Output 'RESULT PASS TARGET>CLOUDPROXY:443' } else { Write-Output 'RESULT FAIL TARGET>CLOUDPROXY:443' }
"@
    }
    if ($CreateMarkerFile) {
      $scriptText += "`n'VCF Ops GuestOps test' | Out-File -FilePath 'C:\Temp\vcfops_guestops_test.txt' -Encoding utf8 -Force`n'Created test file'`n"
    }
    return [pscustomobject]@{ ScriptType = 'Powershell'; ScriptText = $scriptText }
  }

  $cloudProxyBlock = if ([string]::IsNullOrWhiteSpace($CloudProxyTarget)) { '' } else { "test_tcp 'TARGET>CLOUDPROXY:443' '$CloudProxyTarget' 443" }
  $bootstrapUrl = if ([string]::IsNullOrWhiteSpace($CloudProxyTarget) -or [string]::IsNullOrWhiteSpace($CloudProxyBootstrapPath)) {
    $null
  } else {
    'https://{0}{1}' -f $CloudProxyTarget, $CloudProxyBootstrapPath
  }
  $bootstrapBlock = if ([string]::IsNullOrWhiteSpace($bootstrapUrl)) { '' } else { "test_bootstrap '$bootstrapUrl'" }
  $agentStateBlock = if ($IncludeAgentStateChecks) {
@"
if command -v systemctl >/dev/null 2>&1; then
  svc_state=`$( `${SUDO}systemctl is-active telegraf 2>/dev/null || true )
  echo "RESULT INFO TARGET>SERVICESTATE:`$svc_state"
  if [ "`$svc_state" = 'active' ]; then
    echo 'RESULT PASS TARGET>SERVICE:telegraf'
  else
    echo 'RESULT FAIL TARGET>SERVICE:telegraf'
  fi
else
  echo 'RESULT WARN TARGET>SERVICE:systemctl_missing'
fi

if pgrep -a telegraf >/dev/null 2>&1; then
  echo 'RESULT PASS TARGET>PROCESS:telegraf'
else
  echo 'RESULT FAIL TARGET>PROCESS:telegraf'
fi

if [ -f /etc/telegraf/telegraf.conf ]; then
  echo 'RESULT PASS TARGET>PATH:/etc/telegraf/telegraf.conf'
else
  echo 'RESULT FAIL TARGET>PATH:/etc/telegraf/telegraf.conf'
fi

if command -v rpm >/dev/null 2>&1; then
  if `${SUDO}rpm -q telegraf >/dev/null 2>&1; then
    echo 'RESULT PASS TARGET>PACKAGE:telegraf:rpm'
  else
    echo 'RESULT FAIL TARGET>PACKAGE:telegraf:rpm'
  fi
elif command -v dpkg >/dev/null 2>&1; then
  if `${SUDO}dpkg -s telegraf >/dev/null 2>&1; then
    echo 'RESULT PASS TARGET>PACKAGE:telegraf:dpkg'
  else
    echo 'RESULT FAIL TARGET>PACKAGE:telegraf:dpkg'
  fi
else
  echo 'RESULT WARN TARGET>PACKAGE:manager_unknown'
fi
"@
  } else {
    "echo 'RESULT INFO TARGET>AGENT_STATE:SKIPPED'"
  }
  $createFileBlock = if ($CreateMarkerFile) {
@"
printf 'VCF Ops GuestOps test\n' > /tmp/vcfops_guestops_test.txt && echo 'RESULT PASS TARGET>TESTFILE:/tmp/vcfops_guestops_test.txt' || echo 'RESULT FAIL TARGET>TESTFILE:/tmp/vcfops_guestops_test.txt'
"@
  } else { '' }
  $sudoFlag = if ($RequireSudo) { '1' } else { '0' }

  $linuxScript = @'
set -u
echo "RESULT INFO TARGETOS:LINUX"
whoami
hostname
date -Iseconds 2>/dev/null || date
if [ -r /etc/os-release ]; then . /etc/os-release; echo "RESULT INFO TARGETOS:$PRETTY_NAME"; fi
test_tcp(){ label="$1"; host="$2"; port="$3"; if command -v nc >/dev/null 2>&1; then nc -z -w 5 "$host" "$port" >/dev/null 2>&1; rc=$?; elif command -v timeout >/dev/null 2>&1; then timeout 5 bash -lc "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1; rc=$?; else echo 'RESULT WARN TARGET>TOOLING:CONNECTIVITY_HELPER_MISSING'; rc=1; fi; if [ $rc -eq 0 ]; then echo "RESULT PASS $label"; else echo "RESULT FAIL $label"; fi; }
test_bootstrap(){ url="$1"; tmp_file="/tmp/vcfops-telegraf-bootstrap.$$"; tool='none'; rc=1; insecure_rc=''; if command -v curl >/dev/null 2>&1; then tool='curl'; curl -fsS --max-time 20 "$url" -o "$tmp_file" >/dev/null 2>&1; rc=$?; if [ $rc -ne 0 ]; then curl -kfsS --max-time 20 "$url" -o "$tmp_file" >/dev/null 2>&1; insecure_rc=$?; fi; elif command -v wget >/dev/null 2>&1; then tool='wget'; wget -q -T 20 -O "$tmp_file" "$url" >/dev/null 2>&1; rc=$?; if [ $rc -ne 0 ]; then wget --no-check-certificate -q -T 20 -O "$tmp_file" "$url" >/dev/null 2>&1; insecure_rc=$?; fi; else echo 'RESULT WARN TARGET>BOOTSTRAP:DOWNLOAD_TOOL_MISSING'; fi; echo "RESULT INFO TARGET>BOOTSTRAP:TOOL:$tool"; echo "RESULT INFO TARGET>BOOTSTRAP:EXITCODE:$rc"; if [ -n "$insecure_rc" ]; then echo "RESULT INFO TARGET>BOOTSTRAP:INSECURE_EXITCODE:$insecure_rc"; if [ "$insecure_rc" = '0' ]; then echo 'RESULT WARN TARGET>BOOTSTRAP:TLS_OR_CERT'; fi; fi; if [ -f "$tmp_file" ]; then rm -f "$tmp_file"; fi; if [ $rc -eq 0 ]; then echo 'RESULT PASS TARGET>CLOUDPROXY:BOOTSTRAP'; elif [ "$insecure_rc" = '0' ]; then echo 'RESULT WARN TARGET>CLOUDPROXY:BOOTSTRAP_INSECURE'; else echo 'RESULT FAIL TARGET>CLOUDPROXY:BOOTSTRAP'; fi; }
SUDO=''
if [ '__SUDOFLAG__' = '1' ]; then if command -v sudo >/dev/null 2>&1; then if sudo -n true >/dev/null 2>&1; then echo 'RESULT PASS TARGET>SUDO:AVAILABLE'; SUDO='sudo -n '; else echo 'RESULT WARN TARGET>SUDO:UNAVAILABLE'; fi; else echo 'RESULT WARN TARGET>SUDO:MISSING'; fi; fi
test_tcp 'TARGET>VCENTER:443' '__VCENTER__' 443
test_tcp 'TARGET>ESXI:443' '__ESXI__' 443
__CLOUDPROXY_BLOCK__
__BOOTSTRAP_BLOCK__
__CREATEFILE_BLOCK__
__AGENT_STATE_BLOCK__
'@
  $linuxScript = $linuxScript.Replace('__VCENTER__', $vCenterServerName)
  $linuxScript = $linuxScript.Replace('__ESXI__', $EsxiTarget)
  $linuxScript = $linuxScript.Replace('__SUDOFLAG__', $sudoFlag)
  $linuxScript = $linuxScript.Replace('__CLOUDPROXY_BLOCK__', $cloudProxyBlock)
  $linuxScript = $linuxScript.Replace('__BOOTSTRAP_BLOCK__', $bootstrapBlock)
  $linuxScript = $linuxScript.Replace('__AGENT_STATE_BLOCK__', $agentStateBlock)
  $linuxScript = $linuxScript.Replace('__CREATEFILE_BLOCK__', $createFileBlock)

  [pscustomobject]@{ ScriptType = 'Bash'; ScriptText = $linuxScript }
}

function Add-ConnectivityResult {
  param(
    [string]$Output,
    [string]$Pattern,
    [string]$PassTest,
    [string]$FailTest,
    [string]$Suggestion,
    [string[]]$KbLinks = @()
  )
  if ($Output -match $Pattern.Replace('STATUS','PASS')) {
    Add-DeviceResult -Device TargetVm -Status PASS -Test $PassTest
  } elseif ($Output -match $Pattern.Replace('STATUS','FAIL')) {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test $FailTest -Suggestion $Suggestion -KbLinks $KbLinks
  } else {
    Add-DeviceResult -Device TargetVm -Status WARN -Test $FailTest -Suggestion 'The guest connectivity test did not return a valid PASS/FAIL result. Review the guest script output.'
  }
}

if ($CloudProxyVmName) {
  $script:DeviceResults['CloudProxy'].Name = $CloudProxyVmName
  if ([string]::IsNullOrWhiteSpace($CloudProxyGuestUser)) {
    throw 'CloudProxyGuestUser is required when CloudProxyVmName is provided.'
  }
  if (-not $CloudProxyGuestPassword -and -not $PromptForCloudProxyGuestPassword) {
    throw 'Provide CloudProxyGuestPassword or use PromptForCloudProxyGuestPassword when CloudProxyVmName is provided.'
  }
  if ($PromptForCloudProxyGuestPassword) {
    $CloudProxyGuestPassword = Read-Host "Enter Cloud Proxy guest password for $CloudProxyGuestUser" -AsSecureString
  }
} elseif (-not [string]::IsNullOrWhiteSpace($effectiveCloudProxyTargetHost)) {
  $script:DeviceResults['CloudProxy'].Name = $effectiveCloudProxyTargetHost
}

$targetShouldTestCloudProxy = -not [string]::IsNullOrWhiteSpace($effectiveCloudProxyTargetHost)

if (-not (Get-Module -ListAvailable VCF.PowerCLI) -and -not (Get-Module -ListAvailable VMware.VimAutomation.Core) -and -not (Get-Module -ListAvailable VMware.PowerCLI)) {
  throw 'Neither VCF.PowerCLI nor VMware PowerCLI Core modules are installed. Install-Module VCF.PowerCLI or Install-Module VMware.PowerCLI'
}
if (Get-Module -ListAvailable VCF.PowerCLI) {
  Import-Module VCF.PowerCLI -ErrorAction Stop | Out-Null
} elseif (Get-Module -ListAvailable VMware.VimAutomation.Core) {
  Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null
} else {
  Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null
}
try { Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -ParticipateInCEIP:$false -Confirm:$false | Out-Null } catch {}

$targetGuestPasswordPlain = $null
$cloudProxyGuestPasswordPlain = $null
$vCenterPasswordPlain = $null
$vCenterCredential = $null
$vi = $null
try {
  if (-not [string]::IsNullOrWhiteSpace($vCenterUser)) {
    if (-not $vCenterPassword) { throw 'vCenterPassword is required when vCenterUser is provided.' }
    $vCenterPasswordPlain = ConvertTo-PlainText -SecureValue $vCenterPassword
    $vCenterCredential = [pscredential]::new($vCenterUser, $vCenterPassword)
  }
  $targetGuestPasswordPlain = ConvertTo-PlainText -SecureValue $GuestPassword

  W "Testing workstation connectivity to vCenter $vCenterServer on TCP 443 ..."
  $vCenterPortCheck = Test-TcpPortQuick -HostName $vCenterServer -Port 443 -TimeoutMs $vCenterConnectTimeoutMs
  if (-not $vCenterPortCheck.Success) {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Admin workstation > vCenter on 443' -Suggestion "The admin workstation cannot reach $vCenterServer on TCP 443 ($($vCenterPortCheck.Error)). Confirm routing, DNS, firewall policy, VPN/jump-host placement, or rerun from a workstation with vCenter management access."
    throw "Admin workstation cannot reach $vCenterServer on TCP 443: $($vCenterPortCheck.Error)"
  }
  Add-DeviceResult -Device TargetVm -Status PASS -Test 'Admin workstation > vCenter on 443'

  W "Connecting to vCenter $vCenterServer ..."
  if ($vCenterCredential) {
    $vi = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential -Force -ErrorAction Stop
  } else {
    $vi = Connect-VIServer -Server $vCenterServer -ErrorAction Stop
  }
  W "Connected to $($vi.Name) as $($vi.User)" 'PASS'

  $vm = Get-VM -Name $VMName -ErrorAction Stop
  W "VM found: $($vm.Name) (PowerState=$($vm.PowerState))"
  if ($targetShouldTestCloudProxy) {
    Add-DeviceResult -Device TargetVm -Status INFO -Test ("Cloud Proxy target host : {0}" -f $effectiveCloudProxyTargetHost)
  }

  if ($vm.PowerState -ne 'PoweredOn') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'VM power state' -Suggestion 'Power on the target VM, then rerun the validation.'
    throw 'Target VM is not powered on.'
  }

  $view = Get-View -Id $vm.Id -ErrorAction Stop
  $guestFamily = [string]$view.Guest.GuestFamily
  $guestFullName = [string]$view.Guest.GuestFullName
  if (-not $effectiveTargetOs) {
    if ($guestFamily -match 'linux' -or $guestFullName -match 'linux|ubuntu|rhel|centos|rocky|suse|photon|oracle') {
      $effectiveTargetOs = 'Linux'
    } else {
      $effectiveTargetOs = 'Windows'
    }
  }
  $effectiveCloudProxyBootstrapPath = Resolve-CloudProxyBootstrapPath -Os $effectiveTargetOs -ExplicitBootstrapPath $CloudProxyBootstrapPath
  Add-DeviceResult -Device TargetVm -Status INFO -Test ("vCenter guest OS : {0}" -f ($(if ([string]::IsNullOrWhiteSpace($guestFullName)) { 'Unknown' } else { $guestFullName })))
  Add-DeviceResult -Device TargetVm -Status INFO -Test ("Target OS mode selected : {0}" -f $effectiveTargetOs)
  if ($targetShouldTestCloudProxy) {
    Add-DeviceResult -Device TargetVm -Status INFO -Test ("Cloud Proxy bootstrap path : {0}" -f $effectiveCloudProxyBootstrapPath)
  }

  if ($requestedTargetOs -eq 'Linux' -and $guestFamily -notmatch 'linux') {
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Target OS alignment' -Suggestion "The requested TargetOs is Linux, but vCenter reports guest family '$guestFamily'. Confirm the VM selection and VMware Tools guest OS reporting." -KbLinks $script:KbMap.LinuxPlatformSupport
  }
  if ($requestedTargetOs -eq 'Windows' -and $guestFamily -match 'linux') {
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Target OS alignment' -Suggestion "The requested TargetOs is Windows, but vCenter reports guest family '$guestFamily'. Rerun with -TargetOs Linux for Linux guests."
  }

  W "VMware Tools status: $($view.Guest.ToolsRunningStatus) / $($view.Guest.ToolsVersionStatus2)"
  if ($view.Guest.ToolsRunningStatus -notmatch 'guestToolsRunning') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'VMware Tools running' -Suggestion 'Start or repair VMware Tools / open-vm-tools on the target VM. Guest Operations depends on VMware Tools.'
    throw 'VMware Tools is not running on target VM.'
  }

  $esxiHost = $vm.VMHost
  W "Target VM is currently running on ESXi host: $($esxiHost.Name)" 'PASS'
  Add-DeviceResult -Device TargetVm -Status PASS -Test ("Owning ESXi host discovered : {0}" -f $esxiHost.Name)

  $esxiView = Get-View -Id $esxiHost.Id -ErrorAction Stop
  $esxiTestTarget = $esxiHost.Name
  if ($UseEsxiManagementIpForCloudProxyTest) {
    $candidateIp = $null
    try { $candidateIp = $esxiView.Summary.ManagementServerIp } catch {}
    if ([string]::IsNullOrWhiteSpace($candidateIp)) {
      try { $candidateIp = $esxiView.Config.Network.Vnic | Select-Object -First 1 -ExpandProperty Spec | Select-Object -ExpandProperty Ip -ErrorAction SilentlyContinue } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($candidateIp)) {
      $esxiTestTarget = $candidateIp
      W "Using ESXi management IP for tests: $esxiTestTarget"
    } else {
      Add-DeviceResult -Device TargetVm -Status WARN -Test 'ESXi test target selection' -Suggestion 'Could not determine ESXi management IP cleanly, so the script is using the ESXi host name. If DNS resolution is unreliable, rerun with a known-good ESXi management IP.'
    }
  }

  $guestScript = Get-TargetGuestScript -Os $effectiveTargetOs -vCenterServerName $vCenterServer -EsxiTarget $esxiTestTarget -CloudProxyTarget $effectiveCloudProxyTargetHost -CloudProxyBootstrapPath $effectiveCloudProxyBootstrapPath -CreateMarkerFile:$CreateTestFile -RequireSudo:$UseSudo -IncludeAgentStateChecks:$IncludeAgentStateChecks
  W "Invoking $($guestScript.ScriptType) guest script on target VM via Invoke-VMScript ..."
  $r = Invoke-VMScript -VM $vm -GuestUser $GuestUser -GuestPassword $targetGuestPasswordPlain -ScriptType $guestScript.ScriptType -ScriptText $guestScript.ScriptText -ErrorAction Stop
  W "Invoke-VMScript on target VM succeeded (ExitCode=$($r.ExitCode))" 'PASS'
  Write-Host "`n--- Target Guest Script Output ---`n$($r.ScriptOutput)`n----------------------------------" -ForegroundColor Gray

  if ($r.ExitCode -eq 0) {
    Add-DeviceResult -Device TargetVm -Status PASS -Test 'Guest execution'
  } else {
    $guestExecutionSuggestion = if ($effectiveTargetOs -eq 'Linux') {
      'Invoke-VMScript executed on the Linux guest but returned a non-zero exit code. Review shell output, guest account permissions, sudo expectations, and the availability of nc/timeout/systemctl.'
    } else {
      'Invoke-VMScript executed on the target VM but returned a non-zero exit code. Review guest script output, local privileges, and endpoint security controls.'
    }
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Guest execution' -Suggestion $guestExecutionSuggestion -KbLinks ($(if ($effectiveTargetOs -eq 'Linux') { $script:KbMap.LinuxGuestExecution } else { @() }))
  }

  $targetOutput = [string]$r.ScriptOutput

  Add-ConnectivityResult -Output $targetOutput -Pattern '(?m)^RESULT STATUS TARGET>VCENTER:443\s*$' -PassTest 'Telegraf VM target > vCenter on 443' -FailTest 'Telegraf VM target > vCenter on 443' -Suggestion 'Confirm TCP 443 is allowed from the target VM to vCenter. Verify routing, firewall policy, and DNS resolution.' -KbLinks $script:KbMap.CloudProxyPorts
  Add-ConnectivityResult -Output $targetOutput -Pattern '(?m)^RESULT STATUS TARGET>ESXI:443\s*$' -PassTest 'Telegraf VM target > ESXi on 443' -FailTest 'Telegraf VM target > ESXi on 443' -Suggestion 'Confirm TCP 443 is allowed from the target VM to the owning ESXi host. Verify routing, firewall policy, and ESXi hostname/IP resolution.' -KbLinks $script:KbMap.CloudProxyPorts

  if ($targetShouldTestCloudProxy) {
    Add-ConnectivityResult -Output $targetOutput -Pattern '(?m)^RESULT STATUS TARGET>CLOUDPROXY:443\s*$' -PassTest 'Telegraf VM target > Cloud Proxy on 443' -FailTest 'Telegraf VM target > Cloud Proxy on 443' -Suggestion 'Confirm TCP 443 is allowed from the target VM to the Cloud Proxy. Verify routing, DNS resolution, and firewall policy.' -KbLinks $script:KbMap.CloudProxyPorts
  } else {
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > Cloud Proxy on 443' -Suggestion 'CloudProxyTargetHost (or CloudProxyVmName) was not supplied, so the target VM to Cloud Proxy 443 test was skipped.'
  }

  if ($effectiveTargetOs -eq 'Linux') {
    $bootstrapTool = $null
    $bootstrapExitCode = $null
    $bootstrapInsecureExitCode = $null
    if ($targetOutput -match '(?m)^RESULT INFO TARGET>BOOTSTRAP:TOOL:(.+)$') {
      $bootstrapTool = $Matches[1].Trim()
      Add-DeviceResult -Device TargetVm -Status INFO -Test ("Linux bootstrap tool : {0}" -f $bootstrapTool)
    }
    if ($targetOutput -match '(?m)^RESULT INFO TARGET>BOOTSTRAP:EXITCODE:(.+)$') {
      $bootstrapExitCode = $Matches[1].Trim()
      Add-DeviceResult -Device TargetVm -Status INFO -Test ("Linux bootstrap exit code : {0}" -f $bootstrapExitCode)
    }
    if ($targetOutput -match '(?m)^RESULT INFO TARGET>BOOTSTRAP:INSECURE_EXITCODE:(.+)$') {
      $bootstrapInsecureExitCode = $Matches[1].Trim()
      Add-DeviceResult -Device TargetVm -Status INFO -Test ("Linux bootstrap insecure exit code : {0}" -f $bootstrapInsecureExitCode)
    }

    if ($targetShouldTestCloudProxy) {
      if ($targetOutput -match '(?m)^RESULT PASS TARGET>CLOUDPROXY:BOOTSTRAP\s*$') {
        Add-DeviceResult -Device TargetVm -Status PASS -Test 'Telegraf VM target > Cloud Proxy bootstrap download'
      } elseif ($targetOutput -match '(?m)^RESULT WARN TARGET>CLOUDPROXY:BOOTSTRAP_INSECURE\s*$') {
        Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > Cloud Proxy bootstrap download (PASS+INSECURE)' -Suggestion 'The Linux guest could download the bootstrap URL only when HTTPS certificate validation was bypassed. Trust the Cloud Proxy certificate on the guest or replace it with a certificate chain the guest already trusts.' -KbLinks $script:KbMap.CloudProxyCertificates
      } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>CLOUDPROXY:BOOTSTRAP\s*$') {
        $bootstrapSuggestion = "The Linux guest could not download the Cloud Proxy bootstrap URL. Confirm the Cloud Proxy FQDN, verify that $effectiveCloudProxyBootstrapPath is correct for this environment, and test HTTPS download access from the Linux guest."
        $bootstrapKbLinks = $script:KbMap.CloudProxyPorts + $script:KbMap.CloudProxyCertificates
        if ($targetOutput -match '(?m)^RESULT FAIL TARGET>CLOUDPROXY:443\s*$') {
          $bootstrapSuggestion = 'The Linux guest could not open TCP 443 to the Cloud Proxy, so the bootstrap download failed before HTTPS negotiation. Verify routing, DNS resolution, and firewall policy.'
          $bootstrapKbLinks = $script:KbMap.CloudProxyPorts
        } elseif ($targetOutput -match '(?m)^RESULT WARN TARGET>BOOTSTRAP:TLS_OR_CERT\s*$') {
          $bootstrapSuggestion = 'TCP 443 to the Cloud Proxy succeeded, but HTTPS download only worked when certificate validation was bypassed. Trust the Cloud Proxy certificate on the Linux guest or replace it with a certificate chain the guest already trusts.'
        } elseif ($bootstrapTool -eq 'curl' -and $bootstrapExitCode -eq '60') {
          $bootstrapSuggestion = 'curl reached the Cloud Proxy but rejected the HTTPS certificate chain. Trust the Cloud Proxy certificate on the Linux guest or replace it with a certificate chain the guest already trusts.'
        } elseif ($targetOutput -match '(?m)^RESULT PASS TARGET>CLOUDPROXY:443\s*$') {
          $bootstrapSuggestion = 'TCP 443 to the Cloud Proxy succeeded, but curl/wget could not fetch the bootstrap URL. Check the HTTPS response, certificate trust, proxy requirements, and whether the URL is reachable exactly as shown from the Linux guest.'
        }
        Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Telegraf VM target > Cloud Proxy bootstrap download' -Suggestion $bootstrapSuggestion -KbLinks $bootstrapKbLinks
      } elseif ($targetOutput -match '(?m)^RESULT WARN TARGET>BOOTSTRAP:DOWNLOAD_TOOL_MISSING\s*$') {
        Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > Cloud Proxy bootstrap download' -Suggestion 'The Linux guest does not have curl or wget available, so the bootstrap download test could not run. Install one of those tools or validate the telegraf-utils.sh URL manually from the guest.' -KbLinks $script:KbMap.LinuxGuestExecution
      } else {
        Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > Cloud Proxy bootstrap download' -Suggestion 'The Linux guest did not return a valid bootstrap download result. Review guest script output and confirm the Cloud Proxy target host and bootstrap path values.'
      }
    }

    if ($targetOutput -match '(?m)^RESULT INFO TARGET>AGENT_STATE:SKIPPED\s*$') {
      Add-DeviceResult -Device TargetVm -Status INFO -Test 'Linux telegraf installed-state checks skipped (pre-install mode)'
    }

    $targetOsMatches = [regex]::Matches($targetOutput, '(?m)^RESULT INFO TARGETOS:(.+)$')
    if ($targetOsMatches.Count -gt 0) {
      $reportedOsValues = @($targetOsMatches | ForEach-Object { $_.Groups[1].Value.Trim() })
      $preferredReportedOs = $reportedOsValues | Where-Object { $_ -ne 'LINUX' } | Select-Object -First 1
      if ([string]::IsNullOrWhiteSpace($preferredReportedOs)) {
        $preferredReportedOs = $reportedOsValues[0]
      }
      Add-DeviceResult -Device TargetVm -Status INFO -Test ("Linux guest reported OS : {0}" -f $preferredReportedOs)
    }
    if ($targetOutput -match '(?m)^RESULT PASS TARGET>SUDO:AVAILABLE\s*$') {
      Add-DeviceResult -Device TargetVm -Status PASS -Test 'Linux sudo availability'
    } elseif ($UseSudo -and $targetOutput -match '(?m)^RESULT WARN TARGET>SUDO:(UNAVAILABLE|MISSING)\s*$') {
      Add-DeviceResult -Device TargetVm -Status WARN -Test 'Linux sudo availability' -Suggestion 'The Linux guest account could not use sudo non-interactively. Either rerun without -UseSudo for connectivity-only checks or use an account that has the required sudo rights.' -KbLinks $script:KbMap.LinuxGuestExecution
    }
    if ($targetOutput -match '(?m)^RESULT WARN TARGET>TOOLING:CONNECTIVITY_HELPER_MISSING\s*$') {
      Add-DeviceResult -Device TargetVm -Status WARN -Test 'Linux connectivity helper tooling' -Suggestion 'Neither nc nor timeout was available on the Linux guest. Install one of these utilities or use a baseline image that includes them.' -KbLinks $script:KbMap.LinuxGuestExecution
    }
    if ($targetOutput -match '(?m)^RESULT PASS TARGET>SERVICE:telegraf\s*$') {
      Add-DeviceResult -Device TargetVm -Status PASS -Test 'Linux telegraf service'
    } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>SERVICE:telegraf\s*$') {
      Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Linux telegraf service' -Suggestion 'systemd did not report the telegraf service as active. Check whether the package is installed, whether the product-managed deployment has completed, and whether the distro/version is supported.' -KbLinks ($script:KbMap.LinuxPlatformSupport + $script:KbMap.LinuxInstallGuidance)
    } elseif ($targetOutput -match '(?m)^RESULT WARN TARGET>SERVICE:systemctl_missing\s*$') {
      Add-DeviceResult -Device TargetVm -Status WARN -Test 'Linux telegraf service' -Suggestion 'systemctl is not available on this Linux guest, so service validation was skipped. Confirm the distro/service manager and check telegraf manually.' -KbLinks $script:KbMap.LinuxPlatformSupport
    }
    if ($targetOutput -match '(?m)^RESULT PASS TARGET>PROCESS:telegraf\s*$') {
      Add-DeviceResult -Device TargetVm -Status PASS -Test 'Linux telegraf process'
    } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>PROCESS:telegraf\s*$') {
      Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Linux telegraf process' -Suggestion 'No telegraf process was found on the Linux guest. This often means the agent is not installed, failed to start, or is crashing immediately after launch.' -KbLinks $script:KbMap.LinuxInstallGuidance
    }
    if ($targetOutput -match '(?m)^RESULT PASS TARGET>PATH:/etc/telegraf/telegraf\.conf\s*$') {
      Add-DeviceResult -Device TargetVm -Status PASS -Test 'Linux telegraf config path'
    } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>PATH:/etc/telegraf/telegraf\.conf\s*$') {
      Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Linux telegraf config path' -Suggestion 'The expected /etc/telegraf/telegraf.conf path was not present. Verify whether the agent package was installed and whether deployment placed files in the expected location for this distro.' -KbLinks $script:KbMap.LinuxInstallGuidance
    }
    if ($targetOutput -match '(?m)^RESULT PASS TARGET>PACKAGE:telegraf:(rpm|dpkg)\s*$') {
      Add-DeviceResult -Device TargetVm -Status PASS -Test 'Linux telegraf package'
    } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>PACKAGE:telegraf:(rpm|dpkg)\s*$') {
      Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Linux telegraf package' -Suggestion 'The Linux package manager did not report a telegraf package installation. Check whether the agent deployment completed and whether the distro/version is supported for product-managed Linux monitoring.' -KbLinks ($script:KbMap.LinuxPlatformSupport + $script:KbMap.LinuxInstallGuidance)
    } elseif ($targetOutput -match '(?m)^RESULT WARN TARGET>PACKAGE:manager_unknown\s*$') {
      Add-DeviceResult -Device TargetVm -Status WARN -Test 'Linux telegraf package' -Suggestion 'The Linux guest did not expose an rpm or dpkg package manager, so package validation was skipped.' -KbLinks $script:KbMap.LinuxPlatformSupport
    }
  }

  if ($CloudProxyVmName) {
    $cloudProxyVm = Get-VM -Name $CloudProxyVmName -ErrorAction Stop
    W "Cloud Proxy VM found: $($cloudProxyVm.Name) (PowerState=$($cloudProxyVm.PowerState))" 'PASS'
    if ($cloudProxyVm.PowerState -ne 'PoweredOn') {
      Add-DeviceResult -Device CloudProxy -Status FAIL -Test 'VM power state' -Suggestion 'Power on the Cloud Proxy VM, then rerun the validation.'
      throw 'Cloud Proxy VM is not powered on.'
    }

    $cloudProxyView = Get-View -Id $cloudProxyVm.Id -ErrorAction Stop
    W "Cloud Proxy VMware Tools status: $($cloudProxyView.Guest.ToolsRunningStatus) / $($cloudProxyView.Guest.ToolsVersionStatus2)"
    if ($cloudProxyView.Guest.ToolsRunningStatus -notmatch 'guestToolsRunning') {
      Add-DeviceResult -Device CloudProxy -Status FAIL -Test 'VMware Tools running' -Suggestion 'Start or repair VMware Tools / open-vm-tools on the Cloud Proxy appliance so Guest Operations can execute guest-side tests.'
      throw 'VMware Tools is not running on Cloud Proxy VM.'
    }

    $cloudProxyGuestPasswordPlain = ConvertTo-PlainText -SecureValue $CloudProxyGuestPassword
    W 'Running Cloud Proxy guest-side TCP 443 checks to vCenter and owning ESXi host ...'
    $cpTestScript = 'echo "Testing from Cloud Proxy guest"; ' +
    'if command -v nc >/dev/null 2>&1; then ' +
    '  nc -z -w __TIMEOUT__ "__VCENTER__" 443 >/dev/null 2>&1; ' +
    '  if [ $? -eq 0 ]; then echo "RESULT PASS __VCENTER__:443"; else echo "RESULT FAIL __VCENTER__:443"; fi; ' +
    '  nc -z -w __TIMEOUT__ "__ESXI__" 443 >/dev/null 2>&1; ' +
    '  if [ $? -eq 0 ]; then echo "RESULT PASS __ESXI__:443"; else echo "RESULT FAIL __ESXI__:443"; fi; ' +
    'else ' +
    '  timeout __TIMEOUT__ bash -c "cat < /dev/null > /dev/tcp/__VCENTER__/443" >/dev/null 2>&1; ' +
    '  if [ $? -eq 0 ]; then echo "RESULT PASS __VCENTER__:443"; else echo "RESULT FAIL __VCENTER__:443"; fi; ' +
    '  timeout __TIMEOUT__ bash -c "cat < /dev/null > /dev/tcp/__ESXI__/443" >/dev/null 2>&1; ' +
    '  if [ $? -eq 0 ]; then echo "RESULT PASS __ESXI__:443"; else echo "RESULT FAIL __ESXI__:443"; fi; ' +
    'fi'
    $cpTestScript = $cpTestScript.Replace('__VCENTER__', $vCenterServer)
    $cpTestScript = $cpTestScript.Replace('__ESXI__', $esxiTestTarget)
    $cpTestScript = $cpTestScript.Replace('__TIMEOUT__', [string]$CloudProxyPortTestTimeoutSec)

    $cpResult = Invoke-VMScript -VM $cloudProxyVm -GuestUser $CloudProxyGuestUser -GuestPassword $cloudProxyGuestPasswordPlain -ScriptType Bash -ScriptText $cpTestScript -ErrorAction Stop
    Write-Host "`n--- Cloud Proxy Guest Script Output ---`n$($cpResult.ScriptOutput)`n---------------------------------------" -ForegroundColor Gray

    if ($cpResult.ExitCode -eq 0) {
      Add-DeviceResult -Device CloudProxy -Status PASS -Test 'Guest execution'
    } else {
      Add-DeviceResult -Device CloudProxy -Status WARN -Test 'Guest execution' -Suggestion 'Guest-side Bash connectivity script executed on the Cloud Proxy VM but returned a non-zero exit code. Review the guest script output, confirm shell tooling availability (nc/timeout/bash), and verify Guest Operations execution context.' -KbLinks $script:KbMap.CloudProxySupportBundle
    }

    $cpOutput = [string]$cpResult.ScriptOutput
    if ($cpOutput -match "(?m)^RESULT PASS\s+$([regex]::Escape($vCenterServer)):443\s*$") {
      Add-DeviceResult -Device CloudProxy -Status PASS -Test 'Cloud Proxy > vCenter on 443'
    } elseif ($cpOutput -match "(?m)^RESULT FAIL\s+$([regex]::Escape($vCenterServer)):443\s*$") {
      Add-DeviceResult -Device CloudProxy -Status FAIL -Test 'Cloud Proxy > vCenter on 443' -Suggestion 'Confirm routing, firewall policy, DNS resolution, and certificate/trust posture between the Cloud Proxy and vCenter.' -KbLinks ($script:KbMap.CloudProxyPorts + $script:KbMap.CloudProxyCertificates)
    } else {
      Add-DeviceResult -Device CloudProxy -Status WARN -Test 'Cloud Proxy > vCenter on 443' -Suggestion 'The Cloud Proxy guest-side connectivity test to vCenter returned no valid PASS/FAIL result. Review the guest script output.' -KbLinks $script:KbMap.CloudProxySupportBundle
    }

    if ($cpOutput -match "(?m)^RESULT PASS\s+$([regex]::Escape($esxiTestTarget)):443\s*$") {
      Add-DeviceResult -Device CloudProxy -Status PASS -Test 'Cloud Proxy > ESXi on 443'
    } elseif ($cpOutput -match "(?m)^RESULT FAIL\s+$([regex]::Escape($esxiTestTarget)):443\s*$") {
      Add-DeviceResult -Device CloudProxy -Status FAIL -Test 'Cloud Proxy > ESXi on 443' -Suggestion 'Allow TCP 443 from the Cloud Proxy to the ESXi host that currently owns the VM. Also confirm DNS/FQDN resolution or rerun using the ESXi management IP.' -KbLinks $script:KbMap.CloudProxyPorts
    } else {
      Add-DeviceResult -Device CloudProxy -Status WARN -Test 'Cloud Proxy > ESXi on 443' -Suggestion 'The Cloud Proxy guest-side connectivity test to the owning ESXi host returned no valid PASS/FAIL result. Review the guest script output and verify ESXi name resolution or rerun using the ESXi management IP.' -KbLinks $script:KbMap.CloudProxySupportBundle
    }
  } else {
    Add-DeviceResult -Device CloudProxy -Status WARN -Test 'Guest execution' -Suggestion 'Cloud Proxy VM was not supplied, so Cloud Proxy guest-side connectivity checks were skipped. Provide CloudProxyVmName, CloudProxyGuestUser, and CloudProxyGuestPassword to validate Cloud Proxy > vCenter 443 and Cloud Proxy > ESXi 443 directly from the appliance.' -KbLinks $script:KbMap.CloudProxyPorts
  }
}
catch {
  $msg = $_.Exception.Message
  W ("Validation failed: " + $msg) 'FAIL'
  if ($effectiveTargetOs -eq 'Windows' -and $msg -match 'execution policy|Restricted|config-utils\.bat') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'PowerShell execution policy' -Suggestion 'The endpoint PowerShell execution policy may block product-managed Telegraf bootstrap. Set an execution policy that permits the required PowerShell script execution, then retry the agent deployment.' -KbLinks $script:KbMap.WindowsExecutionPolicy
  } elseif ($msg -match 'SSL connection could not be established|unexpected error occurred on a receive|HTTP response to https://.*/sdk') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'vCenter TLS/session handshake' -Suggestion 'The admin workstation reached vCenter on TCP 443, but the SDK TLS/session handshake failed before Guest Operations could start. Check certificate trust, TLS inspection, protocol compatibility, and whether this runner can negotiate with the vCenter SOAP endpoint.' -KbLinks $script:KbMap.CloudProxyCertificates
  } elseif ($effectiveTargetOs -eq 'Linux' -and $msg -match 'sudo|permission denied') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Linux guest permissions' -Suggestion 'The Linux guest account could not execute one or more checks. Confirm guest credentials, VMware Guest Operations rights, and sudo configuration for the target account.' -KbLinks $script:KbMap.LinuxGuestExecution
  } elseif ($msg -match 'Cloud Proxy') {
    Add-DeviceResult -Device CloudProxy -Status FAIL -Test 'Validation sequence' -Suggestion $msg
  } else {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Validation sequence' -Suggestion $msg
  }
}
finally {
  Show-GroupedSummary -Summary $script:DeviceResults
  if ($vi) {
    Disconnect-VIServer -Server $vi -Confirm:$false | Out-Null
    W 'Disconnected from vCenter'
  }
  if ($null -ne $targetGuestPasswordPlain) { $targetGuestPasswordPlain = $null }
  if ($null -ne $cloudProxyGuestPasswordPlain) { $cloudProxyGuestPasswordPlain = $null }
  if ($null -ne $vCenterPasswordPlain) { $vCenterPasswordPlain = $null }
}



