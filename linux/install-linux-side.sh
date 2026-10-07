#!/bin/bash
# claude-on-call: WSL-side installer. Run as the Linux user, from the Windows
# installer or by hand:
#   bash install-linux-side.sh --src <repo dir> --win-claude <path to claude.exe> \
#        --win-home <path to C:\Users\you> --distro Ubuntu
set -eu

SRC=""; WIN_CLAUDE=""; WIN_HOME=""; DISTRO="Ubuntu"
while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="$2"; shift 2 ;;
        --win-claude) WIN_CLAUDE="$2"; shift 2 ;;
        --win-home) WIN_HOME="$2"; shift 2 ;;
        --distro) DISTRO="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ -n "$SRC" ] && [ -n "$WIN_CLAUDE" ] && [ -n "$WIN_HOME" ] || { echo "usage: --src DIR --win-claude FILE --win-home DIR [--distro NAME]" >&2; exit 2; }

ONCALL_HOME="$HOME/.claude-on-call"
step() { printf '==> %s\n' "$1"; }

step "Installing claude-on-call files to $ONCALL_HOME"
mkdir -p "$ONCALL_HOME/bin" "$ONCALL_HOME/logs"
for f in claude-shim hook-relay claude keepalive start-link handoff rewrite_launch.py fix_payload.py; do
    sed 's/\r$//' "$SRC/linux/$f" > "$ONCALL_HOME/bin/$f"
    chmod +x "$ONCALL_HOME/bin/$f"
done

WIN_STATE="$WIN_HOME/.claude-on-call"
mkdir -p "$WIN_STATE/sessions"
cat > "$ONCALL_HOME/config" <<EOF
# claude-on-call configuration (sourced by bash, parsed as KEY=VALUE by python)
WIN_CLAUDE=$WIN_CLAUDE
WIN_HOME=$WIN_HOME
WIN_STATE=$WIN_STATE
WSL_DISTRO=$DISTRO
LINUX_USER=$(id -un)
EOF

step "Adding $ONCALL_HOME/bin and ~/.local/bin to PATH"
for rc in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$rc"
    grep -q 'claude-on-call/bin' "$rc" || printf '\nexport PATH="$HOME/.local/bin:$HOME/.claude-on-call/bin:$PATH"\n' >> "$rc"
done
export PATH="$HOME/.local/bin:$ONCALL_HOME/bin:$PATH"

step "Checking tools (tmux >= 3.4, curl, unzip, python3)"
missing=""
for t in tmux curl unzip python3; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
    step "Installing:$missing"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing
fi
tmux -V

step "Checking Windows Claude Code through the shim"
"$ONCALL_HOME/bin/claude" --version

if ! command -v sesame-link >/dev/null 2>&1; then
    step "Installing Sesame Link"
    curl -fsSL https://storage.googleapis.com/sesame-link/install.sh | sh
else
    step "Sesame Link already installed: $(sesame-link --version)"
fi

if sesame-link status 2>/dev/null | grep -qE "isn't signed in|not signed in"; then
    step "Not signed in to Sesame yet; the daemon starts after 'oncall login'"
else
    step "Starting Sesame Link with the Windows Claude Code shim"
    sesame-link stop >/dev/null 2>&1 || true
    "$ONCALL_HOME/bin/start-link"
fi

echo
sesame-link status || true
