#!/usr/bin/env bash
# Drive the AWS VPN Client from vpnbar's `shell` backend.
#
# The client ships no command line and exposes no accessibility tree at all —
# `AXWindows` is empty and the application element has no attributes — so
# neither of the other two backends can reach it. What it does do is run
# OpenVPN with a management interface on a fixed local port, and that is a
# documented, supported way to ask a tunnel what it is doing and to bring it
# down.
#
#   profiles              what the client's window lists, and the button on each row
#   status                connected / connecting / disconnected, on stdout
#   connect [profile]     clicks Connect on that profile's row
#   disconnect [profile]  clicks Disconnect on it, or SIGTERM with no profile
#   force                 asks, waits, and then quits the client itself
#
# The window is driven through the accessibility API. An earlier version of
# this file claimed the client had none: that was measured while the app was
# running with no window open, which is exactly when it reports nothing. With
# its window up it exposes the whole tree, one group per profile holding the
# name, the state and the button.
#
# That access belongs to whoever spawns this script. Hammerspoon has it, so the
# menu works. A terminal usually does not, and osascript then fails with
# "not allowed assistive access" — which is about the terminal, not about this
# script or the client.
#
# Nothing here needs root: the management port listens on loopback and its
# password file is written readable by the user who owns the session.
set -euo pipefail

# Hammerspoon spawns commands with a minimal environment, not a login shell's,
# so the tools this script uses are named from a PATH it sets itself. The
# override exists for the tests, which put stub `nc` and `open` in front of the
# real ones; nothing else should set it.
PATH="${VPNBAR_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

readonly APP="AWS VPN Client"
readonly MGMT_HOST="127.0.0.1"
readonly MGMT_PORT="${AWS_VPN_MGMT_PORT:-35001}"
readonly MGMT_DIR="${HOME}/.config/AWSVPNClient"
# Seconds to wait for a polite SIGTERM before closing the app out from under it.
readonly FORCE_WAIT="${AWS_VPN_FORCE_WAIT:-5}"

usage() {
  echo "usage: ${0##*/} profiles|status|connect [profile]|disconnect [profile]|force" >&2
  exit 2
}

# The client writes one password file per profile and rewrites it for each
# session, so the most recently touched one belongs to the session that is
# running now. Never printed, never copied anywhere: it is read here and piped
# straight into the socket.
management_password() {
  local newest="" candidate
  # `-nt` rather than `stat`, whose flags are the other way round on BSD and
  # GNU: this way the tests run on either, and the script is doing nothing a
  # shell builtin cannot answer.
  for candidate in "${MGMT_DIR}"/ovpn-mgmt-*; do
    [ -f "${candidate}" ] || continue
    if [ -z "${newest}" ] || [ "${candidate}" -nt "${newest}" ]; then
      newest="${candidate}"
    fi
  done
  [ -n "${newest}" ] && [ -r "${newest}" ] || return 0
  # The client writes these without a trailing newline. Sent as-is, the
  # password and the command after it arrive on one line and OpenVPN rejects
  # both, so the substitution strips whatever is there and exactly one newline
  # is added back.
  printf '%s\n' "$(cat "${newest}")"
}

listening() {
  nc -z -w 1 "${MGMT_HOST}" "${MGMT_PORT}" >/dev/null 2>&1
}

# Send commands and print whatever OpenVPN says back. The sleep is what gives
# it time to answer: closing the pipe immediately would end the session before
# the reply arrives.
management() {
  {
    management_password
    printf '%s\n' "$@"
    sleep 1
    printf 'quit\n'
  } | nc -w 3 "${MGMT_HOST}" "${MGMT_PORT}" 2>/dev/null || true
}

cmd_status() {
  if ! listening; then
    echo disconnected
    return
  fi
  # >STATE:<time>,CONNECTED,SUCCESS,<ip>,… once the tunnel is up. Every other
  # state OpenVPN reports — WAIT, AUTH, GET_CONFIG, ASSIGN_IP, ADD_ROUTES,
  # RECONNECTING — is a session on its way somewhere, which is "working".
  case "$(management state)" in
    *,CONNECTED,*) echo connected ;;
    *) echo connecting ;;
  esac
}

# Bring the window up. The client keeps running without one, and with no
# window there is no accessibility tree to look at.
open_window() {
  open -a "${APP}"
  local waited=0
  while [ "${waited}" -lt 10 ]; do
    if osascript -e "tell application \"System Events\" to tell process \"${APP}\" to return (count of windows)" 2>/dev/null | grep -qv '^0$'; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# One group per profile, in tree order: the name, the state, then the button.
# So: walk the window, remember the row whose name matches, and take the first
# button inside the few elements that follow it. Bounded, so a row without the
# button being asked for cannot reach into the next row and click that instead.
row_script() {
  cat <<'APPLESCRIPT'
on run argv
  set wanted to item 1 of argv
  set verb to item 2 of argv
  set doClick to (item 3 of argv is "click")
  tell application "System Events"
    tell process "AWS VPN Client"
      set found to false
      set since to 0
      set state to "unknown"
      repeat with element in (entire contents of window 1)
        try
          set kind to class of element
          if kind is static text then
            set text to value of element
            if found and since < 4 then
              set state to text
            end if
            if text is wanted then
              set found to true
              set since to 0
            end if
          else if kind is button and found and since < 5 then
            if name of element is verb then
              if doClick then click element
              return verb & " " & state
            end if
          end if
          if found then set since to since + 1
        end try
      end repeat
    end tell
  end tell
  return "not found"
end run
APPLESCRIPT
}

# Every row the window lists, with the button it currently offers.
cmd_profiles() {
  open_window || {
    echo "the ${APP} window did not open — does this process have accessibility access?" >&2
    return 1
  }
  osascript -e 'tell application "System Events" to tell process "AWS VPN Client"
    set out to ""
    set nameNext to true
    repeat with element in (entire contents of window 1)
      try
        if class of element is static text then
          set out to out & value of element & "\t"
        else if class of element is button then
          set out to out & name of element & linefeed
        end if
      end try
    end repeat
    return out
  end tell' 2>/dev/null
}

cmd_connect() {
  local wanted="${1:-}"
  if [ -z "${wanted}" ]; then
    # No profile named: open the app and stop. Picking one for somebody is not
    # a menu's job when it cannot know which.
    open -a "${APP}"
    return 0
  fi
  open_window || {
    echo "the ${APP} window did not open — does this process have accessibility access?" >&2
    return 1
  }
  local answer
  answer="$(row_script | osascript - "${wanted}" Connect click 2>/dev/null || true)"
  case "${answer}" in
    Connect*) : ;;
    *)
      echo "no Connect button on a row called ${wanted}" >&2
      return 1
      ;;
  esac
}

cmd_disconnect() {
  local wanted="${1:-}"
  # With a profile named, click that row's own Disconnect: it ends the session
  # the client thinks it owns, and leaves the client's idea of the world
  # matching the tunnel's. SIGTERM ends whichever session is running, which is
  # the right answer only when there is one.
  if [ -n "${wanted}" ] && open_window; then
    local answer
    answer="$(row_script | osascript - "${wanted}" Disconnect click 2>/dev/null || true)"
    case "${answer}" in
      Disconnect*) return 0 ;;
    esac
  fi
  if ! listening; then
    echo "no AWS VPN session is running" >&2
    return 0
  fi
  management 'signal SIGTERM' >/dev/null
}

# Ask nicely, give it a moment, and if the session is still there close the
# app that owns it. The tunnel goes with the app. This is the last resort and
# not the everyday path: `disconnect` leaves the client running and ready.
cmd_force() {
  if listening; then
    management 'signal SIGTERM' >/dev/null
    local waited=0
    while [ "${waited}" -lt "${FORCE_WAIT}" ]; do
      listening || return 0
      sleep 1
      waited=$((waited + 1))
    done
  fi
  osascript -e "tell application \"${APP}\" to quit" >/dev/null 2>&1 || true
  echo "closed ${APP}"
}

case "${1:-}" in
  profiles) cmd_profiles ;;
  status) cmd_status ;;
  connect)
    shift
    cmd_connect "${1:-}"
    ;;
  disconnect)
    shift
    cmd_disconnect "${1:-}"
    ;;
  force) cmd_force ;;
  *) usage ;;
esac
