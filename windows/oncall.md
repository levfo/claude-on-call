---
description: Hand this conversation to Sesame so you can continue it by voice or from any device (claude-on-call)
allowed-tools: Bash(oncall handoff:*)
disable-model-invocation: true
---
!`oncall handoff "$CLAUDE_CODE_SESSION_ID" "$PWD"`

The output above is from claude-on-call. Tell the user in one sentence what it says happened, and do nothing else.
