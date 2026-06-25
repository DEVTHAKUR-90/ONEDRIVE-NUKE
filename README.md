<div align="center">

```
╔══════════════════════════════════════════════════════════════╗
║     ###   #   #  #####  ####   ####   #####  #   #  #####    ║
║    #   #  ##  #  #      #   #  #   #    #    #   #  #        ║
║    #   #  # # #  ####   #   #  ####     #    #   #  ####     ║
║    #   #  #  ##  #      #   #  #  #     #     # #   #        ║
║     ###   #   #  #####  ####   #   #  #####    #    #####    ║
║                                                              ║
║                  #   #  #   #  #   #  #####                  ║
║                  ##  #  #   #  #  #   #                      ║
║                  # # #  #   #  ###    ####                   ║
║                  #  ##  #   #  #  #   #                      ║
║                  #   #   ###   #   #  #####                  ║
╚══════════════════════════════════════════════════════════════╝
```

### Complete OneDrive removal + permanent installation lockout for Windows 10 & 11
**...and nothing else. Ever.**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![License: MIT](https://img.shields.io/badge/License-MIT-3DA639.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.3.0-orange.svg)](#)
[![Scope: OneDrive Only](https://img.shields.io/badge/scope-OneDrive%20only-critical.svg)](#-scope-guarantee--what-it-will-never-touch)

</div>

---

## ⚡ One-Line Install

> Open **PowerShell as Administrator** and paste:

```powershell
irm https://raw.githubusercontent.com/DEVTHAKUR-90/onedrive-nuke/main/Remove-OneDrive.ps1 | iex
```

### One-liner with parameters

Plain `irm | iex` cannot pass arguments. Use this pattern when you need `-Silent` or `-NoReboot`:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/DEVTHAKUR-90/onedrive-nuke/main/Remove-OneDrive.ps1))) -Silent -NoReboot
```

---

## 📖 Table of Contents

- [What It Does](#-what-it-does)
- [Scope Guarantee — What It Will NEVER Touch](#-scope-guarantee--what-it-will-never-touch)
- [Why Three Layers of Blocking?](#-why-three-layers-of-blocking)
- [Installation](#-installation)
- [Usage](#-usage)
- [What Gets Removed](#-what-gets-removed)
- [How the Lockout Works](#-how-the-lockout-works)
- [Reversing the Changes](#-reversing-the-changes)
- [Testing Before You Push](#-testing-before-you-push)
- [Troubleshooting](#-troubleshooting)
- [Security Notes](#-security-notes)
- [License](#-license)

---

## 🎯 What It Does

OneDrive Nuke performs a **complete, machine-wide removal** of Microsoft OneDrive and applies **three independent layers of policy blocks** to prevent it from ever reinstalling — without touching anything that isn't OneDrive.

```
┌──────────────────────────────┬──────────────────────────────┐
│        PHASE 1: REMOVAL       │       PHASE 2: LOCKOUT        │
├──────────────────────────────┼──────────────────────────────┤
│  Kill processes                │  Group Policy                │
│  Run official uninstallers     │  (OneDrive's own key only)   │
│  Delete scheduled tasks        │                               │
│  Remove services               │  IFEO debugger hijack        │
│  Take ownership of EXEs        │                               │
│  Wipe per-user folders         │  Software Restriction Policy │
│  Clean every user's registry   │                               │
│  Remove shell extensions       │  Verify all blocks are live  │
│  Drop startup shortcuts        │                               │
└──────────────────────────────┴──────────────────────────────┘
```

---

## 🔒 Scope Guarantee — What It Will NEVER Touch

This is the single most important rule in the whole project: **every change is scoped to OneDrive, and only OneDrive.**

| What we touch | Why it's safe |
|----------------|----------------|
| `HKLM:\...\Policies\Microsoft\Windows\OneDrive` | This registry key is **created and owned exclusively by Microsoft for OneDrive policies.** Nothing else reads or writes it. |
| The `OneDrive` / `OneDriveSetup` **values** inside shared keys (e.g. the `Run` key) | Only that one named value is deleted — every other application's autorun entry in the same key is left alone. |
| IFEO entries for exact OneDrive exe names | A new subkey is created per exe name; no other program's IFEO entry is read, modified, or removed. |
| SRP path rules | Each rule is tagged `Description = "OneDrive Nuke - Blocked"` so `Restore-OneDrive.ps1` can find and remove only its own rules. Pre-existing enterprise SRP configuration is left completely untouched. |
| OneDrive's own CLSID `{018D5C66-4533-4307-9B53-224DE2ED1FE6}` | This CLSID belongs only to OneDrive's shell integration. No other shell extension shares it. |

**Deliberately excluded**, after a dedicated scope audit:

- ❌ `CloudContent\DisableWindowsConsumerFeatures` — also controls Windows Spotlight and lock-screen suggestions, unrelated to OneDrive. Never set.
- ❌ `Microsoft.SharePoint.exe` / `FileCoAuth.exe` — SharePoint sync and Office co-authoring, separate Microsoft 365 components. Never killed, never blocked.
- ❌ Broad `OneDrive*` folder wildcards — narrowed to the exact `OneDrive - *` pattern Microsoft actually uses, so a folder a user created themselves (e.g. `OneDriveBackup`) is never touched.

If you find anything in the source that modifies a key or kills a process not directly tied to OneDrive, that's a bug — please open an issue.

---

## 🛡 Why Three Layers of Blocking?

Microsoft re-introduces OneDrive through multiple vectors: Windows Update, feature updates, and per-user silent installs. Any single block can be bypassed — applying all three means each layer is a fallback for the others.

| Layer | What it blocks | Bypass difficulty |
|-------|------------------|---------------------|
| **Group Policy** | All official OneDrive features (file sync, KFM, libraries) | Requires GPO edit |
| **IFEO Debugger Hijack** | Any process literally named `OneDrive.exe` or `OneDriveSetup.exe`, regardless of where it's launched from | Requires admin |
| **Software Restriction Policy** | OneDrive binaries by exact, environment-expanded path | Requires admin |

---

## 🔧 Installation

### Method 1 — One-Line `irm` (Recommended)

```powershell
irm https://raw.githubusercontent.com/DEVTHAKUR-90/onedrive-nuke/main/Remove-OneDrive.ps1 | iex
```

### Method 2 — Clone & Run Locally

```powershell
git clone https://github.com/DEVTHAKUR-90/onedrive-nuke.git
cd onedrive-nuke
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Remove-OneDrive.ps1
```

### Method 3 — Silent / Automated Deployment

```powershell
.\Remove-OneDrive.ps1 -Silent -NoReboot
```

---

## 🚀 Usage

### Parameters

| Parameter | Description |
|-----------|--------------|
| `-Silent` | Skip the YES confirmation prompt (for automation) |
| `-NoReboot` | Don't prompt for a reboot at the end |
| `-LogPath <path>` | Custom log file path (default: `%TEMP%\OneDriveNuke_*.log`) |

### Example interactive session

```
  ============================================================
  =   ###   #   #  #####  ####   ####   #####  #   #  #####  =
  =  #   #  ##  #  #      #   #  #   #    #    #   #  #      =
  =  #   #  # # #  ####   #   #  ####     #    #   #  ####   =
  =  #   #  #  ##  #      #   #  #  #     #     # #   #      =
  =   ###   #   #  #####  ####   #   #  #####    #    #####  =
  =                                                          =
  =                #   #  #   #  #   #  #####                =
  =                ##  #  #   #  #  #   #                    =
  =                # # #  #   #  ###    ####                 =
  =                #  ##  #   #  #  #   #                    =
  =                #   #   ###   #   #  #####                =
  ============================================================

                v2.3.0  -  by Dev Thakur  -  MIT License
  ------------------------------------------------------------
   Complete OneDrive removal + permanent installation lockout
   Touches ONLY OneDrive. No other app, policy, or component.
  ------------------------------------------------------------

  !  This is IRREVERSIBLE without running Restore-OneDrive.ps1.
     All OneDrive files, folders, and sync history will be removed.
     OneDrive will be BLOCKED from reinstalling on this machine.

  Type YES to proceed: YES

  >> Step 1: Terminating OneDrive processes
    + Killed: OneDrive
    . No OneDrive processes were running
  >> Step 2: Running official OneDrive uninstallers
    + Uninstaller completed (exit=0): C:\Windows\SysWOW64\OneDriveSetup.exe
  ...
  >> Step 13: Verifying blocks are in place
    + GP: DisableFileSyncNGSC
    + GP: KFMBlockOptIn
    + IFEO: OneDrive.exe blocked
    + SRP: CodeIdentifiers initialized
    + All blocks verified in place
```

---

## 📦 What Gets Removed

<details>
<summary><b>Click to expand full list</b></summary>

### Processes Terminated (two passes)
- `OneDrive.exe`
- `OneDriveSetup.exe`
- `OneDriveUpdater.exe`
- `OneDriveStandaloneUpdater.exe`
- `FileSyncHelper.exe`

### Folders Removed (system-wide)
- `%ProgramFiles%\Microsoft OneDrive`
- `%ProgramFiles(x86)%\Microsoft OneDrive`
- `%ProgramData%\Microsoft OneDrive`
- `%ProgramData%\Microsoft\OneDrive`

### Folders Removed (per user)
- `%LOCALAPPDATA%\Microsoft\OneDrive`
- `%LOCALAPPDATA%\OneDrive`
- `%APPDATA%\Microsoft\OneDrive`
- `%USERPROFILE%\OneDrive`
- `%USERPROFILE%\OneDrive - Personal`
- Any folder matching the exact `OneDrive - <name>` pattern (business tenant folders)

### Protected Binaries (takeown + icacls + delete)
- `%SystemRoot%\System32\OneDriveSetup.exe`
- `%SystemRoot%\SysWOW64\OneDriveSetup.exe`

### Registry Keys Removed
- `HKLM:\SOFTWARE\Microsoft\OneDrive`
- `HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive`
- `HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}`
- `HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}`
- `HKLM:\SYSTEM\CurrentControlSet\Services\FileSyncHelper`
- `HKLM:\SYSTEM\CurrentControlSet\Services\OneDriveUpdater`
- File Explorer navigation-pane namespace entry (CLSID), HKLM and per-user
- Context menu / shell extension entries
- Same OneDrive-specific set in **every user's** `NTUSER.DAT` hive (live or offline)

### Other Removed Items
- All scheduled tasks matching `OneDrive`
- All Windows services matching `OneDrive`
- Startup shortcuts (system-wide and per user)

</details>

---

## 🔒 How the Lockout Works

### Layer 1 — Group Policy

All values are written to **one single key**, owned exclusively by OneDrive:
`HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive`

| Value | Effect |
|-------|--------|
| `DisableFileSyncNGSC = 1` | Blocks OneDrive (NextGen Sync Client) |
| `DisableFileSync = 1` | Blocks legacy sync |
| `PreventNetworkTrafficPreUserSignIn = 1` | No traffic before login |
| `DisableLibrariesDefaultSaveToOneDrive = 1` | Libraries don't default to OneDrive |
| `KFMBlockOptIn = 1` | Blocks Known Folder Move opt-in |
| `KFMBlockOptOut = 1` | Blocks KFM opt-out prompts |

### Layer 2 — IFEO Debugger Hijack

For each of the 5 OneDrive exe names, a subkey is created under `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<exe>.exe` with `Debugger = "%SystemRoot%\System32\rundll32.exe"`.

When Windows tries to launch any of these, it invokes `rundll32.exe <OneDrivePath>` instead. rundll32 tries to load the OneDrive binary as a DLL, fails immediately, and exits silently — **no window, no error dialog, no event log spam.**

### Layer 3 — Software Restriction Policy

SRP path rules mark these exact locations as **Disallowed**:

- `%SystemRoot%\System32\OneDriveSetup.exe`
- `%SystemRoot%\SysWOW64\OneDriveSetup.exe`
- `%LOCALAPPDATA%\Microsoft\OneDrive\OneDriveSetup.exe`
- `%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe`
- `%ProgramFiles%\Microsoft OneDrive\OneDriveSetup.exe`
- `%ProgramFiles(x86)%\Microsoft OneDrive\OneDriveSetup.exe`

---

## ↩ Reversing the Changes

If you want OneDrive back, run:

```powershell
irm https://raw.githubusercontent.com/DEVTHAKUR-90/onedrive-nuke/main/Restore-OneDrive.ps1 | iex
```

`Restore-OneDrive.ps1` removes all Group Policy, IFEO, and SRP blocks **that OneDrive Nuke itself created** — nothing else. It does **not** reinstall OneDrive — download it manually from:

https://www.microsoft.com/microsoft-365/onedrive/download

A reboot is recommended before reinstalling.

---

## 🧪 Testing Before You Push

Run this on a disposable system before deploying anywhere important:

1. **Use a VM or Windows Sandbox** — this script is destructive and irreversible without `Restore-OneDrive.ps1`.
2. **Syntax-check first:**
   ```powershell
   Get-Command -Syntax .\Remove-OneDrive.ps1
   ```
3. **Allow execution:**
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   ```
4. **Run it, confirm with `YES`, and watch for any red `x` (FAIL) lines.**
5. **Check the log:**
   ```powershell
   Get-Content "$env:TEMP\OneDriveNuke_*.log" | Select-Object -Last 50
   ```
6. **Confirm the lockout works:**
   ```powershell
   Start-Process "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"  # should fail silently
   ```
7. **Run `Restore-OneDrive.ps1` and confirm the policy key is gone:**
   ```powershell
   Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'   # should be False
   ```

---

## 🩺 Troubleshooting

<details>
<summary><b>"Cannot run script. Execution policy..."</b></summary>

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```
Then re-run the script.
</details>

<details>
<summary><b>"Could not load hive for user..."</b></summary>

The user is currently logged in and their hive is already mapped under `HKEY_USERS`. The script automatically detects this via the `ProfileList` registry mapping and edits the live hive instead — no action required.
</details>

<details>
<summary><b>OneDrive still appears in File Explorer after running</b></summary>

Sign out and back in, or reboot. Explorer is restarted by the script, but some shell extensions only re-read at logon.
</details>

<details>
<summary><b>"Failures" count in summary > 0</b></summary>

Check `%TEMP%\OneDriveNuke_<timestamp>.log`. Most common cause: a file locked by another process, or a non-elevated session. Reboot and re-run — the script is fully idempotent.
</details>

<details>
<summary><b>I want OneDrive back</b></summary>

Run `Restore-OneDrive.ps1` — see [Reversing the Changes](#-reversing-the-changes).
</details>

---

## 🔐 Security Notes

- Requires **Administrator privileges** to modify HKLM, take ownership of protected system files, and install policies.
- Every registry write/delete is scoped to OneDrive's own dedicated key, an OneDrive-named value, or an OneDrive-named IFEO/SRP entry — see [Scope Guarantee](#-scope-guarantee--what-it-will-never-touch).
- No data leaves the machine. Logs are local-only at `%TEMP%`.
- The `irm | iex` pattern runs a script directly from the internet. **Always read the source first**, including this one.
- The IFEO debugger hijack uses `rundll32.exe`, a Microsoft-signed system binary present on every Windows install since XP.
- All ACL operations use the locale-independent SID `S-1-5-32-544` for Administrators, so the script works correctly on non-English Windows installs.

---

## 📁 Project Structure

```
onedrive-nuke/
├── Remove-OneDrive.ps1     # Main removal + lockout script (13 steps)
├── Restore-OneDrive.ps1    # Reverse the policy/IFEO/SRP blocks (5 steps)
├── README.md               # This file
├── LICENSE                 # MIT License
└── .gitignore
```

---

## 📋 Requirements

- Windows 10 (21H2+) or Windows 11
- PowerShell 5.1 or higher
- Administrator privileges

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for details.

---

## 👤 Author

**Dev Thakur**

- GitHub: [@DEVTHAKUR-90](https://github.com/DEVTHAKUR-90)
- Repo: [onedrive-nuke](https://github.com/DEVTHAKUR-90/onedrive-nuke)

---

<div align="center">

**⭐ If this helped you reclaim your machine, give it a star!**

</div>
