# Config migration record bytes

These three fixtures pin physical candidate bytes independently from the
migration engines. Their handwritten expected files cover occupied inline,
scalar, Boolean and empty namespaces; comments and quoted foreign identities;
multiline arrays; moved and merged sections; deletion; and added values.

The Lua and Windows registered native suites replay these exact files through
ConfigMigratePlan / config_migrate.plan. Each also repeats the inputs and
expectations with a UTF-8 BOM and CRLF line endings, and without the final LF.
The Windows record renderer has separate lexical and refusal regressions for
multiline strings, table-array ownership and ambiguous quoted edited paths.
The changed fixture has a separate expected_windows.toml: the native typed
encoder renders a moved owned row, while Lua transports its source comment.
All untouched bytes and logical values have identical requirements. A date
here is an untouched opaque native literal, not native date support.

Do not regenerate expected.toml from an engine or a canonical TOML writer.
