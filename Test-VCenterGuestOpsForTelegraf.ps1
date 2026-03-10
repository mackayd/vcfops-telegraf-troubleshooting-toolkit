#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$vCenterServer,
  [Parameter(Mandatory = $true)][string]$VMName,
  [Parameter(Mandatory = $true)][securestring]$GuestPassword,
  [Parameter(Mandatory = $true)][string]$GuestUser,
  [switch]$CreateTestFile,
  [string]$CloudProxyVmName,
  [string]$CloudProxyTargetHost,
  [string]$CloudProxyGuestUser,
  [securestring]$CloudProxyGuestPassword,
  [switch]$PromptForCloudProxyGuestPassword,
  [ValidateRange(1,30)][int]$CloudProxyPortTestTimeoutSec = 5,
  [switch]$UseEsxiManagementIpForCloudProxyTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KbMap = @{
  CloudProxyPorts = @(
    'Broadcom KB 374807 - Telegraf agent install fails / required endpoint-to-Cloud Proxy ports: https://knowledge.broadcom.com/external/article/374807/telegraf-agent-install-fails-with-error.html'
  )
  WindowsExecutionPolicy = @(
    'Broadcom KB 428286 - Windows Telegraf install fails downloading config-utils.bat when PowerShell execution policy is Restricted: https://knowledge.broadcom.com/external/article/428286/telegraf-agent-installation-fails-on-win.html'
  )
  CloudProxyCertificates = @(
    'Broadcom KB 405325 - Loading updated certs to Aria Operations / Cloud Proxy certificate guidance: https://knowledge.broadcom.com/external/article/405325/loading-updated-certs-to-aria-operations.html',
    'Broadcom KB 320343 - Configure a Certificate For Use With VCF Operations: https://knowledge.broadcom.com/external/article/320343/configure-a-certificate-for-use-with-vmw.html'
  )
  CloudProxySupportBundle = @(
    'Broadcom KB 342832 - Collect diagnostic information / generate Cloud Proxy support bundle: https://knowledge.broadcom.com/external/article/342832/collecting-diagnostic-information-from-v.html'
  )
}

$effectiveCloudProxyTargetHost = if (-not [string]::IsNullOrWhiteSpace($CloudProxyTargetHost)) { $CloudProxyTargetHost } else { $CloudProxyVmName }

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

function Show-GroupedSummary {
  param([hashtable]$Summary)
  Write-Host ""
  Write-Host "==================== Validation Summary ====================" -ForegroundColor Cyan

  foreach ($key in @('TargetVm','CloudProxy')) {
    $section = $Summary[$key]
    if ($null -eq $section) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$section.Name) -and $section.Results.Count -eq 0) { continue }

    Write-Host ""
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
        Write-Host ""
        Write-Host "Suggestion:" -ForegroundColor Yellow
        Write-Host $item.Suggestion -ForegroundColor Yellow
      }

      if ($item.Status -in @('WARN','FAIL') -and $item.KbLinks.Count -gt 0) {
        Write-Host ""
        Write-Host "Related articles:" -ForegroundColor Yellow
        foreach ($kb in $item.KbLinks) {
          Write-Host ("- {0}" -f $kb) -ForegroundColor Yellow
        }
      }
    }
  }

  Write-Host ""
  Write-Host "============================================================" -ForegroundColor Cyan
}

function ConvertTo-PlainText {
  param([Parameter(Mandatory = $true)][securestring]$SecureValue)
  $bstr = [IntPtr]::Zero
  try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
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

if (-not (Get-Module -ListAvailable VCF.PowerCLI) -and -not (Get-Module -ListAvailable VMware.PowerCLI)) {
  throw 'Neither VCF.PowerCLI nor VMware.PowerCLI is installed. Install-Module VCF.PowerCLI or Install-Module VMware.PowerCLI'
}
if (Get-Module -ListAvailable VCF.PowerCLI) {
  Import-Module VCF.PowerCLI -ErrorAction Stop | Out-Null
} else {
  Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null
}
try { Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP:$false -Confirm:$false | Out-Null } catch {}

$targetGuestPasswordPlain = $null
$cloudProxyGuestPasswordPlain = $null
$vi = $null

try {
  $targetGuestPasswordPlain = ConvertTo-PlainText -SecureValue $GuestPassword

  W "Connecting to vCenter $vCenterServer ..."
  $vi = Connect-VIServer -Server $vCenterServer -ErrorAction Stop
  W "Connected to $($vi.Name) as $($vi.User)" 'PASS'

  $vm = Get-VM -Name $VMName -ErrorAction Stop
  W "VM found: $($vm.Name) (PowerState=$($vm.PowerState))"

  if ($vm.PowerState -ne 'PoweredOn') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'VM power state' -Suggestion 'Power on the target VM, then rerun the validation.'
    throw 'Target VM is not powered on.'
  }

  $view = Get-View -Id $vm.Id -ErrorAction Stop
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
      W "Using ESXi management IP for tests: $esxiTestTarget" 'INFO'
    } else {
      Add-DeviceResult -Device TargetVm -Status WARN -Test 'ESXi test target selection' -Suggestion 'Could not determine ESXi management IP cleanly, so the script is using the ESXi host name. If DNS resolution is unreliable, rerun with a known-good ESXi management IP.'
    }
  } else {
    W "Using ESXi host name for tests: $esxiTestTarget" 'INFO'
  }

  $targetScript = @"
`$ErrorActionPreference='Stop'
if(-not (Test-Path 'C:\Temp')){ New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null }
whoami
hostname
(Get-Date).ToString('s')

`$vcResult = Test-NetConnection -ComputerName '$vCenterServer' -Port 443 -InformationLevel Quiet
if (`$vcResult) { Write-Output 'RESULT PASS TARGET>VCENTER:443' } else { Write-Output 'RESULT FAIL TARGET>VCENTER:443' }

`$esxiResult = Test-NetConnection -ComputerName '$esxiTestTarget' -Port 443 -InformationLevel Quiet
if (`$esxiResult) { Write-Output 'RESULT PASS TARGET>ESXI:443' } else { Write-Output 'RESULT FAIL TARGET>ESXI:443' }
"@

  if ($targetShouldTestCloudProxy) {
    $targetScript += @"
`$cpResult = Test-NetConnection -ComputerName '$effectiveCloudProxyTargetHost' -Port 443 -InformationLevel Quiet
if (`$cpResult) { Write-Output 'RESULT PASS TARGET>CLOUDPROXY:443' } else { Write-Output 'RESULT FAIL TARGET>CLOUDPROXY:443' }
"@
  }

  if ($CreateTestFile) {
    $targetScript += "`n'VCF Ops GuestOps test' | Out-File -FilePath 'C:\Temp\vcfops_guestops_test.txt' -Encoding utf8 -Force`n'Created test file'`n"
  }

  W 'Invoking guest script on target VM via Invoke-VMScript ...'
  $r = Invoke-VMScript -VM $vm -GuestUser $GuestUser -GuestPassword $targetGuestPasswordPlain -ScriptType Powershell -ScriptText $targetScript -ErrorAction Stop
  W "Invoke-VMScript on target VM succeeded (ExitCode=$($r.ExitCode))" 'PASS'
  Write-Host "`n--- Target Guest Script Output ---`n$($r.ScriptOutput)`n----------------------------------" -ForegroundColor Gray

  if ($r.ExitCode -eq 0) {
    Add-DeviceResult -Device TargetVm -Status PASS -Test 'Guest execution'
  } else {
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Guest execution' -Suggestion 'Invoke-VMScript executed on the target VM but returned a non-zero exit code. Review guest script output, local privileges, and endpoint security controls.'
  }

  $targetOutput = $r.ScriptOutput

  if ($targetOutput -match '(?m)^RESULT PASS TARGET>VCENTER:443\s*$') {
    Add-DeviceResult -Device TargetVm -Status PASS -Test 'Telegraf VM target > vCenter on 443'
  } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>VCENTER:443\s*$') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Telegraf VM target > vCenter on 443' -Suggestion 'Confirm TCP 443 is allowed from the target VM to vCenter. Verify routing, Windows firewall, upstream firewall policy, and DNS resolution.' -KbLinks $script:KbMap.CloudProxyPorts
  } else {
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > vCenter on 443' -Suggestion 'The target VM connectivity test to vCenter did not return a valid PASS/FAIL result. Review the guest script output.'
  }

  if ($targetOutput -match '(?m)^RESULT PASS TARGET>ESXI:443\s*$') {
    Add-DeviceResult -Device TargetVm -Status PASS -Test 'Telegraf VM target > ESXi on 443'
  } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>ESXI:443\s*$') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Telegraf VM target > ESXi on 443' -Suggestion 'Confirm TCP 443 is allowed from the target VM to the owning ESXi host. Verify routing, firewall policy, and ESXi hostname/IP resolution.' -KbLinks $script:KbMap.CloudProxyPorts
  } else {
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > ESXi on 443' -Suggestion 'The target VM connectivity test to the owning ESXi host did not return a valid PASS/FAIL result. Review the guest script output.'
  }

  if ($targetShouldTestCloudProxy) {
    if ($targetOutput -match '(?m)^RESULT PASS TARGET>CLOUDPROXY:443\s*$') {
      Add-DeviceResult -Device TargetVm -Status PASS -Test 'Telegraf VM target > Cloud Proxy on 443'
    } elseif ($targetOutput -match '(?m)^RESULT FAIL TARGET>CLOUDPROXY:443\s*$') {
      Add-DeviceResult -Device TargetVm -Status FAIL -Test 'Telegraf VM target > Cloud Proxy on 443' -Suggestion 'Confirm TCP 443 is allowed from the target VM to the Cloud Proxy. Verify routing, DNS resolution, and firewall policy.' -KbLinks $script:KbMap.CloudProxyPorts
    } else {
      Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > Cloud Proxy on 443' -Suggestion 'The target VM connectivity test to the Cloud Proxy did not return a valid PASS/FAIL result. Review the guest script output.'
    }
  } else {
    Add-DeviceResult -Device TargetVm -Status WARN -Test 'Telegraf VM target > Cloud Proxy on 443' -Suggestion 'CloudProxyTargetHost (or CloudProxyVmName) was not supplied, so the target VM to Cloud Proxy 443 test was skipped.'
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
    W 'Running Cloud Proxy guest-side TCP 443 checks to vCenter and owning ESXi host ...' 'INFO'

    $cpTestScript = 'echo "Testing from Cloud Proxy guest"; ' +
    'echo "RESULT PASS LOCALHOST:443"; ' +
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

    $cpOutput = $cpResult.ScriptOutput

    if ($cpOutput -match "(?m)^RESULT PASS\s+$([regex]::Escape($vCenterServer)):443\s*$") {
      Add-DeviceResult -Device CloudProxy -Status PASS -Test 'Cloud Proxy > vCenter on 443'
    } elseif ($cpOutput -match "(?m)^RESULT FAIL\s+$([regex]::Escape($vCenterServer)):443\s*$") {
      Add-DeviceResult -Device CloudProxy -Status FAIL -Test 'Cloud Proxy > vCenter on 443' -Suggestion 'Confirm routing, firewall policy, DNS resolution, and certificate/trust posture between the Cloud Proxy and vCenter.' -KbLinks ($script:KbMap.CloudProxyPorts + $script:KbMap.CloudProxyCertificates)
    } else {
      Add-DeviceResult -Device CloudProxy -Status WARN -Test 'Cloud Proxy > vCenter on 443' -Suggestion 'The Cloud Proxy guest-side connectivity test to vCenter returned no valid PASS/FAIL result. Review the guest script output and confirm the appliance has the expected shell tools available.' -KbLinks $script:KbMap.CloudProxySupportBundle
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

  if ($msg -match 'execution policy|Restricted|config-utils\.bat') {
    Add-DeviceResult -Device TargetVm -Status FAIL -Test 'PowerShell execution policy' -Suggestion 'The endpoint PowerShell execution policy may block product-managed Telegraf bootstrap. Set an execution policy that permits the required PowerShell script execution, then retry the agent deployment.' -KbLinks $script:KbMap.WindowsExecutionPolicy
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
}
