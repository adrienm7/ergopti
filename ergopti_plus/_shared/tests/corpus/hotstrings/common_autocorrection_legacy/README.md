<!-- _shared/tests/corpus/hotstrings/common_autocorrection_legacy/README.md -->

# Frozen common autocorrection input

`autocorrection.toml` is the complete source image captured independently before
the runtime section split. Its SHA-256 is
`166201004786d8ab0b95629c86dab65a7d31776c18c0f6664f88b99d6f411684`, the exact
`source_sha256` recorded in the adjacent `common_autocorrection_entries.json`.
Never regenerate this input or the JSON expectations from the current source.

The one sanctioned edit is the 2026-11-10 history purge: it replaced a
personal trigger with a neutral one in this input and in the expectations
alike, so the recorded digest was updated with them.

The three native suites retain the original reader, cache and registry tests
against this input. Additional tests project the unchanged 140 historical
expectations through the separately reviewed editorial classification and run
the shipped split source, including each selectable section and the original
composed registration order.
