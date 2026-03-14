# VCF Ops Telegraf Toolkit v3.0

PowerShell toolkit for troubleshooting **product-managed Telegraf agent deployment** in **VCF Operations / Aria Operations** environments across **Windows** and **Linux** endpoints.

It validates the same dependency chain the platform depends on in production: **vCenter Guest Operations, VMware Tools, Cloud Proxy reachability, DNS, HTTPS/TLS trust, bootstrap delivery, and local endpoint execution**.

<p align="left">
  <img alt="PowerShell" src="https://img.shields.io/badge/PowerShell-7+-blue">
  <img alt="Platform" src="https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20PowerCLI-lightgrey">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-green">
  <img alt="Status" src="https://img.shields.io/badge/Status-v3.0-blueviolet">
</p>

---

## Why this toolkit exists

When a product-managed Telegraf deployment fails, the root cause is often not Telegraf itself. The failure is usually somewhere around it:

- **vCenter Guest Operations** permissions, credentials, or VMware Tools state
- **Cloud Proxy connectivity** on the required ports
- **DNS resolution** or hostname mismatch
- **HTTPS/TLS trust** issues and certificate chain problems
- **Bootstrap delivery** failures for the expected Cloud Proxy path
- **Endpoint-side execution controls** such as AV, EDR, policy, or sudo restrictions

This toolkit gives you a repeatable way to validate those layers, capture evidence, and generate output that can be shared with platform, firewall, security, or support teams.
[Open the example Guest Fleet report](https://mackayd.github.io/vcfops-telegraf-troubleshooting-toolkit/Example-GuestFleetReport.html)

![Toolkit workflow](Images/Telegraf-toolkit-workflow.png)

---

## What changed in v3.0

Version 3.0 is a major refresh of the toolkit:

- **Guest Ops fleet testing** supports mixed Windows and Linux targets from the same CSV
- **Credential handling** supports:
  - plaintext CSV credentials when you accept the risk
  - DPAPI-protected credential files
  - per-VM credential overrides using `AltCredFile`
- **Cloud Proxy hostname discovery** no longer assumes a fixed DNS suffix and can use VMware Tools guest hostname/FQDN data
- **Interactive HTML reporting** now includes:
  - summary graphics
  - clickable VM drill-down
  - Show All VMs overview
- **Guest Ops fleet output** and **vCenter fleet output** can be parsed by the same HTML report script, however vCenter Fleet script is retired to archive as Guest Ops now performs the same fucntion using faster execution
- **Help output** is now consistent across the toolkit with `-h`, `-Full`, and `-Examples`

Because the Guest Ops workflow and reporting experience changed significantly, this release is documented as **v3.0**.

---

## Quick Start

### 1. Create a target CSV

Example `targets.csv`:

```csv
VMName,GuestUser,GuestPassword,TargetOs,UseSudo,AltCredFile
AppServer-01,devops\DomainAdmin,P@ssw0rd123!,Auto,false,
LinuxWeb-01,telegraf,P@ssw0rd123!,Auto,true,
LinuxDB-01,,,Auto,true,DBA-Linux.xml
```

Notes:

- `TargetOs` can remain `Auto` in most cases
- `AltCredFile` overrides the default credential source for that VM only
- If you use credential files, `GuestUser` and `GuestPassword` can be left blank for those rows

### 2. Choose how to provide credentials

**Preferred option: DPAPI-protected credential files**

Create a credential file:

```powershell
.\Save-VcfOpsTelegrafCredential.ps1 -Path .\Windows.xml
```

Then create another for Linux if needed:

```powershell
.\Save-VcfOpsTelegrafCredential.ps1 -Path .\Linux.xml
```

**Alternative option: plaintext in the CSV**

If you accept the security risk, you can populate `GuestUser` and `GuestPassword` directly in the CSV.

### 3. Run the fleet Guest Ops tests

```powershell
.\Invoke-VcfOpsFleetGuestOps.ps1 `
  -vCenterServer 'vCenter-01.devops.local' `
  -TargetsCsv '.\targets.csv' `
  -vCenterUser 'administrator@vsphere.local' `
  -vCenterPassword $vcPw `
  -CloudProxyVmName 'CloudProxy-01' `
  -CloudProxyGuestUser 'root' `
  -CloudProxyGuestPassword $cpPw `
  -WindowsCredentialFile '.\Windows.xml' `
  -LinuxCredentialFile '.\Linux.xml' `
  -OutDir '.'
```

This produces:

- `GuestOpsFleetSummary-<timestamp>.json`
- `GuestOpsFleetSummary-<timestamp>.csv`

### 4. Generate the HTML dashboard

```powershell
.\New-VcfOpsTelegrafHtmlReport.ps1 `
  -InputPath .\GuestOpsFleetSummary-20260313-204315.json `
  -OutputHtml .\GuestFleetReport.html
```

---

## Interactive report experience

The HTML report is one of the biggest changes in v3.0.

It provides:

- top-level status counters and graphics
- clickable VM navigation
- Show All VMs overview
- single-VM drill-down
- raw output expansion
- support for both Guest Ops fleet JSON and vCenter fleet JSON

![Interactive VCF fleet report](Images/Example-VcfFleetReport.gif)

---

## Repository layout

```text
├── Invoke-VcfOpsFleetGuestOps.ps1
├── New-VcfOpsTelegrafHtmlReport.ps1
├── Save-VcfOpsTelegrafCredential.ps1
├── Test-VCenterGuestOpsForTelegraf.ps1
├── Example-Fleet-targets.csv
├── Example-GuestFleetReport.html
├── Images
│   ├── ExampleSingleVMtestingCommands.png
│   ├── Example-Fleet-Report.png
│   ├── Example-VcfFleetReport.gif
│   └── Telegraf-toolkit-workflow.png
└── EndPointTests
    ├── Collect-VcfOpsTelegrafDeployDiag.ps1
    ├── Invoke-VcfOpsTelegrafBootstrapProbe.ps1
    └── Test-VcfOpsTelegrafEndpoint.ps1
```

> The endpoint-executed scripts are stored in the `EndPointTests` folder and support Virtual or Baremetal Windows deployments.

---

## Script overview

| Script | Purpose | Typical use |
|---|---|---|
| `Invoke-VcfOpsFleetGuestOps.ps1` | Fleet Guest Ops test runner | Validate many VMs and generate HTML-ready JSON/CSV |
| `Test-VCenterGuestOpsForTelegraf.ps1` | Detailed single-VM Guest Ops validator | Deep-dive troubleshooting for one VM |
| `New-VcfOpsTelegrafHtmlReport.ps1` | Interactive HTML report generator | Convert compatible result files into dashboard-style HTML |
| `Save-VcfOpsTelegrafCredential.ps1` | Credential file creator | Create DPAPI-protected credential files for later runs |
| `Test-VcfOpsTelegrafEndpoint.ps1` | Endpoint-executed validator | Local validation on an endpoint |
| `Invoke-VcfOpsTelegrafBootstrapProbe.ps1` | Bootstrap probe | Isolate Cloud Proxy bootstrap path and TLS issues |
| `Collect-VcfOpsTelegrafDeployDiag.ps1` | Diagnostic collector | Gather local logs and deployment evidence after a failure |

---

## Core workflow

### Fleet Guest Ops workflow

`Invoke-VcfOpsFleetGuestOps.ps1` is the primary fleet script.

It:

- connects to vCenter
- reads a CSV of target VMs
- detects whether each VM is Windows or Linux
- resolves the Cloud Proxy hostname/FQDN
- uses VMware Guest Operations to run:
  - PowerShell inside Windows guests
  - Bash inside Linux guests
- tests connectivity, bootstrap reachability, and Cloud Proxy dependencies
- writes fleet JSON and CSV output ready for reporting

### Single-VM workflow

`Test-VCenterGuestOpsForTelegraf.ps1` is the primary single-target validator.

Use it when you want the most detailed console output for one VM.

![Example single VM commands](Images/ExampleSingleVMtestingCommands.png)

### Local endpoint workflow

The `EndPointTests` scripts are used when you want to test directly from an endpoint rather than via VMware Guest Operations.

- `Test-VcfOpsTelegrafEndpoint.ps1` tests endpoint-side reachability and execution prerequisites
- `Invoke-VcfOpsTelegrafBootstrapProbe.ps1` isolates bootstrap path behaviour and TLS trust issues
- `Collect-VcfOpsTelegrafDeployDiag.ps1` collects supporting diagnostics after a warning or failure

---

## Credential handling

The toolkit supports three credential approaches.

### 1. Default credential files by OS

Use `Save-VcfOpsTelegrafCredential.ps1` to create DPAPI-protected credential files:

```powershell
.\Save-VcfOpsTelegrafCredential.ps1 -Path .\Windows.xml
.\Save-VcfOpsTelegrafCredential.ps1 -Path .\Linux.xml
```

Then use them in the fleet runner:

```powershell
.\Invoke-VcfOpsFleetGuestOps.ps1 `
  -vCenterServer 'vCenter-01.devops.local' `
  -TargetsCsv '.\targets.csv' `
  -vCenterUser 'administrator@vsphere.local' `
  -vCenterPassword $vcPw `
  -CloudProxyVmName 'CloudProxy-01' `
  -CloudProxyGuestUser 'root' `
  -CloudProxyGuestPassword $cpPw `
  -WindowsCredentialFile '.\Windows.xml' `
  -LinuxCredentialFile '.\Linux.xml'
```

### 2. Per-VM alternate credential file

Populate `AltCredFile` in the CSV for a specific VM:

```csv
VMName,GuestUser,GuestPassword,TargetOs,UseSudo,AltCredFile
LinuxDB-01,,,Auto,true,DBA-Linux.xml
```

When `AltCredFile` is populated, that credential file is used for that VM and overrides the default credential source.

### 3. Plaintext CSV credentials

If you accept the security tradeoff, you can store `GuestUser` and `GuestPassword` in the CSV.

This is supported, but **credential files are strongly preferred**.

### Credential precedence

The fleet runner resolves credentials in this order:

1. `AltCredFile` in the CSV row
2. default credential file for the detected OS (`-WindowsCredentialFile` / `-LinuxCredentialFile`)
3. global credential file if used
4. `GuestUser` and `GuestPassword` from the CSV

---

## Cloud Proxy hostname / FQDN logic

If you provide `-CloudProxyFqdn`, that value is used directly.

If you omit it, the fleet runner:

1. queries the Cloud Proxy VM through VMware Tools guest metadata
2. uses the guest-reported hostname/FQDN where available
3. falls back to `-CloudProxyVmName` if guest hostname data is not available

This avoids assuming a fixed DNS suffix and makes the toolkit portable across environments such as `devops.local` and others.

---

## Report examples

Fleet results can be rendered into the dashboard-style report with `New-VcfOpsTelegrafHtmlReport.ps1`.

![Fleet report example](Images/Example-Fleet-Report.png)

The same report script can parse:

- Guest Ops fleet JSON
- ~~vCenter fleet JSON~~ :Deprecated script
- compatible CSV summary files

---

## Help built into the scripts

The key scripts now support:

- `-h` or `-Help`
- `-Full`
- `-Examples`

Examples:

```powershell
.\Invoke-VcfOpsFleetGuestOps.ps1 -h
.\Invoke-VcfOpsFleetGuestOps.ps1 -Full
.\Invoke-VcfOpsFleetGuestOps.ps1 -Examples
```

```powershell
.\New-VcfOpsTelegrafHtmlReport.ps1 -h
.\Save-VcfOpsTelegrafCredential.ps1 -Examples
.\Test-VCenterGuestOpsForTelegraf.ps1 -Full
```

---

## Security notes

- DPAPI-protected credential files created with `Save-VcfOpsTelegrafCredential.ps1` are tied to the current Windows user on the current machine
- Plaintext CSV passwords are supported for flexibility, but they are a deliberate security compromise
- Use separate credential files where different Windows and Linux credential sets are required
- Use `AltCredFile` for targeted exceptions rather than overloading the default credential files

---

## Requirements

Typical requirements include:

- Windows administration workstation
- PowerShell 7 or Windows PowerShell as required by your environment
- VMware PowerCLI
- network reachability to vCenter
- sufficient vCenter and Guest Operations privileges
- VMware Tools running in the target guests

---

## Typical use cases

- validate whether a Telegraf deployment issue is really Guest Operations, not Telegraf itself
- prove Cloud Proxy connectivity from the guest and from the Cloud Proxy appliance
- identify DNS or TLS trust problems affecting bootstrap delivery
- generate HTML evidence for firewall, certificate, platform, and support teams
- test a mixed Windows/Linux estate from one CSV-driven workflow

---

## License

Released under the MIT License. See [`LICENSE`](LICENSE).
