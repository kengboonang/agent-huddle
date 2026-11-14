#!/bin/zsh
# Removes Agent Huddle and its Claude Code settings. Handoff documents (~/claude-handoffs) and evidence logs (~/claude-evidence) are kept.
set -uo pipefail

ROOT="${0:A:h}"
pkill -x AgentHuddle 2>/dev/null
/usr/bin/python3 "$ROOT/scripts/settings.py" uninstall
rm -f "$HOME/Library/LaunchAgents/local.agent-huddle.plist"
rm -rf "$HOME/Applications/Agent Huddle.app" "$HOME/.claude/huddle"
echo "Agent Huddle is removed. Your files in ~/claude-handoffs and ~/claude-evidence are kept."
