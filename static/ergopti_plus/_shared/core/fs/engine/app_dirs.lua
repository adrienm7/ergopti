--- _shared/core/fs/engine/app_dirs.lua
--- AUTO-GENERATED from _shared/core/fs/data/paths/app_dirs.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.

--- ==============================================================================
--- DATA: Application Folders and Log File Names
--- DESCRIPTION:
--- The application folder name of each Lua driver, its root and purpose
--- folders, the log file-name prefixes and the old folder names the one-time
--- boot migration moves away from. Each driver has ONE logs-folder resolver
--- built on this table (macOS infra/logger.lua, Linux infra/logger_sink.lua);
--- nothing else spells a prefix or a folder formula. The folder name lives
--- under the OS table (`macos.folder_name`, `linux.folder_name`) because it
--- differs in case between the two Lua drivers.
--- ==============================================================================

return {
	override_key = "LogsDirPath",
	linux_storage_key = "paths.logs_dir",
	crash_reports_dir = "crash_reports",
	files = {
		unified_prefix = "ErgoptiPlus_",
		errors_prefix = "ErgoptiPlus_errors_",
		topical_prefix = "ErgoptiPlus_",
		extension = ".log",
		bootstrap_log = "bootstrap.log",
	},
	macos = {
		folder_name = "Ergopti",
		base_env = "HOME",
		relative = "Library/Logs/Ergopti",
		support_relative = "Library/Application Support/Ergopti",
		cache_relative = "Library/Caches/Ergopti",
		launcher_log = "launcher.log",
		fatal_report = "hammerspoon-fatal.txt",
		reload_breadcrumb = "reload_breadcrumb.txt",
	},
	linux = {
		folder_name = "ergopti",
		base_env = "XDG_STATE_HOME",
		base_fallback = ".local/state",
		relative = "ergopti/logs",
		config_env = "XDG_CONFIG_HOME",
		config_fallback = ".config",
		data_env = "XDG_DATA_HOME",
		data_fallback = ".local/share",
		cache_env = "XDG_CACHE_HOME",
		cache_fallback = ".cache",
		runtime_env = "XDG_RUNTIME_DIR",
	},
	config = {
		override_key = "ConfigDirPath",
		hotstrings_dir = "hotstrings",
		personal_hotstrings_file = "personal_hotstrings.toml",
		macos_base_env = "HOME",
		macos_relative = "Library/Application Support/Ergopti/config",
		macos_paths_file = "Library/Application Support/Ergopti/paths.toml",
	},
	owned_runtime = {
		macos_folder_name = "ErgoptiPlus",
	},
	migration = {
		backup_suffix = ".before-folder-migration",
		backup_folder = "before-folder-migration",
		macos = {
			legacy_support_relative = "Library/Application Support/ErgoptiPlus",
			moved_support_entries = { "paths.toml", "RemapRuntime" },
			legacy_config_relative = ".config/ergopti_plus",
			legacy_logs_relative = "Library/Logs/ergopti_plus",
			legacy_cache_relative = "Library/Caches/ergopti_plus",
			legacy_control_relative = "Library/Application Support/ergopti_plus",
		},
		linux = {
			legacy_folder = "ergopti_plus",
		},
	},
}
