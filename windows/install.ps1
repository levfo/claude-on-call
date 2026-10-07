#Requires -Version 5.1
<#
.SYNOPSIS
  claude-on-call installer for Windows.

.DESCRIPTION
  Makes your Windows-native Claude Code reachable from Sesame (link.sesame.com and
  Sesame's voice agents) by running Sesame Link inside WSL and pointing it at a shim
  that launches the Windows Claude Code binary.

  One-liner:
    irm https://raw.githubusercontent.com/levfo/claude-on-call/main/windows/install.ps1 | iex

  Re-running is safe; every step is idempotent.

.PARAMETER Distro
  WSL distro to use or create. Default: Ubuntu.
.PARAMETER LinuxUser
  Linux account inside the distro. Default: your Windows username, lower-cased.
.PARAMETER Ref
  Git ref of levfo/claude-on-call to download when not running from a checkout. Default: main.
.PARAMETER NoLogin
  Skip the interactive Sesame sign-in at the end.
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu",
    [string]$LinuxUser = "",
    [string]$Repo = "levfo/claude-on-call",
    [string]$Ref = "main",
    [switch]$NoLogin
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"   # wsl.exe prints UTF-16 by default; this makes its output readable here

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Fail($m) { Write-Host ""; Write-Host "claude-on-call: $m" -ForegroundColor Red; exit 1 }

$AppDir = Join-Path $env:LOCALAPPDATA "claude-on-call"
$BinDir = Join-Path $AppDir "bin"
$SrcDir = Join-Path $AppDir "src"
New-Item -ItemType Directory -Force $AppDir, $BinDir | Out-Null

function Write-Lf([string]$Path, [string[]]$Lines) {
    # LF line endings, UTF-8 without BOM: these files are read by bash inside WSL.
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}
function To-WslPath([string]$WindowsPath) {
    $p = (& wsl.exe -d $Distro -- wslpath -u $WindowsPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $p) { Fail "could not translate path '$WindowsPath' for WSL" }
    return ($p -join "").Trim()
}
function Wsl-Root([string]$ScriptText) {
    $tmp = Join-Path $env:TEMP ("oncall-root-" + [guid]::NewGuid().ToString("n") + ".sh")
    Write-Lf $tmp ($ScriptText -split "`r?`n")
    try { & wsl.exe -d $Distro -u root -- bash (To-WslPath $tmp); return $LASTEXITCODE } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- 1. WSL
Step "Checking WSL"
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Fail "WSL is not installed. In an Administrator PowerShell run:  wsl --install   then reboot and run this installer again."
}
$verText = ((& wsl.exe --version 2>$null) -join "`n")
$m = [regex]::Match($verText, 'WSL version:\s*(\d+)\.(\d+)\.(\d+)')
if (-not $m.Success) {
    Fail "This WSL is too old to report a version (needs the Store/MSI WSL, 2.4 or newer). In an Administrator PowerShell run:  wsl --update   then run this installer again."
}
$wslVer = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
if ($wslVer -lt [version]"2.4.0") {
    Fail "WSL $wslVer is too old for current Ubuntu images. In an Administrator PowerShell run:  wsl --update   (it needs admin to restart the WSL service), then run this installer again."
}
Note "WSL $wslVer"

# ---------------------------------------------------------------- 2. Windows Claude Code
Step "Finding Windows Claude Code"
$claudeExe = $null
$candidates = @("$env:USERPROFILE\.local\bin\claude.exe")
try { $npmRoot = (& npm root -g 2>$null | Select-Object -First 1); if ($npmRoot) { $candidates += (Join-Path $npmRoot "@anthropic-ai\claude-code\bin\claude.exe") } } catch {}
try { $w = (& where.exe claude.exe 2>$null); if ($w) { $candidates += ($w -split "`r?`n") } } catch {}
foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $claudeExe = (Resolve-Path $c).Path; break } }
if (-not $claudeExe) {
    Fail "Claude Code for Windows was not found. Install it (https://code.claude.com/docs/en/setup), sign in with 'claude', then run this installer again."
}
$claudeVer = (& $claudeExe --version 2>$null | Select-Object -First 1)
Note "$claudeExe ($claudeVer)"

# ---------------------------------------------------------------- 3. Distro
Step "Checking WSL distro '$Distro'"
$installed = ((& wsl.exe -l -q 2>$null) -join "`n") -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($installed -notcontains $Distro) {
    Step "Installing $Distro (this downloads the image; a few minutes)"
    & wsl.exe --install $Distro --no-launch
    if ($LASTEXITCODE -ne 0) { Fail "wsl --install $Distro failed" }
    $launcher = (($Distro -replace '[^A-Za-z0-9]', '').ToLower()) + ".exe"
    if (Get-Command $launcher -ErrorAction SilentlyContinue) {
        Note "Registering $Distro without the first-run prompt"
        & $launcher install --root 2>$null | Out-Null
    }
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        & wsl.exe -d $Distro -u root -- true 2>$null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ok) { Fail "$Distro was installed but could not be started. Open '$Distro' from the Start menu once to finish its setup, then run this installer again." }
}
& wsl.exe -d $Distro -u root -- true 2>$null
if ($LASTEXITCODE -ne 0) { Fail "WSL could not start '$Distro' (error above). If it says 'Catastrophic failure', run  wsl --update  in an Administrator PowerShell." }

# ---------------------------------------------------------------- 4. Linux user
if (-not $LinuxUser) { $LinuxUser = ($env:USERNAME.ToLower() -replace '[^a-z0-9_-]', ''); if (-not $LinuxUser) { $LinuxUser = "oncall" } }
Step "Preparing Linux user '$LinuxUser' in $Distro"
$rootScript = @"
set -e
id '$LinuxUser' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo '$LinuxUser'
printf '%s ALL=(ALL) NOPASSWD:ALL\n' '$LinuxUser' > /etc/sudoers.d/90-claude-on-call && chmod 440 /etc/sudoers.d/90-claude-on-call
if ! grep -qs 'default=$LinuxUser' /etc/wsl.conf; then
  printf '[boot]\nsystemd=true\n\n[user]\ndefault=$LinuxUser\n' > /etc/wsl.conf
  echo RESTART_NEEDED
fi
export DEBIAN_FRONTEND=noninteractive
if ! command -v tmux >/dev/null || ! command -v unzip >/dev/null || ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
  apt-get update -qq && apt-get install -y -qq curl unzip tmux python3 ca-certificates >/dev/null
fi
"@
$out = (& wsl.exe -d $Distro -u root -- bash -c "$(($rootScript -split "`r?`n") -join "; ")") 2>&1
if ($LASTEXITCODE -ne 0) { Fail "preparing the Linux user failed:`n$out" }
if (($out -join "`n") -match "RESTART_NEEDED") {
    Note "Applying default user; restarting $Distro"
    & wsl.exe --terminate $Distro 2>$null | Out-Null
}

# ---------------------------------------------------------------- 5. Source files
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$checkout = if ($scriptDir -and (Test-Path (Join-Path $scriptDir "..\linux\claude-shim"))) { (Resolve-Path (Join-Path $scriptDir "..")).Path } else { $null }
if ($checkout) {
    Step "Using source checkout at $checkout"
    $src = $checkout
} else {
    Step "Downloading $Repo@$Ref"
    $zip = Join-Path $env:TEMP "claude-on-call-$Ref.zip"
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/refs/heads/$Ref.zip" -OutFile $zip
    if (Test-Path $SrcDir) { Remove-Item -Recurse -Force $SrcDir }
    Expand-Archive -Path $zip -DestinationPath $SrcDir -Force
    Remove-Item $zip -ErrorAction SilentlyContinue
    $src = (Get-ChildItem $SrcDir -Directory | Select-Object -First 1).FullName
}

# ---------------------------------------------------------------- 6. WSL side
Step "Installing the WSL side (shim, hook relay, Sesame Link)"
$srcWsl = To-WslPath $src
$claudeWsl = To-WslPath $claudeExe
$homeWsl = To-WslPath $env:USERPROFILE
& wsl.exe -d $Distro -u $LinuxUser -- bash "$srcWsl/linux/install-linux-side.sh" --src "$srcWsl" --win-claude "$claudeWsl" --win-home "$homeWsl" --distro "$Distro"
if ($LASTEXITCODE -ne 0) { Fail "the WSL-side installer failed (see output above)" }

# ---------------------------------------------------------------- 7. oncall CLI
Step "Installing the 'oncall' command to $BinDir"
Copy-Item (Join-Path $src "windows\oncall.ps1") (Join-Path $BinDir "oncall.ps1") -Force
Copy-Item (Join-Path $src "windows\oncall.cmd") (Join-Path $BinDir "oncall.cmd") -Force
@{ distro = $Distro; linuxUser = $LinuxUser; claudeExe = $claudeExe; installedAt = (Get-Date).ToString("o") } |
    ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $AppDir "config.json")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ";") -notcontains $BinDir) {
    [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(";")) + ";" + $BinDir), "User")
    Note "Added to your PATH (new terminals will see 'oncall')"
}
if (($env:Path -split ";") -notcontains $BinDir) { $env:Path += ";$BinDir" }

# ---------------------------------------------------------------- 8. Claude Code slash command
Step "Installing Claude Code's /oncall command"
$cmdDir = Join-Path $env:USERPROFILE ".claude\commands"
New-Item -ItemType Directory -Force $cmdDir | Out-Null
Copy-Item (Join-Path $src "windows\oncall.md") (Join-Path $cmdDir "oncall.md") -Force

# ---------------------------------------------------------------- 9. Keep-alive at sign-in
Step "Installing the sign-in keep-alive"
$startup = [Environment]::GetFolderPath("Startup")
$vbs = Join-Path $startup "claude-on-call.vbs"
$keep = "wsl.exe -d $Distro -u $LinuxUser -- bash -lc ""exec `$HOME/.claude-on-call/bin/keepalive"""
Set-Content -Path $vbs -Encoding ASCII -Value ('CreateObject("WScript.Shell").Run "' + ($keep -replace '"', '""') + '", 0, False')
Get-Process wsl -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*keepalive*" } | Out-Null
Start-Process wscript.exe -ArgumentList "`"$vbs`"" | Out-Null

# ---------------------------------------------------------------- 10. Sign in
$status = ((& wsl.exe -d $Distro -u $LinuxUser -- bash -lc "sesame-link status" 2>&1) -join "`n")
if ($status -match "isn't signed in|not signed in") {
    if ($NoLogin) {
        Note "Not signed in to Sesame yet. Run:  oncall login"
    } else {
        Step "Signing in to Sesame (enter the code it shows at the link)"
        & wsl.exe -d $Distro -u $LinuxUser -- bash -lc "sesame-link auth login"
        Step "Starting Sesame Link"
        & wsl.exe -d $Distro -u $LinuxUser -- bash -lc "cd '$homeWsl' && sesame-link restart >/dev/null 2>&1 || sesame-link start --open-terminal off --claude-executable `$HOME/.claude-on-call/bin/claude-shim"
    }
}

Write-Host ""
Write-Host "claude-on-call is installed." -ForegroundColor Green
Write-Host ""
Write-Host "  oncall status            is this PC connected to Sesame?"
Write-Host "  oncall claude            in a project folder: start Claude Code as a session Sesame can see"
Write-Host "  /oncall                  inside any Claude Code session: hand it to Sesame"
Write-Host "  https://link.sesame.com  start, watch and talk to sessions from any device"
Write-Host ""
