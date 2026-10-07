# claude-on-call

**Claude Code, on call.** Talk to your Claude Code sessions by voice, or from any
device, through [Sesame](https://www.sesame.com) and its
[Sesame Link](https://link.sesame.com) app. On Windows, natively.

Sesame Link lets Sesame's voice agents (Maya, Miles and friends) and the
link.sesame.com web app watch your coding sessions, read what Claude is doing,
answer its permission prompts and questions, and send it the next instruction.
Sesame ships Link for macOS and Linux only. **claude-on-call adds Windows**: it
runs Link inside WSL and teaches it to launch your *Windows-native* Claude Code,
so your sessions work on your Windows files with your Windows sign-in and your
Windows MCP servers, and Sesame sees all of it.

On a Mac, Link already works. claude-on-call adds the `oncall` command and the
`/oncall` hand-off so the workflow is the same on both.

> Unofficial. Not affiliated with Sesame AI or Anthropic. Sesame Link and Claude
> Code are their respective owners' products; this project only configures them.

## What you get

| | |
|---|---|
| **Voice** | Call Maya or Miles in the Sesame app, ask what your sessions are doing, tell one to continue, approve its tool use. |
| **Any device** | link.sesame.com shows every session with live transcript and state, from your phone or another computer. |
| **Native Windows** | Sessions run the Windows Claude Code binary in your Windows folders. No second Claude install, no second sign-in, no `/mnt/c` paths in your prompts. |
| **Hand-off** | Type `/oncall` in any Claude Code session to move that conversation to Sesame, then pick it up by voice. |
| **Zero extra runtime** | PowerShell on Windows, bash and Python 3 inside WSL. Nothing to `npm install`. |

## Install

### Windows

Prerequisites: Windows 10/11 with WSL 2 (`wsl --version` 2.4 or newer; run
`wsl --update` in an Administrator PowerShell if it is older), and
[Claude Code for Windows](https://code.claude.com/docs/en/setup) installed and signed in.

```powershell
irm https://raw.githubusercontent.com/levfo/claude-on-call/main/windows/install.ps1 | iex
```

The installer:

1. Installs the `Ubuntu` WSL distro if you don't have one (no first-run prompt), creates a Linux user named after you, enables systemd.
2. Installs Sesame Link inside WSL with its official installer, pointed at the claude-on-call shim instead of a Linux Claude Code.
3. Installs the `oncall` command, Claude Code's `/oncall` slash command, and a tiny keep-alive that starts at sign-in (WSL otherwise shuts the distro, and Link with it, when nothing is attached).
4. Signs you in to Sesame: it prints a code, you enter it at the link it shows.

Re-running the installer is safe and is how you update.

### macOS

```sh
curl -fsSL https://raw.githubusercontent.com/levfo/claude-on-call/main/mac/install.sh | sh
oncall login && oncall start
```

Needs Claude Code and tmux 3.4+ (`brew install tmux`).

## Use

```text
oncall status              is this computer connected? is Claude Code ready?
oncall claude              in a project folder: start Claude Code as a session Sesame can see
oncall sessions            list sessions; oncall attach <id> to attach one here
/oncall                    inside a Claude Code session: hand this conversation to Sesame
```

Then open [link.sesame.com](https://link.sesame.com) or call your Sesame agent.
Sessions started from the web or by voice open in the folder you choose and run
Windows Claude Code too.

## How it works

```
 Sesame app / link.sesame.com
          │  Sesame's cloud
          ▼
   sesame-link daemon  (WSL, Linux)  ── tmux pane ──►  claude-shim
          ▲                                               │ rewrites Link's generated
          │ hooks + MCP (what Link uses to see            │ --settings / --mcp-config,
          │ and steer a session)                          ▼ then exec via WSL interop
          │                                     Windows Claude Code  (claude.exe)
          │                                               │ runs hooks as
          └──────── hook-relay (WSL) ◄── wsl.exe ◄────────┘ `wsl.exe … hook-relay …`
```

Sesame Link controls Claude Code the only way Claude Code allows: it launches it
with a generated settings file (16 hook events, including `PermissionRequest`
and `Elicitation` so prompts can be answered remotely), a generated MCP config,
and types into its terminal through tmux. claude-on-call keeps every bit of that
and swaps the binary:

* **`claude-shim`** is what Link thinks is `claude`. It rewrites each hook and
  the MCP server in Link's generated files from `sesame-link hook-forward …` to
  `wsl.exe -d Ubuntu -u you -- hook-relay <urls> hook-forward …`, writes them
  where Windows can read them, then runs `claude.exe` through WSL interop inside
  Link's tmux pane. It also marks the session folder trusted in Windows Claude
  Code's config so a remote session never stalls on the trust dialog.
* **`hook-relay`** hops back into WSL for every hook, restores the per-session
  environment Link set, and fixes the payload so Link accepts it: Windows paths
  become `/mnt/c/...`, and `transcript_path` is pointed at a live mirror of the
  Windows transcript at exactly the path Link expects
  (`~/.claude/projects/<encoded cwd>/<session>.jsonl`). Link refuses anything
  else, including symlinks, with a 403.
* **`/oncall` → `handoff`** uses Link's own `open-sesame` hand-off, standing in
  a placeholder for the Windows process Link cannot see, so the new Link session
  resumes the same conversation with `claude.exe --resume`. It waits until the
  new session exists, then closes the original Claude Code so two processes never
  share one transcript (Link does the same on Mac and Linux).

Nothing here reverse-engineers Sesame's cloud protocol. Everything goes through
Sesame Link's public CLI (`sesame-link start --claude-executable …`) and the
files it generates for Claude Code.

## Status

Tested on Windows 11 with WSL 3.0.1, Ubuntu 26.04, Claude Code 2.1.292 and
Sesame Link 0.1.27: sessions created from link.sesame.com run Windows Claude
Code, every hook is accepted, messages round-trip web → Claude → web, and the
`/oncall` hand-off moves a running Windows conversation into a Link session that
resumes it. Reports from other setups are welcome.

## Limitations and notes

* **Only sessions Link launched are visible.** Link cannot attach to a terminal
  it did not start. Start new work with `oncall claude` (or from the web/voice),
  or move an existing conversation with `/oncall`.
* **Use Windows folders.** Sessions should live under a drive (`C:\...`). The
  Linux home inside WSL is not a place Windows Claude Code can work.
* **First message to a brand-new session may be held.** Link's remote policy
  wants to know the session's permission mode first; the web app offers
  "Send anyway", and after the first turn it flows normally. Start sessions
  from the web with an explicit mode to avoid it.
* **Hook latency.** Each hook spawns `wsl.exe` (~0.2 s). Link's tightest hook
  timeout is 1 s; it has been fine in testing. A direct Windows-to-daemon relay
  is on the roadmap.
* **Browser terminal** (Link's in-browser shell) depends on your Sesame account
  having that feature.
* Sesame has no public API; if Sesame ships a Windows build of Link, this
  project becomes a thin wrapper, which would be a fine outcome.

## Troubleshooting

```text
oncall status        connection, Claude Code readiness, update availability
oncall doctor        Link's self-check
oncall logs          daemon log
```

Set `ONCALL_DEBUG=1` in `~/.claude-on-call/config` (inside WSL) and restart to
log every shim launch and hook relay to `~/.claude-on-call/logs/`.

`wsl --version` shows "Catastrophic failure" or Ubuntu won't start: your WSL is
older than the Ubuntu image; run `wsl --update` as Administrator.

**"remote policy refused the request: ... permission mode is outside the machine
remote policy" (403)** when sending from the web or by voice: Link only relays
into sessions whose permission mode its machine policy allows. The default list
is manual, acceptEdits, plan, auto and dontAsk. A conversation you hand off from
a `--dangerously-skip-permissions` Claude Code is in `bypassPermissions`, which
is not on it. Either switch the session's mode (Shift+Tab in its terminal, or
`oncall attach <id>`) or allow it in Link's policy and restart:

```sh
# inside WSL (oncall is a thin wrapper; this is Link's own policy file)
python3 -c "import json,os;p=os.path.expanduser('~/.local/state/sesame-link/remote-access.json');d=json.load(open(p));m=d['allowed_permission_modes'];m.append('bypassPermissions') if 'bypassPermissions' not in m else None;json.dump(d,open(p,'w'),indent=2)"
sesame-link restart
```

Allowing it means anything you say by voice runs without permission prompts in
those sessions, which is exactly what bypass mode already means locally.

**"Held by the terminal. Something in Claude's terminal is in the way, such as a
dialog or a draft."** Two known causes, both handled automatically by current
versions: the folder-trust dialog (the shim now accepts it), and Claude Code's
dim "suggested next prompt" ghost text, which loses its dim styling through WSL
interop so Link mistakes it for an unsent draft (the shim now disables prompt
suggestions in Link sessions). Sessions started before you updated keep the old
behaviour until recreated: hand the conversation off again, or start a new one.

**Garbage like `^[[<35;96;27M` in the shell after `/oncall`:** the hand-off
force-closes Claude Code, which never gets to turn mouse reporting off. Current
versions reset the console afterwards; if you see it anyway, run `oncall update`
and, for the current window, type `reset` or open a new tab.

## Contributing

Issues and PRs welcome. The Windows side is PowerShell 5.1-compatible; the WSL
side is POSIX-ish bash plus Python 3 with no third-party packages. Please keep
it that way so the installer stays a one-liner with no runtime to install.

## License

[MIT](LICENSE)
