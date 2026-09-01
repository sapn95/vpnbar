#!/usr/bin/env bash
# Link the Spoon into Hammerspoon and print the two lines that load it.
#
# A symlink rather than a copy, so `git pull` is the whole update procedure and
# there is never a second, older copy of the code being the one that runs.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spoons="${HOME}/.hammerspoon/Spoons"

mkdir -p "${spoons}"
ln -sfn "${repo}/VpnBar.spoon" "${spoons}/VpnBar.spoon"
echo "linked ${spoons}/VpnBar.spoon -> ${repo}/VpnBar.spoon"

cat <<'EOF'

Add this to ~/.hammerspoon/init.lua, then reload Hammerspoon:

    hs.loadSpoon("VpnBar"):start()

The first connect or disconnect of a GlobalProtect profile asks macOS for
Accessibility permission for Hammerspoon. Nothing else here needs it.
EOF
