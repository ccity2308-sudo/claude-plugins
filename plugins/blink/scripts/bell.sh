#!/bin/sh
# blink: sound + a notification card when your coding agent needs you or is done.
#   bell.sh start            Claude Code UserPromptSubmit: remember when the turn started, mark the agent as working
#   bell.sh tick             Claude Code PostToolUse: a request answered in the terminal, so the agent is working again
#   bell.sh end              Claude Code SessionEnd: the agent leaves the agent bar
#   bell.sh ask              Claude Code PermissionRequest / AskUserQuestion / Notification (hook JSON on stdin)
#   bell.sh done             Claude Code Stop (hook JSON on stdin)
#   bell.sh codex JSON       Codex CLI `notify` program (event JSON as the argument)
#   bell.sh settings         open the settings window (Windows) or print where the settings file is
#   bell.sh test             show and play both notifications for Claude Code
# Settings live in a small key=value file (see `settings`); env vars override it:
#   BLINK=0  BLINK_SOUND=0  BLINK_DESKTOP=0  BLINK_DONE=0  BLINK_THEME=eyes|glass|bell|system|off
# Never fails the hook: every branch ends with exit 0.

cmd="${1:-ask}"
here="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*|*_NT*) os=win ;; Darwin) os=mac ;; Linux) os=linux ;; *) os=other ;; esac

if [ "$os" = win ]; then
  cfgdir="$(cygpath -u "$APPDATA" 2>/dev/null)/blink"; state="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null)/blink"
else
  cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/blink"; state="${XDG_CACHE_HOME:-$HOME/.cache}/blink"
fi
conf="$cfgdir/settings.conf"
mkdir -p "$state" 2>/dev/null
[ -f "$conf" ] || { old="${cfgdir%/blink}/agent-bell/settings.conf"; [ -f "$old" ] && mkdir -p "$cfgdir" && cp "$old" "$conf"; }   # the old name's settings

cfg() { v="$(sed -n "s/^$1=//p" "$conf" 2>/dev/null | tail -1 | tr -d '\r')"; printf '%s' "${v:-$2}"; }

notchbin() { printf '%s/notch-%s' "$state" "$(cksum < "$here/scripts/notch.swift" | cut -d' ' -f1)"; }
ui() {   # The resident helper draws the cards and the agent bar (Windows) or the notch (Mac); start it if it is not running
  hb="$state/heartbeat"; now=$(date +%s)
  if [ "$os" = mac ]; then
    if stamp="$(stat -f %m "$hb" 2>/dev/null)"; [ -n "$stamp" ] && [ $((now - stamp)) -le 15 ]; then return; fi
    nb="$(notchbin)"; [ -x "$nb" ] || return
    touch "$hb"; nohup "$nb" "$state" "$conf" >/dev/null 2>&1 &
    return
  fi
  if [ ! -f "$hb" ] || [ $((now - $(date -r "$hb" +%s 2>/dev/null || echo 0))) -gt 15 ]; then
    touch "$hb"   # claim the start so two hooks firing together do not launch two helpers
    powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$(cygpath -w "$here/scripts/ui.ps1")" "$@" >/dev/null 2>&1 &
  fi
}
live() {   # Is there a helper to talk to? Windows always; a Mac once the notch is built and chosen.
  [ "$os" = win ] && return 0
  [ "$os" = mac ] && [ "$(cfg popup 1)" = 1 ] && [ "$(cfg mac.style notch)" = notch ] && [ -x "$(notchbin)" ]
}

case "$cmd" in
  settings)
    if [ "$os" = win ]; then wscript.exe "$(cygpath -w "$here/scripts/open-settings.vbs")" >/dev/null 2>&1 &   # no console window
    else echo "blink settings file: $conf"; fi
    exit 0 ;;
  test)
    printf '%s' '{"session_id":"blink-test-1","hook_event_name":"PermissionRequest","cwd":"blink","tool_name":"Bash","tool_input":{"command":"npm test"}}' | BLINK_KIND=ask sh "$0" ask
    sleep 2
    printf '%s' '{"session_id":"blink-test-2","cwd":"blink"}' | BLINK_FORCE_DONE=1 sh "$0" done
    exit 0 ;;
esac

agent=claude
if [ "$cmd" = codex ]; then
  agent=codex; input="$2"
  case "$input" in *approval*) kind=ask ;; *) kind=done ;; esac
else
  input="$(cat 2>/dev/null || true)"; kind="$cmd"
fi

# cut -c counts bytes, so a limit can land inside a Cyrillic letter and the card shows a broken one: iconv -c drops that tail.
clip() { cut -c1-"$1" | { if command -v iconv >/dev/null 2>&1; then iconv -c -f UTF-8 -t UTF-8 2>/dev/null; else cat; fi; }; }

# Pull a string field out of the event JSON without jq/python (first match wins).
field() {
  printf '%s' "$input" | tr '\n' ' ' | sed 's/\\"/'"'"'/g' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1 | clip 200
}
sid="$(field session_id)"; [ -z "$sid" ] && sid="$(field thread-id)"; sid="$(printf '%s' "${sid:-x}" | tr -cd 'A-Za-z0-9_-' | cut -c1-40)"
now=$(date +%s)

# PostToolUse fires for every tool: leave at once unless this session was waiting for an answer.
if [ "$kind" = tick ]; then [ -f "$state/$sid.asking" ] || exit 0; rm -f "$state/$sid.asking"; fi

# Which session is ringing: its title as the sidebar shows it (the last "customTitle" in the transcript; only the end
# of the file is read, so this stays fast on long sessions), else the cached first message.
session_name() {
  tp="$(field transcript_path | sed 's/\\\\/\\/g')"; [ "$os" = win ] && [ -n "$tp" ] && tp="$(cygpath -u "$tp" 2>/dev/null)"
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    t="$(tail -c 3000000 "$tp" 2>/dev/null | grep -o '"customTitle":"[^"]*"' | tail -n1 | sed 's/^"customTitle":"//; s/"$//')"
    [ -n "$t" ] && { printf '%s' "$t" | clip 160 > "$state/$sid.name"; cat "$state/$sid.name"; return; }
  fi
  clip 160 < "$state/$sid.name" 2>/dev/null
}

[ "${BLINK:-1}" = 0 ] && exit 0
[ "$(cfg "$agent.enabled" 1)" = 0 ] && exit 0

proj="$(field cwd)"; proj="${proj##*[/\\]}"

# A status line for the agent bar: no sound, no card.
status() {
  live || return 0
  mkdir -p "$state/spool"; f="$state/spool/$now-$$-s"
  { printf 'agent=%s\nkind=%s\nkey=%s\nproject=%s\n' "$agent" "$1" "$agent-$sid" "$proj"
    [ "$agent" = claude ] && printf 'session=%s\n' "$(session_name | tr -d '\r\n')"
  } > "$f.tmp"; mv "$f.tmp" "$f.evt"
  ui
}
case "$kind" in
  start)
    echo "$now" > "$state/$sid.start"
    # Until the session has a title, name it by the start of its first message.
    [ -s "$state/$sid.name" ] || field prompt | tr -s '[:space:]' ' ' | clip 120 > "$state/$sid.name"
    status work; exit 0 ;;
  tick) status work; exit 0 ;;
  end) rm -f "$state/$sid.asking"; status end; exit 0 ;;
esac
msg="$(field message)"; [ -z "$msg" ] && msg="$(field last-assistant-message)"
tool="$(field tool_name)"; command="$(field command)"; question="$(field question)"

if [ "$kind" = ask ]; then
  case "$msg" in
    *"waiting for your input"*)   # the 60 s idle reminder after a turn: skip it if we just rang "done"
      [ -f "$state/$sid.done" ] && [ $((now - $(cat "$state/$sid.done"))) -lt 300 ] && exit 0 ;;
    *uthenticat*|*"logged in"*) exit 0 ;;
  esac
  # Permission prompts and questions can be switched off separately.
  ev="$(field hook_event_name)"
  case "$ev:$msg" in PermissionRequest:*|Notification:*ermission*) what=permission ;; *) what=question ;; esac
  [ "$(cfg "$agent.on_$what" 1)" = 0 ] && exit 0
  # PermissionRequest and Notification both fire for one prompt: ring once.
  [ -f "$state/$sid.ask" ] && [ $((now - $(cat "$state/$sid.ask"))) -lt 4 ] && exit 0
  echo "$now" > "$state/$sid.ask"; : > "$state/$sid.asking"
  [ -n "$question" ] && msg="$question"
  reply=""; wait="$(cfg "$agent.quick_wait" 20)"
  if live && [ "$(field hook_event_name)" = PermissionRequest ] && [ "$(cfg "$agent.quick" 1)" = 1 ] && [ "$wait" -gt 0 ] 2>/dev/null; then
    reply="$sid-$now-$$"; mkdir -p "$state/replies"
    [ -n "$tool" ] && [ -z "$command" ] && msg="Allow $tool?"
    [ -n "$command" ] && msg="Allow this command?"
  fi
  [ -z "$msg" ] && [ -n "$tool" ] && msg="Wants to use $tool"
  [ -z "$msg" ] && msg="Waiting for your answer."
  title="Needs you"
else
  rm -f "$state/$sid.asking"
  [ "${BLINK_DONE:-1}" = 0 ] && { status idle; exit 0; }
  after="$(cfg "$agent.done_after" 30)"     # never | 0 (always) | seconds the turn must have taken
  [ "$after" = never ] && [ -z "$BLINK_FORCE_DONE" ] && { status idle; exit 0; }
  if [ -z "$BLINK_FORCE_DONE" ] && [ "$agent" = claude ] && [ -f "$state/$sid.start" ] && [ "$after" -gt 0 ] 2>/dev/null; then
    [ $((now - $(cat "$state/$sid.start"))) -lt "$after" ] && { status idle; exit 0; }   # a quick answer you were watching anyway
  fi
  echo "$now" > "$state/$sid.done"
  title="Finished"; [ -z "$msg" ] && msg="Your turn."
fi

theme="${BLINK_THEME:-$(cfg "$agent.theme" eyes)}"; [ "${BLINK_SOUND:-1}" = 0 ] && theme=off
quiet="$(cfg quiet off)"                   # quiet hours, e.g. 22-08: the card still shows, the sound stays off
case "$quiet" in [0-9][0-9]-[0-9][0-9])
  h=$(date +%H); qa=${quiet%-*}; qb=${quiet#*-}; h=${h#0}; qa=${qa#0}; qb=${qb#0}; h=${h:-0}; qa=${qa:-0}; qb=${qb:-0}
  if [ "$qa" -gt "$qb" ]; then { [ "$h" -ge "$qa" ] || [ "$h" -lt "$qb" ]; } && theme=off
  else [ "$h" -ge "$qa" ] && [ "$h" -lt "$qb" ] && theme=off; fi ;;
esac
popup="$(cfg popup 1)"; [ "${BLINK_DESKTOP:-1}" = 0 ] && popup=0
label=Claude; [ "$agent" = codex ] && label=Codex
wav=""; [ "$theme" != off ] && [ "$theme" != system ] && [ -f "$here/assets/${theme}_$kind.wav" ] && wav="$here/assets/${theme}_$kind.wav"
if [ "$theme" = custom ]; then wav="$(cfg "$agent.custom_$kind")"; [ -z "$wav" ] && wav="$(cfg "$agent.custom_ask")"; [ -f "$wav" ] || wav=""; fi   # your own file

# Mac: the first build of the notch takes a while, so it runs in the background and this one ping uses the banner.
if [ "$os" = mac ] && [ "$popup" = 1 ] && [ "$(cfg mac.style notch)" = notch ]; then
  nb="$(notchbin)"
  if [ ! -x "$nb" ] && [ ! -f "$nb.building" ] && command -v swiftc >/dev/null 2>&1; then
    { touch "$nb.building"; swiftc -O -o "$nb" "$here/scripts/notch.swift" >/dev/null 2>&1; rm -f "$nb.building"; } &
  fi
fi

if live; then
  # One small UTF-8 file per event; the helper picks it up within ~50 ms. Written then renamed, so it is never read half-done.
  mkdir -p "$state/spool"; f="$state/spool/$now-$$"
  { printf 'agent=%s\nkind=%s\nkey=%s\nproject=%s\ntitle=%s\ntheme=%s\npopup=%s\n' "$agent" "$kind" "$agent-$sid" "$proj" "$title" "$theme" "$popup"
    [ "$agent" = claude ] && printf 'session=%s\n' "$(session_name | tr -d '\r\n')"
    printf 'msg=%s\n' "$msg" | tr -d '\r'
    if [ "$kind" = ask ] && [ -n "$command" ]; then printf 'cmd=%s\n' "$command"; fi
    if [ -n "$reply" ]; then printf 'reply=%s\nwait=%s\n' "$reply" "$wait"; fi
    # The helper re-reads the hook JSON with a real parser, so the card shows exactly what will run.
    if [ "$kind" = ask ] && [ -n "$input" ]; then
      printf '%s' "$input" > "$f.json"
      if [ "$os" = win ]; then printf 'raw=%s\n' "$(cygpath -w "$f.json")"; else printf 'raw=%s\n' "$f.json"; fi
    fi
  } > "$f.tmp"; mv "$f.tmp" "$f.evt"
  ui
  if [ "$os" = mac ] && [ "$theme" != off ]; then
    s="$wav"; [ -z "$s" ] && { s=/System/Library/Sounds/Glass.aiff; [ "$kind" = done ] && s=/System/Library/Sounds/Tink.aiff; }
    afplay "$s" >/dev/null 2>&1 &
  fi
  # Quick replies: wait for Allow / Deny on the card and answer the permission prompt for you.
  # "In terminal", or no click within the wait, leaves the normal prompt to you.
  if [ -n "$reply" ]; then
    r="$state/replies/$reply"; n=0; lim=$((wait * 10))
    while [ ! -f "$r" ] && [ $n -lt $lim ]; do sleep 0.1; n=$((n + 1)); done
    ans="$(cat "$r" 2>/dev/null)"; rm -f "$r"
    case "$ans" in
      allow) rm -f "$state/$sid.asking"; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
      deny)  rm -f "$state/$sid.asking"; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the blink card. Ask the user what to do instead."}}}' ;;
    esac
  fi
  exit 0
fi

case "$os" in
  mac)
    if [ "$popup" = 1 ]; then
      t="$(printf '%s' "$label ${title} · $proj" | tr -d "\"\\\\")"; m="$(printf '%s' "${command:-$msg}" | tr -d "\"\\\\")"
      osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1 &
    fi
    if [ "$theme" != off ]; then
      s="$wav"; [ -z "$s" ] && { s=/System/Library/Sounds/Glass.aiff; [ "$kind" = done ] && s=/System/Library/Sounds/Tink.aiff; }
      afplay "$s" >/dev/null 2>&1 &
    fi ;;
  linux)
    if [ -n "$DISPLAY$WAYLAND_DISPLAY" ]; then
      [ "$popup" = 1 ] && command -v notify-send >/dev/null 2>&1 && \
        notify-send -a blink -i "$here/assets/icon_$kind.png" "$label ${title}${proj:+ · $proj}" "${command:-$msg}" >/dev/null 2>&1 &
      if [ "$theme" != off ]; then
        s="$wav"; [ -z "$s" ] && { s=/usr/share/sounds/freedesktop/stereo/message-new-instant.oga; [ "$kind" = done ] && s=/usr/share/sounds/freedesktop/stereo/complete.oga; }
        if [ -f "$s" ]; then
          if command -v paplay >/dev/null 2>&1; then paplay "$s" >/dev/null 2>&1 &
          elif command -v pw-play >/dev/null 2>&1; then pw-play "$s" >/dev/null 2>&1 &
          elif command -v aplay >/dev/null 2>&1; then aplay -q "$s" >/dev/null 2>&1 &
          fi
        fi
      fi
    elif [ "$theme" != off ] && [ -w /dev/tty ]; then { printf '\a' > /dev/tty; } 2>/dev/null
    fi ;;
  *) [ "$theme" != off ] && [ -w /dev/tty ] && { printf '\a' > /dev/tty; } 2>/dev/null ;;
esac
exit 0
