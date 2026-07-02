# Publishing checklist (free public repo + winget)

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

## 5. Code signing — optional, NOT a gate for free OSS

An unsigned exe trips SmartScreen ("unrecognized app"). For a free, open-source
tool distributed via GitHub Releases this is acceptable: trust comes from the
open code, a transparent README, and a clean uninstaller — not a certificate.
Revisit an EV cert only if/when this becomes a more formal product.
