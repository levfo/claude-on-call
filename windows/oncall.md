---
description: Hand this conversation to Sesame so you can continue it by voice or from any device (claude-on-call)
allowed-tools: Bash(*claude-on-call/bin/oncall.cmd handoff:*)
disable-model-invocation: true
---
!`"$LOCALAPPDATA/claude-on-call/bin/oncall.cmd" handoff "$CLAUDE_CODE_SESSION_ID" "$PWD" "$CLAUDE_PID"`

The output above is from claude-on-call. If it reports a new session, this Claude Code is about to close and the conversation continues in Sesame. Tell the user in one sentence what the output says happened, and do nothing else.
