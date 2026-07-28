# Handoff — Ullage 0.1.1 release readiness

Context transferred from a Claude Code session on 2026-07-28. Everything below was
verified against the repo in that session, not recalled. This file is untracked
scratch — delete it or gitignore it before committing.

## What this project is

Ullage: a macOS menu-bar app that tracks usage limits **and** cost for Claude and
Cursor in one place. SwiftPM package (no working `.xcodeproj` — the app bundle is
assembled by hand in `Scripts/package_app.sh`). Distributed as an ad-hoc-signed
DMG plus a Homebrew cask. Public repo: `FR1EDDY/Ullage`.

Three design commitments that explain most of the code:

1. **Design-led and focused** — menu-bar only, `LSUIElement`, no Dock icon.
2. **Limits and cost unified** — nobody else shows both.
3. **Honest forecasting** — no number is surfaced without a confidence qualifier,
   and the forecast returns `nil` rather than guess when it has nothing truthful
   to say. This is the moat; preserve it in any change.

Overriding goal: the install and first run must be **seamless** — Homebrew,
zero-config, credentials auto-detected.

## Where things stand right now

- Working tree is **dirty and uncommitted**. VERSION is `0.1.1`; the only git tag
  is `v0.1.0`.
- `swift build` and `swift test` both pass — 163 tests, 0 failures.
- Universal release build succeeds (x86_64 + arm64, `minos 13.0` on both slices).
- `dist/Ullage-0.1.1.dmg` is already built and current with the tree
  (sha256 `406186621c515e582d6341cef0fb994c3e11b8a02c0ae6a1dc3cf2798abbc5ad`).
  `dist/` is gitignored. Rebuild the DMG if any source changes before release —
  that sha will change.

The uncommitted work is the branding pass: bundled provider icons replacing the
old "read the icon off the installed Claude.app/Cursor.app" approach, a new
`CardStyle.swift` / `ProviderIcon.swift` / `BundledResource.swift`, plus README,
CI, and packaging updates.

## BLOCKER — do this before committing

Three files the build depends on are **untracked** (not gitignored — simply never
added):

- `Resources/AppIcon.icns`
- `Sources/Ullage/Resources/claude-icon.png`
- `Sources/Ullage/Resources/cursor-icon.png`

`git commit -am` will not include them. `.github/workflows/ci.yml` asserts all
three reach the app bundle, so CI's package job fails without them — and a release
cut from a clean clone would ship with no branding anywhere. That is exactly the
bug v0.1.0 shipped with, which is why those CI assertions exist.

**Use an explicit `git add` for these three paths.**

Also untracked and worth a decision (probably do *not* commit the root-level ones,
they duplicate `docs/images/`): `ullage-banner-v5.{png,svg}`,
`ullage-icon-v6.{png,svg}` at the repo root.

## Release order (packaging comes AFTER the commit)

The cask's `url` points at `releases/download/v#{version}/`, and its `sha256` must
match the file actually uploaded — so the cask cannot be updated until the release
exists.

1. Commit (including the three untracked resources above).
2. Run `Scripts/release.sh`. It repackages, tags `v0.1.1`, pushes the tag, creates
   the GitHub release, uploads the DMG, and prints the two cask lines to change.
   Note it tags `HEAD` but packages the *working tree* — committing first is what
   keeps the tag honest.
3. Paste the printed `version` / `sha256` into `Casks/ullage.rb` in the **separate
   `homebrew-ullage` tap repository**, and mirror the same edit into
   `Distribution/ullage.rb` here (that copy is documentation, not what Homebrew
   reads). Both are still on `0.1.0` with the old sha.

## Answers to the four questions that drove this session

### Does it work across macOS versions?

Structurally safe, empirically unverified.

- Binary declares `minos 13.0` (Ventura) on both architecture slices.
- There is not one `#available` guard in the codebase because nothing needs one:
  no API newer than Ventura is used. `MenuBarExtra` is 13.0;
  `MainActor.assumeIsolated` back-deploys to 10.15. The compiler enforces the
  deployment target, so a version mistake cannot compile.
- **Gap:** nobody has ever launched the app on 13, 14, or 15. CI builds and
  packages on `macos-14` but never runs it; the only runtime evidence is a
  macOS 26 machine. The real risk is SwiftUI layout drift in the panel and HUD,
  not API availability. A Ventura VM for five minutes closes this.
- Ad-hoc signed, not notarised: a manual DMG download needs right-click → Open.
  The cask's `postflight` strips quarantine so `brew install` is clean. Both
  documented deliberately.

### Does it lag after long use?

Architecture is sound; no soak evidence exists.

Verified in `Sources/Ullage/UsageModel.swift`: refresh timer is non-repeating and
rescheduled with `[weak self]`; in-flight task cancelled before each new one;
sleep/wake observers removed in `deinit`; persistence and forecasting run off the
main thread in one serialized task (deliberately serialized — they used to race,
and the forecast could read history a moment before the newest sample landed).
Polling is 5–15 min, jittered to avoid lockstep with other clients on the same
account-wide endpoint. SQLite is indexed on the series column and each poll reads
a bounded 10-day window. `ProviderIcon` caches decoded `NSImage`s including `nil`,
because `ProviderDescriptor.icon` is a computed property SwiftUI re-reads every
body pass.

Two things to watch, not bugs:

- `pruneExpired()` runs **once per launch** (`UsageModel.swift:349`). A menu-bar
  app running for months never prunes. Growth measured at ~224 KB / 2 days, so
  180-day retention plateaus near 20 MB — harmless, but unbounded *within* a
  launch.
- `~/Library/Application Support/Ullage/cost-cache.json` is already 1.2 MB and is
  fully re-encoded and atomically rewritten whenever any transcript changes.
  Bounded by the cost window so it plateaus, but it is the largest per-refresh
  disk write in the app.

**Honest limit:** the only running instance observed had 21 minutes uptime at
131 MB RSS and 0% CPU. That is not a soak test. Nothing here has been profiled
over hours.

### Are the forecasts real and reliable?

Real, honestly hedged, and linear.

Every figure derives from samples actually observed and persisted, extrapolated by
pure functions in `Analytics/Forecast.swift`, `BurnRate.swift`,
`WeeklyProjection.swift`. `ForecastEngine` is the only part touching I/O; the
split is what makes the rules testable. Coverage: 25 analytics tests + 7 engine
tests.

Three safeguards worth not breaking:

- Series are split wherever the percentage **drops** — that is what a window reset
  looks like from outside. Without it the delta goes negative and the app would
  forecast a limit that heals itself.
- `Forecast.session` returns `nil` when there is nothing truthful to say: no
  samples, no measurable rate, or a window already at cap.
- Confidence tiers gate the wording. Below 5 completed windows the percentile
  baseline is just "the worst thing seen so far", so the UI says "rough estimate"
  instead of pretending.

Limitations to state plainly if asked: it is a **linear projection of the
window-long average rate**, and real usage is bursty — a forecast taken mid-burst
overestimates, one after idle underestimates. Accuracy is also capped upstream:
when `ClaudeUsageProvider` falls back to rate-limit headers, the forecast inherits
that coarseness. A fresh install shows a placeholder for the first few hours by
design.

## Working agreements from the session

- Claims get verified by running the command, not asserted from reading code.
  Where evidence is missing (macOS 13 runtime, long-run soak), say so rather than
  imply coverage that does not exist.
- The dense explanatory comments throughout the codebase are load-bearing — most
  encode a specific bug that already shipped once. Do not strip them.
