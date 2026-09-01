# Safe Exam Browser preflight + install/update + launch — Windows
#
# Usage (after uploading to S3, from an ELEVATED PowerShell):
#   & ([scriptblock]::Create((irm "https://s3.us-east-1.amazonaws.com/staging_shared/seb-launch/seb-launch.ps1"))) -ContestCode "SEB"
#
# -ContestCode is the contest code (e.g. "SEB"), not the full seb:// URL.
# It's substituted into the fixed exam-config URL template below.
# If no contest code is given, SEB is just installed/updated and opened normally.

[CmdletBinding()]
param(
    [string]$ContestCode = ""
)

$ErrorActionPreference = "Stop"

# ---- Pinned fallback, used only if the GitHub API lookup below fails/is blocked ----
$FallbackWinVersion = "3.10.2.920"
$FallbackWinInstallerUrl = "https://github.com/SafeExamBrowser/seb-win-refactoring/releases/download/v3.10.2/SEB_3.10.2.920_SetupBundle.exe"

# ---- Exam config URL template; only the contest code varies per exam ----
$SebUrlTemplate = "seb://staging.codechef.com/api/assess/{0}/seb-config"
$StartUrl = ""
if ($ContestCode) {
    $StartUrl = $SebUrlTemplate -f $ContestCode
}

$LogFile = Join-Path $env:TEMP ("seb-launch-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# ---- 0. Elevation check ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run from an elevated (Administrator) PowerShell. Right-click PowerShell > 'Run as administrator', then re-run the command."
    exit 1
}

$buildNumber = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
Log "Safe Exam Browser preflight starting on Windows build $buildNumber"

# ---- 1. Stop known-conflict services ----
foreach ($svc in @("chromoting", "Safe Exam Browser Service")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") {
        Log "Stopping service: $svc"
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
}
try { Set-Service -Name "chromoting" -StartupType Disabled -ErrorAction SilentlyContinue } catch {}

# ---- 2. Kill any running SEB process ----
Get-Process -Name "SafeExamBrowser" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# ---- 3. Determine installed vs. latest version ----
$installedVersion = $null
$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$sebEntry = Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "Safe Exam Browser*" } | Select-Object -First 1
if ($sebEntry) { $installedVersion = $sebEntry.DisplayVersion }

$latestVersion = $FallbackWinVersion
$installerUrl = $FallbackWinInstallerUrl
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/SafeExamBrowser/seb-win-refactoring/releases/latest" -TimeoutSec 6
    $asset = $release.assets | Where-Object { $_.name -like "*SetupBundle.exe" } | Select-Object -First 1
    if ($release.tag_name -and $asset) {
        $latestVersion = $release.tag_name.TrimStart("v")
        $installerUrl = $asset.browser_download_url
    }
} catch {
    Log "GitHub API unreachable, using pinned fallback version $FallbackWinVersion"
}

function Test-VersionGe($a, $b) {
    try { return ([version]$a) -ge ([version]$b) } catch { return $false }
}

$needsInstall = $true
if ($installedVersion -and (Test-VersionGe $installedVersion $latestVersion)) {
    $needsInstall = $false
    Log "Installed SEB $installedVersion is up to date (latest: $latestVersion)."
} else {
    $shown = if ($installedVersion) { $installedVersion } else { "none" }
    Log "Installed SEB version: $shown. Latest available: $latestVersion. Will (re)install."
}

# ---- 4. Install/update if needed ----
if ($needsInstall) {
    # Only clear settings on reinstall — wiping them every launch trips SEB's own
    # tamper check, which shows "SEB local preference has been reset".
    Log "Clearing cached SEB settings/logs..."
    Remove-Item -Recurse -Force "$env:APPDATA\SafeExamBrowser" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$env:LOCALAPPDATA\SafeExamBrowser" -ErrorAction SilentlyContinue

    if ($sebEntry -and $sebEntry.UninstallString) {
        Log "Uninstalling existing Safe Exam Browser (best-effort)..."
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

    Log "Downloading Safe Exam Browser $latestVersion..."
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath

    Log "Installing Safe Exam Browser (silent)..."
    Start-Process -FilePath $installerPath -ArgumentList "/install", "/quiet", "/norestart" -Wait

    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    Log "Safe Exam Browser $latestVersion installed."
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

# ---- 8. Launch with the exam start URL ----
if ($StartUrl) {
    Log "Launching Safe Exam Browser with start URL..."
    Start-Process $StartUrl

    # Force-kill this console ourselves, immediately after launch — no confirmation
    # — so SEB's own "close console" kiosk prompt never fires (that prompt is what
    # makes people re-run the command and double-launch).
    Log "Done. Log saved to $LogFile"
    Stop-Process -Id $PID -Force
} else {
    Log "No start URL supplied, opening Safe Exam Browser normally."
    $sebExe = Get-ChildItem "C:\Program Files*\SafeExamBrowser*" -Recurse -Filter "SafeExamBrowser.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sebExe) { Start-Process $sebExe.FullName }
    Log "Done. Log saved to $LogFile"
}
