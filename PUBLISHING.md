# Publishing checklist (free public repo + winget + Homebrew)

Do these **in order**. Step 0 is blocking — do not push public until it passes.

---

## 0. Secret sweep of the WHOLE git history — BLOCKING

This app reads `~/.claude/.credentials.json` and `~/.codex/auth.json`, and during
development it produces builds, diagnostics files and live tests that write files.
A real OAuth token committed even once to a public repo is **not** fixable by
deleting it later — it must be treated as leaked and rotated. `.gitignore` only
protects *future* commits; it does **not** clean history.

**The safe order is to make the FIRST commit clean — not to scan after.** A secret that
lands in the initial commit is already in history; removing it later is painful. So:

```bash
# 1) Eyeball .gitignore — confirm it excludes *.log, the exported diagnostics txt, bin/, obj/,
#    and any *.credentials.json / auth.json test file.
# 2) Stage, then LOOK at exactly what you're about to commit — BEFORE committing:
git add -A
git status
git diff --cached --stat        # scan this list for anything that shouldn't ship
# 3) Only once it's clean, commit:
git commit -m "Initial commit"
# 4) Now confirm with gitleaks (belt-and-suspenders), and re-run it before every push:
gitleaks detect --source . --redact -v          # scans the full history
gitleaks protect --staged --redact -v           # staged + working tree
```

- **0 findings → proceed.**
- **Any finding → STOP.** Remove the secret from history (`git filter-repo`),
  rotate the leaked token at the provider, and re-scan. Do not publish until clean.
- The point is step 2 (look before you commit), not step 4 (scan after). gitleaks confirms; the
  `.gitignore` + `git status` review is what keeps the first commit clean.

> **Status as of this writing:** the repo's `.git` exists but has **no commits**
> (no `logs/HEAD`, empty `refs/heads`, no index), and no `.credentials.json` /
> `auth.json` is present in the working tree. So there is **no history to leak** yet
> — the risk is only future commits, which `.gitignore` covers. Still run gitleaks
> once after your first commit, before the first push. If you ever import an older
> dev history, sweep that too (or start the public repo from a fresh clean commit
> rather than carrying old history).

> **Already verified:** the public single-file exe was grepped for `api/oauth/usage`,
> `wham/usage` and `chatgpt.com/backend-api` → **0 matches**. The `#if USAGE_LOCAL`
> exclusion holds at the binary level. Re-run this grep on the FINAL exe you upload.

`.gitignore` already excludes `.credentials.json`, `auth.json`, `*.key`, `.env*`,
diagnostics files and build output — keep it that way.

> Note: the maintainer runs `git init` / first push manually. This repo ships no
> git history of its own.

---

## 1. Verify the public build is clean (no token / no gray endpoint)

The default Release build is the **public** flavor: usage comes only from the
official channels (Claude statusline capture + Codex rollout). The undocumented
OAuth endpoints are compiled out (they live behind `#if USAGE_LOCAL`).

```bash
# PUBLIC, self-contained (standalone, ~290 MB RAM, ~69 MB exe, no prereq):
dotnet publish src/MyAgents -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true

# PUBLIC, framework-dependent (~180 MB RAM, ~0.3 MB exe) — needs the .NET 8 Desktop Runtime.
# OPTIONAL smaller build. The winget manifest ships the SELF-CONTAINED portable above (no
# prereq, most reliable). If you'd rather ship FD via winget, add a .NET Desktop Runtime
# dependency to the manifest and test on a clean VM first.
dotnet publish src/MyAgents -c Release -r win-x64 --self-contained false \
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=false

# LOCAL (personal, keeps the endpoint fallback) — DO NOT distribute:
dotnet publish src/MyAgents -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:DefineConstants=USAGE_LOCAL
```

Sanity check the shipped exe never references the gray endpoints:

```bash
# Should print NOTHING for the public build:
grep -a -o "api/oauth/usage\|wham/usage" \
  src/MyAgents/bin/Release/net8.0-windows/win-x64/publish/MyAgents.exe
```

## 2. Attribution & licence

- `LICENSE` (MIT) present.
- `THIRD-PARTY-NOTICES.md` carries the verbatim copyright + MIT text of the two
  projects this work was informed by. Keep it shipped in the release.

## 2b. Create the repo WITHOUT a terminal (GitHub Desktop)

If you don't use git from the command line, use **GitHub Desktop** (free GUI) — it does init +
review + commit + push, and it shows exactly which files will be committed so the first commit stays clean:

1. Install **GitHub Desktop** (desktop.github.com) and sign in.
2. **File → Add local repository** → pick this folder (`…\IdeaProjects\ClaudeCODEAPP`). It offers to
   **create a repository here** (that's `git init`) — accept.
3. It reads `.gitignore` and lists **only the files that will be committed**. **Read that list with
   your eyes** — confirm there's NO `.credentials.json`, `auth.json`, `*.log`, or diagnostics file.
   (This is the "review staged before committing" step, in a GUI.)
4. Type a summary ("Initial commit") → **Commit to main**.
5. **Publish repository** — keep **"Keep this code private" TICKED for now**.
6. On github.com → repo → **Settings → Change visibility → Public** after a last look. GitHub's
   **secret scanning** runs automatically on public repos and warns if a token ever slips in — a good
   safety net instead of running gitleaks by hand.

Public vs private: for a winget-installable tool it should end up **public**; publishing **private
first, then flipping to public** gives you a calm moment to review before it's visible.

## 3. GitHub release

1. Tag a version (e.g. `v0.1.0`).
2. Upload the **public** `MyAgents.exe` as a release asset.
3. Record its SHA256 (needed for winget):
   ```powershell
   (Get-FileHash .\MyAgents.exe -Algorithm SHA256).Hash
   ```

## 4. winget

See `packaging/winget/` — it ships the **self-contained portable** exe (standalone, no
runtime prereq), matching the SHA256 of the asset you upload. Fill the placeholders (version, release URL, SHA256),
validate, then submit a PR to `microsoft/winget-pkgs`:

```powershell
winget validate --manifest packaging\winget
winget install --manifest packaging\winget   # local install test
# then: wingetcreate submit, or PR the manifests into winget-pkgs
```

## 5. Code signing — optional, NOT a gate for free OSS (Windows)

An unsigned exe trips SmartScreen ("unrecognized app"). For a free, open-source
tool distributed via GitHub Releases this is acceptable: trust comes from the
open code, a transparent README, and a clean uninstaller — not a certificate.
Revisit an EV cert only if/when this becomes a more formal product.

---

## macOS release checklist (Developer ID + notarization + Homebrew)

Unlike Windows, an unsigned/unnotarized macOS app is **not a soft warning** — Gatekeeper
refuses to launch it at all on any Mac other than the one that built it (`"MyAgentsMac.app"
can't be opened because Apple cannot check it for malicious software`). So for macOS this
IS a gate: every public release must be Developer ID signed + notarized. Everything below
this point that doesn't need the certificate itself (project signing config, the release
script, the icon, the cask template, `mac/README.md`) is already done (HITO 3) — what's left
is the steps that only Miguel can do (they need his Apple Developer account).

### One-time setup (do once per machine/account)

1. **Create the "Developer ID Application" certificate** (Miguel does not yet have one — only
   Apple Development/Distribution certs exist as of writing). Requires the paid **Apple Developer
   Program** membership (team `2BYX29N42C`):
   - developer.apple.com/account/resources/certificates/list → **+** → **Developer ID
     Application** → follow the CSR flow (or use Xcode → Settings → Accounts → *Manage
     Certificates* → **+** → **Developer ID Application**, which handles the CSR for you).
   - Confirm it landed in your login keychain:
     `security find-identity -v -p codesigning` should list
     `"Developer ID Application: Miguel Ángel Ramírez (2BYX29N42C)"`.
2. **Store notarytool credentials** (once; never put a password in a script or commit):
   ```bash
   xcrun notarytool store-credentials "myagents-notary" \
       --apple-id "<your Apple ID email>" \
       --team-id "2BYX29N42C" \
       --password "<an app-specific password from appleid.apple.com>"
   ```
   (An App Store Connect API key also works instead of `--apple-id`/`--password` — see
   `xcrun notarytool store-credentials --help`. Either way the secret lives ONLY in the keychain,
   referenced later by profile name `myagents-notary`.)
3. **Create your Homebrew tap** (once): `brew tap-new miguelangelxramirez/tap`, then copy
   `mac/dist/Casks/myagents.rb` into that repo's `Casks/myagents.rb` and push it.

### Per-release steps

1. Bump `MARKETING_VERSION` in `mac/project.yml` if this is a new version, and confirm
   `mac/CHANGELOG`-equivalent (commit messages / release notes) reflects what changed.
2. Run the release script from the `mac/` directory:
   ```bash
   cd mac
   ./scripts/build-release.sh
   ```
   This does `xcodegen generate` → archive (Release, Developer ID) → export
   (`method: developer-id`) → zip (`ditto`) → `xcrun notarytool submit --wait` → staple → re-zip →
   prints the **version** and **sha256** of the final zip. It fails loudly (with the exact fix
   command) if the cert or the notary profile is missing — it never falls back to ad-hoc signing.
3. Tag the release: `git tag v<version> && git push origin v<version>`.
4. Create the GitHub release for that tag and upload `mac/build/MyAgentsMac-<version>.zip`
   as the release asset.
5. Update `mac/dist/Casks/myagents.rb` (in this repo, as the template) **and** the copy in
   `miguelangelxramirez/homebrew-tap`'s `Casks/myagents.rb`: set `version` and `sha256` to the
   values `build-release.sh` printed. Push both.
6. Sanity-check before telling anyone it's out:
   ```bash
   brew uninstall --cask myagents 2>/dev/null; brew untap miguelangelxramirez/tap 2>/dev/null
   brew install --cask miguelangelxramirez/tap/myagents   # fresh install from the tap
   open -a MyAgents                                       # launches with no Gatekeeper warning
   xcrun stapler validate /Applications/MyAgentsMac.app   # confirms the staple is valid offline
   ```

### What's already done vs. what's Miguel-only

- ✅ Done (HITO 3, this repo): Release signing config in `mac/project.yml` (Developer ID identity
  + manual style, Debug stays Automatic), no entitlements file (confirmed unnecessary — see
  `mac/README.md`/CONTEXT.md D5), `mac/scripts/build-release.sh`, the generated `AppIcon`,
  `mac/dist/Casks/myagents.rb` template, `mac/README.md`. Verified: Debug tests green, an
  ad-hoc/no-signing Release build compiles.
- ⛔ Miguel-only (needs his Apple Developer account, cannot be done by an agent): create the
  Developer ID Application certificate, run `notarytool store-credentials`, create the Homebrew
  tap repo, run `build-release.sh` for real, create the GitHub release, push the filled-in cask.

## Sparkle auto-updates (direct-.zip installs)

Homebrew users update with `brew upgrade`. Everyone who installed the `.zip` directly gets updates
through **Sparkle 2** (embedded via SPM; no XPC services/entitlements because the app isn't
sandboxed). The app reads `SUFeedURL` + `SUPublicEDKey` from `mac/Resources/Info.plist` and offers
"Check for Updates…" in the ⚙ menu.

- **Feed:** `appcast.xml` at the repo root, served at
  `https://raw.githubusercontent.com/miguelangelxramirez/MyAgents/main/appcast.xml`. An empty
  channel = "no updates". `build-release.sh` step 9 regenerates it.
- **Signing key (EdDSA):** the PRIVATE key lives ONLY in Miguel's login keychain (created once with
  Sparkle's `generate_keys`). The matching public key is `SUPublicEDKey` in Info.plist
  (`5eP0+rh5u/nGuv03JlX31fjdjZG1VUHYJN9Vv8LlCkA=`). ⚠️ **Back up the private key** — without it you
  can never sign another update, and users would need to reinstall by hand. Export it with
  `generate_keys -x sparkle_private_key.txt` and store it somewhere safe (a password manager), then
  delete the export file.
- **Release flow (added to `build-release.sh`):** bump `MARKETING_VERSION` **and**
  `CURRENT_PROJECT_VERSION` in `project.yml` first (Sparkle compares `CFBundleVersion`), run the
  script (step 9 downloads the pinned Sparkle tools, signs the stapled zip, rewrites `appcast.xml`),
  then upload the zip to the GitHub release **and commit+push `appcast.xml` to `main`**. macOS may
  prompt once to allow keychain access to the signing key — approve it.
- **Not yet end-to-end:** the feed goes live only after the first Sparkle-enabled release is cut and
  `appcast.xml` is pushed. Until then the app checks, finds an empty feed, and reports "up to date".
