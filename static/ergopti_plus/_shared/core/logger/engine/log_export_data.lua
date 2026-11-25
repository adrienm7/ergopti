--- _shared/core/logger/engine/log_export_data.lua
--- AUTO-GENERATED from _shared/core/logger/data/log_export.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:log-export` to refresh.

--- ==============================================================================
--- DATA: Log Export Archive
--- DESCRIPTION:
--- What « Export the logs (zip) » archives and the privacy rules each entry is
--- copied through, read by core/logger/engine/log_export.lua on macOS and Linux.
--- ==============================================================================

return {
	days = 3,
	name_prefix = "Ergopti-logs_",
	extension = ".zip",
	crash_report_extension = ".json",
	withheld = "<text withheld>",
	rules = {
		{ marker = "Auto-expand: ", cut = "" },
		{ marker = "Terminator-expand: ", cut = "" },
		{ marker = "KL_LogHotstring: trigger=", cut = "" },
		{ marker = "Fire-log drain failed for trigger ", cut = "" },
		{ marker = "PROMPT (", cut = " -> " },
		{ marker = "STREAM chunk (", cut = "): " },
		{ marker = "KEEP: keystroke ", cut = "" },
		{ marker = "DISMISS: keystroke ", cut = "" },
		{ marker = "OnChar error for char ", cut = "" },
		{ marker = "UIA wrap error for char ", cut = "" },
		{ marker = "DBG calling TooltipShow: ", cut = "first=" },
		{ marker = "Raw (", cut = "c): " },
		{ marker = "Opening the selected ", cut = " " },
		{ marker = "Handed the selected ", cut = " " },
		{ marker = "Registry navigation to ", cut = "" },
		{ marker = "inject(): bc=", cut = "text=" },
		{ marker = "Cannot deliver '", cut = "" },
		{ marker = "selection window opened — typing ", cut = "" },
		{ marker = "«", cut = "" },
	},
}
