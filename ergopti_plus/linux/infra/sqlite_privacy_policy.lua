--- infra/sqlite_privacy_policy.lua
--- ==============================================================================
--- MODULE: SQLite File Privacy Policy
--- DESCRIPTION:
--- One permission policy for native descriptor admission and SQLite children.
--- ==============================================================================

return {
	file_mode = 384, -- 0600: only the recording account reads and writes history.
	creation_mask = 63, -- 0077: SQLite companions are private from creation.
}
