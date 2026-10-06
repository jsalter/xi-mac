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
# Position and size of every window, front to back, as a flat list of numbers.
frames() { ui "get {position, size} of every window"; }
# The tab bar's selection flags for window $1, or "none" when it is not in a tab group.
tab_values() {
  ui "if (count of tab groups of window $1) is 0 then return \"none\"
get value of every radio button of tab group 1 of window $1"
}
# True when two comma-separated number lists match element-wise within $3 (default 1).
same_numbers() {
  awk -v a="$1" -v b="$2" -v tol="${3:-1}" 'BEGIN {
    n = split(a, x, /, */); m = split(b, y, /, */)
    if (n == 0 || n != m) exit 1
    for (i = 1; i <= n; i++) { d = x[i] - y[i]; if (d < 0) d = -d; if (d > tol) exit 1 }
  }'
}
# Scrolls window 1's text with the wheel, without touching the caret.
scroll_wheel_down() {
  local p z
  p=$(ui "get position of window 1"); z=$(ui "get size of window 1")
  osascript -l JavaScript -e "ObjC.import('CoreGraphics')" \
    -e "var p = '$p'.split(', ').map(Number), z = '$z'.split(', ').map(Number)" \
    -e "$.CGWarpMouseCursorPosition($.CGPointMake(p[0] + z[0] / 2, p[1] + z[1] / 2)); delay(0.3)" \
    -e "for (var i = 0; i < 6; i++) { $.CGEventPost(0, $.CGEventCreateScrollWheelEvent(null, 1, 1, -40)); delay(0.1) }"
  sleep 1
}
# Clicks just inside the top edge of window 1's text area (System Events' own click is an AXPress that
# does not reach the editor view), which puts the caret at the end of the first visible line.
click_top_of_text() {
  local p
  p=$(ui "get position of scroll area 1 of window 1")
  osascript -l JavaScript -e "ObjC.import('CoreGraphics')" \
    -e "var p = '$p'.split(', ').map(Number), pt = $.CGPointMake(p[0] + 120, p[1] + 8)" \
    -e "$.CGWarpMouseCursorPosition(pt); delay(0.2)" \
    -e "$.CGEventPost(0, $.CGEventCreateMouseEvent(null, 1, pt, 0)); delay(0.05)" \
    -e "$.CGEventPost(0, $.CGEventCreateMouseEvent(null, 2, pt, 0))"
  sleep 0.5
}
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

echo "--- tab group session"
rm -f "$SESSION"
launch
type_text "tab one"
key t
type_text "tab two"
key t
type_text "tab three"
# Select the middle tab so neither the first nor the last position can pass by default.
ui "key code 33 using {command down, shift down}"; sleep 0.8
ui "set position of window 1 to {120, 140}"
ui "set size of window 1 to {700, 500}"
key n
type_text "separate window"
ui "set position of window 1 to {300, 220}"
ui "set size of window 1 to {620, 450}"
FRAMES_BEFORE=$(frames)
echo "frames before quit: $FRAMES_BEFORE"
[ "$(window_count)" = 2 ] || fail "expected 2 windows (one tab group, one single) before quit, got $(window_count)"
[ "$(tab_values 1)" = none ] || fail "window 1 should be the single window"
[ "$(tab_values 2)" = "false, true, false" ] || fail "window 2 should be a three-tab group with the middle tab selected: $(tab_values 2)"
key q
wait_for_exit || fail "tab group quit prompted"

launch
echo "frames after relaunch: $(frames)"
[ "$(window_count)" = 2 ] || fail "expected 2 windows after relaunch, got $(window_count)"
pass "window count restored"
[ "$(tab_values 1)" = none ] || fail "window 1 (frontmost group) should be the single window, got: $(tab_values 1)"
pass "single window is frontmost"
[ "$(tab_values 2)" = "false, true, false" ] || fail "tab group not restored with three tabs, middle selected: $(tab_values 2)"
pass "tab group restored with three tabs and the middle one selected"
same_numbers "$FRAMES_BEFORE" "$(frames)" || fail "window frames changed across the suspend"
pass "frames restored within 1 point"
[ "$(front_contents)" = "separate window" ] || fail "single window contents not restored"
ui "perform action \"AXRaise\" of window 2"; sleep 0.5
[ "$(front_contents)" = "tab two" ] || fail "selected tab is not the one that was selected: $(front_contents)"
pass "selected tab shows its own text"
ui "key code 33 using {command down, shift down}"; sleep 0.8
[ "$(front_contents)" = "tab one" ] || fail "first tab text not restored in tab order: $(front_contents)"
ui "key code 30 using {command down, shift down}"; sleep 0.4
ui "key code 30 using {command down, shift down}"; sleep 0.8
[ "$(front_contents)" = "tab three" ] || fail "third tab text not restored in tab order: $(front_contents)"
pass "tabs restored in order"

key q
wait_for_exit || fail "tab group second quit prompted"

echo "--- viewport session"
rm -f "$SESSION"
launch
# 200 lines, so scrolling stops short of the end of the text, each starting with a two-byte character so a column in bytes differs from one in characters.
LC_ALL=en_US.UTF-8 awk 'BEGIN { for (i = 1; i <= 200; i++) print "éL" i }' | LC_ALL=en_US.UTF-8 pbcopy
key v
sleep 1
# Line 58 (index 57), after its first character: byte column 2.
ui "key code 126 using command down"; sleep 0.6
ui "repeat 57 times
key code 125
delay 0.03
end repeat"
ui "key code 124"; sleep 0.8
key q
wait_for_exit || fail "viewport quit prompted"

launch
type_text "ZZ"
LINE=$(front_contents | sed -n 58p)
[ "$LINE" = "éZZL58" ] || fail "caret restored to the wrong place: line 58 is '$LINE', expected 'éZZL58'"
pass "caret restored to line 58, byte column 2"
# Caret to the top, then scroll the view away from it with the wheel, so no caret is visible at quit.
ui "key code 126 using command down"; sleep 0.6
scroll_wheel_down
key q
wait_for_exit || fail "scrolled quit prompted"
TOP_LINE=$(plutil -extract groups.0.tabs.0.viewport.topLine raw -o - "$SESSION")
echo "stored top line: $TOP_LINE"
[ "$TOP_LINE" -gt 0 ] || fail "the wheel did not scroll the view"
plutil -extract groups.0.tabs.0.viewport.caret raw -o - "$SESSION" >/dev/null 2>&1 && fail "a caret was stored although none was visible"

launch
click_top_of_text
type_text "QQ"
EXPECTED_LINE=$((TOP_LINE + 1))
CONTENTS=$(front_contents)
LINE=$(printf '%s\n' "$CONTENTS" | sed -n "${EXPECTED_LINE}p")
[ "$LINE" = "éL${EXPECTED_LINE}QQ" ] || fail "first visible line after relaunch is not line $EXPECTED_LINE: line $EXPECTED_LINE is '$LINE'; marker is on line $(printf '%s\n' "$CONTENTS" | grep -n QQ | head -1)"
pass "top line restored without a visible caret (line $EXPECTED_LINE)"

key q
wait_for_exit || fail "final quit prompted"
echo "ALL PASS (work dir $WORK)"
