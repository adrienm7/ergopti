# macOS repeat timing — contradictory followup

Audited source: `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`.

This is a qualified timing-policy observation, not a new assertion of an intentional OS difference or a universal missing-output defect. Earlier macOS repeat coverage already observed the fallback timing gate; the cross-OS policy decision was not established by that observation.

`public-timing.lua REPO` executes the actual public Keymap tap, Expander, SyntheticInput and shared complex-key rule through the repository native-port fixture. The inert configuration fixture is replaced by the actual HotstringsConfig owner, reading the actual shipped `magickey.toml` and a private empty overrides file. The file is removed afterward; no user configuration is read. The native clock port advances deterministically rather than sleeping. Observations concern timing-policy decisions, not measured latency or native desktop receiving.

The actual resolver returns a shipped magic-category delay of **2 seconds**, equal to the live initial STAR_TRIGGER value and ultimate fallback. This must not be confused with the separate shared base expansion delay, **0.75 seconds**. The actual complex-key multiplier is **2**, with **300 ms** carry. Idle reset is explicitly disabled through its supported public setter to isolate this policy.

| Runtime magic delay     | Gap before magic | Modifiers on magic | Actual repeat                     |
| ----------------------- | ---------------- | ------------------ | --------------------------------- |
| Shipped 2 s             | 1 s              | None               | Yes                               |
| Shipped 2 s             | 2 s              | None               | Yes, inclusive boundary           |
| Shipped 2 s             | 2.1 s / 3 s      | None               | No; literal magic passes through  |
| Shipped 2 s             | 3 s              | Shift              | Yes, effective 4 s threshold      |
| Shipped 2 s             | 4.1 s            | Shift              | No                                |
| Explicit runtime 0 s    | 60 s             | None               | Yes; zero disables this time gate |
| Explicit runtime 10 s   | 3 s              | None               | Yes                               |
| Explicit runtime 10 s   | 10.1 s           | None               | No                                |
| Explicit runtime 0.75 s | 1 s / 2 s        | None               | No                                |
| Explicit runtime 0.75 s | 1 s              | Shift              | Yes                               |

These runtime thresholds are applied through the actual public `set_delay('STAR_TRIGGER', value)` owner, which the menu-state startup projection also uses. The custom 0.75 s threshold is not called the shipped category default. With an explicitly registered `po★ → EXPLICIT` mapping, a 3-second gap still commits that mapping even while the repeat fallback threshold is 0.75 seconds: explicit magic mapping resolution and unmatched repetition have different timing policies.

The actual live caller computes `CoreState.DELAYS.STAR_TRIGGER * complex_mult` and admits fallback only when zero or `_tc_dt <= star_allowed`, in both magic dispatch branches. `try_repeat_feature` itself has no time gate; directly calling it would therefore miss this public behavior. This is why the public tap is essential to this followup.

No explicit product policy authorizing macOS-only repeat timing was found in the shared feature declaration, timing-free repeat corpus, current English repeat labels, routed text-input decisions or maintainer decisions. The shared declaration describes portable repeat behavior without a timing exception. Text-input memory describes Windows repeat as ungated. The caller's deliberate conditional establishes implementation behavior; it alone does not establish intended cross-OS semantics. Windows/Linux execution belongs to the root reviewers; this artifact does not independently certify those drivers.

Suggested inventory qualification: “macOS unmatched repetition follows the magic-category time window and complex-key multiplier; compare Windows/Linux timing owners and settle or explicitly document the intended common/OS-specific policy.” There is no proposed weakening of the idle, matching-precedence or privacy guards, and no reason to turn this unknown-intent difference into an automatic G2 claim.

The source and the executable receipt are retained alongside this note. After bounded manual source review of the live caller versus direct helper, actual configuration derivation and intent evidence, two final executable dry replays cover zero/long/short thresholds, modifier factor and explicit-mapping priority. Each runs twelve timing scenarios and one explicit-mapping positive control. Their receipts time executable work only; the two green programs do not mechanically prove that no other root exists. No additional canonical finding is proposed. No completed audit artifact was edited.
