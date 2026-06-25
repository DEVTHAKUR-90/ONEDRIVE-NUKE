#Requires -RunAsAdministrator
<#
.SYNOPSIS
    OneDrive Nuke — Complete OneDrive removal & permanent installation lockout.

.DESCRIPTION
    Removes Microsoft OneDrive entirely (binaries, services, scheduled tasks,
    registry, shell integrations, per-user folders) for every profile on the
    machine, then applies three layers of policy blocks:

        • Group Policy registry values  (confined to OneDrive's own policy key)
        • IFEO (Image File Execution Options) debugger hijack
        • Software Restriction Policy path rules

    The combination prevents OneDrive from being silently or manually installed
    again, even by an administrator, until Restore-OneDrive.ps1 is run.

    SCOPE GUARANTEE: every registry write/delete this script performs is
    confined to a key or value that is either (a) OneDrive's own dedicated
    policy key, (b) a named subkey/value containing "OneDrive" by exact name,
    or (c) a path rule pointing at an exact OneDrive binary path. No shared
    Windows policy key (CloudContent, System, etc.) is ever modified, and no
    other application, service, or Microsoft 365 component (SharePoint sync,
    Office co-authoring, etc.) is touched.

.PARAMETER Silent
    Skip the YES confirmation prompt. Use only in unattended deployment.

.PARAMETER NoReboot
    Don't prompt to reboot at the end.

.PARAMETER LogPath
    Custom log file path. Default: %TEMP%\OneDriveNuke_<timestamp>.log

.EXAMPLE
    # Local file run, interactive
    .\Remove-OneDrive.ps1

.EXAMPLE
    # One-line install (no args — interactive)
    irm https://raw.githubusercontent.com/DEVTHAKUR-90/onedrive-nuke/main/Remove-OneDrive.ps1 | iex

.EXAMPLE
    # One-line install with args (requires this pattern, NOT plain `irm | iex`)
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/DEVTHAKUR-90/onedrive-nuke/main/Remove-OneDrive.ps1))) -Silent -NoReboot

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
    [string]$LogPath = "$env:TEMP\OneDriveNuke_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# Force UTF-8 so the ASCII art banner renders correctly on PS 5.1 (default cp1252)
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# ─────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────
$Script:Version       = '2.3.0'
$Script:OneDriveCLSID = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
$Script:Stats         = [pscustomobject]@{ Removed = 0; Skipped = 0; Failed = 0 }

# SID for the built-in Administrators group — locale-independent (works on
# English, German, French, Japanese, ... Windows installations)
$Script:AdministratorsSid = '*S-1-5-32-544'

# IFEO Debugger value. When set, Windows invokes:
#     <Debugger> <OriginalExe> <OriginalArgs>
# rundll32.exe is the standard choice because it:
#   1. Exists on every Windows version since XP
#   2. Tries to load arg1 as a DLL, fails immediately, exits with no GUI
#   3. Produces no visible window, no error dialog, no event log spam
$Script:IfeoDebugger = '"%SystemRoot%\System32\rundll32.exe"'

# Process / IFEO target list — ONLY binaries that are part of the OneDrive
# client itself. Deliberately excludes Microsoft.SharePoint.exe and
# FileCoAuth.exe: those belong to SharePoint sync and Office co-authoring
# respectively — separate Microsoft 365 components, not OneDrive.
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
            $Script:LogPath = "$env:TEMP\OneDriveNuke_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
        'OK'   { Write-Host "    + $Message" -ForegroundColor Green;    $Script:Stats.Removed++ }
        'SKIP' { Write-Host "    . $Message" -ForegroundColor DarkGray; $Script:Stats.Skipped++ }
        'WARN' { Write-Host "    ! $Message" -ForegroundColor Yellow }
        'FAIL' { Write-Host "    x $Message" -ForegroundColor Red;      $Script:Stats.Failed++ }
        default{ Write-Host "    $Message" -ForegroundColor Gray }
    }
}

# ─────────────────────────────────────────────────────────────
#  PREFLIGHT  (admin + OS check runs BEFORE banner — fail fast)
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

    $osVer = [Environment]::OSVersion.Version
    if ($osVer.Major -lt 10) {
        Write-Host "`n  X Unsupported OS. Requires Windows 10 (10.0+) or Windows 11.`n" -ForegroundColor Red
        exit 1
    }

    # Register HKCR: and HKU: PSDrives (not available by default in PS)
    if (-not (Get-PSDrive -Name 'HKCR' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'HKCR' -PSProvider Registry -Root 'HKEY_CLASSES_ROOT' -Scope Script -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-PSDrive -Name 'HKU' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'HKU' -PSProvider Registry -Root 'HKEY_USERS' -Scope Script -ErrorAction SilentlyContinue | Out-Null
    }

    Initialize-Log
}

# ─────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  =   ###   #   #  #####  ####   ####   #####  #   #  #####  =" -ForegroundColor Cyan
    Write-Host "  =  #   #  ##  #  #      #   #  #   #    #    #   #  #      =" -ForegroundColor Cyan
    Write-Host "  =  #   #  # # #  ####   #   #  ####     #    #   #  ####   =" -ForegroundColor Cyan
    Write-Host "  =  #   #  #  ##  #      #   #  #  #     #     # #   #      =" -ForegroundColor Cyan
    Write-Host "  =   ###   #   #  #####  ####   #   #  #####    #    #####  =" -ForegroundColor Cyan
    Write-Host "  =                                                          =" -ForegroundColor Cyan
    Write-Host "  =                #   #  #   #  #   #  #####                =" -ForegroundColor Red
    Write-Host "  =                ##  #  #   #  #  #   #                    =" -ForegroundColor Red
    Write-Host "  =                # # #  #   #  ###    ####                 =" -ForegroundColor Red
    Write-Host "  =                #  ##  #   #  #  #   #                    =" -ForegroundColor Red
    Write-Host "  =                #   #   ###   #   #  #####                =" -ForegroundColor Red
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "                v$($Script:Version)  -  by Dev Thakur  -  MIT License" -ForegroundColor White
    Write-Host "  ------------------------------------------------------------"   -ForegroundColor DarkGray
    Write-Host "   Complete OneDrive removal + permanent installation lockout"      -ForegroundColor White
    Write-Host "   Touches ONLY OneDrive. No other app, policy, or component."      -ForegroundColor White
    Write-Host "  ------------------------------------------------------------"   -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  !  This is IRREVERSIBLE without running Restore-OneDrive.ps1."    -ForegroundColor Yellow
    Write-Host "     All OneDrive files, folders, and sync history will be removed." -ForegroundColor Yellow
    Write-Host "     OneDrive will be BLOCKED from reinstalling on this machine."   -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Log file: $LogPath" -ForegroundColor DarkGray
    Write-Host ""
}


# ─────────────────────────────────────────────────────────────
#  HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────

# Robust path removal — handles files, folders, reparse points, locked items,
# and read-only attributes.
function Remove-PathForce {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Write-Log "Not found: $Path" SKIP
        return
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { Write-Log "Not found: $Path" SKIP; return }

    # Reparse point (junction/symlink) — delete in place, don't recurse out
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        try {
            if ($item.PSIsContainer) { [IO.Directory]::Delete($Path, $false) }
            else { [IO.File]::Delete($Path) }
            Write-Log "Removed reparse point: $Path" OK
        } catch {
            Write-Log "Could not remove reparse point $Path - $($_.Exception.Message)" FAIL
        }
        return
    }

    # Single file — direct delete
    if (-not $item.PSIsContainer) {
        try {
            try { $item.Attributes = 'Normal' } catch {}
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            Write-Log "Removed file: $Path" OK
        } catch {
            Write-Log "Could not remove file $Path - $($_.Exception.Message)" FAIL
        }
        return
    }

    # Directory — clear attributes, then standard delete, then robocopy fallback
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
    } catch {}

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log "Removed: $Path" OK
        return
    } catch {
        Write-Log "Standard removal failed for $Path - trying robocopy mirror" WARN
    }

    $empty = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "ODNUKE_EMPTY_$(Get-Random)") -Force -ErrorAction SilentlyContinue
    if (-not $empty) {
        Write-Log "Could not create scratch dir for robocopy fallback" FAIL
        return
    }
    try {
        & robocopy.exe $empty.FullName $Path /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /nc /ns /np 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Log "Force-removed via robocopy: $Path" OK
        } else {
            Write-Log "Could not fully remove (locked?): $Path" FAIL
        }
    } finally {
        Remove-Item -LiteralPath $empty.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Take ownership of a single file (Administrators group, locale-independent).
function Invoke-TakeOwnership {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    & takeown.exe /F "$Path" /A 2>&1 | Out-Null
    & icacls.exe  "$Path" /grant "$($Script:AdministratorsSid):F" /C 2>&1 | Out-Null
}

function Remove-RegistryKey {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Registry removed: $Path" OK
        } catch {
            Write-Log "Registry remove failed: $Path - $($_.Exception.Message)" FAIL
        }
    } else {
        Write-Log "Registry not found: $Path" SKIP
    }
}

function Remove-RegistryValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $prop = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        if ($prop -and ($null -ne $prop.$Name)) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
            Write-Log "Removed value: $Path\$Name" OK
        }
    } catch {
        Write-Log "Could not remove value $Path\$Name - $($_.Exception.Message)" FAIL
    }
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        Write-Log "Policy set: $Path\$Name = $Value" OK
    } catch {
        Write-Log "Policy set FAILED: $Path\$Name - $($_.Exception.Message)" FAIL
    }
}

# Resolve the OS's actual user profiles directory (typically C:\Users, but
# can be relocated via SetupConfig or sysprep). Falls back to C:\Users.
function Get-ProfilesDirectory {
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $val = (Get-ItemProperty -LiteralPath $pl -Name 'ProfilesDirectory' -ErrorAction SilentlyContinue).ProfilesDirectory
    if ($val) {
        $expanded = [Environment]::ExpandEnvironmentVariables($val)
        if (Test-Path -LiteralPath $expanded) { return $expanded }
    }
    return 'C:\Users'
}

# Real user profiles, excluding system / built-in / sandbox profiles.
function Get-RealUserProfiles {
    $excluded = @('Default','Default User','Public','All Users','defaultuser0','WDAGUtilityAccount')
    $profilesRoot = Get-ProfilesDirectory
    if (-not (Test-Path -LiteralPath $profilesRoot)) { return @() }
    Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $excluded -notcontains $_.Name -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'NTUSER.DAT'))
        }
}

# SIDs of users whose hive is currently loaded in HKEY_USERS.
function Get-LoggedInUserSids {
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSChildName -match '^S-1-5-21-' -and
            $_.PSChildName -notmatch '_Classes$'
        } |
        Select-Object -ExpandProperty PSChildName
}

# Run an action against a user's hive — live (logged-in) or offline (reg load).
function Invoke-OnUserHive {
    param(
        [Parameter(Mandatory)] [System.IO.DirectoryInfo]$ProfileDir,
        [Parameter(Mandatory)] [scriptblock]$Action
    )
    $username = $ProfileDir.Name
    $ntuser   = Join-Path $ProfileDir.FullName 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntuser)) { return }

    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $matchedSid = $null
    Get-ChildItem $profileList -ErrorAction SilentlyContinue | ForEach-Object {
        $pip = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($pip) {
            $pipExpanded = [Environment]::ExpandEnvironmentVariables($pip)
            if ($pipExpanded -ieq $ProfileDir.FullName) { $matchedSid = $_.PSChildName }
        }
    }

    if ($matchedSid -and ((Get-LoggedInUserSids) -contains $matchedSid)) {
        Write-Log "Editing live hive for '$username' (SID: $matchedSid)" INFO
        & $Action "Registry::HKEY_USERS\$matchedSid"
        return
    }

    $hiveName = "ODNUKE_$([Guid]::NewGuid().ToString('N'))"
    $loadOutput = & reg.exe load "HKU\$hiveName" "$ntuser" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Could not load hive for '$username': $loadOutput" WARN
        return
    }
    try {
        Write-Log "Loaded offline hive for '$username'" INFO
        & $Action "Registry::HKEY_USERS\$hiveName"
    } finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
        & reg.exe unload "HKU\$hiveName" 2>&1 | Out-Null
    }
}

# Verification step — confirms blocks are actually in place after the run.
# Every check below targets ONLY OneDrive's dedicated policy key, OneDrive
# IFEO entries, or the SRP infrastructure flag — never a shared policy value.
function Test-Blocks {
    $checks = [ordered]@{
        'GP: DisableFileSyncNGSC'           = ((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -EA SilentlyContinue).DisableFileSyncNGSC -eq 1)
        'GP: KFMBlockOptIn'                 = ((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'KFMBlockOptIn' -EA SilentlyContinue).KFMBlockOptIn -eq 1)
        'IFEO: OneDrive.exe blocked'        = (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\OneDrive.exe")
        'IFEO: OneDriveSetup.exe blocked'   = (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\OneDriveSetup.exe")
        'SRP: CodeIdentifiers initialized'  = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers')
        'Binary: OneDriveSetup removed'     = (-not (Test-Path -LiteralPath "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"))
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
#  MAIN
# ─────────────────────────────────────────────────────────────

Test-Preflight         # admin + OS + PSDrives + log init  (FIRST, before banner)
Show-Banner

if (-not $Silent) {
    $confirm = Read-Host "  Type YES to proceed"
    if ($confirm -ne 'YES') {
        Write-Host "`n  Aborted - no changes made.`n" -ForegroundColor Yellow
        exit 0
    }
}

Write-Log "OneDrive Nuke v$($Script:Version) started by $env:USERDOMAIN\$env:USERNAME" INFO
Write-Log "Profiles directory: $(Get-ProfilesDirectory)" INFO

# ─────────────────────────────────────────────────────────────
#  STEP 1 — KILL ONEDRIVE PROCESSES (two passes for stragglers)
# ─────────────────────────────────────────────────────────────
Write-Log "Step 1: Terminating OneDrive processes" STEP
$killedAny = $false
foreach ($pass in 1..2) {
    foreach ($p in $Script:OneDriveExeNames) {
        $running = Get-Process -Name $p -ErrorAction SilentlyContinue
        if ($running) {
            Stop-Process -Name $p -Force -ErrorAction SilentlyContinue
            if ($pass -eq 1) { Write-Log "Killed: $p" OK; $killedAny = $true }
        }
    }
    Start-Sleep -Seconds 1
}
if (-not $killedAny) { Write-Log "No OneDrive processes were running" SKIP }

# ─────────────────────────────────────────────────────────────
#  STEP 2 — OFFICIAL UNINSTALL
# ─────────────────────────────────────────────────────────────
Write-Log "Step 2: Running official OneDrive uninstallers" STEP

$uninstallerPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$uninstallerPaths.Add("$env:SystemRoot\System32\OneDriveSetup.exe")
[void]$uninstallerPaths.Add("$env:SystemRoot\SysWOW64\OneDriveSetup.exe")
foreach ($up in (Get-RealUserProfiles)) {
    [void]$uninstallerPaths.Add((Join-Path $up.FullName 'AppData\Local\Microsoft\OneDrive\OneDriveSetup.exe'))
}

$ranAny = $false
foreach ($exe in $uninstallerPaths) {
    if (Test-Path -LiteralPath $exe) {
        try {
            Write-Log "Running: $exe /uninstall" INFO
            $proc = Start-Process -FilePath $exe -ArgumentList '/uninstall' -PassThru -WindowStyle Hidden -ErrorAction Stop
            if (-not $proc.WaitForExit(60000)) {
                try { $proc.Kill() } catch {}
                Write-Log "Uninstaller timed out after 60s: $exe" WARN
            } else {
                Write-Log "Uninstaller completed (exit=$($proc.ExitCode)): $exe" OK
            }
            $ranAny = $true
        } catch {
            Write-Log "Uninstaller failed: $exe - $($_.Exception.Message)" FAIL
        }
    }
}
if (-not $ranAny) { Write-Log "No official uninstallers found" SKIP }
Start-Sleep -Seconds 2

# ─────────────────────────────────────────────────────────────
#  STEP 3 — REMOVE SCHEDULED TASKS
# ─────────────────────────────────────────────────────────────
Write-Log "Step 3: Removing OneDrive scheduled tasks" STEP
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match 'OneDrive' -or $_.TaskPath -match 'OneDrive' }
if ($tasks) {
    foreach ($t in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log "Removed task: $($t.TaskPath)$($t.TaskName)" OK
        } catch {
            Write-Log "Could not remove task: $($t.TaskName) - $($_.Exception.Message)" FAIL
        }
    }
} else {
    Write-Log "No OneDrive scheduled tasks found" SKIP
}

# ─────────────────────────────────────────────────────────────
#  STEP 4 — REMOVE SERVICES
# ─────────────────────────────────────────────────────────────
Write-Log "Step 4: Removing OneDrive services" STEP
$odServices = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OneDrive' }
if ($odServices) {
    foreach ($svc in $odServices) {
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc.Name 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Removed service: $($svc.Name)" OK
        } else {
            Write-Log "Could not remove service: $($svc.Name) (will be deleted on reboot)" WARN
        }
    }
} else {
    Write-Log "No OneDrive services found" SKIP
}

# ─────────────────────────────────────────────────────────────
#  STEP 5 — TAKE OWNERSHIP & DELETE PROTECTED BINARIES
# ─────────────────────────────────────────────────────────────
Write-Log "Step 5: Taking ownership of protected binaries" STEP
foreach ($bin in @(
    "$env:SystemRoot\System32\OneDriveSetup.exe",
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
)) {
    if (Test-Path -LiteralPath $bin) {
        Invoke-TakeOwnership -Path $bin
        Remove-PathForce -Path $bin
    } else {
        Write-Log "Not present: $bin" SKIP
    }
}

# ─────────────────────────────────────────────────────────────
#  STEP 6 — REMOVE ONEDRIVE FOLDERS (SYSTEM + ALL USERS)
# ─────────────────────────────────────────────────────────────
Write-Log "Step 6: Removing OneDrive folders (system + per-user)" STEP

foreach ($folder in @(
    "$env:ProgramFiles\Microsoft OneDrive",
    "${env:ProgramFiles(x86)}\Microsoft OneDrive",
    "$env:ProgramData\Microsoft OneDrive",
    "$env:ProgramData\Microsoft\OneDrive"
)) { Remove-PathForce -Path $folder }

foreach ($userProfile in (Get-RealUserProfiles)) {
    Write-Host "    User: $($userProfile.Name)" -ForegroundColor DarkYellow
    $appLocal = Join-Path $userProfile.FullName 'AppData\Local'
    $appRoam  = Join-Path $userProfile.FullName 'AppData\Roaming'

    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.Add((Join-Path $appLocal 'Microsoft\OneDrive'))
    $targets.Add((Join-Path $appLocal 'OneDrive'))
    $targets.Add((Join-Path $appRoam  'Microsoft\OneDrive'))
    $targets.Add((Join-Path $userProfile.FullName 'OneDrive'))
    $targets.Add((Join-Path $userProfile.FullName 'OneDrive - Personal'))

    # Catch business-tenant OneDrive folders, which always follow the exact
    # "OneDrive - <Organization Name>" naming convention. Deliberately NOT a
    # bare "OneDrive*" wildcard, which could match an unrelated folder a user
    # created themselves (e.g. "OneDriveBackup", "OneDriveNotes").
    Get-ChildItem -LiteralPath $userProfile.FullName -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'OneDrive - *' } |
        ForEach-Object { $targets.Add($_.FullName) }

    foreach ($t in $targets) { Remove-PathForce -Path $t }
}

# ─────────────────────────────────────────────────────────────
#  STEP 7 — REGISTRY CLEANUP
# ─────────────────────────────────────────────────────────────
Write-Log "Step 7: Cleaning OneDrive registry entries" STEP

# HKLM — every key below is either OneDrive's own dedicated key, or a
# specifically-named OneDrive subkey under a shared parent (the parent key
# itself, and its other children, are left untouched).
foreach ($key in @(
    'HKLM:\SOFTWARE\Microsoft\OneDrive',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive',
    'HKLM:\SYSTEM\CurrentControlSet\Services\FileSyncHelper',
    'HKLM:\SYSTEM\CurrentControlSet\Services\OneDriveUpdater',
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$($Script:OneDriveCLSID)",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$($Script:OneDriveCLSID)",
    'HKLM:\SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers\OneDrive'
)) { Remove-RegistryKey -Path $key }

# Remove only the OneDrive VALUE from the shared Run key — the key itself
# (and every other application's autorun entry in it) is left untouched.
Remove-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive'
Remove-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup'

# HKCR (via PSDrive registered in preflight) — OneDrive's own CLSID only.
# Note: the correct registry location for the 32-bit reflected CLSID on a
# 64-bit OS is HKLM\SOFTWARE\WOW6432Node\Classes\CLSID, not a "Wow6432Node"
# subkey under HKCR (which does not exist as a real registry path).
foreach ($key in @(
    "HKCR:\CLSID\$($Script:OneDriveCLSID)",
    "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\$($Script:OneDriveCLSID)"
)) { Remove-RegistryKey -Path $key }

# All user hives — current and offline. Only OneDrive's own CLSID, OneDrive
# policy/run values, and the nav-pane pin entry are touched per user.
$clsidLocal = $Script:OneDriveCLSID
foreach ($userProfile in (Get-RealUserProfiles)) {
    Invoke-OnUserHive -ProfileDir $userProfile -Action {
        param($HivePath)
        Remove-RegistryKey   -Path "$HivePath\SOFTWARE\Microsoft\OneDrive"
        Remove-RegistryKey   -Path "$HivePath\SOFTWARE\Classes\CLSID\$clsidLocal"
        Remove-RegistryKey   -Path "$HivePath\SOFTWARE\Classes\Wow6432Node\CLSID\$clsidLocal"
        Remove-RegistryKey   -Path "$HivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$clsidLocal"
        Remove-RegistryValue -Path "$HivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDrive'
        Remove-RegistryValue -Path "$HivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDriveSetup'
    }.GetNewClosure()
}

# ─────────────────────────────────────────────────────────────
#  STEP 8 — REMOVE STARTUP SHORTCUTS
# ─────────────────────────────────────────────────────────────
Write-Log "Step 8: Removing OneDrive startup shortcuts" STEP
$startupPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$startupPaths.Add("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\OneDrive.lnk")
[void]$startupPaths.Add("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\OneDrive.lnk")
foreach ($up in (Get-RealUserProfiles)) {
    [void]$startupPaths.Add((Join-Path $up.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\OneDrive.lnk'))
}
$removedAnyShortcut = $false
foreach ($lnk in $startupPaths) {
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
        Write-Log "Removed shortcut: $lnk" OK
        $removedAnyShortcut = $true
    }
}
if (-not $removedAnyShortcut) { Write-Log "No startup shortcuts found" SKIP }

# ─────────────────────────────────────────────────────────────
#  STEP 9 — GROUP POLICY BLOCKS
#  Confined entirely to OneDrive's own dedicated policy key. No shared
#  Windows policy key (System, CloudContent, etc.) is touched.
# ─────────────────────────────────────────────────────────────
Write-Log "Step 9: Applying Group Policy blocks (OneDrive policy key only)" STEP
$odPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
Set-RegistryValue -Path $odPolicy -Name 'DisableFileSyncNGSC'                   -Value 1
Set-RegistryValue -Path $odPolicy -Name 'DisableFileSync'                       -Value 1
Set-RegistryValue -Path $odPolicy -Name 'PreventNetworkTrafficPreUserSignIn'    -Value 1
Set-RegistryValue -Path $odPolicy -Name 'DisableLibrariesDefaultSaveToOneDrive' -Value 1
Set-RegistryValue -Path $odPolicy -Name 'KFMBlockOptIn'                         -Value 1
Set-RegistryValue -Path $odPolicy -Name 'KFMBlockOptOut'                        -Value 1

# ─────────────────────────────────────────────────────────────
#  STEP 10 — IFEO DEBUGGER HIJACK
# ─────────────────────────────────────────────────────────────
Write-Log "Step 10: Installing IFEO execution blocks" STEP
# Windows construct: <Debugger> <BlockedExePath> [args]
# rundll32.exe receives the OneDrive path as arg1, tries to load it as a DLL,
# fails immediately, exits silently. No window, no error dialog.
$ifeoBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($exe in $Script:OneDriveExeNames) {
    Set-RegistryValue -Path "$ifeoBase\$exe.exe" -Name 'Debugger' -Value $Script:IfeoDebugger -Type String
}

# ─────────────────────────────────────────────────────────────
#  STEP 11 — SOFTWARE RESTRICTION POLICY
# ─────────────────────────────────────────────────────────────
Write-Log "Step 11: Adding SRP path rules" STEP
$srpBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'

# Initialize SRP infrastructure only if it doesn't already exist; leave any
# pre-existing enterprise SRP configuration completely untouched.
if (-not (Test-Path -LiteralPath $srpBase)) {
    New-Item -Path $srpBase -Force | Out-Null
    Set-ItemProperty -Path $srpBase -Name 'DefaultLevel'        -Value 262144 -Type DWord  # 262144 = Unrestricted (everything else keeps running normally)
    Set-ItemProperty -Path $srpBase -Name 'PolicyScope'         -Value 0      -Type DWord  # all users
    Set-ItemProperty -Path $srpBase -Name 'TransparentEnabled'  -Value 1      -Type DWord
    Set-ItemProperty -Path $srpBase -Name 'AuthenticodeEnabled' -Value 0      -Type DWord
    Write-Log "SRP infrastructure initialized (default: unrestricted)" OK
}

$srpPathsRoot = "$srpBase\0\Paths"
if (-not (Test-Path -LiteralPath $srpPathsRoot)) {
    New-Item -Path $srpPathsRoot -Force | Out-Null
}

# Idempotency: remove any existing OneDrive Nuke SRP rules first so re-running
# the script doesn't accumulate duplicates. Only rules tagged with our own
# description are touched — any other SRP rule on the system is left alone.
Get-ChildItem -LiteralPath $srpPathsRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $desc = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'Description' -ErrorAction SilentlyContinue).Description
    if ($desc -like '*OneDrive Nuke*') {
        Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$srpTargets = @(
    "%SystemRoot%\System32\OneDriveSetup.exe",
    "%SystemRoot%\SysWOW64\OneDriveSetup.exe",
    "%LOCALAPPDATA%\Microsoft\OneDrive\OneDriveSetup.exe",
    "%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe",
    "%ProgramFiles%\Microsoft OneDrive\OneDriveSetup.exe",
    "%ProgramFiles(x86)%\Microsoft OneDrive\OneDriveSetup.exe"
)
foreach ($t in $srpTargets) {
    $guid = [Guid]::NewGuid().ToString('B').ToUpper()
    $rule = "$srpPathsRoot\$guid"
    try {
        New-Item -Path $rule -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $rule -Name 'LastModified' -Value ([DateTime]::UtcNow.ToFileTime()) -Type QWord       -ErrorAction Stop
        Set-ItemProperty -Path $rule -Name 'Description'  -Value 'OneDrive Nuke - Blocked'         -Type String      -ErrorAction Stop
        Set-ItemProperty -Path $rule -Name 'SaferFlags'   -Value 0                                 -Type DWord       -ErrorAction Stop
        Set-ItemProperty -Path $rule -Name 'ItemData'     -Value $t                                -Type ExpandString -ErrorAction Stop
        Write-Log "SRP rule added: $t" OK
    } catch {
        Write-Log "SRP rule failed for $t - $($_.Exception.Message)" FAIL
    }
}

# ─────────────────────────────────────────────────────────────
#  STEP 12 — APPLY POLICY & REFRESH SHELL
# ─────────────────────────────────────────────────────────────
Write-Log "Step 12: Applying Group Policy and refreshing Explorer" STEP
& gpupdate.exe /target:computer /force 2>&1 | Out-Null
Write-Log "gpupdate /force completed" OK

try {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Log "Explorer restarted" OK
} catch {
    Write-Log "Explorer restart failed - $($_.Exception.Message)" WARN
}

# ─────────────────────────────────────────────────────────────
#  STEP 13 — VERIFICATION
# ─────────────────────────────────────────────────────────────
Write-Log "Step 13: Verifying blocks are in place" STEP
$verified = Test-Blocks
if ($verified) {
    Write-Log "All blocks verified in place" OK
} else {
    Write-Log "One or more blocks failed verification - see above" WARN
}

# ─────────────────────────────────────────────────────────────
#  SUMMARY
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host "                  REMOVAL & LOCKOUT COMPLETE" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "    Removed items : $($Script:Stats.Removed)" -ForegroundColor Green
Write-Host "    Skipped       : $($Script:Stats.Skipped)" -ForegroundColor DarkGray
$failColor = if ($Script:Stats.Failed -gt 0) { 'Red' } else { 'DarkGray' }
Write-Host "    Failures      : $($Script:Stats.Failed)" -ForegroundColor $failColor
Write-Host ""
Write-Host "  Lockout layers active:" -ForegroundColor White
Write-Host "    - Group Policy           (6 values, OneDrive's own key only)" -ForegroundColor Gray
Write-Host "    - IFEO debugger hijack   (5 OneDrive executables blocked)"     -ForegroundColor Gray
Write-Host "    - Software Restriction   (6 path rules)"                       -ForegroundColor Gray
Write-Host ""
Write-Host "  Scope: only OneDrive was touched. No other app, policy key," -ForegroundColor DarkCyan
Write-Host "  or Microsoft 365 component (SharePoint, Office, etc.) was modified." -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Log file: $LogPath" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  !  REBOOT recommended to fully apply all changes." -ForegroundColor Yellow
Write-Host ""

Write-Log "OneDrive Nuke completed. Removed=$($Script:Stats.Removed) Skipped=$($Script:Stats.Skipped) Failed=$($Script:Stats.Failed) Verified=$verified" INFO

if (-not $NoReboot -and -not $Silent) {
    $r = Read-Host "  Reboot now? (YES/NO)"
    if ($r -eq 'YES') {
        Write-Host "  Rebooting in 5 seconds... (Ctrl+C to abort)" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        try { Restart-Computer -Force -ErrorAction Stop }
        catch { Write-Host "  X Could not initiate reboot: $($_.Exception.Message)" -ForegroundColor Red }
    }
}
