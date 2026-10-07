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

function Load-ConsoleHelper {
    if ("OncallConsole" -as [type]) { return $true }
    $sig = @"
using System; using System.Runtime.InteropServices; using System.Threading;
public static class OncallConsole {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr h, uint mode);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteConsoleW(IntPtr h, string s, uint n, out uint written, IntPtr r);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
  // Claude Code runs slash-command shells in a hidden console of their own, so CONIN$/CONOUT$
  // here are not the user's terminal. Attach to the console of the Claude Code process first.
  public static bool AttachTo(uint pid) { FreeConsole(); return AttachConsole(pid); }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct KEY_EVENT_RECORD { public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode; public char UnicodeChar; public uint dwControlKeyState; }
  [StructLayout(LayoutKind.Explicit)]
  public struct INPUT_RECORD { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent; }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint n, out uint written);

  static IntPtr Open(string name) { IntPtr h = CreateFileW(name, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); return (h.ToInt64() == -1) ? IntPtr.Zero : h; }

  // Turn off mouse reporting, focus events and bracketed paste in the terminal
  // and put the console input mode back to a plain shell's expectations.
  public static void Reset(string seq) {
    IntPtr h = Open("CONOUT$");
    if (h != IntPtr.Zero) {
      uint mode; if (GetConsoleMode(h, out mode)) SetConsoleMode(h, mode | 0x0004);  // ENABLE_VIRTUAL_TERMINAL_PROCESSING
      uint w; WriteConsoleW(h, seq, (uint)seq.Length, out w, IntPtr.Zero);
      CloseHandle(h);
    }
    IntPtr i = Open("CONIN$");
    if (i != IntPtr.Zero) {
      uint im; if (GetConsoleMode(i, out im)) SetConsoleMode(i, (im & ~0x0010u & ~0x0200u) | 0x0002 | 0x0004 | 0x0001); // mouse off, VT input off; line, echo, processed on
      CloseHandle(i);
    }
  }

  // Type a key `times` times into this console's shared input buffer, as if pressed on
  // the keyboard. All presses go in one write so nothing can interrupt between them.
  public static bool TypeKey(ushort vk, char ch, uint ctrlState, int times) {
    IntPtr i = Open("CONIN$"); if (i == IntPtr.Zero) return false;
    INPUT_RECORD[] recs = new INPUT_RECORD[2 * times];
    for (int k = 0; k < recs.Length; k++) {
      recs[k].EventType = 1; // KEY_EVENT
      recs[k].KeyEvent.bKeyDown = (k % 2 == 0) ? 1 : 0;
      recs[k].KeyEvent.wRepeatCount = 1;
      recs[k].KeyEvent.wVirtualKeyCode = vk;
      recs[k].KeyEvent.wVirtualScanCode = 0;
      recs[k].KeyEvent.UnicodeChar = ch;
      recs[k].KeyEvent.dwControlKeyState = ctrlState;
    }
    uint written; bool ok = WriteConsoleInputW(i, recs, (uint)recs.Length, out written);
    CloseHandle(i); return ok;
  }
  public static void CtrlCTwice() { TypeKey(0x43, (char)3, 0x0008, 2); } // 'C' with LEFT_CTRL_PRESSED

  // Print straight to the console (our stdout is Claude Code's capture pipe).
  public static void Say(string text) {
    IntPtr h = Open("CONOUT$"); if (h == IntPtr.Zero) return;
    uint w; WriteConsoleW(h, text, (uint)text.Length, out w, IntPtr.Zero); CloseHandle(h);
  }
}
"@
    try { Add-Type -TypeDefinition $sig -ErrorAction Stop; return $true } catch { return $false }
}

$script:ResetSeq = "$([char]27)[?1000l$([char]27)[?1002l$([char]27)[?1003l$([char]27)[?1004l$([char]27)[?1005l$([char]27)[?1006l$([char]27)[?1015l$([char]27)[?2004l$([char]27)[?25h"

function Reset-ConsoleModes {
    # Claude Code turns on mouse reporting, focus events and bracketed paste in the
    # terminal. If it dies without turning them off, the shell underneath sees every
    # mouse move as text like ^[[<35;96;27M. Our stdout is a pipe (Claude Code
    # captures the command's output), so write straight to the console.
    if (Load-ConsoleHelper) { try { [OncallConsole]::Reset($script:ResetSeq) } catch { } }
}

function Close-OriginalClaude([int]$ClaudePid, [string]$Message) {
    # Prefer a graceful exit: two Ctrl+C keypresses make Claude Code quit and restore
    # the terminal itself, exactly as if the user had pressed them. Claude Code may
    # end this process as part of exiting, so say our piece on the console first.
    # Fall back to killing it, with a terminal reset before and after.
    $helper = Load-ConsoleHelper
    if ($helper) {
        try {
            $attached = [OncallConsole]::AttachTo([uint32]$ClaudePid)
            if ($Message) { [OncallConsole]::Say("`r`n" + $Message + "`r`n") }
            if ($attached) { [OncallConsole]::CtrlCTwice() }
        } catch { }
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            if (-not (Get-Process -Id $ClaudePid -ErrorAction SilentlyContinue)) { return }
        }
    }
    Reset-ConsoleModes
    Stop-Process -Id $ClaudePid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Reset-ConsoleModes
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
        if ($Rest.Count -lt 1) { Write-Host "usage: oncall handoff <claude-session-id> [folder] [claude-pid]"; exit 2 }
        $folder = if ($Rest.Count -ge 2 -and $Rest[1]) { $Rest[1] } else { (Get-Location).Path }
        # Claude Code's shell on Windows is Git Bash, whose $PWD looks like /c/Users/you.
        if ($folder -match '^/([A-Za-z])(/.*)?$') { $folder = $matches[1].ToUpper() + ":" + (($matches[2] -replace '/', '\') -replace '^$', '\') }
        Run-Wsl -Folder $folder "~/.claude-on-call/bin/handoff $(Quote-Bash $Rest[0])"
        # Link ends the Claude Code it took over on Linux/macOS; here that process is on
        # Windows, so end it ourselves, but only once the new session really exists.
        if ($script:LastExit -eq 0 -and $Rest.Count -ge 3 -and $Rest[2] -match '^\d+$') {
            Write-Host "Closing this Claude Code; the conversation continues in Sesame."
            Start-Sleep -Seconds 1
            Close-OriginalClaude ([int]$Rest[2]) "claude-on-call: this conversation now continues in Sesame (https://link.sesame.com). Closing this Claude Code."
        }
    }
    "web"      { Start-Process "https://link.sesame.com" }
    "fix-terminal" {
        # Repair a console left with mouse reporting on (garbage like ^[[<35;96;27M).
        Reset-ConsoleModes
        Write-Host "Terminal modes reset."
        $script:LastExit = 0
    }
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
