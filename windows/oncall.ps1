#Requires -Version 5.1
<#
  oncall - Claude Code on call. Voice-call your Claude Code sessions from anywhere.
  Windows front end for claude-on-call: every command runs Sesame Link inside WSL.
#>
param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)
$ErrorActionPreference = "Continue"
$env:WSL_UTF8 = "1"

$AppDir = Join-Path $env:LOCALAPPDATA "claude-on-call"
$cfgPath = Join-Path $AppDir "config.json"
if (-not (Test-Path $cfgPath)) {
    Write-Host "oncall: not installed. Run:  irm https://raw.githubusercontent.com/levfo/claude-on-call/main/windows/install.ps1 | iex" -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$Distro = $cfg.distro
$User = $cfg.linuxUser
$script:LastExit = 0

function Quote-Bash([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }
function Bash-Args([string[]]$a) { if (-not $a) { return "" }; ($a | ForEach-Object { Quote-Bash $_ }) -join " " }
function Run-Wsl([string]$BashCommand, [switch]$Here, [string]$Folder) {
    # Output streams straight to the console (interactive commands need the real TTY),
    # so this deliberately does not capture or return it. -lc puts ~/.local/bin and
    # ~/.claude-on-call/bin on PATH. --cd keeps the Windows working folder.
    $wslArgs = @("-d", $Distro, "-u", $User)
    if ($Folder) { $wslArgs += @("--cd", $Folder) } elseif ($Here) { $wslArgs += @("--cd", (Get-Location).Path) }
    $wslArgs += @("--", "bash", "-lc", $BashCommand)
    & wsl.exe @wslArgs
    $script:LastExit = $LASTEXITCODE
}

$extra = Bash-Args $Rest
switch ($Command.ToLower()) {
    "status"   { Run-Wsl "sesame-link status $extra" }
    "login"    { Run-Wsl "sesame-link auth login $extra" }
    "logout"   { Run-Wsl "sesame-link auth logout $extra" }
    "start"    { Run-Wsl "~/.claude-on-call/bin/start-link $extra" }
    "stop"     { Run-Wsl "sesame-link stop" }
    "restart"  { Run-Wsl "sesame-link restart" }
    "logs"     { Run-Wsl "sesame-link logs $extra" }
    "doctor"   { Run-Wsl "sesame-link doctor $extra" }
    "sessions" { Run-Wsl "sesame-link sessions $extra" }
    "attach"   { Run-Wsl "sesame-link sessions attach $extra" }
    "config"   { Run-Wsl "sesame-link config $extra" }
    "claude"   {
        # Start Windows Claude Code in this folder as a session Sesame can see, attached here.
        Run-Wsl -Here "sesame-link claude $extra"
    }
    "handoff"  {
        # Called by Claude Code's /oncall command:  oncall handoff <claude-session-id> [folder]
        if ($Rest.Count -lt 1) { Write-Host "usage: oncall handoff <claude-session-id> [folder]"; exit 2 }
        $folder = if ($Rest.Count -ge 2 -and $Rest[1]) { $Rest[1] } else { (Get-Location).Path }
        Run-Wsl -Folder $folder "~/.claude-on-call/bin/handoff $(Quote-Bash $Rest[0])"
    }
    "web"      { Start-Process "https://link.sesame.com" }
    "update"   {
        Write-Host "Re-running the installer..."
        Invoke-Expression (Invoke-RestMethod "https://raw.githubusercontent.com/levfo/claude-on-call/main/windows/install.ps1")
    }
    "uninstall" {
        Run-Wsl "sesame-link stop"
        Remove-Item (Join-Path ([Environment]::GetFolderPath("Startup")) "claude-on-call.vbs") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:USERPROFILE ".claude\commands\oncall.md") -ErrorAction SilentlyContinue
        Write-Host "Stopped Sesame Link and removed the keep-alive and /oncall command."
        Write-Host "Left in place: $AppDir, the WSL distro '$Distro', and Sesame Link inside it."
        Write-Host "To remove Sesame Link from this PC entirely:  wsl -d $Distro -u $User -- bash -lc 'sesame-link uninstall'"
        $script:LastExit = 0
    }
    default {
        Write-Host @"
oncall - Claude Code on call. Reach your Windows Claude Code sessions by voice or from any device.

  oncall status              is this PC connected to Sesame? is Claude Code ready?
  oncall login               sign in to Sesame and add this PC
  oncall start | stop | restart
  oncall claude [args]       start Claude Code in this folder as a session Sesame can see, attached here
  oncall sessions            list sessions;  oncall attach <id>  to attach one in this terminal
  oncall logs | doctor | config
  oncall web                 open link.sesame.com
  oncall update              re-run the installer
  oncall uninstall

Inside any Claude Code session, type  /oncall  to hand that conversation to Sesame.
Everything runs through Sesame Link inside WSL ($Distro, user $User).
"@
        $script:LastExit = 0
    }
}
exit $script:LastExit
