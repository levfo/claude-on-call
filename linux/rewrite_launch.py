#!/usr/bin/env python3
"""Rewrite Sesame Link's generated --settings and --mcp-config for Windows Claude Code.

Link generates two JSON files per session. Every hook and the MCP server in them
run `sesame-link hook-forward ...` / `sesame-link mcp-forward ...` on Linux.
Windows Claude Code cannot run those directly, so each one becomes

    wsl.exe -d <distro> -u <user> -- <hook-relay> <HOOK_URL> <MCP_URL> <original args...>

which hops back into WSL, restores the per-session environment Link set, fixes
Windows paths in the payload, and forwards to the real sesame-link.

Also pre-trusts the session folder in Windows Claude Code's config so a remote
session does not sit on the "do you trust this folder" dialog where nobody can
answer it.

Prints the rewritten argument list, one argument per line.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ONCALL_HOME = os.environ.get("ONCALL_HOME", os.path.expanduser("~/.claude-on-call"))


def read_config():
    cfg = {}
    with open(os.path.join(ONCALL_HOME, "config")) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def wslpath_w(p):
    return subprocess.check_output(["wslpath", "-w", p]).decode().strip()


def relay_prefix(cfg):
    return [
        "-d", cfg["WSL_DISTRO"],
        "-u", cfg["LINUX_USER"],
        "--",
        os.path.join(ONCALL_HOME, "bin", "hook-relay"),
        os.environ.get("SESAME_LINK_HOOK_URL", ""),
        os.environ.get("SESAME_LINK_MCP_URL", ""),
        # Link's working directory for this session. Link validates every hook's cwd
        # and transcript path against it, while Windows Claude Code reports wherever
        # the conversation has cd'd to, so the relay pins both to this folder.
        os.getcwd(),
    ]


def rewrite_command(entry, prefix):
    cmd = entry.get("command", "")
    if cmd.endswith("sesame-link") or cmd.endswith("sesame-link.exe"):
        entry["args"] = prefix + list(entry.get("args", []))
        entry["command"] = "wsl.exe"
    return entry


def pretrust(cfg, win_cwd):
    """Mark the session folder trusted in Windows Claude Code's ~/.claude.json."""
    if os.environ.get("ONCALL_AUTO_TRUST", "1") != "1":
        return
    path = os.path.join(cfg["WIN_HOME"], ".claude.json")
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    except Exception:
        return  # never break a launch over this
    projects = data.setdefault("projects", {})
    entry = projects.setdefault(win_cwd, {})
    if entry.get("hasTrustDialogAccepted") is True:
        return
    entry["hasTrustDialogAccepted"] = True
    tmp = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path), delete=False, suffix=".tmp")
    try:
        json.dump(data, tmp, indent=2)
        tmp.close()
        os.replace(tmp.name, path)
    except Exception:
        try:
            os.unlink(tmp.name)
        except Exception:
            pass


def main(argv):
    cfg = read_config()
    args = list(argv)
    if "--session-id" in args:
        sid = args[args.index("--session-id") + 1]
    elif "--resume" in args and args.index("--resume") + 1 < len(args):
        sid = "resume-" + args[args.index("--resume") + 1]
    else:
        sid = "launch-" + str(os.getpid())
    outdir = os.path.join(cfg["WIN_STATE"], "sessions", sid)
    os.makedirs(outdir, exist_ok=True)
    prefix = relay_prefix(cfg)

    out = []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--settings", "--mcp-config") and i + 1 < len(args) and os.path.isfile(args[i + 1]):
            with open(args[i + 1]) as f:
                doc = json.load(f)
            if a == "--settings":
                for groups in doc.get("hooks", {}).values():
                    for group in groups:
                        group["hooks"] = [rewrite_command(h, prefix) for h in group.get("hooks", [])]
                # Claude Code draws a dim "suggested next prompt" in the empty composer
                # after each turn. Through WSL interop the dim attribute is lost, so Link
                # reads the suggestion as an unsent draft and holds remote messages
                # ("Held by the terminal"). Remote sessions don't need suggestions.
                doc["promptSuggestionEnabled"] = False
                doc.setdefault("env", {})["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "0"
                # Messages from other Claude Code sessions on this machine (the team
                # manager pattern) are held for terminal approval by default when a
                # session bypasses permissions. Nobody can approve them from Sesame,
                # so accept them. ONCALL_CROSS_SESSION=hold restores the default.
                doc["crossSessionInbound"] = os.environ.get("ONCALL_CROSS_SESSION", "accept")
            else:
                for server in doc.get("mcpServers", {}).values():
                    rewrite_command(server, prefix)
            dst = os.path.join(outdir, os.path.basename(args[i + 1]))
            with open(dst, "w") as f:
                json.dump(doc, f, indent=1)
            out += [a, wslpath_w(dst)]
            i += 2
            continue
        out.append(a)
        i += 1

    try:
        pretrust(cfg, wslpath_w(os.getcwd()))
    except Exception:
        pass

    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1:])
