[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Path)
$cred = Get-Credential -Message 'Enter guest OS credential for Guest Ops fleet validator'
$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$cred | Export-Clixml -Path $Path
Write-Host "Credential saved (DPAPI-protected for current user on this machine): $Path" -ForegroundColor Green
