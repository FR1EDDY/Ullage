# Ullage — Execution Plan

**North star:** the calmest, best-looking, *seamless* AI-usage app — Claude + Cursor + a few, done perfectly, with **cost** and **honest forecasting** no competitor has.

**Built on:** the current simple tree (`Sources/Ullage/`). We do *not* resurrect the reverted heavy version (`fff65f2`); at most its analytics math is a correctness reference.

**Locked decisions:**
- Distribution: **unsigned + ad-hoc sign + Gatekeeper note** (the CodexBar experience). Signing is a later flip-a-switch upgrade.
- Claude fetch: **keep current bearer + cookie paths, add the rate-limit-header method as a fallback**.
- Percentages stay **0–100** internally (matches current `ClaudeUsageProvider`); all time math in **UTC**, localized only at display.

**The three wedges** (see memory `project-strategy-and-differentiation`):
1. Design-led & focused. 2. Limits **and** cost, unified. 3. Honest forecasting (the moat).

---

## Phase 1 — Foundations
*Small, enables everything after.*

- **`Persistence/SnapshotStore.swift`** — a minimal SQLite store recording each poll: `(provider, capturedAt, kind, percentUsed, resetsAt, rawJSON)`. No framework split; one store in the current target. Schema-versioned from day one. Stored at `~/Library/Application Support/Ullage/usage.sqlite`.
- **Fetch resilience** — add `POST https://api.anthropic.com/v1/messages` (1-token payload) reading `anthropic-ratelimit-unified-5h/7d-utilization` + `-reset` response headers, as a third strategy behind the current bearer + cookie paths in `ClaudeUsageProvider`.
- **Wire persistence** — `UsageModel` inserts a snapshot on every successful poll; prune older than 180 days on launch.

**Acceptance:** readings survive relaunch; Claude still resolves if one fetch path fails.

---

## Phase 2 — Cost from local logs
*Wedge #2. Parity with CodexBar's best trick, offline.*

- **`Providers/ClaudeCostProvider.swift`** — read `~/.claude/projects/**/*.jsonl`; parse per-request `input`, `output`, `cache_creation`, `cache_read` tokens + `model` + `timestamp`.
- **Pricing** — bundle a LiteLLM-style pricing table (`model_prices.json`) in the app resources; cache and use offline. Custom-override friendly.
- **UI** — a **Cost** section in the popover: `Today`, `30d`, `tokens`, `top model`, small daily bar chart.

**Acceptance:** cost/tokens render with no network; unknown models degrade gracefully (shown as "unpriced", not $0).

---

## Phase 3 — Honest forecasting  *(the moat — detailed below)*

See **"Phase 3 in depth"** further down.

---

## Phase 4 — Settings redesign + extensible providers
*Wedge #1.*

- Rework `Views/SettingsView.swift` into three groups: **General** (launch at login, refresh) · **Menu bar** (choose up to **2** logos, enforced with a live counter) · **Connections** (extensible provider list + "Add a platform").
- **`Providers/ProviderRegistry.swift`** — adding ChatGPT/Codex/Gemini becomes one row + one registry line, not a refactor.
- Move **Floating HUD** toggle to the main popover. Fix button semantics: neutral **Sign out**, accent **Connect**, amber **Reconnect**.

**Acceptance:** adding a provider touches only the registry + its provider file; menu-bar "max 2" is enforced in the UI.

---

## Phase 5 — Seamless distribution
*The experience you loved.*

- **`Scripts/package_app.sh`** — build a real `.app` bundle (Info.plist with `LSUIElement`), ad-hoc sign, produce a DMG. (Also fixes that the repo is SPM-only with a broken `.xcodeproj`.)
- **Homebrew cask** in a `homebrew-ullage` tap → one-command `brew install --cask`.
- **Sparkle** auto-update (EdDSA-signed `appcast.xml` on GitHub Releases).
- **README** — one-line install, the "right-click → Open the first time" note, privacy section (endpoints, Keychain, no telemetry).

**Acceptance:** paste one command → trust once → it auto-detects the Claude login and works.

---

## Phase 6 — Extra providers + polish

- Implement ChatGPT / Codex / Gemini against the Phase 4 registry.
- Tests (**Swift Testing**): window-math/DST, forecasting, cost parsing, persistence.
- Design polish pass across popover / HUD / menu bar.

---

## Recommended order

`1 → 2 → 3 → 4 → 5 → 6`. Phases 2–3 are the value; Phase 1 unlocks both; Phase 5 delivers the seamless feel. Distribution (5) can be pulled forward to right after Phase 1 if shipping the install experience early matters more than features.

---
---

# Phase 3 in depth — Honest forecasting

**Why it's the moat:** none of the ~12 competitors forecast. They show *where you are*; we show *where you're heading* — and, just as usefully, when you're safe. Everything here is **pure functions over `[(Date, Double)]`** (timestamp, percentUsed 0–100), living in `Sources/Ullage/Analytics/`, with **no I/O** so it's trivially testable.

## 3.0 The data it runs on

From `SnapshotStore` (Phase 1) we can pull, per provider + window kind, an ordered series of `(capturedAt, percentUsed)`:
- **Claude session** — the 5-hour window. Drives time-to-exhaustion + anomaly.
- **Claude weekly** — the 7-day window. Drives the weekly projection (the valuable one).
- **Cursor total** — monthly billing window. Same math, longer horizon.

All series are UTC. Reset boundaries come from the stored `resetsAt`.

## 3.1 Burn rate — `Analytics/BurnRate.swift`

Percent-points consumed per hour, computed two ways:

```
burnRate = (percentUsed_end − percentUsed_start) / hoursElapsed
```

- **Window-long rate** — first→last sample within the current window. Drives the **forecast**.
- **Short-horizon rate** — samples within the trailing **30 min**. Drives the **anomaly detector**.

**Guards (return `nil`, never NaN):**
- fewer than 2 samples;
- elapsed time < ~1s (division blow-up);
- **negative delta** → the window reset mid-series; discard and restart from the post-reset sample rather than reporting a negative rate.

## 3.2 Percentile baseline — `Analytics/Percentile.swift`

Consumption is **bursty and session-quantized** — you hammer a 5-hour window or you don't touch it. A mean under-predicts spikes and over-predicts idle days, so the baseline is a **percentile**.

- `Percentile.p(_ q: Double, of: [Double]) -> Double?` using **linear interpolation between order statistics** (R-7 / NumPy default), not nearest-rank.
- **"Heavy session" estimate = P90** of a set defined in 3.4.
- Requires **≥ 5** completed windows; below that, fall back to the observed max and mark the forecast `lowConfidence`.

## 3.3 Session forecast — time to exhaustion — `Analytics/Forecast.swift`

For the **current session window**:

```
hoursRemaining = (100 − percentUsed) / windowLongBurnRate
exhaustionAt   = now + hoursRemaining
```

**Only surface it if `exhaustionAt < resetsAt`.** Otherwise the honest answer is **"safe until reset"** — and saying that plainly is a feature, not a fallback.

Label format: `~45m left` · `~3h left` · `safe until reset`.

## 3.4 Weekly projection + under-utilization — `Analytics/WeeklyProjection.swift`

The most valuable output, and the one built to work from **percentages alone** (we don't know absolute token quotas, so we measure the weekly window's own movement):

1. For each **completed session window** in the trailing **8 days**, measure how much the **weekly %** rose across it:
   `weeklyDelta_i = weekly%(at session end) − weekly%(at session start)`
2. `p90Delta = Percentile.p(0.90, of: weeklyDeltas)` — the "cost to the weekly budget of one heavy session."
3. `windowsRemaining = floor(secondsUntilWeeklyReset / 5h)`
4. `projectedWeekly = currentWeekly% + windowsRemaining × p90Delta`

**Two branches, both useful:**
- If `projectedWeekly ≥ 100` → report **when** it crosses (interpolate the crossing time) → *"On track to hit your weekly limit ~Thu 3pm."*
- If well under → report the **inverse**: `unusedWindows = floor((100 − currentWeekly%) / p90Delta)` (capped by `windowsRemaining`) → *"≈11 unused 5-hour windows remain before reset."* **No competitor shows under-utilization** — it's genuinely reassuring information.

*(Alternative if we later expose quota sizes: express P90 session peak as a fraction of the weekly quota directly. The delta method above is preferred because it needs no quota constants.)*

## 3.5 Confidence — always attached

```
enum ForecastConfidence { case high, medium, low }
```
- **high** — ≥ 20 samples **and** ≥ 5 completed windows
- **medium** — some history, thresholds not yet met
- **low** — cold start / < 5 windows (baseline fell back to observed max)

**Rule: the UI never shows a bare number without its confidence.** A low-confidence forecast is phrased softly ("early estimate").

## 3.6 Anomaly detection — `Analytics/AnomalyDetector.swift`

Flag a runaway session (e.g. an agent looping):

```
fire when  shortHorizonBurnRate > 3 × median(windowBurnRate over trailing 7 days of ACTIVE windows)
```
- **Median, not mean** — one runaway session shouldn't poison its own baseline.
- **Sustained ≥ 3 consecutive polls** before firing — kills flapping.
- Clears when the short rate falls back under the threshold.

## 3.7 Surfacing it in the UI

- **Popover (Claude card):** one line under the session meter — `2.4%/hr · ~3h left` or `safe until reset`; and under the weekly meter — the projection or unused-windows line, with a small confidence chip.
- **HUD:** burn rate + projection are the whole point of the focused view; add a subtle **accent shift** when the anomaly detector fires.
- **Cursor:** same weekly-style projection against the monthly window.
- Tone: calm and honest. "Safe until reset" and "unused windows" are first-class messages, not error states.

## 3.8 Edge cases (must not crash or mislead)

- **Mid-window reset** — percent drops to ~0; detect via negative delta, restart the series.
- **Cold start / single sample** — everything returns `nil`/`low`; UI shows "gathering data," never a fake number.
- **Stale `resetsAt` in the past** — treat the window as already reset.
- **DST / non-UTC** — all math in UTC; only format in local time. Test Vienna + a negative-offset zone across a DST boundary.
- **Degenerate input** — empty series, all-equal samples, huge gaps → no NaN, no negative rates.

## 3.9 Files

```
Sources/Ullage/Analytics/
  BurnRate.swift
  Percentile.swift
  Forecast.swift          // session: time-to-exhaustion + label + confidence
  WeeklyProjection.swift  // weekly: projection / under-utilization
  AnomalyDetector.swift
```

## 3.10 Tests (Swift Testing) & acceptance

Synthetic series, each a plain `[(Date, Double)]`:
- **steady burn** → stable positive rate + sane exhaustion;
- **bursty burn** → P90 >> mean (proves the percentile choice);
- **mid-window reset** → no negative rate, series restarts;
- **idle week** → under-utilization branch, "N unused windows";
- **cold start (1 sample)** → all `nil`/`low`, no crash;
- **anomaly** → fires only after 3 sustained high polls, clears after;
- **DST boundary** → reset countdown correct in Vienna and a negative-offset zone.

**Acceptance:** all analytics are pure, fully unit-tested, and produce no `NaN` / negative / misleading output on any degenerate input. Every surfaced forecast carries a confidence.
