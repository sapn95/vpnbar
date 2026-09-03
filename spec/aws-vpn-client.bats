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

  # Real sleeps would add a second to every test that talks to the socket.
  printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB}/sleep"

  chmod +x "${STUB}/nc" "${STUB}/open" "${STUB}/osascript" "${STUB}/sleep"
  export VPNBAR_PATH="${STUB}:/usr/bin:/bin"
}

teardown() {
  rm -rf "${TMP}"
}

password_file() {
  printf '%s' "$2" >"${HOME}/.config/AWSVPNClient/ovpn-mgmt-$1"
}

@test "status is disconnected when nothing is listening" {
  export STUB_NC_LISTENING=0
  run "${SCRIPT}" status
  [ "${status}" -eq 0 ]
  [ "${output}" = "disconnected" ]
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
