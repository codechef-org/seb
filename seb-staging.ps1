# Safe Exam Browser preflight + install/update + launch — Windows

[CmdletBinding()]
param(
    [string]$ContestCode = ""
)

$ErrorActionPreference = "Stop"

# ---- Pinned version to install ----
$FallbackWinVersion = "3.10.2.920"
$FallbackWinInstallerUrl = "https://cdn.codechef.com/SafeExamBrowser/seb-win-refactoring/releases/download/v3.10.2/SEB_3.10.2.920_SetupBundle.exe"

# ---- Exam config URL template; only the contest code varies per exam ----
$SebUrlTemplate = "seb://staging.codechef.com/api/assess/{0}/seb-config"
if (-not $ContestCode) {
    Write-Error "Contest code not specified."
    exit 1
}
$StartUrl = $SebUrlTemplate -f $ContestCode

$LogFile = Join-Path $env:TEMP ("seb-launch-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# ---- 0. Self-elevation: relaunch as Administrator if not already ----
$ScriptUrl = "https://seb.cchef.co/seb-staging.ps1"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not running elevated - requesting Administrator rights (a UAC prompt will appear)..."
    $relaunch = "& ([scriptblock]::Create((irm '$ScriptUrl'))) -ContestCode '$ContestCode'"
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $relaunch -ErrorAction Stop
    } catch {
        Write-Error "Elevation was cancelled or failed. Re-run from an elevated (Administrator) PowerShell instead."
        exit 1
    }
    exit 0
}

$buildNumber = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
Log "Safe Exam Browser preflight starting on Windows build $buildNumber"

# ---- 1. Stop known-conflict services ----
# Chrome Remote Desktop's "chromoting" service can register as a foreground-
# capable/remote-access process (a red flag for SEB's prohibited-process
# detection) and its remoting_host.exe can steal focus from SEB's kiosk
# window even before that check fires — stop and disable it so it can't
# relaunch on reboot.
foreach ($svc in @("chromoting", "Safe Exam Browser Service")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") {
        Log "Stopping service: $svc"
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
}
try { Set-Service -Name "chromoting" -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
Get-Process -Name "remoting_host" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# ---- 2. Kill any running SEB process ----
Get-Process -Name "SafeExamBrowser" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# ---- 3. Determine installed vs. pinned version ----
$installedVersion = $null
$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$sebEntry = Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "Safe Exam Browser*" } | Select-Object -First 1
if ($sebEntry) { $installedVersion = $sebEntry.DisplayVersion }

function Test-VersionGe($a, $b) {
    try { return ([version]$a) -ge ([version]$b) } catch { return $false }
}

$needsInstall = $true
if ($installedVersion -and (Test-VersionGe $installedVersion $FallbackWinVersion)) {
    $needsInstall = $false
    Log "Installed SEB $installedVersion meets the pinned version $FallbackWinVersion - skipping install."
} else {
    $shown = if ($installedVersion) { $installedVersion } else { "none" }
    Log "Installed SEB version: $shown is older than the pinned version $FallbackWinVersion. Installing pinned version."
}

# ---- 4. Install/update if needed ----
if ($needsInstall) {
    # Only clear settings on reinstall — wiping them every launch trips SEB's own
    # tamper check, which shows "SEB local preference has been reset".
    Log "Clearing cached SEB settings/logs..."
    Remove-Item -Recurse -Force "$env:APPDATA\SafeExamBrowser" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$env:LOCALAPPDATA\SafeExamBrowser" -ErrorAction SilentlyContinue

    if ($sebEntry -and $sebEntry.UninstallString) {
        Log "Uninstalling existing Safe Exam Browser ..."
        try {
            $parts = $sebEntry.UninstallString -split ' ', 2
            Start-Process -FilePath $parts[0].Trim('"') -ArgumentList "/uninstall /quiet /norestart" -Wait -ErrorAction SilentlyContinue
        } catch {
            Log "Uninstall step failed or not applicable, continuing with fresh install (installer upgrades in place)."
        }
    }

    $tmpDir = Join-Path $env:TEMP ("seb-install-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    $installerPath = Join-Path $tmpDir "SEB_Setup.exe"

    Log "Downloading Safe Exam Browser $FallbackWinVersion..."
    Invoke-WebRequest -Uri $FallbackWinInstallerUrl -OutFile $installerPath

    Log "Installing Safe Exam Browser ..."
    Start-Process -FilePath $installerPath -ArgumentList "/install", "/quiet", "/norestart" -Wait

    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    Log "Safe Exam Browser $FallbackWinVersion installed."
}

# ---- 6. Known-conflict cleanup ----
try {
    Add-MpPreference -ExclusionProcess "SafeExamBrowser.exe" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath "C:\Program Files (x86)\SafeExamBrowser" -ErrorAction SilentlyContinue
    Log "Added Windows Defender exclusion for SEB."
} catch {
    Log "Could not set Defender exclusion (non-Defender AV or insufficient rights) - skipping."
}

try {
    $proxyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $proxySettings = Get-ItemProperty $proxyKey -ErrorAction SilentlyContinue
    if ($proxySettings.ProxyEnable -eq 1) {
        $override = $proxySettings.ProxyOverride
        if ($override -notlike "*localhost*") {
            $newOverride = if ($override) { "$override;localhost;127.0.0.1" } else { "localhost;127.0.0.1" }
            Set-ItemProperty -Path $proxyKey -Name ProxyOverride -Value $newOverride
            Log "Added localhost/127.0.0.1 to proxy bypass list."
        }
    }
} catch {
    Log "Could not inspect/update proxy bypass list - skipping."
}

# ---- 7. Registry resetter, if bundled, for stuck post-crash lockdown state ----
$resetter = Get-ChildItem "C:\Program Files*\SafeExamBrowser*" -Recurse -Filter "SebRegistryResetter.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($resetter) {
    Log "Running SebRegistryResetter.exe to clear any stuck lockdown state..."
    Start-Process -FilePath $resetter.FullName -Wait -ErrorAction SilentlyContinue
}

# ---- 7.5 Reset mouse cursor to Windows default ----
try {
    Set-ItemProperty -Path "HKCU:\Control Panel\Cursors" -Name "(Default)" -Value "Windows Default" -ErrorAction SilentlyContinue
    foreach ($cursorName in @("Arrow","Help","AppStarting","Wait","Crosshair","IBeam","NWPend","No","SizeNS","SizeWE","SizeNWSE","SizeNESW","SizeAll","UpArrow","Hand","Pin","Person")) {
        Remove-ItemProperty -Path "HKCU:\Control Panel\Cursors" -Name $cursorName -ErrorAction SilentlyContinue
    }
    Add-Type -Namespace SebCursor -Name NativeMethods -MemberDefinition @"
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
"@ -ErrorAction SilentlyContinue
    [SebCursor.NativeMethods]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0) | Out-Null
    Log "Reset mouse cursor scheme to Windows default."
} catch {
    Log "Could not reset mouse cursor scheme - skipping."
}

# ---- 8. Launch with the exam start URL ----
Log "Launching Safe Exam Browser with start URL..."
Start-Process $StartUrl

# Force-kill this console ourselves, immediately after launch — no confirmation
# — so SEB's own "close console" kiosk prompt never fires (that prompt is what
# makes people re-run the command and double-launch).
Log "Done. Log saved to $LogFile"
Stop-Process -Id $PID -Force
