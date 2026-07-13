# Homebrew Cask for MyAgents (macOS menu-bar monitor for Claude Code / Codex sessions).
#
# This file lives in the MAIN MyAgents repo as a TEMPLATE. The actual cask that `brew install`
# resolves lives in Miguel's own tap repo, e.g. `miguelangelxramirez/homebrew-tap`
# (`Casks/myagents.rb` there). After each release, copy this file over there (or symlink it) with
# `version`/`sha256` filled in — `mac/scripts/build-release.sh` prints both at the end of a run.
#
# Install (once the tap exists and this is pushed there):
#   brew install --cask miguelangelxramirez/tap/myagents
#
# Verify locally before pushing to the tap:
#   brew style --cask mac/dist/Casks/myagents.rb
#   brew install --cask ./mac/dist/Casks/myagents.rb   # local file install, no tap needed
cask "myagents" do
  version "0.1.0"
  sha256 "b3d27eaf0dbc6f536ffd6bcc1fdffa5c97178d394610273b5ba6c7ce6cd2b976"

  url "https://github.com/miguelangelxramirez/MyAgents/releases/download/v#{version}/MyAgentsMac-#{version}.zip"
  name "MyAgents"
  desc "Menu bar monitor for Claude Code and Codex coding-agent sessions"
  homepage "https://github.com/miguelangelxramirez/MyAgents"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :tahoe" # macOS 26 — matches MACOSX_DEPLOYMENT_TARGET in mac/project.yml

  app "MyAgentsMac.app"

  # `zap` only ever runs with `brew uninstall --zap` (never on a plain uninstall) — it removes
  # MyAgents' OWN app state. It deliberately does NOT touch anything under ~/.claude or ~/.codex:
  # those are the user's Claude Code / Codex install, shared with other tools, and MyAgents' own
  # hooks there must be removed through the app itself first (see caveats below) so the installer
  # can restore any statusline it chained rather than leaving Claude Code in a half-configured state.
  zap trash: [
    "~/Library/Preferences/com.miguelangelramirez.myagents.mac.plist",
    "~/Library/Saved Application State/com.miguelangelramirez.myagents.mac.savedState",
    "~/Library/HTTPStorages/com.miguelangelramirez.myagents.mac",
  ]

  caveats <<~EOS
    MyAgents is a menu-bar-only app (no Dock icon) — after installing, launch it once from
    Spotlight/Launchpad ("MyAgents") or:
      open -a MyAgents

    The FIRST time you enable tracking (⚙ menu → "Enable tracking" in the app), it installs a few
    small Node hook scripts under ~/.claude/statusbar/ and registers them in
    ~/.claude/settings.json (and, if you use Codex, Codex's own managed-hooks location) so it can
    see what each session is doing. Nothing is sent over the network and no token is read.

    Before `brew uninstall --zap myagents`, use ⚙ → "Remove tracking" INSIDE the app first — that
    cleanly reverts ~/.claude/settings.json (restoring any statusline you had) and deletes
    ~/.claude/statusbar/. `--zap` only clears MyAgents' own preferences/state, not files it wrote
    inside ~/.claude or ~/.codex.

    It will ask for two permissions the first time you use them (see the README for details):
      - Automation, to bring the right terminal tab/window to the front when you click a session.
      - Notifications, to alert you when a session is waiting on your permission.
  EOS
end
