<!-- docs/handovers/2026-10-10-group5-logger-fixture/README.md -->

# Daily-reset logger fixture ownership

This standalone correction is based on Dev
`9e370a3926f23ff09e0a272fae8fa841afdb4d0b`. The test previously selected every
captured open sharing the karabiner sub-file basename. A legitimate append in
another folder could therefore hide the later correct truncating open of the
fixture's own stale file. The observation now selects the complete owned path.
No production logger behavior changes.

The additive regression captures a foreign-folder append before invoking the
real logger for its own stale file. Before the selector correction and with the
selector omitted, the original three cases pass and the new case fails at the
ownership count assertion (expected one, observed two). The later truncation
assertion is not reached in those failing cases. Afterward all four pass,
including the unchanged original `w` assertion. Filesystem and writable sink
ports are modeled; this proves observation ownership, not persisted file bytes.

The complete unmodified Devb424 Lua suite reproduced the original failure:
18,191 cases passed and one failed. Private observation found the foreign
cached-file append before the owned stale-file truncation. Focused isolated and
preceding-fallback replays passed, so this correction addresses full-suite
cross-instance observation. The observer adds timing overhead; it changed no
assertion or verdict. Full default change-scoped gates remain required before
publication, and their terminal counts are retained with the publication
receipt. The retained-PAUSED lease backport is a separate correction and must
receive this fixture prerequisite without importing the full feature chain.

Native macOS execution and the initial PONG/READY/exit-73 cause remain
unqualified by this test-fixture correction. No TODO item was removed.
