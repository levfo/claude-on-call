#!/usr/bin/env python3
"""Make a Windows Claude Code hook payload look like one from Linux Claude Code.

Sesame Link validates two things in every hook payload:

* `cwd` must be the session's working directory as Link knows it (a /mnt/... path).
* `transcript_path` must be exactly `~/.claude/projects/<encoded cwd>/<session id>.jsonl`
  on the Linux side, and it must be a real file (Link canonicalizes the path, so
  a symlink to the Windows transcript is refused with 403).

Windows Claude Code reports `C:\\...` paths and writes its transcript under the
Windows home. This script translates the paths and keeps a live mirror of the
Windows transcript at the path Link expects, using a polling `tail -F` (inotify
does not fire on DrvFs mounts). On SessionEnd the mirror is stopped.

Reads the payload on stdin, writes the fixed payload on stdout.
"""
import json
import os
import re
import signal
import subprocess
import sys

BACKSLASH = chr(92)


def is_windows_path(p):
    return isinstance(p, str) and len(p) > 2 and p[1] == ":" and p[2] in (BACKSLASH, "/")


def to_linux(p):
    if is_windows_path(p):
        return subprocess.check_output(["wslpath", "-u", p]).decode().strip()
    return p


def encode_project_dir(cwd):
    # Claude Code names the per-project transcript folder after the cwd with
    # every non-alphanumeric character replaced by '-'.
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def mirror_alive(pidfile):
    try:
        with open(pidfile) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return None


def start_mirror(src, dst, pidfile):
    out = open(dst, "wb")  # truncate; tail -c +1 replays the whole file
    proc = subprocess.Popen(
        ["tail", "---disable-inotify", "-s", "0.3", "-F", "-c", "+1", src],
        stdout=out, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    with open(pidfile, "w") as f:
        f.write(str(proc.pid))


def stop_mirror(pidfile):
    pid = mirror_alive(pidfile)
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
    try:
        os.unlink(pidfile)
    except Exception:
        pass


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw or "{}")

    if "cwd" in payload:
        payload["cwd"] = to_linux(payload["cwd"])

    if payload.get("transcript_path") and payload.get("cwd") and payload.get("session_id"):
        win_transcript = to_linux(payload["transcript_path"])
        project_dir = os.path.expanduser("~/.claude/projects/" + encode_project_dir(payload["cwd"]))
        mirror = os.path.join(project_dir, payload["session_id"] + ".jsonl")
        pidfile = mirror + ".mirror.pid"
        os.makedirs(project_dir, exist_ok=True)
        if os.path.islink(mirror):
            os.unlink(mirror)
        if payload.get("hook_event_name") == "SessionEnd":
            # Give the mirror a moment to catch the final lines, then stop it.
            subprocess.call(["sleep", "0.5"])
            stop_mirror(pidfile)
        elif not mirror_alive(pidfile):
            start_mirror(win_transcript, mirror, pidfile)
        payload["transcript_path"] = mirror

    sys.stdout.write(json.dumps(payload))


if __name__ == "__main__":
    main()
