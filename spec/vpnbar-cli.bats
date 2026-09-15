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

  export VPNBAR_APP_DIR="${TMP}/Applications"
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
  # Never let a search reach the real Hammerspoon on this machine.
  export VPNBAR_HS="${STUB}/hs"
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

# ---------------------------------------------------------------- starting it

@test "start asks Hammerspoon to start the Spoon" {
  export STUB_HS_ANSWER="started"
  run "${SCRIPT}" start
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"started"* ]]
}

@test "start says so rather than starting a second one" {
  export STUB_HS_ANSWER="already running"
  run "${SCRIPT}" start
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already running"* ]]
}

@test "start fails loudly when the Spoon will not load" {
  export STUB_HS_ANSWER="FAIL could not load the Spoon: nope"
  run "${SCRIPT}" start
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"could not load the Spoon"* ]]
  [[ "${output}" != *"FAIL "* ]]
}

@test "start opens Hammerspoon when it is not running" {
  export STUB_PGREP_EXIT=1
  export OPENED="${TMP}/opened"
  # Silent, so "does the command line answer" is a no and the process has to be
  # started. A talking stub would mean Hammerspoon was already up.
  export VPNBAR_HS="${TMP}/quiet-hs"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP}/quiet-hs"
  chmod +x "${TMP}/quiet-hs"
  cat >"${STUB}/open" <<'SH'
#!/usr/bin/env bash
echo "opened $*" >>"${OPENED}"
SH
  chmod +x "${STUB}/open"
  # pgrep never succeeds, so this gives up rather than hanging forever.
  cat >"${STUB}/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${STUB}/sleep"
  run "${SCRIPT}" start
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"did not come up"* ]]
  [[ "$(cat "${OPENED}")" == *"Hammerspoon.app"* ]]
}

@test "stop says so when there is nothing to stop" {
  export STUB_HS_ANSWER="not running"
  run "${SCRIPT}" stop
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not running"* ]]
}

@test "the doctor points at start, not at a reload" {
  export STUB_HS_ANSWER="none"
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"vpnbar start"* ]]
}

# ------------------------------------------------- a copy is not a link

@test "link replaces a real directory instead of linking inside it" {
  mkdir -p "${HOME}/.hammerspoon/Spoons/VpnBar.spoon/vpnbar"
  echo stale >"${HOME}/.hammerspoon/Spoons/VpnBar.spoon/init.lua"
  run "${SCRIPT}" link
  [ "${status}" -eq 0 ]
  [ -L "${HOME}/.hammerspoon/Spoons/VpnBar.spoon" ]
  [ ! -e "${HOME}/.hammerspoon/Spoons/VpnBar.spoon/VpnBar.spoon" ]
  [[ "${output}" == *"replacing the copy"* ]]
}

@test "the doctor tells a copy apart from a link" {
  mkdir -p "${HOME}/.hammerspoon/Spoons/VpnBar.spoon"
  run "${SCRIPT}" doctor
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"a copy, not a link"* ]]
}

@test "unlink removes a copy, which -f alone could not" {
  mkdir -p "${HOME}/.hammerspoon/Spoons/VpnBar.spoon/vpnbar"
  run "${SCRIPT}" unlink
  [ "${status}" -eq 0 ]
  [ ! -e "${HOME}/.hammerspoon/Spoons/VpnBar.spoon" ]
}

# --------------------------------------------------------- something to click

@test "app writes a bundle that launches start" {
  run "${SCRIPT}" app
  [ "${status}" -eq 0 ]
  [ -x "${VPNBAR_APP_DIR}/vpnbar.app/Contents/MacOS/vpnbar" ]
  [ -f "${VPNBAR_APP_DIR}/vpnbar.app/Contents/Info.plist" ]
  [[ "$(cat "${VPNBAR_APP_DIR}/vpnbar.app/Contents/MacOS/vpnbar")" == *" start"* ]]
}

# The Finder launches a bundle from a working directory of its own choosing, so
# a relative path is an app that works from the checkout and nowhere else.
@test "the launcher holds an absolute path" {
  cd "${BATS_TEST_DIRNAME}/.." && run ./scripts/vpnbar app
  [ "${status}" -eq 0 ]
  local launcher="${VPNBAR_APP_DIR}/vpnbar.app/Contents/MacOS/vpnbar"
  [[ "$(grep exec "${launcher}")" == *'exec "/'* ]]
  [[ "$(grep exec "${launcher}")" != *'"./'* ]]
}

@test "the bundle stays out of the Dock, being a launcher" {
  run "${SCRIPT}" app
  [[ "$(cat "${VPNBAR_APP_DIR}/vpnbar.app/Contents/Info.plist")" == *"LSUIElement"* ]]
}

# plutil is macOS only and CI is Linux. plistlib parses the file rather than
# linting it, which is the stronger check anyway.
@test "the plist is well formed" {
  run "${SCRIPT}" app
  run python3 -c "import plistlib,sys; d=plistlib.load(open(sys.argv[1],'rb')); sys.exit(0 if d['CFBundleExecutable']=='vpnbar' else 1)" \
    "${VPNBAR_APP_DIR}/vpnbar.app/Contents/Info.plist"
  [ "${status}" -eq 0 ]
}

@test "app is idempotent" {
  "${SCRIPT}" app
  run "${SCRIPT}" app
  [ "${status}" -eq 0 ]
  [ -x "${VPNBAR_APP_DIR}/vpnbar.app/Contents/MacOS/vpnbar" ]
}

@test "unlink takes the bundle away as well" {
  "${SCRIPT}" link
  "${SCRIPT}" app
  run "${SCRIPT}" unlink
  [ "${status}" -eq 0 ]
  [ ! -e "${VPNBAR_APP_DIR}/vpnbar.app" ]
}

@test "link points at the app command" {
  run "${SCRIPT}" link
  [[ "${output}" == *"app"* ]]
}

# ------------------------------------------- a GUI launch has almost no PATH

# The bug this guards: a double-clicked bundle gets
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, so an `hs` that is only reachable through
# PATH is not reachable at all. Rather than rebuilding that PATH here — which
# decides what bash and env the test host has, and CI is not macOS — the stub is
# taken off PATH entirely. Nothing but the bundle can answer, so a lookup that
# consulted only PATH fails this.
@test "start finds hs inside the Hammerspoon bundle, not on PATH" {
  mkdir -p "${VPNBAR_HAMMERSPOON_APP}/Contents/Frameworks/hs"
  cat >"${VPNBAR_HAMMERSPOON_APP}/Contents/Frameworks/hs/hs" <<'SH'
#!/usr/bin/env bash
echo "started from the bundle"
SH
  chmod +x "${VPNBAR_HAMMERSPOON_APP}/Contents/Frameworks/hs/hs"
  rm -f "${STUB}/hs"
  unset VPNBAR_HS
  run "${SCRIPT}" start
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"started from the bundle"* ]]
}

@test "start fails when Hammerspoon's command line is nowhere" {
  export VPNBAR_HS="${TMP}/no-such-hs"
  run "${SCRIPT}" start
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"hs.ipc.cliInstall()"* ]]
}

@test "a FAIL answer is an error, not a success with a message" {
  export STUB_HS_ANSWER="FAIL start did not take"
  run "${SCRIPT}" start
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"no answer"* ]]
}

# ------------------------------------------------ the two review findings

# /opt/homebrew/bin/vpnbar points into the Cellar at a path carrying the
# version. Following it bakes that version into the launcher, and the next
# brew upgrade removes the keg and leaves an app pointing at nothing.
@test "the launcher keeps the stable path, not the versioned one it resolves to" {
  mkdir -p "${TMP}/Cellar/vpnbar/HEAD-abc123/bin" "${TMP}/opt/bin"
  cp "${SCRIPT}" "${TMP}/Cellar/vpnbar/HEAD-abc123/bin/vpnbar"
  ln -s "${TMP}/Cellar/vpnbar/HEAD-abc123/bin/vpnbar" "${TMP}/opt/bin/vpnbar"
  run "${TMP}/opt/bin/vpnbar" app
  [ "${status}" -eq 0 ]
  local launcher="${VPNBAR_APP_DIR}/vpnbar.app/Contents/MacOS/vpnbar"
  [[ "$(cat "${launcher}")" == *"${TMP}/opt/bin/vpnbar"* ]]
  [[ "$(cat "${launcher}")" != *"Cellar"* ]]
}

# The process is in the table before ipc is listening, so waiting on pgrep
# alone returns early and the first real request comes back empty.
@test "start waits for the command line, not just for the process" {
  export STUB_PGREP_EXIT=0
  export VPNBAR_HS="${TMP}/quiet-hs"
  cat >"${TMP}/quiet-hs" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${TMP}/quiet-hs"
  cat >"${STUB}/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${STUB}/sleep"
  run "${SCRIPT}" start
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"did not come up"* ]]
  [[ "${output}" == *"cliInstall"* ]]
}

@test "start goes ahead when the command line answers straight away" {
  export STUB_HS_ANSWER="started"
  run "${SCRIPT}" start
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"started"* ]]
  [[ "${output}" != *"starting Hammerspoon"* ]]
}
