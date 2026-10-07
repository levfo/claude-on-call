---
description: Hand this conversation to Sesame so you can continue it by voice or from any device (claude-on-call)
allowed-tools: Bash(*claude-on-call/bin/oncall.cmd handoff:*)
disable-model-invocation: true
---
!`"$LOCALAPPDATA/claude-on-call/bin/oncall.cmd" handoff "$CLAUDE_CODE_SESSION_ID" "$PWD"`

The output above is from claude-on-call. Tell the user in one sentence what it says happened, and do nothing else.
