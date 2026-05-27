# Ergopti+ — Domain Glossary

This glossary defines the key concepts, components, and terms used throughout
the Ergopti+ codebase. Entries are grouped by domain and sorted alphabetically
within each group. Cross-references appear as **→ Term**.

---

## Table of Contents

1. [Keymap Engine](#1-keymap-engine)
2. [Hotstrings](#2-hotstrings)
3. [Tap-Hold & Layers](#3-tap-hold--layers)
4. [LLM Prediction](#4-llm-prediction)
5. [Gestures](#5-gestures)
6. [Keylogger & Metrics](#6-keylogger--metrics)
7. [Architecture & Infrastructure](#7-architecture--infrastructure)

---

## 1. Keymap Engine

**Auto-Expand**
A **→ Hotstring** expansion mode where the expansion fires the instant the
full trigger is typed, without waiting for a **→ Terminator** keystroke. Enabled
by the `auto` flag on a hotstring entry. Implemented in
`static/drivers/hammerspoon/modules/keymap/expander.lua` and
`static/drivers/autohotkey/lib/hotstrings/hotstring_engine.ahk`.

**Buffer (Typing Buffer)**
The rolling in-memory string that records the characters the user has typed
since the last word boundary or reset event. The **→ HotstringMatcher** reads
the buffer on every keypress to detect matching triggers. The buffer is
maintained in `CoreState` and is managed by `modules/keymap/init.lua`.

**Caret Positioning**
After a hotstring expansion, the caret (text cursor) is placed at the correct
position inside the replacement. The **→ Expander** calculates how many
characters to delete (backspaces) and what sequence to type so the caret ends
up where the user expects. See `expander.lua` → `perform_text_replacement`.

**CoreState**
The shared runtime state table that is passed by reference to every keymap
sub-module (Registry, Expander, LLMBridge). It stores the typing buffer,
active delays, the magic key character, and feature flags. Defined and
instantiated in `modules/keymap/state.lua`. See also **→ Registry**, **→ Expander**.

**Eventtap**
The Hammerspoon mechanism (wrapping macOS `CGEventTap`) through which
Ergopti+ intercepts every keydown and keyup event system-wide. The eventtap
loop in `modules/keymap/init.lua` is the entry point for all keymap and
hotstring processing.

**Expander**
The module responsible for executing a hotstring expansion once the
**→ HotstringMatcher** has identified a match. It calculates the number of
backspaces to issue, emits the replacement text, and updates the
**→ CoreState** buffer. Domain spec: `_shared/domain/Expander.spec.js`.
Implementations: `modules/keymap/expander.lua` (Hammerspoon),
`modules/hotstrings.ahk` (AHK).

**HotstringMatcher**
The pure matching algorithm that, given the current **→ Buffer** and the last
typed character, queries the **→ Registry** for candidates in the
**→ Tail-Char Bucket** and applies **→ Word Boundary** and case-sensitivity
rules to select the longest matching trigger. Domain spec:
`_shared/domain/HotstringMatcher.spec.js`. Shared Lua implementation:
`_shared/lua/hotstring_engine/init.lua`.

**Interceptor**
A callback registered via `M.register_interceptor()` in `keymap/init.lua`
that runs before the main hotstring pipeline on every keypress. Used by
modules such as the personal-info guard to short-circuit expansion in sensitive
contexts.

**Longest-Match-First**
The rule that, when multiple hotstring triggers share the same
**→ Tail-Char Bucket**, the longest trigger is tested first. This prevents a
short trigger from firing when a longer one that subsumes it is also present.
Enforced by sorting mappings by trigger length descending in the **→ Registry**.

**Magic Key (★)**
A special trigger character (default `★`, Unicode U+2605) that fires an
expansion without a terminator. Used for manual expansions and to repeat the
last character correction. Stored in `CoreState.magic_key` and updated by
`Registry.update_trigger_char()`. Hotstring data lives in
`_shared/hotstrings/magic_key/`.

**Registry**
The in-memory data store for all hotstring mappings, groups, sections, and
terminators. Provides O(1) lookup via **→ Tail-Char Bucket** indexing and
manages the enable/disable lifecycle of hotstring groups. Domain spec:
`_shared/domain/Registry.spec.js`. Implementations:
`modules/keymap/registry.lua` (Hammerspoon),
`lib/hotstrings/hotstring_engine.ahk` (AHK).

**Repeat Feature**
An optional feature that re-expands the most recently expanded hotstring by
typing the **→ Magic Key**. Enabled/disabled via `Registry.set_repeat_feature_enabled()`.

**Smart Casing**
The Registry auto-generates three variants for each hotstring trigger —
all-lowercase, Title Case, and ALL-CAPS — so the expansion matches the
capitalisation style the user types. Implemented in `registry.lua` →
`M.add()`.

**Tail-Char Bucket**
An O(1) lookup index inside the **→ Registry** that groups hotstring mappings
by the last Unicode codepoint of their trigger. On every keypress, only the
bucket for the typed character is examined, keeping the hot-path cost
proportional to the bucket size rather than the total number of mappings.
See `_shared/lua/hotstring_engine/init.lua` and
`_shared/domain/HotstringMatcher.spec.js`.

**Terminator**
A keypress (space, punctuation, Enter, etc.) that signals the end of a
potential hotstring trigger and triggers expansion if the buffer matches.
The full catalogue of enabled terminators is managed by the Terminators
module. Domain spec: `_shared/domain/Terminators.spec.js`. Implementations:
`modules/keymap/terminators.lua` (Hammerspoon),
`lib/hotstrings/hotstring_prefix_watcher.ahk` (AHK).

**Word Boundary**
A non-word character (space, tab, punctuation, or start-of-buffer) that
immediately precedes the trigger in the buffer. Hotstrings with the `word`
flag only fire when the character at that position qualifies as a word
boundary. Enforced by the **→ HotstringMatcher**.

---

## 2. Hotstrings

**Autocorrection**
A category of hotstrings that silently fixes common typos, accent errors,
and casing mistakes as the user types. Stored in
`_shared/hotstrings/autocorrection/`. Entries typically carry the `word` flag
to avoid false positives mid-word.

**Category**
A logical grouping of hotstring files (e.g. `autocorrection`, `rolls`,
`sfbs_reduction`). Each category folder may include a `category.toml` file
with a display colour, default activation delay, and description. Consumed
by the Registry and the UI menu.

**Dead Key Expansion**
A hotstring that maps a dead-key sequence (e.g. typing `e^`) to a precomposed
Unicode character (e.g. `ê`). Stored under
`_shared/hotstrings/distances_reduction/dead_key_*.toml`. See also
**→ Distances Reduction**.

**Distances Reduction**
A hotstring category that replaces awkward key-reach sequences with shorter
alternatives to reduce finger travel. Examples: `qu` → `qu` with a closer
key, or combining vowel + modifier into a single typed sequence. Stored in
`_shared/hotstrings/distances_reduction/`.

**Dynamic Hotstrings**
Hotstrings whose replacement is computed at expansion time rather than being
a static string. Implemented in
`static/drivers/hammerspoon/modules/dynamic_hotstrings/`. Examples include
the `{date}` and `{time}` template tokens.

**`final` Flag**
A hotstring flag that prevents further substitution passes after the expansion
fires. Useful when the replacement itself would match another hotstring trigger.

**Group**
A named collection of hotstring **→ Sections** that can be enabled or disabled
together. Groups map to top-level folders or named files in the hotstring data
directory. The Registry tracks enabled state per group in `hs.settings` (on
macOS) for persistence across reloads.

**Rolls**
A hotstring category for sequences that arise naturally from fast bidirectional
finger rolls on the keyboard (e.g. typing `->`). These are ergonomic shortcuts
for coding symbols and writing patterns. Stored in
`_shared/hotstrings/rolls/`.

**SFB (Same-Finger Bigram)**
A bigram (two-character sequence) where both characters are typed with the same
finger. Ergopti+ includes a dedicated hotstring category (`sfbs_reduction`) that
replaces common SFBs with equivalent sequences typed with different fingers,
reducing strain and increasing speed.

**Section**
A named subset within a hotstring **→ Group**, corresponding to a single TOML
file. Users can toggle individual sections from the menu. The Registry stores
per-section enabled state in `hs.settings`.

**TOML Hotstring File**
The canonical source format for hotstring data. Each file contains an array of
`[[entry]]` tables with `trigger`, `replacement`, and optional `flags`. Files
live under `_shared/hotstrings/` and are consumed by the code-generator
(`npm run build:hotstrings`) to produce driver-specific output. Schema:
`_shared/hotstrings/schema.md`.

---

## 3. Tap-Hold & Layers

**Chord**
A modifier key combination (two or more modifiers pressed simultaneously) that
can be mapped to a custom action via Karabiner-Elements. Chord slots are defined
in `macos/modules/karabiner/data/mod_combos.json` and configured via
`modules/karabiner/init.lua`. Distinct from **→ Tap-Hold**.

**Combo**
In the Karabiner bridge context, a two-modifier combination that exposes three
slots: `tap`, `hold`, and `chord`. Each slot maps to an action from the shared
action dictionary. See `macos/modules/karabiner/data/mod_combos.json`.

**Hold Action**
The action emitted when a **→ Tap-Hold** key is held past the activation
threshold. Can be a modifier key (`hold_modifier`) or a layer switch
(`hold_layer`). See `windows/data/tap_hold/defaults.toml`.

**Karabiner-Elements**
The macOS kernel-extension tool used by Ergopti+ to implement **→ Tap-Hold**
mappings, **→ Layers**, and **→ Chord** actions at the HID level, below the
Hammerspoon eventtap. Ergopti+ generates the Karabiner JSON config dynamically
via `modules/karabiner/generator.lua`.

**Layer**
A virtual keyboard mode activated by holding a designated key. While the layer
is active, other keys emit different characters or actions. Layers are defined
in `windows/data/tap_hold/defaults.toml` under `[tap_hold.layers]` and implemented
in the Karabiner JSON generated by `modules/karabiner/generator.lua`.

**Nav-Layer Sentinel**
A synthetic keycode (F20, keycode 90) injected by Karabiner-Elements when a
navigation layer becomes active or inactive. The eventtap in
`modules/keymap/init.lua` detects this sentinel to suppress hotstring
processing while a layer is engaged.

**Tap Action**
The action emitted when a **→ Tap-Hold** key is pressed and released quickly,
below the activation threshold. Declared as `tap_action` in
`windows/data/tap_hold/defaults.toml`.

**Tap-Hold**
A key-behaviour mode where a short press (tap) and a long press (hold) on the
same physical key emit different actions. The threshold is configurable via
`time_activation_seconds` in `windows/data/tap_hold/defaults.toml`. Test vectors
for the timing logic: `shared/tests/corpus/tap_hold/vectors.json`.

---

## 4. LLM Prediction

**Adaptive Temperature**
When multiple predictions are requested (`num_predictions > 1`), the
**→ PromptBuilder** optionally raises the temperature for each successive
prediction to encourage diversity. The formula and cap (`TEMP_DIVERSITY_CAP
= 1.0`) are defined in `_shared/domain/PromptBuilder.js`.

**Backend**
The local inference server that processes LLM requests. Supported backends
are Ollama and MLX (Apple Silicon). Backend auto-detection runs at startup
via `modules/llm/backend_detector.lua`. The active backend is stored in
`modules/llm/init.lua`.

**Chain Trigger**
After a prediction is accepted, the **→ Prediction Engine** arms a special
F16 sentinel detection so that the next LLM request fires as soon as the HID
queue drains, creating a seamless chained prediction flow. Implemented in
`modules/llm/prediction_engine.lua`.

**Context Truncation**
The **→ PromptBuilder** limits the forwarded typing context to a length
proportional to the predicted output, cutting LLM prefill tokens and reducing
time-to-first-token (TTFT). Canonical constant: `CONTEXT_TAIL_WORDS = 5`.
See `_shared/domain/PromptBuilder.js`.

**Debounce**
A configurable delay (default: `llm_debounce` seconds) after the last keypress
before an LLM prediction request is fired. Prevents sending a request on every
single keystroke. Implemented as a timer in `modules/llm/prediction_engine.lua`.

**LLM Bridge**
The thin orchestrator in `modules/keymap/llm_bridge.lua` that connects the
keymap core to the **→ Prediction Engine**. Handles keymap-specific concerns:
hotstring preview, keystroke routing (arrow keys, Enter, modifier+digit) for
navigating predictions, and buffer management on navigation or escape events.

**Prediction Engine**
The module (`modules/llm/prediction_engine.lua`) that owns the full lifecycle
of AI-assisted text predictions: request dispatch, streaming ingestion,
deduplication, display, and state management. The LLM Bridge delegates all
LLM-specific logic here.

**Profile**
A named LLM system-prompt template that determines how the LLM is instructed
to behave. Built-in profiles (`raw`, `basic`, `advanced`, `batch_advanced`)
are defined in `_shared/llm/profiles.json`. The active profile is selected via
`modules/llm/profiles.lua`. See also **→ ProfileSelector**.

**ProfileSelector**
The domain module (`_shared/domain/ProfileSelector.js`) that loads the profile
catalogue from `profiles.json`, merges user-defined overrides, resolves the
active profile by ID, and injects template variables (`{context}`, `{tail}`,
`{min_words}`, etc.) into the system prompt.

**PromptBuilder**
The domain module (`_shared/domain/PromptBuilder.js`) that constructs the
complete LLM request parameters from the user's buffer and configuration:
context string, tail excerpt, token budget, and temperature. See also
**→ Context Truncation**, **→ Adaptive Temperature**.

**Streaming**
An LLM response mode where prediction tokens arrive incrementally and are
displayed in the tooltip as they stream in, reducing perceived latency.
Managed by `modules/llm/streaming_handler.lua`. Controlled by the
`llm_streaming` feature flag.

**TokenParser**
The domain module (`_shared/domain/TokenParser.js`) that diff-colours the LLM
output for display in the tooltip: green for corrected tail words, orange for
new continuation words, and no colour for unchanged text. Driver adapters:
`modules/llm/parser.lua` (Hammerspoon), `ui/tooltip_llm.ahk` (AHK, partial).

---

## 5. Gestures

**Axis Locking**
Once the **→ GestureRecognizer** commits a gesture to a horizontal or vertical
axis, cross-axis noise is ignored for the remainder of that gesture. This
prevents diagonal drift from mis-classifying a clean swipe. Documented in
`_shared/domain/GestureRecognizer.spec.js`.

**Centroid**
The average position of all active touch points in a touch frame. The
**→ GestureRecognizer** tracks the centroid's movement vector between frames
to determine gesture direction and magnitude. Computed in
`modules/gestures/engine.lua`.

**GestureRecognizer**
The domain module that processes raw touch frame data, computes the centroid
and movement vector, applies threshold constants, and emits a normalised
gesture event (e.g. `swipe_3_left`, `tap_3`). Domain spec:
`_shared/domain/GestureRecognizer.spec.js`. Implementation:
`modules/gestures/engine.lua`.

**Gesture Slot**
A named gesture identifier (e.g. `tap_3`, `swipe_3_left`, `swipe_4_up`) that
maps to a user-configurable action. The full catalogue is defined in the
GestureRecognizer spec and shared by all drivers.

**Primer (Touchpad Wakeup)**
A brief synthetic probe sent to the macOS Precision Touchpad driver to wake it
from kernel-level dormancy before a gesture sequence begins. The touchpad
cannot be activated before the first physical touch — this is a kernel
constraint, not a software bug. The primer acts as the wakeup signal, after
which an adaptive probe loop waits for the device to become ready. See memory
file `project_gestures_startup_design.md`.

---

## 6. Keylogger & Metrics

**Aggregator**
The keylogger sub-module (`modules/keylogger/aggregator.lua`) that walks
accumulated keystroke events and flushes computed N-gram statistics, burst
metrics, and session summaries to the SQLite cache in batches.

**data.sql**
The append-only plain-text SQL file that is the canonical on-disk source of
truth for keystroke metrics. Located at
`<config_dir>/metrics/by_device/<device_id>/data.sql`. Written as batches of
`INSERT OR IGNORE` statements, it is Git-friendly and human-readable without
any helper tool. See `KEYLOGGER_SPEC.md` §1.6.

**device.json**
A small JSON file (`~200 bytes`) that records the UUID, human-readable name,
OS, and schema version for a specific device. Located alongside `data.sql`.
The device UUID is generated once at first boot and never changes.

**N-gram**
A sequence of N consecutive characters (or words) recorded from the user's
typing stream. The keylogger stores character unigrams through heptagrams and
word unigrams/bigrams in separate SQLite tables (`ngram_chars`,
`ngram_bigrams`, etc.) for typing-pattern analysis.

**SQLite Cache**
A `db.sqlite` file in the system temp directory (`<tmpdir>/ergopti_metrics/
<device_id>/db.sqlite`) that aggregates metrics from all synced devices for
fast UI queries. It is a transparent cache — if deleted or corrupted, it is
fully reconstructed from the `data.sql` files. Never synced to Git.

**Synthetic Typing**
The keylogger differentiates between human keystrokes and keys injected by the
**→ Expander** (hotstring expansions). Synthetic events are tagged via
`M.notify_synthetic()` and excluded from N-gram stats so profiling reflects
actual human typing patterns.

**today.log**
A JSONL (JSON Lines) append-only file that absorbs keystroke events on the hot
path without touching SQLite. One line per event. Ingested in batches by the
**→ Aggregator**. Deleted at day rollover after all data is flushed. Never
synced (listed in the auto-generated `.gitignore`). See `KEYLOGGER_SPEC.md`
§1.5.

---

## 7. Architecture & Infrastructure

**Adapter**
A driver-specific implementation of a **→ Port** contract. Each driver (macOS,
Windows, Linux) provides its own set of adapters for the nine OS-facing
interfaces. Adapters live under `static/drivers/<driver>/adapters/`. See
ADR-001.

**Codegen (Code Generation)**
The build-time process that reads the authoritative TOML manifest
(`_shared/features/manifest.toml`) and emits driver-specific feature
registries and config templates. Run via `npm run build:manifest`. Generated
files live under `_generated/` directories and are committed to the repository.
See ADR-002.

**Corpus**
Shared JSON test-vector files (`_shared/tests/corpus/`) consumed by all
driver test suites. Each vector is an `{ input, expected }` pair (or richer
structure) that all driver implementations must pass. Adding a vector to the
corpus automatically exercises every driver. See ADR-006.

**Driver**
A self-contained integration of Ergopti+ for a specific OS runtime:
`hammerspoon` (macOS), `autohotkey` (Windows), `linux` (LuaJIT+libinput).
Each driver implements the nine **→ Port** adapters and consumes the
shared domain modules. All live under `static/drivers/<driver>/`.

**Domain Module**
A pure, platform-agnostic module in `_shared/domain/` that contains only
business logic — no OS API calls, no file I/O, no driver imports. Domain
modules are specified as JavaScript spec files and ported faithfully to each
driver's runtime language. See ADR-005.

**Features Manifest**
The single authoritative TOML file (`_shared/features/manifest.toml`) that
declares all user-configurable features with their default values. All
driver-specific feature registries are generated from this file. See ADR-002.

**Hexagonal Architecture (Ports and Adapters)**
The structural pattern adopted by Ergopti+ to decouple domain logic from OS
APIs. Domain modules depend only on **→ Port** interfaces; driver adapters
implement those interfaces. This makes domain logic unit-testable without any
OS runtime and allows new drivers to be added by implementing the nine port
contracts. See ADR-001.

**i18n (Internationalisation)**
The system through which all user-facing strings are delivered in the user's
active language. Ergopti+ supports 21 languages. All UI text must go through
`lib.i18n.get("key")` — hardcoded strings in any language are a violation.
See `copilot-instructions.md` §1 and ADR-007.

**Manifest Schema**
A JSON Schema file (`_shared/features/manifest.schema.json`) that validates
the structure of the features manifest. Prevents malformed entries from
reaching the codegen step.

**Port**
A formal JavaScript interface contract stored in `_shared/ports/` as a
`*.spec.js` file. Each port defines method signatures, parameter shapes, return
values, and compliance test vectors. The nine ports are: `Clipboard`,
`FileSystem`, `HttpClient`, `KeyboardHook`, `Notifier`, `ProcessLifecycle`,
`SecureFieldDetector`, `Storage`, `TextSender`, `TimerScheduler`,
`TooltipRenderer`, `TrayMenu`, `WindowInfo`. See ADR-001 and
`_shared/ports/SPEC.md`.

**Port Compliance**
Verified by `npm run test:port-compliance`, which runs the contract test
vectors defined in each `*.spec.js` against the corresponding driver adapters.
A driver that does not pass all vectors for a port is considered non-compliant.

**`_generated/`**
Directories under each driver folder that contain files produced by the
**→ Codegen** step. These files are never edited by hand; they are committed
so drivers can boot without running a build. Examples:
`autohotkey/_generated/features_manifest.ahk`,
`hammerspoon/_generated/features_manifest.lua`.
