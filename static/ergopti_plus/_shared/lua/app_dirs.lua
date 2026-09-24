--- _shared/lua/app_dirs.lua
--- AUTO-GENERATED from _shared/modules/paths/app_dirs.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.

--- ==============================================================================
--- DATA: Application Folders and Log File Names
--- DESCRIPTION:
--- The application folder name, the default logs folder of each Lua driver and
--- the log file-name prefixes. Each driver has ONE logs-folder resolver built on
--- this table (macOS infra/logger.lua, Linux infra/logger_sink.lua); nothing
--- else spells a prefix or a folder formula.
--- ==============================================================================

return {
	folder_name = "ergopti_plus",
	override_key = "LogsDirPath",
	linux_storage_key = "paths.logs_dir",
	crash_reports_dir = "crash_reports",
	files = {
		unified_prefix = "ErgoptiPlus_",
		errors_prefix = "ErgoptiPlus_errors_",
		topical_prefix = "ErgoptiPlus_",
		extension = ".log",
	},
	macos = {
		base_env = "HOME",
		relative = "Library/Logs/ergopti_plus",
		launcher_log = "launcher.log",
		fatal_report = "hammerspoon-fatal.txt",
	},
	linux = {
		base_env = "XDG_STATE_HOME",
		base_fallback = ".local/state",
		relative = "ergopti_plus/logs",
	},
}
