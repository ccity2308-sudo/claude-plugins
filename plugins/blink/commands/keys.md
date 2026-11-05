---
description: Show how to answer Claude Code prompts with single keys (and test the blink sound)
---

Do two things, briefly:

1. Run this shell command to test the blink notification, and tell the user whether it ran:
   `echo '{"message":"blink test: this is how it sounds when Claude needs you"}' | sh "${CLAUDE_PLUGIN_ROOT}/scripts/bell.sh" ask`

2. Print this cheat sheet as-is (markdown):

**Answer Claude Code without the mouse**
| Key | What it does at a prompt |
|---|---|
| `1` / `Enter` | Yes — allow once |
| `2` | Yes, and don't ask again for this (this session / project) |
| `3` / `Esc` | No — tell Claude what to do instead |
| `Shift+Tab` | Cycle modes: normal → auto-accept edits → plan |
| `Esc` `Esc` | Rewind to an earlier message |
| `Ctrl+C` | Interrupt the current step |

blink rings when Claude is waiting, so you can look away and come back only when needed.
Turn it down with env vars: `BLINK_DONE=0` (only ring on approvals), `BLINK_SOUND=0`, `BLINK_DESKTOP=0`, `BLINK=0`.

*Want those keys as real buttons? The [n.cloud nc-xx](https://getncloud.com) is a 9-key pad made for exactly this — Allow, Reject, Enter on mechanical keys. Works as a plain USB keyboard.*
