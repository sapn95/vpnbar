#!/usr/bin/env bats
#
# The AWS VPN Client helper, with the two commands it depends on replaced by
# stubs: `nc`, which is the management interface, and `open`, which is the app.
# VPNBAR_PATH is the hook that puts them in front of the real ones — the script
# otherwise pins its own PATH, because Hammerspoon does not give it a useful
# one.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/aws-vpn-client.sh"
  TMP="$(mktemp -d)"
  STUB="${TMP}/bin"
  mkdir -p "${STUB}"

  # A home of its own, so a test never reads or writes the real client's state.
  export HOME="${TMP}/home"
  mkdir -p "${HOME}/.config/AWSVPNClient"

  export STUB_SENT="${TMP}/sent"
  export STUB_OPENED="${TMP}/opened"
  export STUB_OSASCRIPT="${TMP}/osascript"
  : >"${STUB_SENT}"
  : >"${STUB_OPENED}"
  : >"${STUB_OSASCRIPT}"

  cat >"${STUB}/nc" <<'EOF'
#!/usr/bin/env bash
# -z is the "is anything listening" probe; anything else is a real session.
for argument in "$@"; do
  [ "${argument}" = "-z" ] && exec test "${STUB_NC_LISTENING:-0}" = 1
done
cat >>"${STUB_SENT}"
[ -n "${STUB_NC_REPLY:-}" ] && printf '%s\n' "${STUB_NC_REPLY}"
exit 0
EOF

  cat >"${STUB}/open" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_OPENED}"
EOF

  cat >"${STUB}/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_OSASCRIPT}"
EOF

  # Whether the client's window process is there. Version 6 keeps no management
  # interface, so this is half of how the log is judged.
  cat >"${STUB}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit "${STUB_PGREP_EXIT:-0}"
EOF

  export AWS_VPN_LOG_DIR="${TMP}/logs"
  mkdir -p "${AWS_VPN_LOG_DIR}"

  # Real sleeps would add a second to every test that talks to the socket.
  printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB}/sleep"

  chmod +x "${STUB}/nc" "${STUB}/open" "${STUB}/osascript" "${STUB}/sleep" "${STUB}/pgrep"
  export VPNBAR_PATH="${STUB}:/usr/bin:/bin"
}

teardown() {
  rm -rf "${TMP}"
}

password_file() {
  printf '%s' "$2" >"${HOME}/.config/AWSVPNClient/ovpn-mgmt-$1"
}

# This asserted "disconnected" until version 6 of the client turned up with no
# management interface at all. Nothing listening stopped meaning "no session"
# and started meaning "no way to ask", and the guess was wrong about a tunnel
# that was up and carrying routes.
@test "nothing listening and nothing written down is unknown, not disconnected" {
  export STUB_NC_LISTENING=0
  run "${SCRIPT}" status
  [ "${status}" -eq 0 ]
  [ "${output}" = "unknown" ]
}

@test "status is connected when the management interface says CONNECTED" {
  export STUB_NC_LISTENING=1
  export STUB_NC_REPLY=">STATE:1788227014,CONNECTED,SUCCESS,10.0.0.2,198.51.100.7,443"
  run "${SCRIPT}" status
  [ "${output}" = "connected" ]
}

@test "every other OpenVPN state counts as working" {
  export STUB_NC_LISTENING=1
  for state in WAIT AUTH GET_CONFIG ASSIGN_IP ADD_ROUTES RECONNECTING; do
    export STUB_NC_REPLY=">STATE:1788227014,${state},,,"
    run "${SCRIPT}" status
    [ "${output}" = "connecting" ]
  done
}

@test "a listening port that answers nothing is still working, not connected" {
  export STUB_NC_LISTENING=1
  export STUB_NC_REPLY=""
  run "${SCRIPT}" status
  [ "${output}" = "connecting" ]
}

@test "disconnect sends signal SIGTERM" {
  export STUB_NC_LISTENING=1
  run "${SCRIPT}" disconnect
  [ "${status}" -eq 0 ]
  grep -q '^signal SIGTERM$' "${STUB_SENT}"
}

@test "disconnect sends the newest management password first" {
  export STUB_NC_LISTENING=1
  password_file old "OLDPASSWORD00000"
  sleep 1
  password_file work "NEWPASSWORD00000"
  run "${SCRIPT}" disconnect
  [ "$(head -1 "${STUB_SENT}")" = "NEWPASSWORD00000" ]
}

@test "disconnect with no password file still sends the command" {
  export STUB_NC_LISTENING=1
  run "${SCRIPT}" disconnect
  [ "$(head -1 "${STUB_SENT}")" = "signal SIGTERM" ]
}

@test "disconnect says so and changes nothing when no session is running" {
  export STUB_NC_LISTENING=0
  run "${SCRIPT}" disconnect
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no AWS VPN session is running"* ]]
  [ ! -s "${STUB_SENT}" ]
}

@test "connect opens the app and does nothing else" {
  export STUB_NC_LISTENING=0
  run "${SCRIPT}" connect
  [ "${status}" -eq 0 ]
  grep -q 'AWS VPN Client' "${STUB_OPENED}"
  [ ! -s "${STUB_SENT}" ]
}

@test "an unknown or missing verb is a usage error" {
  run "${SCRIPT}" bogus
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"usage:"* ]]

  run "${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "force asks politely first" {
  export STUB_NC_LISTENING=1
  export AWS_VPN_FORCE_WAIT=1
  run "${SCRIPT}" force
  [ "${status}" -eq 0 ]
  grep -q '^signal SIGTERM$' "${STUB_SENT}"
}

@test "force closes the app when the session will not go" {
  # The stub keeps answering, which is exactly the case force exists for.
  export STUB_NC_LISTENING=1
  export AWS_VPN_FORCE_WAIT=1
  run "${SCRIPT}" force
  grep -q 'AWS VPN Client' "${STUB_OSASCRIPT}"
  grep -q 'quit' "${STUB_OSASCRIPT}"
}

@test "force closes the app even when nothing is listening" {
  export STUB_NC_LISTENING=0
  run "${SCRIPT}" force
  [ "${status}" -eq 0 ]
  [ ! -s "${STUB_SENT}" ]
  grep -q 'quit' "${STUB_OSASCRIPT}"
}

@test "disconnect never closes the app" {
  export STUB_NC_LISTENING=1
  run "${SCRIPT}" disconnect
  [ ! -s "${STUB_OSASCRIPT}" ]
}

# --------------------------------------------- version 6 has no management port
#
# The client shipped as 6.0.3 carries no OpenVPN binary and nothing listens on
# 35001, so `listening` is false for a tunnel that is up and carrying routes.
# Answering "disconnected" to that is a guess, and it was wrong on a live
# machine: vpnbar read both VPNs as down, the one-at-a-time rule had nothing to
# act on, and autoconnect kept asking an already-connected client to connect.

log_says() {
  printf '%s\n' "$@" >"${AWS_VPN_LOG_DIR}/aws_vpn_client_gui_20260917.log"
}

@test "status reads the client's own log when nothing is listening" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T09:11:13Z  INFO ThreadId(01) [poll] Tray state changed to connected"
  run "${SCRIPT}" status
  [ "${output}" = "connected" ]
}

@test "status is connecting while the client says so" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T09:11:08Z  INFO ThreadId(01) [poll] Tray state changed to connecting"
  run "${SCRIPT}" status
  [ "${output}" = "connecting" ]
}

@test "status is disconnected when the client says none" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T09:10:18Z  INFO ThreadId(01) [poll] Tray state changed to none"
  run "${SCRIPT}" status
  [ "${output}" = "disconnected" ]
}

# The heartbeat repeats every three minutes. A disconnection after it must win,
# or the client would read as connected until the file rolled over at midnight.
@test "a disconnection after the heartbeat wins" {
  export STUB_NC_LISTENING=0
  log_says \
    "2026-09-17T10:50:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work" \
    "2026-09-17T10:53:00Z  INFO ThreadId(01) [poll] Tray state changed to none"
  run "${SCRIPT}" status
  [ "${output}" = "disconnected" ]
}

@test "a heartbeat after a reconnection wins in turn" {
  export STUB_NC_LISTENING=0
  log_says \
    "2026-09-17T10:50:00Z  INFO ThreadId(01) [poll] Tray state changed to none" \
    "2026-09-17T10:53:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work"
  run "${SCRIPT}" status
  [ "${output}" = "connected" ]
}

@test "a SAML prompt is a disconnection with a reason" {
  export STUB_NC_LISTENING=0
  log_says \
    "2026-09-17T09:10:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work" \
    "2026-09-17T09:10:19Z  INFO ThreadId(01) [renderer] [poll] SAML authentication required for profile: work"
  run "${SCRIPT}" status
  [ "${output}" = "disconnected" ]
}

@test "the shutdown line counts as a disconnection" {
  export STUB_NC_LISTENING=0
  log_says \
    "2026-09-17T09:10:00Z  INFO ThreadId(01) [poll] Tray state changed to connected" \
    "2026-09-17T23:59:00Z  INFO ThreadId(01) [shutdown] Disconnecting all connections before OS shutdown/logout"
  run "${SCRIPT}" status
  [ "${output}" = "disconnected" ]
}

@test "the tray refresh lines are read too" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T09:00:00Z  INFO ThreadId(01) [tray] Refresh state: none"
  run "${SCRIPT}" status
  [ "${output}" = "disconnected" ]
}

# The one that used to be answered with a guess.
@test "status is unknown, not disconnected, when there is nothing to read" {
  export STUB_NC_LISTENING=0
  run "${SCRIPT}" status
  [ "${output}" = "unknown" ]
}

@test "status is unknown when the log holds nothing it recognises" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T09:00:00Z  INFO ThreadId(01) Sparkle updater started"
  run "${SCRIPT}" status
  [ "${output}" = "unknown" ]
}

# A log is a record, not a live reading, and the tunnel is held by a different
# process than the one that wrote it.
@test "a positive answer from a closed client is unknown, not connected" {
  export STUB_NC_LISTENING=0
  export STUB_PGREP_EXIT=1
  log_says "2026-09-17T09:11:13Z  INFO ThreadId(01) [poll] Tray state changed to connected"
  run "${SCRIPT}" status
  [ "${output}" = "unknown" ]
}

@test "a negative answer survives the client being closed" {
  export STUB_NC_LISTENING=0
  export STUB_PGREP_EXIT=1
  log_says "2026-09-17T09:10:18Z  INFO ThreadId(01) [poll] Tray state changed to none"
  run "${SCRIPT}" status
  [ "${output}" = "disconnected" ]
}

# The name carries the date, so the newest file is picked by name. Written in
# the wrong order on purpose: modification time would give the opposite answer.
@test "the newest log file is the one that counts" {
  export STUB_NC_LISTENING=0
  printf '%s\n' "2026-09-17T09:00:00Z  INFO ThreadId(01) [poll] Tray state changed to connected" \
    >"${AWS_VPN_LOG_DIR}/aws_vpn_client_gui_20260917.log"
  printf '%s\n' "2026-09-16T09:00:00Z  INFO ThreadId(01) [poll] Tray state changed to none" \
    >"${AWS_VPN_LOG_DIR}/aws_vpn_client_gui_20260916.log"
  run "${SCRIPT}" status
  [ "${output}" = "connected" ]
}

# Backwards compatible: an older client still answers, and a live reading beats
# anything written down.
@test "a listening management interface is still preferred to the log" {
  export STUB_NC_LISTENING=1
  export STUB_NC_REPLY=">STATE:1700000000,CONNECTED,SUCCESS,10.11.12.13"
  log_says "2026-09-17T09:10:18Z  INFO ThreadId(01) [poll] Tray state changed to none"
  run "${SCRIPT}" status
  [ "${output}" = "connected" ]
}

# ------------------------------------------- which profile, which the old way could not answer

@test "a named profile is connected only when the log names that one" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T10:50:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work"
  run "${SCRIPT}" status work
  [ "${output}" = "connected" ]
}

@test "the other profile is disconnected, not connected, while that one is up" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T10:50:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work"
  run "${SCRIPT}" status work-full
  [ "${output}" = "disconnected" ]
}

@test "without a name, any connected profile counts" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T10:50:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work-full"
  run "${SCRIPT}" status
  [ "${output}" = "connected" ]
}

@test "switching profiles is seen as the switch it is" {
  export STUB_NC_LISTENING=0
  log_says \
    "2026-09-17T10:00:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work" \
    "2026-09-17T10:30:00Z  INFO ThreadId(01) [poll] Tray state changed to none" \
    "2026-09-17T10:31:00Z  INFO ThreadId(01) [tray] Profile connect succeeded: work-full"
  run "${SCRIPT}" status work
  [ "${output}" = "disconnected" ]
  run "${SCRIPT}" status work-full
  [ "${output}" = "connected" ]
}

@test "a named profile still yields to a disconnection after it" {
  export STUB_NC_LISTENING=0
  log_says \
    "2026-09-17T10:00:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: work" \
    "2026-09-17T10:30:00Z  INFO ThreadId(01) [poll] Tray state changed to none"
  run "${SCRIPT}" status work
  [ "${output}" = "disconnected" ]
}

# An AWS profile name is free text. $NF would have compared "VPN" with "Corp VPN".
@test "a profile name with spaces is matched whole" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T10:50:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: Corp VPN"
  run "${SCRIPT}" status "Corp VPN"
  [ "${output}" = "connected" ]
}

@test "a name that is only the tail of the real one does not match" {
  export STUB_NC_LISTENING=0
  log_says "2026-09-17T10:50:00Z  INFO ThreadId(01) [renderer] [poll] Profile connected: Corp VPN"
  run "${SCRIPT}" status "VPN"
  [ "${output}" = "disconnected" ]
}

@test "trailing whitespace in the log does not break the match" {
  export STUB_NC_LISTENING=0
  printf '%s\n' "2026-09-17T10:50:00Z  INFO ThreadId(01) [tray] Profile connect succeeded: work  " \
    >"${AWS_VPN_LOG_DIR}/aws_vpn_client_gui_20260917.log"
  run "${SCRIPT}" status "work"
  [ "${output}" = "connected" ]
}
