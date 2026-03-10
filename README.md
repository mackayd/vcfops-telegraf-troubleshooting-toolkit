# VCF Operations / Aria Operations Telegraf Troubleshooting Toolkit (Windows)

**PowerShell toolkit for troubleshooting product-managed Telegraf agent deployment** in **VCF Operations / Aria Operations** environments (Windows endpoints).

This toolkit helps isolate which stage of the **product-managed Telegraf deployment flow** is failing by testing the same dependencies the product relies on, including **network reachability, DNS, Guest Operations, guest-side execution, and Cloud Proxy communication paths**, while still keeping the final deployment method **product-managed**.

<p align="left">
  <img alt="PowerShell" src="https://img.shields.io/badge/PowerShell-7+-blue">
  <img alt="Platform" src="https://img.shields.io/badge/Platform-Windows%20%7C%20PowerCLI-lightgrey">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-green">
  <img alt="Status" src="https://img.shields.io/badge/Status-Stable-brightgreen">
</p>

---

## Purpose

When a product-managed Telegraf deployment fails, the issue is often not “Telegraf” itself — it is usually one of the stages *around* it:

- **vCenter Guest Operations** (VMware Tools / guest credentials / permissions)
- **Cloud Proxy reachability** (ports, routing, firewall)
- **Target VM to platform dependencies** (vCenter / ESXi / Cloud Proxy over 443)
- **Cloud Proxy to platform dependencies** (vCenter / owning ESXi over 443)
- **TLS / HTTPS trust** (certificate chain, SSL inspection, FQDN mismatch)
- **Managed control path** (registration/config push ports)
- **Endpoint security / policy** (EDR, AppLocker, Defender ASR)
- **DNS resolution** (wrong interface/IP, split DNS, stale records)

This toolkit gives you a repeatable way to validate each layer, compare failing vs known-good hosts, and collect evidence for platform, firewall/security teams, or Broadcom support.

![Alt text for accessibility](Telegraf-toolkit-workflow.png)

---

## Scope and supportability note

> **Important**
>
> This toolkit is intended for **troubleshooting and diagnostics** of **product-managed Telegraf deployment**.
>
> It is **not** a replacement for the supported product-managed deployment workflow in VCF / Aria Operations.

The included bootstrap probe script is a **semi-manual diagnostic tool** to test the bootstrap path and surrounding dependencies. Once the root cause is identified and fixed, the **final install should still be performed from the VCF/Aria Operations UI**.

---

## What’s included (v2.2.0)

### Core endpoint diagnostics (run on target Windows VM)
- **`Test-VcfOpsTelegrafEndpoint.ps1`**
  - Tests DNS resolution to Cloud Proxy
  - Tests TCP ports (**443, 8443, 4505, 4506**)
  - Tests HTTPS/TLS reachability
  - Checks related services/processes (Telegraf/UCP/Salt patterns)
  - Outputs console + JSON + TXT summary

- **`Collect-VcfOpsTelegrafDeployDiag.ps1`**
  - Collects post-failure evidence (services, processes, logs, networking, firewall/proxy indicators)
  - Produces a zipped diagnostic bundle for analysis/support cases

---

### Guest Operations validation (run from admin workstation with PowerCLI)
- **`Test-VCenterGuestOpsForTelegraf.ps1`**
  - Connects to vCenter
  - Validates target VM power state and VMware Tools health
  - Identifies the **owning ESXi host** for the target VM
  - Runs guest-side checks inside the target Windows VM using `Invoke-VMScript`
  - Tests:
    - **Target VM > vCenter on 443**
    - **Target VM > owning ESXi host on 443**
    - **Target VM > Cloud Proxy on 443** (when supplied)
  - Optionally creates a harmless guest test file in `C:\Temp`
  - Optionally performs **Cloud Proxy guest-side checks** using `Invoke-VMScript` against the Cloud Proxy appliance
  - Tests:
    - **Cloud Proxy > vCenter on 443**
    - **Cloud Proxy > owning ESXi host on 443**
  - Supports either **ESXi hostname** or **ESXi management IP** for Cloud Proxy-side testing
  - Produces a grouped console summary with:
    - PASS / WARN / FAIL outcomes
    - remediation suggestions
    - related Broadcom KB references for common failure conditions

- **`Test-VCenterGuestOpsFleetForTelegraf.ps1`**
  - CSV-driven Guest Ops validation across multiple VMs

---

### Semi-manual bootstrap diagnostics (troubleshooting use)
- **`Invoke-VcfOpsTelegrafBootstrapProbe.ps1`**
  - Diagnostic probe for testing bootstrap-style download/execution path from the endpoint
  - Helps determine whether the issue is:
    - Guest Ops launch/orchestration
    - Bootstrap transport/download
    - Endpoint execution/security
    - Cloud Proxy registration/control path

> **Warning**
>
> This script is for diagnostics and controlled testing. It is not intended to replace product-managed deployment.

---

### Fleet execution / reporting / comparison
- **`Invoke-VcfOpsTelegrafFleetRunner.ps1`**
  - Runs endpoint checks across multiple hosts from a CSV target list

- **`New-VcfOpsTelegrafHtmlReport.ps1`**
  - Builds a consolidated HTML report/dashboard from collected JSON outputs
   ![Alt text for accessibility](toolkit-report-example.png)

- **`Invoke-VcfOpsTelegrafCompareMode.ps1`**
  - Wrapper for comparing a **known-good** host to failing hosts

- **`Export-VcfOpsTelegrafKnownGoodDiff.ps1`**
  - Exports host comparison differences to CSV for sharing with platform/firewall/security teams

---

### Credential helper (for repeated Guest Ops testing)
- **`Save-VcfOpsTelegrafCredential.ps1`**
  - Helper for securely capturing/storing credentials for repeated testing workflows

> **Tip**
>
> Align usage with your organisation’s credential handling policy and least-privilege standards.

---

## Recommended troubleshooting workflow (single host)

> **Example Output**
> ![Alt text for accessibility](ExampleSingleVMtestingCommands.png)

### 1) Run endpoint precheck (on target Windows VM)
```powershell
.\Test-VcfOpsTelegrafEndpoint.ps1 -CloudProxyFqdn cp01.yourdomain.local
```

**What it tells you**
- **TCP 4505/4506 FAIL** → likely Cloud Proxy control-path firewall issue
- **HTTPS 443/8443 FAIL** → likely TLS/cert trust or HTTPS reachability issue
- All pass → likely issue is Guest Ops, guest-side execution, or endpoint security/policy

---

### 2) Validate Guest Ops path and target connectivity (PowerCLI from admin workstation)
```powershell
$pw = Read-Host "Guest password" -AsSecureString

.\Test-VCenterGuestOpsForTelegraf.ps1 `
  -vCenterServer vcsa01.yourdomain.local `
  -VMName APP-SRV-01 `
  -GuestUser 'DOMAIN\svc_vmguestops' `
  -GuestPassword $pw `
  -CloudProxyTargetHost cp01.yourdomain.local `
  -CreateTestFile
```

**What it tells you**
- If `Invoke-VMScript` fails on the target VM → focus on:
  - VMware Tools health
  - guest credentials / local admin rights
  - vCenter Guest Operations permissions
  - endpoint security blocking VMware Tools-launched execution
- If **Target VM > vCenter 443** fails → focus on target VM to vCenter connectivity, routing, firewall, or DNS
- If **Target VM > ESXi 443** fails → focus on target VM to owning ESXi host connectivity
- If **Target VM > Cloud Proxy 443** fails → focus on target VM to Cloud Proxy connectivity and name resolution

---

### 3) (Optional) Validate Cloud Proxy guest-side connectivity
If you want to test directly from the Cloud Proxy appliance guest OS as well:

```powershell
$pw = Read-Host "Target guest password" -AsSecureString
$cppw = Read-Host "Cloud Proxy guest password" -AsSecureString

.\Test-VCenterGuestOpsForTelegraf.ps1 `
  -vCenterServer vcsa01.yourdomain.local `
  -VMName APP-SRV-01 `
  -GuestUser 'DOMAIN\svc_vmguestops' `
  -GuestPassword $pw `
  -CloudProxyVmName aria-cp01 `
  -CloudProxyGuestUser 'root' `
  -CloudProxyGuestPassword $cppw `
  -UseEsxiManagementIpForCloudProxyTest
```

**What it tells you**
- If **Cloud Proxy > vCenter 443** fails → focus on Cloud Proxy routing, firewall, DNS, certificates, or trust
- If **Cloud Proxy > ESXi 443** fails → focus on Cloud Proxy to ESXi firewall/routing and possibly ESXi name resolution
- If hostname resolution is unreliable between the Cloud Proxy and ESXi, rerun with:
  - `-UseEsxiManagementIpForCloudProxyTest`

---

### 4) (Optional) Run bootstrap probe (diagnostic)
Run on the target VM to test the bootstrap path more directly:

```powershell
.\Invoke-VcfOpsTelegrafBootstrapProbe.ps1 `
  -CloudProxyFqdn cp01.yourdomain.local `
  -BootstrapPath '/downloads/salt/config-utils.bat' `
  -DownloadOnly
```

Then, if appropriate for diagnostic testing:

```powershell
.\Invoke-VcfOpsTelegrafBootstrapProbe.ps1 `
  -CloudProxyFqdn cp01.yourdomain.local `
  -BootstrapPath '/downloads/salt/config-utils.bat' `
  -ExecuteBootstrap
```

> **Note**
>
> The exact bootstrap path varies by environment/build/topology. Confirm the path from your environment logs, UI, or network traces.

---

### 5) Retry product-managed deployment in VCF / Aria Operations UI
Once the failing layer is corrected, retry **Deploy Agent** from the product UI.

---

### 6) Collect evidence if it still fails
Run on the target Windows VM after the failed attempt:

```powershell
.\Collect-VcfOpsTelegrafDeployDiag.ps1 -LookbackHours 6
```

This creates a diagnostic bundle suitable for:
- internal firewall/security/platform teams
- Broadcom support SRs
- known-good vs failing comparisons

---

## `Test-VCenterGuestOpsForTelegraf.ps1` parameters and usage notes

### Key parameters
- **`-vCenterServer`**  
  vCenter Server FQDN or IP.

- **`-VMName`**  
  Target Windows VM to validate.

- **`-GuestUser` / `-GuestPassword`**  
  Guest OS credentials used for `Invoke-VMScript` inside the target VM.

- **`-CreateTestFile`**  
  Creates `C:\Temp\vcfops_guestops_test.txt` inside the target VM as a harmless write test.

- **`-CloudProxyTargetHost`**  
  FQDN or IP of the Cloud Proxy to test from the target VM when you do not want to run guest-side checks on the Cloud Proxy appliance itself.

- **`-CloudProxyVmName`**  
  Cloud Proxy VM name in vCenter. When supplied, the script can perform guest-side Bash connectivity tests directly from the Cloud Proxy appliance.

- **`-CloudProxyGuestUser` / `-CloudProxyGuestPassword`**  
  Guest OS credentials for the Cloud Proxy appliance.

- **`-PromptForCloudProxyGuestPassword`**  
  Prompts interactively for the Cloud Proxy guest password instead of passing a secure string variable.

- **`-CloudProxyPortTestTimeoutSec`**  
  Timeout used by the Cloud Proxy guest-side TCP 443 checks. Default is `5`.

- **`-UseEsxiManagementIpForCloudProxyTest`**  
  Uses the ESXi management IP rather than the ESXi hostname for Cloud Proxy-side connectivity tests. Useful where DNS resolution from the appliance is unreliable.

### Notes
- `CloudProxyTargetHost` defaults to `CloudProxyVmName` if a separate target host is not supplied.
- If `CloudProxyVmName` is omitted, Cloud Proxy guest-side tests are skipped and the script records that as a warning rather than a hard failure.
- The script supports **VCF.PowerCLI** and **VMware.PowerCLI**.
- The script uses `Set-PowerCLIConfiguration -InvalidCertificateAction Ignore` to simplify lab and troubleshooting usage.
- Cloud Proxy guest-side tests use:
  - `nc` where available
  - Bash `/dev/tcp` fallback when `nc` is not present

---

## Fleet usage (multi-host diagnostics)

### Endpoint fleet checks (CSV-driven)
```powershell
.\Invoke-VcfOpsTelegrafFleetRunner.ps1 `
  -TargetsCsv .\targets-example.csv `
  -CloudProxyFqdn cp01.yourdomain.local `
  -OutputRoot C:\Temp\TelegrafFleet
```

### Generate consolidated HTML report
```powershell
.\New-VcfOpsTelegrafHtmlReport.ps1 `
  -InputRoot C:\Temp\TelegrafFleet `
  -OutputPath C:\Temp\TelegrafFleet\VCFOps-Telegraf-Report.html
```

### Compare known-good vs failing hosts
```powershell
.\Invoke-VcfOpsTelegrafCompareMode.ps1 `
  -KnownGoodHost APP-SRV-BASELINE01 `
  -InputRoot C:\Temp\TelegrafFleet `
  -ExportCsv
```

### Direct diff export to CSV
```powershell
.\Export-VcfOpsTelegrafKnownGoodDiff.ps1 `
  -KnownGoodJson .\KnownGood\EndpointCheck-APP-SRV-BASELINE01.json `
  -CompareJsonFolder .\Failures `
  -OutCsv .\KnownGood-Diff.csv
```

---

## Example `targets-example.csv`

```csv
ComputerName,Notes
APP-SRV-01,Failing example
APP-SRV-02,Failing example
APP-SRV-BASELINE01,Known good
```

> **Note**
>
> If your packaged script expects slightly different CSV column names, check the script help (`Get-Help <script> -Full`).

---

## Typical failure patterns this toolkit helps identify

### 1) Cloud Proxy control-path ports blocked
**Symptoms**
- `TCP 4505` / `TCP 4506` = FAIL
- `TCP 443` may still work
- Product-managed install starts but does not complete registration/config push

**Likely cause**
- Firewall path blocked between server subnet/VLAN and Cloud Proxy control ports

---

### 2) TLS / certificate trust issue
**Symptoms**
- TCP 443/8443 succeeds
- HTTPS/TLS test fails with trust/name/handshake errors
- Bootstrap probe fails at download stage
- Cloud Proxy to vCenter 443 may connect at TCP level but still have certificate/trust issues operationally

**Likely cause**
- Endpoint does not trust Cloud Proxy certificate chain / internal CA
- SSL inspection/proxy interception
- FQDN mismatch (cert CN/SAN vs requested hostname)

---

### 3) Guest Operations launch failure (pre-bootstrap)
**Symptoms**
- `Invoke-VMScript` fails
- VMware Tools not running or unhealthy
- Product-managed deployment fails immediately / never starts bootstrap

**Likely cause**
- Invalid guest credentials
- Missing local admin rights
- vCenter Guest Operations permission issue
- EDR/AppLocker/Defender ASR blocking execution launched via VMware Tools

---

### 4) Target VM cannot reach required platform endpoints
**Symptoms**
- `Target VM > vCenter on 443` = FAIL
- and/or `Target VM > ESXi on 443` = FAIL
- and/or `Target VM > Cloud Proxy on 443` = FAIL

**Likely cause**
- Routing issue
- host firewall / upstream firewall policy
- DNS resolution failure
- incorrect Cloud Proxy FQDN/IP

---

### 5) Cloud Proxy cannot reach vCenter or owning ESXi
**Symptoms**
- `Cloud Proxy > vCenter on 443` = FAIL
- and/or `Cloud Proxy > ESXi on 443` = FAIL

**Likely cause**
- Firewall path blocked from Cloud Proxy network
- DNS resolution issue between appliance and infrastructure endpoints
- incorrect ESXi hostname resolution
- appliance routing issue

---

### 6) Endpoint security / local policy blocking execution
**Symptoms**
- Network + Guest Ops tests pass
- Bootstrap probe fails during execution/service creation
- Files appear briefly then disappear / are quarantined

**Likely cause**
- AV/EDR/AppLocker blocking bootstrap/minion/telegraf binaries or scripts

---

## Requirements

### On target Windows endpoints
- PowerShell 7 recommended
- Local Administrator (recommended for full checks)
- Ability to run local scripts (`RemoteSigned` or process-scope bypass as appropriate)

### On admin workstation / jump host (Guest Ops scripts)
- PowerShell 7
- **VCF PowerCLI** or **VMware PowerCLI**
- vCenter connectivity
- Appropriate vCenter permissions
- Valid guest OS credentials for test execution

### For optional Cloud Proxy guest-side validation
- Cloud Proxy VM visible in vCenter
- VMware Tools / open-vm-tools running on the Cloud Proxy appliance
- Valid Cloud Proxy guest credentials
- Shell tooling available on the appliance:
  - `nc`, or
  - `bash` with `/dev/tcp` and `timeout`

---

## PowerCLI install (if needed)

```powershell
Install-Module VCF.PowerCLI -Scope CurrentUser
```

If you prefer standard VMware PowerCLI:

```powershell
Install-Module VMware.PowerCLI -Scope CurrentUser
```

---

## Script help

Each script includes comment-based help. Examples:

```powershell
Get-Help .\Test-VcfOpsTelegrafEndpoint.ps1 -Full
Get-Help .\Test-VCenterGuestOpsForTelegraf.ps1 -Full
Get-Help .\Invoke-VcfOpsTelegrafBootstrapProbe.ps1 -Full
```

---

## Security and handling guidance

- Treat generated outputs as potentially sensitive (hostnames, IPs, logs, service names)
- Review evidence bundles before sharing externally
- Do not hardcode production credentials into scripts or CSV files
- Prefer dedicated service accounts and least privilege where possible

---

## Suggested usage during a real incident

1. Run endpoint precheck
2. Run Guest Ops validator against the target VM
3. Optionally run Cloud Proxy guest-side validation
4. Retry product-managed deploy in UI
5. Run evidence collector
6. Compare with known-good host
7. Share diff/evidence with the relevant team (platform, firewall, security, support)

This sequence helps isolate the failing layer quickly and reduces random trial-and-error.

---

## License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.
