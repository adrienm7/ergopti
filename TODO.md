<!-- TODO.md -->

# TODO

Work that is known, scoped and **not done**. Two sources: an audit that was
specified but never run, and the actionable leftovers of the 2026-07-21
performance campaign (whose report has been deleted — everything still worth
doing from it lives here).

Rules that apply to everything below: no behaviour change without a regression
test, never weaken a test to make a change pass, and run the gates that cover
what you touched — `node ./tools/test/verify-change.cjs` derives them for you
(see the `verify-change` skill).

Before starting any item, read [docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md):
several neighbouring ideas have already been tried and rejected with reasons, and
re-proposing them wastes a pass.

---

## 1. Audits specified but never run

The audit prompts live in [`docs/prompts/`](docs/prompts/) and are the canonical
statement of what each pass must cover — read the prompt, do not work from a
summary. Each asks for a **prioritised report, not code**, with every finding
proved by real paths and line numbers.

| Prompt | Status |
| --- | --- |
| `audit_mise_en_commun_et_simplification.md` | **never run** — see below |
| `perf_ahk.md` | run 2026-07-21; the fixes landed, the leftovers are §2 and §3 |
| `bugs_ahk.md`, `bugs_hs.md`, `bugs.md` | run repeatedly; outcomes in PROJECT_MEMORY |
| `perf_hs.md` | status unknown — check PROJECT_MEMORY before running |
| `refactor.md` | the refactor cycle it belongs to was declared complete and its plan deleted (`d533b0753`); re-read before assuming it still applies |

**The sharing + simplification audit has never been executed.** Its two axes:
push everything that is not intrinsically platform-specific into `_shared/`
(windows and dialogs still native on either driver, menu SSoT coverage,
duplicated defaults, parallel catalogues, hardcoded UI strings), and reduce mass
(are the `_generated/` trees still earning their committed size, can `_shared/`
be flattened, god-files, orphan tooling). It names concrete suspects and the
evidence standard it expects; work from the file.

One correction to apply when running it: it tells you to confront your
conclusions against `docs/REFACTOR_PLAN.md`, which no longer exists — that plan
was folded into `REFACTOR_GUIDE.md` and then deleted when the refactor cycle
completed. `docs/PROJECT_MEMORY.md` is now the only canonical memory.

---

## 2. Instrumentation — the prerequisite for the next perf pass

The 2026-07-21 campaign closed the levers it could prove. What remains is mostly
**unmeasured**, and silence reads as "optimal". Ordered by value.

1. **Sub-segment `_TooltipPresentStack`** (`ui/tooltip/helpers.ahk`). Since the
   UIA fix, `Tooltip.Present` is the dominant offender (102 of 194 slow lines on
   the first post-fix day, ~12.9 ms mean) and it has **no surviving lever** —
   every candidate was either rejected in verification or forbidden by
   PROJECT_MEMORY. It aggregates six sub-steps (monitor clamp, `Gui.Show`, DWM,
   corners, `_TooltipShowBorder` DIB, `_TooltipRevealSurfaces`) with no
   attribution. **Any tooltip optimisation proposed before this exists is
   speculation.**
2. **`LLM.FeedChar`** (`LLM_Bridge_FeedCharIfActive`, called from
   `hotstring_inputhook.ahk` *before* the Hotstrings gate). Prime suspect for the
   ~600 slow `OnChar` events with no matching slow `HSE.FeedChar`. Second
   suspect: the post-match region of `_OnPrefixChar`.
3. **`RemapEmit`** (`modules/keymap/layout.ahk`) — the first stage of every
   keystroke, `SendEvent` under `Critical`, with no segment at all. Contention in
   the hook chain is currently invisible.
4. **Keylogger fan-out** (`KL_Hook_OnChar` / `OnKeyDown`) and **`Hook.KeyDown`**
   (`lib/hook_dispatcher.ahk`) — needed to close the per-keystroke budget.
5. **`_OnPrefixKeyDown`** (a slow backspace is indistinguishable from a slow
   `OnChar` today) and **`Prefix.Lookup`** (`_LookupAndRender`).
6. **Exit counters for `_TooltipResolvePosition`** (caret / cache-hit / probe /
   skip-idle / skip-hostile / frame / mouse) plus a **total render counter** —
   without a denominator the slow-render ratio is incalculable. A periodic DEBUG
   aggregate is enough.
7. **Boot**: five retroactive marks before `BootProfile_Begin` (mutex,
   `Bundle_Init`, `ParseTomlFile(config)`, onboarding, `HotstringEngineInit`) —
   the "parse + load" bucket currently blends them; plus sub-marks inside
   "Config, features & shortcuts loaded" (313-407 ms with no detail).
8. **Idle**: `UIA.SelectionPoll`, `Metrics.FocusRefresh` (a `WinGetTitle` on a
   Not Responding window blocks 20×/s with no trace), `KL.Ingest`; and a
   meta-test inventorying every `SetTimer` with a positive period under 1000 ms
   against a whitelist, so a fast poller cannot reappear silently.

---

## 3. Follow-ups found while implementing the perf fixes

- **Five independent decodes of the same manifest at boot (~200 ms).** The four
  `_MM_*` loaders in `lib/menu_manifest.ahk` each keep their own cache, and
  `_MR_MANIFEST_CACHE` is a fifth — all decoding the same 12.5 KB file, which
  benches at 44 ms per decode. Consolidating them behind `_MR_GetManifestRoot()`
  is a legitimate follow-up to the per-item fix already shipped, but it touches
  five sites and four caches: separate commit, and only after measuring the
  already-shipped fix in isolation.
- **Dead Ollama WinHTTP path.** `LLM_OllamaCancelAsync` (singular) has no
  production callers, and `_LLM_Ollama_PollRequest` is never armed; both carry an
  `entry.Has("http")` branch that cannot be true, since the only creation site of
  an async entry writes no `"http"` key. curl is the live transport. Remove the
  lot under §5.6 — out of scope for the cancel-path fix, which only removed the
  branch it was touching.
- **Magic numbers around the LLM health probe.** The 3 s throttle is inline, and
  the 10 s interval is duplicated between `menu_llm/init.ahk` and
  `menu_llm/actions.ahk`. Both violate §5.1 and §5.2; name them next to
  `LLM_HEALTH_PROBE_IDLE_MAX_MS` in `menu_llm/_index.ahk`.
- **Regex per keylogger event.** `MF_ShouldFilter` / `MF_ShouldFilterFor`
  (`lib/metrics/metrics_filters.ahk`) run 7 `RegExMatch` over the window title on
  every logged event when `private_browsing` is on. It is the only real
  per-event regex site and was never instructed. Either memoize the verdict per
  focus-cache generation (the title only changes on refresh, 50 ms TTL) or
  discard it explicitly with the measurement that justifies it.
- **Stale comment**: `modules/hotstrings/hotstrings_text_expansion.ahk:244`
  describes the old `DeferHeavy = true` boot, which no longer exists; the
  associated PROJECT_MEMORY passage (~L980-988) says the same. Docs only, but it
  actively misleads.

---

## 4. Decided — do not re-raise

Recorded so nobody spends a pass re-deriving these. Details and evidence in
`docs/PROJECT_MEMORY.md`.

- **Per-tail cap on the end-char match loop.** Five synchronised sites where
  missing one silently shortens the bound — a hotstring that stops firing — for a
  sub-microsecond gain four orders of magnitude below the profiler threshold. The
  same mechanism on the hotter STAR loop was already refuted for unmeasurable
  gain.
- **Tooltip window reuse**, **chunking the emoji/symbol registration**, and
  **timing tricks around the WebView2 cold start**: tried, reverted, or rejected
  with documented blockers.
- **Idle-gating the keylogger network ticks** (wifi 15 s, vpn 20 s, reach 30 s)
  and the AV WMI scan: cost accepted explicitly — in-process, and they only emit
  on a state change.
