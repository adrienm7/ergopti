<!-- _shared/tests/corpus/hotstrings/common_autocorrection_legacy/README.md -->

# Frozen common autocorrection input

`autocorrection.toml` is the complete source image captured independently before
the runtime section split. Its SHA-256 is
`6aa39e0cf0b216e8a5ae47d84ef15dd00019dbbe35a8f77c7c9d332f7b6394f8`, the exact
`source_sha256` recorded in the adjacent `common_autocorrection_entries.json`.
Never regenerate this input or the JSON expectations from the current source.

The three native suites retain the original reader, cache and registry tests
against this input. Additional tests project the unchanged 140 historical
expectations through the separately reviewed editorial classification and run
the shipped split source, including each selectable section and the original
composed registration order.
