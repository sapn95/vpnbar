# frozen_string_literal: true

# The formula lives in the repository it builds rather than in a separate tap,
# the same way sapn95/git-tidy does it: `brew tap sapn95/vpnbar
# https://github.com/sapn95/vpnbar.git` taps this repository directly, so there
# is one place to change and no second repository to keep in step.
class Vpnbar < Formula
  desc "Menu-bar VPN controller for Hammerspoon"
  homepage "https://github.com/sapn95/vpnbar"
  # HTTPS, so anyone can install it without an SSH key of their own. While the
  # repository was private this was `ssh://git@github.com/...` — and note the
  # `ssh://`: Homebrew parses this with URI and rejects the scp-style
  # `git@github.com:...` outright with "bad URI (is not URI?)", even though
  # `brew tap` accepts either spelling.
  head "https://github.com/sapn95/vpnbar.git", branch: "main"

  depends_on :macos

  def install
    # The Spoon cannot be linked into ~/.hammerspoon from here: a formula must
    # not write to a home directory. `vpnbar link` is the step that does.
    libexec.install "VpnBar.spoon"
    bin.install "scripts/vpnbar"
    bin.install "scripts/aws-vpn-client.sh" => "aws-vpn-client"
  end

  def caveats
    <<~CAVEATS
      Link the Spoon into Hammerspoon:

        vpnbar link

      Add the line it prints to ~/.hammerspoon/init.lua, reload Hammerspoon,
      and check the result:

        vpnbar doctor

      If the icon does not appear, doctor will say whether a menu bar manager
      is holding it off-screen. That is the usual answer.
    CAVEATS
  end

  test do
    # The Spoon has to be where the command line expects to find it, and the
    # command line has to run at all.
    assert_predicate libexec/"VpnBar.spoon/init.lua", :exist?
    assert_match "usage:", shell_output("#{bin}/vpnbar 2>&1", 2)
    assert_match "usage:", shell_output("#{bin}/aws-vpn-client 2>&1", 2)
  end
end
