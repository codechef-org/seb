# Safe Exam Browser preflight + install/update + launch — Windows

[CmdletBinding()]
param(
    [string]$ContestCode = "",
    [string]$LoginToken = "",
    [ValidateSet("production", "staging", "local")]
    [string]$Environment = "production"
)

$ErrorActionPreference = "Stop"

# ---- Pinned version to install ----
$FallbackWinVersion = "3.10.2.920"
$FallbackWinInstallerUrl = "https://cdn.codechef.com/SafeExamBrowser/seb-win-refactoring/releases/download/v3.10.2/SEB_3.10.2.920_SetupBundle.exe"

# Releases replaced with the pinned version even though they are newer. 3.10.3's
# runtime integrity check falsely locks some gaming laptops (HP OMEN/Victus etc.;
# SafeExamBrowser/seb-win-refactoring#1586). Matched on major.minor.build.
$BlockedWinVersions = @("3.10.3")

# ---- Windows on ARM (e.g. Snapdragon) ----
# SEB has no ARM64 build. The setup bundle can fail on ARM64 (0x80070666), so ARM64
# machines get the 32-bit MSI, which runs under emulation, and its Visual C++ x86
# prerequisite. The bundle normally installs that prerequisite; the MSI does not.
$FallbackWinX86MsiUrl = "https://cdn.codechef.com/SafeExamBrowser/seb-win-refactoring/releases/download/v3.10.2/SEB_3.10.2.920_x86_Setup.msi"
$VcRedistX86Urls = @(
    "https://cdn.codechef.com/SafeExamBrowser/prerequisites/vc_redist.x86.exe",
    "https://aka.ms/vs/17/release/vc_redist.x86.exe"
)

# ---- Target host; defaults to production ----
$SebHost = switch ($Environment) {
    "production" { "www.codechef.com" }
    "staging"    { "staging.codechef.com" }
    "local"      { "www.acodechef.com" }
}

# ---- Exam config URL template; only the contest code varies per exam ----
# sebs:// makes SEB fetch the config over https; seb:// (local only) uses http.
$SebScheme = if ($Environment -eq "local") { "seb" } else { "sebs" }
$SebUrlTemplate = "${SebScheme}://$SebHost/api/assess/{0}/seb-config"
if (-not $ContestCode) {
    Write-Error "Contest code not specified."
    exit 1
}
$StartUrl = $SebUrlTemplate -f $ContestCode

# The token is interpolated into the elevated relaunch command, so only a strict 64-hex value is accepted.
if ($LoginToken -and $LoginToken -cnotmatch '^[a-f0-9]{64}$') {
    Write-Warning "Ignoring invalid login token; you will need to log in manually inside Safe Exam Browser."
    $LoginToken = ""
}
if ($LoginToken) {
    $StartUrl = "${StartUrl}??seb_login_token=$LoginToken"
}

$LogFile = Join-Path $env:TEMP ("seb-launch-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# ---- 0. Self-elevation: relaunch as Administrator if not already ----
$ScriptUrl = "https://seb.cchef.co/seb.ps1"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not running elevated - requesting Administrator rights (a UAC prompt will appear)..."
    $relaunch = "& ([scriptblock]::Create((irm '$ScriptUrl'))) -ContestCode '$ContestCode'"
    if ($LoginToken) {
        $relaunch += " -LoginToken '$LoginToken'"
    }
    if ($Environment -ne "production") {
        $relaunch += " -Environment '$Environment'"
    }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $relaunch -ErrorAction Stop
    } catch {
        Write-Error "Elevation was cancelled or failed. Re-run from an elevated (Administrator) PowerShell instead."
        exit 1
    }
    exit 0
}

$buildNumber = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber

# The machine-wide value, read from the registry, reports ARM64 even when this
# PowerShell process itself runs under x86/x64 emulation.
$osArch = $null
try {
    $osArch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction Stop).PROCESSOR_ARCHITECTURE
} catch {}
if (-not $osArch) { $osArch = $env:PROCESSOR_ARCHITECTURE }
$isArm64 = $osArch -eq "ARM64"

Log "Safe Exam Browser preflight starting on Windows build $buildNumber ($osArch)"
Log "Target environment: $Environment ($SebHost)"

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
$sebEntries = @(Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "Safe Exam Browser*" })
# A setup bundle install registers both the bundle and its MSI. Prefer the bundle
# entry, since uninstalling through it also removes its registration.
$sebEntry = $sebEntries | Where-Object { $_.UninstallString -and $_.UninstallString -notmatch '(?i)msiexec' } | Select-Object -First 1
if (-not $sebEntry) { $sebEntry = $sebEntries | Select-Object -First 1 }
if ($sebEntry) { $installedVersion = $sebEntry.DisplayVersion }

function Test-VersionGe($a, $b) {
    try { return ([version]$a) -ge ([version]$b) } catch { return $false }
}

function Test-VersionBlocked($v) {
    try { $p = [version]$v } catch { return $false }
    return $BlockedWinVersions -contains ("{0}.{1}.{2}" -f $p.Major, $p.Minor, [Math]::Max($p.Build, 0))
}

$needsInstall = $true
if ($installedVersion -and (Test-VersionBlocked $installedVersion)) {
    Log "Installed SEB $installedVersion is a release we don't use. Replacing it with the pinned version $FallbackWinVersion."
} elseif ($installedVersion -and (Test-VersionGe $installedVersion $FallbackWinVersion)) {
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
            $productCode = [regex]::Match($sebEntry.UninstallString, '\{[0-9A-Fa-f-]{36}\}').Value
            if ($sebEntry.UninstallString -match '(?i)msiexec' -and $productCode) {
                # MSI-only install (e.g. the ARM64 path below): the bundle's /uninstall switch doesn't apply.
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/x", $productCode, "/qn", "/norestart" -Wait -ErrorAction SilentlyContinue
            } else {
                $parts = $sebEntry.UninstallString -split ' ', 2
                Start-Process -FilePath $parts[0].Trim('"') -ArgumentList "/uninstall /quiet /norestart" -Wait -ErrorAction SilentlyContinue
            }
        } catch {
            Log "Uninstall step failed or not applicable, continuing with fresh install (installer upgrades in place)."
        }
    }

    $tmpDir = Join-Path $env:TEMP ("seb-install-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    if ($isArm64) {
        Log "Windows on ARM detected - installing the 32-bit (x86) build, which runs under emulation."

        $vcRedistPath = Join-Path $tmpDir "vc_redist.x86.exe"
        $vcRedistDownloaded = $false
        foreach ($url in $VcRedistX86Urls) {
            try {
                Log "Downloading Visual C++ x86 runtime from $url ..."
                Invoke-WebRequest -Uri $url -OutFile $vcRedistPath -UseBasicParsing
                $vcRedistDownloaded = $true
                break
            } catch {
                Log "Download failed from $url - trying the next source."
            }
        }
        if ($vcRedistDownloaded) {
            Log "Installing Visual C++ x86 runtime ..."
            $vc = Start-Process -FilePath $vcRedistPath -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
            # 3010 = installed, reboot pending; 1638 = a newer version is already installed.
            if (@(0, 1638, 3010) -notcontains $vc.ExitCode) {
                Log "WARNING: Visual C++ x86 runtime installer exited with code $($vc.ExitCode); continuing."
            }
        } else {
            Log "WARNING: could not download the Visual C++ x86 runtime; Safe Exam Browser may fail to start."
        }

        $installerPath = Join-Path $tmpDir "SEB_x86_Setup.msi"
        $msiLog = Join-Path $env:TEMP ("seb-msi-install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        Log "Downloading Safe Exam Browser $FallbackWinVersion (x86 MSI)..."
        Invoke-WebRequest -Uri $FallbackWinX86MsiUrl -OutFile $installerPath -UseBasicParsing

        Log "Installing Safe Exam Browser (x86 MSI) ..."
        $msi = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$installerPath`"", "/qn", "/norestart", "/l*v", "`"$msiLog`"" -Wait -PassThru
        if (@(0, 3010) -notcontains $msi.ExitCode) {
            Log "ERROR: Safe Exam Browser MSI exited with code $($msi.ExitCode). Installer log: $msiLog"
        }
    } else {
        $installerPath = Join-Path $tmpDir "SEB_Setup.exe"

        Log "Downloading Safe Exam Browser $FallbackWinVersion..."
        Invoke-WebRequest -Uri $FallbackWinInstallerUrl -OutFile $installerPath

        Log "Installing Safe Exam Browser ..."
        Start-Process -FilePath $installerPath -ArgumentList "/install", "/quiet", "/norestart" -Wait
    }

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
