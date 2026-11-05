---
description: Open blink settings (sound per agent, ring on finish, quick replies, card position, volume)
---

Run this shell command: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/bell.sh" settings`

On Windows it opens the blink settings window; tell the user the changes save as they click.
On macOS and Linux it prints the path of the settings file. Offer to edit it for them. The keys, one `key=value` per line:
- `claude.enabled`, `codex.enabled`: `1` or `0`
- `claude.theme`, `codex.theme`: `eyes`, `glass`, `bell`, `system` or `off`
- `claude.done_after`: `0` (always ring when Claude finishes), a number of seconds the turn must have taken (default `30`), or `never`; `codex.done_after`: `0` or `never`
- `claude.quick` (`1`/`0`) and `claude.quick_wait` (seconds): Allow / Deny on the card, Windows only
- `popup` (`1`/`0`), `position` (`top-right` or `bottom-right`), `volume` (`35`, `70`, `100`)
