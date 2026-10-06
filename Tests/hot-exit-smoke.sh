#!/bin/bash
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
frames() { ui "get {position, size} of every window"; }
tab_values() {
  ui "if (count of tab groups of window $1) is 0 then return \"none\"
get value of every radio button of tab group 1 of window $1"
}
same_numbers() {
  awk -v a="$1" -v b="$2" -v tol="${3:-1}" 'BEGIN {
    n = split(a, x, /, */); m = split(b, y, /, */)
    if (n == 0 || n != m) exit 1
    for (i = 1; i <= n; i++) { d = x[i] - y[i]; if (d < 0) d = -d; if (d > tol) exit 1 }
  }'
}
scroll_wheel_down() {
  local p z
  p=$(ui "get position of window 1"); z=$(ui "get size of window 1")
  osascript -l JavaScript -e "ObjC.import('CoreGraphics')" \
    -e "var p = '$p'.split(', ').map(Number), z = '$z'.split(', ').map(Number)" \
    -e "$.CGWarpMouseCursorPosition($.CGPointMake(p[0] + z[0] / 2, p[1] + z[1] / 2)); delay(0.3)" \
    -e "for (var i = 0; i < 6; i++) { $.CGEventPost(0, $.CGEventCreateScrollWheelEvent(null, 1, 1, -40)); delay(0.1) }"
  sleep 1
}
# System Events' own click is an AXPress that does not reach the editor view.
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
open_file() {
  key o
  sleep 1
  ui "keystroke \"g\" using {command down, shift down}"
  sleep 0.6
  ui "keystroke \"$1\""
  ui "keystroke return"
  sleep 0.6
  ui "keystroke return"
  sleep 1.5
}
alert_buttons() { ui "get name of every button of window 1"; }
launch_without_focus() {
  open -a "$APP"
  for _ in $(seq 40); do pgrep -x XiEditor >/dev/null && break; sleep 0.25; done
  sleep 2
}

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
type_text "untitled scratch text"
open_file "$NAMED"
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
LC_ALL=en_US.UTF-8 awk 'BEGIN { for (i = 1; i <= 200; i++) print "éL" i }' | LC_ALL=en_US.UTF-8 pbcopy
key v
sleep 1
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

echo "--- clean quit session"
launch
key w
sleep 0.8
[ "$(ui 'count sheets of window 1')" = "1" ] || fail "Cmd-W on a dirty buffer no longer prompts"
pass "Cmd-W still prompts for a dirty buffer"
ui 'click button "Delete" of sheet 1 of window 1'
sleep 0.8
key q
wait_for_exit || fail "clean quit prompted"
[ "$(cat "$SESSION")" = '{"groups":[],"version":1}' ] || fail "quitting with every window closed did not store an empty session, so the old one would come back: $(head -c 400 "$SESSION")"
pass "clean quit replaces the session with an empty one"
launch
[ "$(window_count)" = "1" ] || fail "expected the default untitled window, got $(window_names)"
pass "closed-everything session relaunches to one untitled window"

echo "--- conflict session"
CONFLICT="$WORK/conflict.txt"
printf 'original\n' > "$CONFLICT"
open_file "$CONFLICT"
type_text "MINE "
sleep 0.5
printf 'theirs\n' > "$CONFLICT"
sleep 0.5
key q
wait_for_exit || fail "conflict quit prompted"
[ "$(cat "$CONFLICT")" = "theirs" ] || fail "conflict file was written by quit"
launch_without_focus
for _ in $(seq 20); do alert_buttons >/dev/null 2>&1 && break; sleep 0.5; done
BUTTONS=$(alert_buttons)
echo "alert buttons: $BUTTONS"
[ "$BUTTONS" = "Keep Suspended Edits, Use Version on Disk, Keep Both" ] || fail "no conflict alert for a file changed on disk while suspended (buttons: $BUTTONS)"
pass "file changed on disk while suspended raises the conflict alert"
ui "click button \"Keep Both\" of window 1"
sleep 2
ui "set frontmost to true"
TABS=$(ui "get name of every radio button of tab group 1 of window 1")
echo "tabs after keep both: $TABS"
case "$TABS" in *"conflict.txt"*"Untitled"*) ;; *) fail "keep both did not open the disk version and an untitled copy as tabs: $TABS";; esac
FOUND_DISK=0; FOUND_MINE=0
for i in 1 2; do
  ui "click radio button $i of tab group 1 of window 1"
  sleep 0.5
  c=$(front_contents)
  case "$c" in "theirs"*) FOUND_DISK=1 ;; "MINE original"*) FOUND_MINE=1 ;; esac
done
[ "$FOUND_DISK" = 1 ] || fail "keep both lost the version on disk"
[ "$FOUND_MINE" = 1 ] || fail "keep both lost the suspended edits"
pass "keep both restores the disk version and the suspended edits"
[ "$(cat "$CONFLICT")" = "theirs" ] || fail "conflict file was written by relaunch"
key q
wait_for_exit || fail "post-conflict quit prompted"

echo "--- unreadable file session"
LOCKED="$WORK/locked.txt"
printf 'locked\n' > "$LOCKED"
launch
open_file "$LOCKED"
type_text "KEEP "
sleep 0.5
key q
wait_for_exit || fail "locked quit prompted"
chmod 000 "$LOCKED"
launch_without_focus
for _ in $(seq 20); do alert_buttons >/dev/null 2>&1 && break; sleep 0.5; done
echo "alert buttons: $(alert_buttons)"
ui "click button 1 of window 1"
sleep 1.5
ui "set frontmost to true"
key q
wait_for_exit || fail "quit after a failed restore prompted"
chmod 644 "$LOCKED"
grep -q "KEEP locked" "$SESSION" || fail "the buffer that failed to open was dropped from the next session"
pass "a buffer core could not reopen stays in the session"
launch
FOUND_KEEP=0
for i in $(seq 1 "$(window_count)"); do
  ui "perform action \"AXRaise\" of window $i" || true
  sleep 0.4
  case "$(front_contents)" in "KEEP locked"*) FOUND_KEEP=1 ;; esac
done
[ "$FOUND_KEEP" = 1 ] || fail "the once-unreadable buffer did not come back after the file became readable"
pass "the once-unreadable buffer comes back on the next launch"
[ "$(cat "$LOCKED")" = "locked" ] || fail "locked file was written"
key q
wait_for_exit || fail "last quit prompted"
echo "ALL PASS (work dir $WORK)"
