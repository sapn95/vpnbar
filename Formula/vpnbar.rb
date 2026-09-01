# frozen_string_literal: true

# vpnbar is a private repository, so this formula lives in it rather than in a
# public tap: `brew tap sapn95/vpnbar git@github.com:sapn95/vpnbar.git` taps it
# over SSH with the keys the user already has, and no release tarball has to be
# fetched from anywhere that would need a token.
class Vpnbar < Formula
  desc "Menu-bar VPN controller for Hammerspoon"
  homepage "https://github.com/sapn95/vpnbar"
  head "git@github.com:sapn95/vpnbar.git", branch: "main"

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
