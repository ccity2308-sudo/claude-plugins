---
description: Show both blink notifications (needs you, finished) so you can see and hear them
---

Run this shell command: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/bell.sh" test`

It shows a "needs you" card with Allow / Deny buttons (it waits up to 20 seconds for a click; nothing is really allowed, it is a test), then a "finished" card. Then tell the user, briefly:
- they should have heard two sounds and seen two cards (on macOS and Linux: two system notifications);
- `/blink:settings` changes the sound per agent, when to ring on finish, quick replies, where the card shows and the volume;
- if the Claude desktop app also shows its own banners, they can turn those off in Settings → Claude Code → Notifications, so only blink pops up.
