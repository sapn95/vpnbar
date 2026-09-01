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
#   status      connected / connecting / disconnected, on stdout
#   connect     opens the app; the federated login is finished by hand
#   disconnect  asks OpenVPN to terminate, through the management interface
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

usage() {
  echo "usage: ${0##*/} status|connect|disconnect" >&2
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

cmd_connect() {
  # The endpoints here authenticate through a browser, so this opens the app
  # and stops. Automating the federated login is not something a menu should
  # be doing on anyone's behalf.
  open -a "${APP}"
}

cmd_disconnect() {
  if ! listening; then
    echo "no AWS VPN session is running" >&2
    return 0
  fi
  management 'signal SIGTERM' >/dev/null
}

case "${1:-}" in
  status) cmd_status ;;
  connect) cmd_connect ;;
  disconnect) cmd_disconnect ;;
  *) usage ;;
esac
