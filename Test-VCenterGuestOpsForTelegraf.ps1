[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$vCenterServer,
  [Parameter(Mandatory = $true)][string]$VMName,
  [Parameter(Mandatory = $true)][string]$GuestUser,
  [Parameter(Mandatory = $true)][securestring]$GuestPassword,
  [switch]$CreateTestFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function W([string]$m, [string]$l = 'INFO') { $c = @{INFO = 'Cyan'; PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$l]; Write-Host "[$l] $m" -ForegroundColor $c }
if (-not (Get-Module -ListAvailable VMware.PowerCLI)) { throw 'VMware.PowerCLI not installed. Install-Module VMware.PowerCLI' }
Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null
try { Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP:$false -Confirm:$false | Out-Null } catch {}
$plain = $null
$bstr = [IntPtr]::Zero
try {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($GuestPassword)
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
  if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$vi = $null
try {
  W "Connecting to vCenter $vCenterServer ..."
  $vi = Connect-VIServer -Server $vCenterServer -ErrorAction Stop
  W "Connected to $($vi.Name) as $($vi.User)" 'PASS'
  $vm = Get-VM -Name $VMName -ErrorAction Stop
  W "VM found: $($vm.Name) (PowerState=$($vm.PowerState))"
  if ($vm.PowerState -ne 'PoweredOn') { W 'VM is not powered on.' 'FAIL'; return }
  $view = Get-View -Id $vm.Id -ErrorAction Stop
  W "VMware Tools status: $($view.Guest.ToolsRunningStatus) / $($view.Guest.ToolsVersionStatus2)"
  if ($view.Guest.ToolsRunningStatus -notmatch 'guestToolsRunning') { W 'VMware Tools is not running.' 'FAIL'; return }
  $script = @"
`$ErrorActionPreference='Stop'
if(-not (Test-Path 'C:\Temp')){ New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null }
whoami
hostname
(Get-Date).ToString('s')
"@
  if ($CreateTestFile) { $script += "`n'VCF Ops GuestOps test' | Out-File -FilePath 'C:\Temp\vcfops_guestops_test.txt' -Encoding utf8 -Force`n'Created test file'`n" }
  W 'Invoking guest script via Invoke-VMScript ...'
  $r = Invoke-VMScript -VM $vm -GuestUser $GuestUser -GuestPassword $plain -ScriptType Powershell -ScriptText $script -ErrorAction Stop
  W "Invoke-VMScript succeeded (ExitCode=$($r.ExitCode))" 'PASS'
  Write-Host "`n--- Guest Script Output ---`n$($r.ScriptOutput)`n---------------------------" -ForegroundColor Gray
  if ($r.ExitCode -ne 0) { W 'Guest script returned non-zero exit code.' 'WARN' }
  W 'Guest Operations path looks functional. Investigate bootstrap/UCP/Cloud Proxy path next if product-managed deployment still fails.' 'PASS'
}
catch {
  W ("Guest Ops validation failed: " + $_.Exception.Message) 'FAIL'
  Write-Host @"
Troubleshooting pointers:
- VMware Tools running/healthy
- Guest credentials + local admin rights
- vCenter Guest Operations permissions
- EDR/AppLocker/Defender ASR blocking VMware Tools-launched processes
"@ -ForegroundColor Yellow
}
finally {
  if ($vi) { Disconnect-VIServer -Server $vi -Confirm:$false | Out-Null; W 'Disconnected from vCenter' }
  if ($null -ne $plain) { $plain = $null }
}
