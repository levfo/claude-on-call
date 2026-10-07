#Requires -Version 5.1
<#
  oncall - Claude Code on call. Voice-call your Claude Code sessions from anywhere.
  Windows front end for claude-on-call: every command runs Sesame Link inside WSL.
#>
param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)
$ErrorActionPreference = "Stop"
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

function Quote-Bash([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }
function Bash-Args([string[]]$a) { ($a | ForEach-Object { Quote-Bash $_ }) -join " " }
function Run-Wsl([string]$bashCommand, [switch]$Here) {
    # -lc so ~/.local/bin and ~/.claude-on-call/bin are on PATH. --cd keeps the Windows folder.
    $args = @("-d", $Distro, "-u", $User)
    if ($Here) { $args += @("--cd", (Get-Location).Path) }
    $args += @("--", "bash", "-lc", $bashCommand)
    & wsl.exe @args
    return $LASTEXITCODE
}

switch ($Command.ToLower()) {
    "status"   { exit (Run-Wsl "sesame-link status $(Bash-Args $Rest)") }
    "login"    { exit (Run-Wsl "sesame-link auth login $(Bash-Args $Rest)") }
    "logout"   { exit (Run-Wsl "sesame-link auth logout $(Bash-Args $Rest)") }
    "start"    { exit (Run-Wsl "cd ~ && cd `"`$(sed -n 's/^WIN_HOME=//p' ~/.claude-on-call/config)`" && sesame-link start --open-terminal off --claude-executable `$HOME/.claude-on-call/bin/claude-shim $(Bash-Args $Rest)") }
    "stop"     { exit (Run-Wsl "sesame-link stop") }
    "restart"  { exit (Run-Wsl "sesame-link restart") }
    "logs"     { exit (Run-Wsl "sesame-link logs $(Bash-Args $Rest)") }
    "doctor"   { exit (Run-Wsl "sesame-link doctor $(Bash-Args $Rest)") }
    "sessions" { exit (Run-Wsl "sesame-link sessions $(Bash-Args $Rest)") }
    "attach"   { exit (Run-Wsl "sesame-link sessions attach $(Bash-Args $Rest)") }
    "config"   { exit (Run-Wsl "sesame-link config $(Bash-Args $Rest)") }
    "claude"   {
        # Start Windows Claude Code in this folder as a session Sesame can see, attached here.
        exit (Run-Wsl -Here "sesame-link claude $(Bash-Args $Rest)")
    }
    "handoff"  {
        # Called by Claude Code's /oncall command: oncall handoff <claude-session-id> [folder]
        if ($Rest.Count -lt 1) { Write-Host "usage: oncall handoff <claude-session-id> [folder]"; exit 2 }
        $sid = $Rest[0]
        $folder = if ($Rest.Count -ge 2 -and $Rest[1]) { $Rest[1] } else { (Get-Location).Path }
        $args = @("-d", $Distro, "-u", $User, "--cd", $folder, "--", "bash", "-lc", "`$HOME/.claude-on-call/bin/handoff $(Quote-Bash $sid)")
        & wsl.exe @args
        exit $LASTEXITCODE
    }
    "web"      { Start-Process "https://link.sesame.com"; exit 0 }
    "update"   {
        Write-Host "Re-running the installer..."
        Invoke-Expression (Invoke-RestMethod "https://raw.githubusercontent.com/levfo/claude-on-call/main/windows/install.ps1")
        exit 0
    }
    "uninstall" {
        Run-Wsl "sesame-link stop" | Out-Null
        Remove-Item (Join-Path ([Environment]::GetFolderPath("Startup")) "claude-on-call.vbs") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:USERPROFILE ".claude\commands\oncall.md") -ErrorAction SilentlyContinue
        Write-Host "Stopped Sesame Link and removed the keep-alive and /oncall command."
        Write-Host "Left in place: $AppDir, the WSL distro '$Distro', and Sesame Link inside it."
        Write-Host "To remove Sesame Link from this PC entirely:  wsl -d $Distro -u $User -- bash -lc 'sesame-link uninstall'"
        exit 0
    }
    default {
        @"
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
"@ | Write-Host
        exit 0
    }
}
