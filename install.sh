#!/bin/zsh
# Builds Agent Huddle, installs it, and connects it to Claude Code.
#   ./install.sh                  install or update
#   ./install.sh --no-login-item  do not start the widget at login
set -euo pipefail

ROOT="${0:A:h}"
APP="$HOME/Applications/Agent Huddle.app"
BIN="$HOME/.claude/huddle/bin"
AGENT="$HOME/Library/LaunchAgents/local.agent-huddle.plist"
LOGIN_ITEM=1
[[ "${1:-}" == "--no-login-item" ]] && LOGIN_ITEM=0

echo "Building…"
swift build -c release --package-path "$ROOT" 2>&1 | grep -E "error|Build complete" || true
BUILT="$(swift build -c release --package-path "$ROOT" --show-bin-path)/AgentHuddle"
[[ -x "$BUILT" ]] || { echo "Build failed."; exit 1; }

pkill -x AgentHuddle 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILT" "$APP/Contents/MacOS/AgentHuddle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Huddle</string>
  <key>CFBundleIdentifier</key><string>local.agent-huddle</string>
  <key>CFBundleExecutable</key><string>AgentHuddle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Agent Huddle selects the Terminal tab that runs a session when you click Open.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1

mkdir -p "$BIN" "$HOME/claude-handoffs"
chmod 700 "$HOME/.claude/huddle"
cp "$ROOT/hooks/huddle_hook.py" "$ROOT/hooks/huddle_statusline.py" "$ROOT/hooks/handoff.py" "$BIN/"
/usr/bin/python3 "$ROOT/scripts/settings.py" install

if (( LOGIN_ITEM )); then
  mkdir -p "${AGENT:h}"
  cat > "$AGENT" <<AGENT_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.agent-huddle</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
AGENT_PLIST
fi

open "$APP"
echo "Agent Huddle is running: look in the bottom-right corner of the screen."
echo "Sessions you start from now on use the new hooks. Restart sessions that are already open."
