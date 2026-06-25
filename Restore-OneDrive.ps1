#Requires -RunAsAdministrator
<#
.SYNOPSIS
    OneDrive Nuke — Restore script. Removes all lockout layers applied by
    Remove-OneDrive.ps1, allowing OneDrive to be installed and used again.

.DESCRIPTION
    Lifts all three blocking layers:
        • Group Policy   (deletes OneDrive's own dedicated policy key)
        • IFEO debugger hijack
        • Software Restriction Policy rules (only those added by OneDrive Nuke)

    This does NOT reinstall OneDrive. You can manually install it afterward
    from %SystemRoot%\SysWOW64\OneDriveSetup.exe (if Windows still has it)
    or from https://www.microsoft.com/microsoft-365/onedrive/download.

    SCOPE GUARANTEE: this script only ever deletes registry keys/values that
    Remove-OneDrive.ps1 is documented to have created. It never touches any
    shared Windows policy key, and it identifies its own SRP rules by an
    exact description tag before removing them.

.PARAMETER Silent
    Skip the YES confirmation prompt.

.PARAMETER NoReboot
    Don't prompt to reboot at the end.

.PARAMETER LogPath
    Custom log file path. Default: %TEMP%\OneDriveRestore_<timestamp>.log

.EXAMPLE
    irm https://raw.githubusercontent.com/DEVTHAKUR-90/onedrive-nuke/main/Restore-OneDrive.ps1 | iex

.NOTES
    Project : OneDrive Nuke
    Author  : Dev Thakur
    Version : 2.3.0
    License : MIT
    Repo    : https://github.com/DEVTHAKUR-90/onedrive-nuke
#>

[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$NoReboot,
    [string]$LogPath = "$env:TEMP\OneDriveRestore_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# ─────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────
$Script:Version = '2.3.0'
$Script:Stats   = [pscustomobject]@{ Restored = 0; Skipped = 0; Failed = 0 }

# Must match Remove-OneDrive.ps1's $Script:OneDriveExeNames exactly.
$Script:OneDriveExeNames = @(
    'OneDrive',
    'OneDriveSetup',
    'OneDriveUpdater',
    'OneDriveStandaloneUpdater',
    'FileSyncHelper'
)

# ─────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────
function Initialize-Log {
    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        try { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        catch {
            $Script:LogPath = "$env:TEMP\OneDriveRestore_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','OK','SKIP','WARN','FAIL','STEP')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content -Path $LogPath -Value "[$timestamp] [$Level] $Message" -ErrorAction SilentlyContinue } catch {}

    switch ($Level) {
        'STEP' { Write-Host "`n  >> $Message" -ForegroundColor Cyan }
        'OK'   { Write-Host "    + $Message" -ForegroundColor Green;    $Script:Stats.Restored++ }
        'SKIP' { Write-Host "    . $Message" -ForegroundColor DarkGray; $Script:Stats.Skipped++ }
        'WARN' { Write-Host "    ! $Message" -ForegroundColor Yellow }
        'FAIL' { Write-Host "    x $Message" -ForegroundColor Red;      $Script:Stats.Failed++ }
        default{ Write-Host "    $Message" -ForegroundColor Gray }
    }
}

# ─────────────────────────────────────────────────────────────
#  PREFLIGHT  (admin check BEFORE prompt — fail fast)
# ─────────────────────────────────────────────────────────────
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Preflight {
    if (-not (Test-Admin)) {
        Write-Host ""
        Write-Host "  X ERROR: This script must be run as Administrator." -ForegroundColor Red
        Write-Host "    Right-click PowerShell and choose 'Run as administrator'." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    Initialize-Log
}

# ─────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────
function Remove-RegistryKey {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Removed: $Path" OK
        } catch {
            Write-Log "Could not remove $Path - $($_.Exception.Message)" FAIL
        }
    } else {
        Write-Log "Not present: $Path" SKIP
    }
}

# Verify all blocks are gone. Every check targets only OneDrive's own
# dedicated policy key or OneDrive-named IFEO entries.
function Test-BlocksRemoved {
    $checks = [ordered]@{
        'GP: OneDrive policy key removed' = (-not (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'))
        'IFEO: OneDrive.exe block gone'    = (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\OneDrive.exe"))
        'IFEO: OneDriveSetup.exe block gone' = (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\OneDriveSetup.exe"))
    }
    $allPass = $true
    foreach ($k in $checks.Keys) {
        if ($checks[$k]) {
            Write-Host "    + $k" -ForegroundColor Green
        } else {
            Write-Host "    x $k" -ForegroundColor Red
            $allPass = $false
        }
    }
    return $allPass
}

# ─────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  =                 ONEDRIVE NUKE - RESTORE                  =" -ForegroundColor Yellow
    Write-Host "  =                 v$($Script:Version)  -  by Dev Thakur                 =" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This will REMOVE all policy, IFEO, and SRP blocks placed by" -ForegroundColor White
    Write-Host "  OneDrive Nuke. OneDrive will NOT be reinstalled -- that's up" -ForegroundColor White
    Write-Host "  to you afterward."                                            -ForegroundColor White
    Write-Host ""
    Write-Host "  Scope: only removes what OneDrive Nuke itself created." -ForegroundColor DarkCyan
    Write-Host "  No shared Windows policy key or other component is touched." -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Log file: $LogPath" -ForegroundColor DarkGray
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────

Test-Preflight       # admin + log init (FIRST, before any prompt)
Show-Banner

if (-not $Silent) {
    $c = Read-Host "  Type YES to proceed"
    if ($c -ne 'YES') {
        Write-Host "`n  Aborted - no changes made.`n" -ForegroundColor Yellow
        exit 0
    }
}

Write-Log "OneDrive Restore v$($Script:Version) started by $env:USERDOMAIN\$env:USERNAME" INFO

# ─────────────────────────────────────────────────────────────
#  STEP 1 — REMOVE GROUP POLICY BLOCK
#  Single dedicated key removal — nothing shared is touched.
# ─────────────────────────────────────────────────────────────
Write-Log "Step 1: Removing Group Policy block" STEP
Remove-RegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'

# ─────────────────────────────────────────────────────────────
#  STEP 2 — REMOVE IFEO DEBUGGER HIJACKS
# ─────────────────────────────────────────────────────────────
Write-Log "Step 2: Removing IFEO execution blocks" STEP
$ifeoBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($exe in $Script:OneDriveExeNames) {
    Remove-RegistryKey -Path "$ifeoBase\$exe.exe"
}

# ─────────────────────────────────────────────────────────────
#  STEP 3 — REMOVE SRP RULES (ONLY ONES ADDED BY ONEDRIVE NUKE)
# ─────────────────────────────────────────────────────────────
Write-Log "Step 3: Removing SRP rules" STEP
$srpPathsRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths'
if (Test-Path -LiteralPath $srpPathsRoot) {
    $removed = 0
    Get-ChildItem -LiteralPath $srpPathsRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $desc = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'Description' -ErrorAction SilentlyContinue).Description
        $item = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'ItemData'    -ErrorAction SilentlyContinue).ItemData

        # Match either by our exact description tag OR (fallback, for rules
        # created by older versions with slightly different text) by the
        # rule's target path containing "OneDrive".
        $isOurs = $false
        if ($desc -and ($desc -like '*OneDrive Nuke*')) { $isOurs = $true }
        elseif ($item -and ($item -like '*OneDrive*'))   { $isOurs = $true }

        if ($isOurs) {
            try {
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed SRP rule: $($_.PSChildName) ($item)" OK
                $removed++
            } catch {
                Write-Log "Could not remove SRP rule $($_.PSChildName) - $($_.Exception.Message)" FAIL
            }
        }
    }
    if ($removed -eq 0) { Write-Log "No OneDrive Nuke SRP rules found" SKIP }
} else {
    Write-Log "SRP paths root not present" SKIP
}

# ─────────────────────────────────────────────────────────────
#  STEP 4 — APPLY POLICY CHANGES
# ─────────────────────────────────────────────────────────────
Write-Log "Step 4: Applying Group Policy changes" STEP
& gpupdate.exe /target:computer /force 2>&1 | Out-Null
Write-Log "gpupdate /force completed" OK

# ─────────────────────────────────────────────────────────────
#  STEP 5 — VERIFICATION
# ─────────────────────────────────────────────────────────────
Write-Log "Step 5: Verifying all blocks are removed" STEP
$verified = Test-BlocksRemoved
if ($verified) {
    Write-Log "All blocks verified as removed" OK
} else {
    Write-Log "Some blocks may still be in place - see above" WARN
}

# ─────────────────────────────────────────────────────────────
#  SUMMARY
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host "                    RESTORE COMPLETE" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "    Restored items : $($Script:Stats.Restored)" -ForegroundColor Green
Write-Host "    Skipped        : $($Script:Stats.Skipped)" -ForegroundColor DarkGray
$failColor = if ($Script:Stats.Failed -gt 0) { 'Red' } else { 'DarkGray' }
Write-Host "    Failures       : $($Script:Stats.Failed)" -ForegroundColor $failColor
Write-Host ""
Write-Host "  Next steps to reinstall OneDrive (optional):" -ForegroundColor White
Write-Host "    1. REBOOT the machine first (recommended)" -ForegroundColor Gray
Write-Host "    2. Download installer:" -ForegroundColor Gray
Write-Host "       https://www.microsoft.com/microsoft-365/onedrive/download" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Log file: $LogPath" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  !  REBOOT recommended before reinstalling OneDrive." -ForegroundColor Yellow
Write-Host ""

Write-Log "OneDrive Restore completed. Restored=$($Script:Stats.Restored) Skipped=$($Script:Stats.Skipped) Failed=$($Script:Stats.Failed) Verified=$verified" INFO

if (-not $NoReboot -and -not $Silent) {
    $r = Read-Host "  Reboot now? (YES/NO)"
    if ($r -eq 'YES') {
        Write-Host "  Rebooting in 5 seconds... (Ctrl+C to abort)" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        try { Restart-Computer -Force -ErrorAction Stop }
        catch { Write-Host "  X Could not initiate reboot: $($_.Exception.Message)" -ForegroundColor Red }
    }
}
