#!/bin/sh
# claude-on-call for macOS.
#
# Sesame Link already runs natively on macOS, so on a Mac claude-on-call is a
# thin layer: it installs Sesame Link if needed, adds the `oncall` command, and
# installs Claude Code's /open-sesame command so any running conversation can
# be handed to Sesame.
#
#   curl -fsSL https://raw.githubusercontent.com/levfo/claude-on-call/main/mac/install.sh | sh
set -eu

step() { printf '==> %s\n' "$1"; }
BIN_DIR="${ONCALL_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

command -v claude >/dev/null 2>&1 || {
    echo "claude-on-call: Claude Code (claude) is not installed. Install it first: https://code.claude.com/docs/en/setup" >&2
    exit 1
}

if ! command -v tmux >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        step "Installing tmux with Homebrew"
        brew install tmux
    else
        echo "claude-on-call: tmux 3.4+ is required (brew install tmux)" >&2
        exit 1
    fi
fi

if ! command -v sesame-link >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/sesame-link" ]; then
    step "Installing Sesame Link"
    curl -fsSL https://storage.googleapis.com/sesame-link/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

step "Installing the oncall command to $BIN_DIR/oncall"
cat > "$BIN_DIR/oncall" <<'SH'
#!/bin/sh
# claude-on-call (macOS): voice-call your Claude Code sessions from anywhere.
export PATH="$HOME/.local/bin:$PATH"
cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
    login)    exec sesame-link auth login "$@" ;;
    start)    exec sesame-link start --open-terminal off "$@" ;;
    stop|restart|status|logs|doctor|sessions|update|config) exec sesame-link "$cmd" "$@" ;;
    claude)   exec sesame-link claude "$@" ;;
    attach)   exec sesame-link sessions attach "$@" ;;
    handoff)  exec sesame-link open-sesame "$@" ;;
    web)      open "https://link.sesame.com" ;;
    help|*)
        cat <<'TXT'
oncall - Claude Code on call. Reach your coding sessions by voice or from any device.

  oncall login            sign in to Sesame and add this Mac
  oncall start            start Sesame Link in the background (restarts at login)
  oncall status           is this Mac connected? is Claude Code ready?
  oncall claude [args]    start Claude Code here as a session Sesame can see, and attach
  oncall sessions         list sessions; `oncall attach <id>` to attach
  oncall handoff          (run from inside Claude Code via /open-sesame) move this conversation to Sesame
  oncall logs|doctor|stop|restart|update
  oncall web              open link.sesame.com
TXT
        ;;
esac
SH
chmod +x "$BIN_DIR/oncall"

step "Installing Claude Code's /open-sesame command"
sesame-link install-claude-command >/dev/null 2>&1 || true

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: add $BIN_DIR to your PATH, e.g.  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

echo
echo "claude-on-call installed. Next:"
echo "  oncall login     # sign in to Sesame"
echo "  oncall start     # start Sesame Link"
echo "  oncall claude    # in a project folder: start a session Sesame can reach"
