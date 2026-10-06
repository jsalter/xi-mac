#!/bin/bash
# Smoke test for hot exit against the built XiEditor.app.
# Usage: hot-exit-smoke.sh /path/to/XiEditor.app
# Requires Accessibility access for the shell that runs it (System Events keystrokes).
set -euo pipefail

APP="${1:?path to XiEditor.app}"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
WORK=$(mktemp -d /tmp/hot-exit-smoke.XXXXXX)
NAMED="$WORK/named.txt"
printf 'line one\nline two\n' > "$NAMED"
ORIGINAL_NAMED=$(cat "$NAMED")

SESSION="$HOME/Library/Application Support/XiEditor/session.json"
SESSION_BACKUP="$WORK/session.json.user"
[ -f "$SESSION" ] && mv "$SESSION" "$SESSION_BACKUP"
cleanup() {
  pkill -x XiEditor || true
  rm -f "$SESSION"
  [ -f "$SESSION_BACKUP" ] && mv "$SESSION_BACKUP" "$SESSION"
  return 0
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

ui() { osascript -e "tell application \"System Events\" to tell process \"XiEditor\"" -e "$1" -e "end tell"; }
key() { ui "keystroke \"$1\" using command down"; sleep 0.6; }
type_text() { ui "keystroke \"$1\""; sleep 0.4; }
window_names() { ui "get name of every window"; }
window_count() { ui "count windows"; }
front_contents() { pbcopy < /dev/null; key a; key c; sleep 0.3; pbpaste; }

launch() {
  open -a "$APP"
  for _ in $(seq 40); do pgrep -x XiEditor >/dev/null && break; sleep 0.25; done
  sleep 2.5
  ui "set frontmost to true"
  sleep 0.5
}

wait_for_exit() {
  for _ in $(seq 40); do pgrep -x XiEditor >/dev/null || return 0; sleep 0.25; done
  return 1
}

pkill -x XiEditor || true
sleep 1

echo "--- first session"
launch
# The app opens one untitled window on launch; type into it.
type_text "untitled scratch text"
# Open the named file in a new window and edit it.
key o
sleep 1
ui "keystroke \"g\" using {command down, shift down}"
sleep 0.6
ui "keystroke \"$NAMED\""
ui "keystroke return"
sleep 0.6
ui "keystroke return"
sleep 1.5
type_text "EDITED "
sleep 0.5
echo "windows before quit: $(window_names)"
BEFORE_COUNT=$(window_count)
key q
wait_for_exit || fail "app still running 10s after Cmd-Q (prompted?)"
pass "quit without a prompt"
[ "$(cat "$NAMED")" = "$ORIGINAL_NAMED" ] || fail "named file was written by quit"
pass "named file untouched on disk"

echo "--- second session"
launch
AFTER_COUNT=$(window_count)
echo "windows after relaunch: $(window_names)"
[ "$AFTER_COUNT" = "$BEFORE_COUNT" ] || fail "expected $BEFORE_COUNT windows, got $AFTER_COUNT"
pass "window count restored ($AFTER_COUNT)"

FOUND_UNTITLED=0; FOUND_NAMED=0
for i in $(seq 1 "$AFTER_COUNT"); do
  ui "perform action \"AXRaise\" of window $i" || true
  sleep 0.4
  c=$(front_contents)
  echo "window $i contents: $(printf '%s' "$c" | head -c 60 | tr '\n' '|')"
  case "$c" in
    *"untitled scratch text"*) FOUND_UNTITLED=1 ;;
    "EDITED line one"*) FOUND_NAMED=1 ;;
  esac
done
[ "$FOUND_UNTITLED" = 1 ] || fail "untitled buffer contents not restored"
pass "untitled buffer restored"
[ "$FOUND_NAMED" = 1 ] || fail "edited named file contents not restored"
pass "unsaved edit to named file restored"
[ "$(cat "$NAMED")" = "$ORIGINAL_NAMED" ] || fail "named file was written by relaunch"
pass "named file still untouched after relaunch"

case "$(window_names)" in *"•"*|*"named.txt"*) pass "window titles mention the named file" ;; *) echo "note: titles: $(window_names)";; esac

key q
wait_for_exit || fail "second quit prompted"
pass "second quit without a prompt"
echo "ALL PASS (work dir $WORK)"
