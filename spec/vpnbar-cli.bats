#!/usr/bin/env bats
#
# The command line: link, unlink, and the doctor that exists because the first
# thing to go wrong is a menu bar manager holding the icon off-screen, which
# looks exactly like a program that failed to start.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/vpnbar"
  TMP="$(mktemp -d)"
  STUB="${TMP}/bin"
  mkdir -p "${STUB}"

  export HOME="${TMP}/home"
  mkdir -p "${HOME}/.hammerspoon"

  export VPNBAR_HAMMERSPOON_APP="${TMP}/Hammerspoon.app"
  mkdir -p "${VPNBAR_HAMMERSPOON_APP}"

  # `hs` answers with whatever the test puts in STUB_HS_ANSWER; `pgrep` decides
  # whether Hammerspoon counts as running.
  cat >"${STUB}/hs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_HS_ANSWER:-}"
EOF
  cat >"${STUB}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit "${STUB_PGREP_EXIT:-0}"
EOF
  chmod +x "${STUB}/hs" "${STUB}/pgrep"
  export PATH="${STUB}:${PATH}"
  export STUB_HS_ANSWER="900 32"
}

teardown() {
  rm -rf "${TMP}"
}

loads_it() {
  printf 'local v = hs.loadSpoon("VpnBar")\n_G.vpnbar = v:start()\n' >"${HOME}/.hammerspoon/init.lua"
}

@test "no verb is a usage error" {
  run "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"usage:"* ]]
}

@test "link creates the symlink and prints the line to add" {
  run "${SCRIPT}" link
  [ "${status}" -eq 0 ]
  [ -L "${HOME}/.hammerspoon/Spoons/VpnBar.spoon" ]
  [[ "${output}" == *'hs.loadSpoon("VpnBar"):start()'* ]]
}

@test "link says nothing to add when the config already loads it" {
  loads_it
  run "${SCRIPT}" link
  [[ "${output}" == *"already loads it"* ]]
}

@test "link is idempotent" {
  run "${SCRIPT}" link
  run "${SCRIPT}" link
  [ "${status}" -eq 0 ]
  [ -L "${HOME}/.hammerspoon/Spoons/VpnBar.spoon" ]
}

@test "unlink removes the symlink and leaves the config alone" {
  loads_it
  "${SCRIPT}" link
  run "${SCRIPT}" unlink
  [ "${status}" -eq 0 ]
  [ ! -e "${HOME}/.hammerspoon/Spoons/VpnBar.spoon" ]
  grep -q 'loadSpoon' "${HOME}/.hammerspoon/init.lua"
}

@test "doctor is happy when everything is in place" {
  "${SCRIPT}" link
  loads_it
  run "${SCRIPT}" doctor
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to fix"* ]]
}

@test "doctor accepts a config that keeps a handle on the Spoon" {
  # The two-line form. Matching the whole suggested line would call it broken.
  "${SCRIPT}" link
  loads_it
  run "${SCRIPT}" doctor
  [[ "${output}" != *"init.lua does not load it"* ]]
}

@test "doctor names the menu bar manager when the icon is off-screen" {
  "${SCRIPT}" link
  loads_it
  export STUB_HS_ANSWER="-9224 32"
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"off-screen"* ]]
  [[ "${output}" == *"Bartender"* ]]
}

@test "doctor says so when the Spoon is not linked" {
  loads_it
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"vpnbar link"* ]]
}

@test "doctor says so when the config does not load it" {
  "${SCRIPT}" link
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"init.lua does not load it"* ]]
}

@test "doctor says so when Hammerspoon is not running" {
  "${SCRIPT}" link
  loads_it
  export STUB_PGREP_EXIT=1
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not running"* ]]
}

@test "doctor says so when vpnbar is not inside Hammerspoon" {
  "${SCRIPT}" link
  loads_it
  export STUB_HS_ANSWER="none"
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not running inside Hammerspoon"* ]]
}

@test "link prefers Homebrew's stable opt path over the Cellar" {
  # brew --prefix answers with opt/, which survives an upgrade; the Cellar path
  # carries the version and would leave a dangling link behind.
  mkdir -p "${TMP}/opt/vpnbar/libexec/VpnBar.spoon"
  cat >"${STUB}/brew" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${TMP}/opt/vpnbar"
EOF
  chmod +x "${STUB}/brew"
  run "${SCRIPT}" link
  [ "${status}" -eq 0 ]
  [ "$(readlink "${HOME}/.hammerspoon/Spoons/VpnBar.spoon")" = "${TMP}/opt/vpnbar/libexec/VpnBar.spoon" ]
}

@test "link falls back to the checkout when brew knows nothing" {
  cat >"${STUB}/brew" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB}/brew"
  run "${SCRIPT}" link
  [ "${status}" -eq 0 ]
  [[ "$(readlink "${HOME}/.hammerspoon/Spoons/VpnBar.spoon")" == *"/VpnBar.spoon" ]]
}

@test "doctor tells a dangling link apart from a missing one" {
  mkdir -p "${HOME}/.hammerspoon/Spoons"
  ln -sfn "${TMP}/gone/VpnBar.spoon" "${HOME}/.hammerspoon/Spoons/VpnBar.spoon"
  loads_it
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"points at nothing"* ]]
}
