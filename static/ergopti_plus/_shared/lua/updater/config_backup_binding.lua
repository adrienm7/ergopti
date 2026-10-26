--- _shared/lua/updater/config_backup_binding.lua

--- ==============================================================================
--- MODULE: Configuration Backup Binding (Shared)
--- DESCRIPTION:
--- The assembly both drivers' modules/updater/config_backup.lua used to repeat:
--- read the `config_backup` rules from the shared updater defaults, refuse with
--- one logged line when they are unusable, resolve the roots, honour the test
--- seam, and hand the pieces to the shared owner (updater/config_backup.lua).
--- What stays in a driver is what only it can know: how a folder is listed and a
--- file read or published, the clock, where the shared defaults are read from,
--- and which roots exist (macOS has the configuration folder; Linux adds the
--- settings store file beside it).
---
--- FEATURES & RATIONALE:
--- 1. One refusal path. An unusable rule block and an unresolvable root both log
---    one error and return nil plus a reason; neither falls back to a guess.
--- 2. Built per use. The owner is rebuilt on each call because the configuration
---    folder can move while the driver runs (the paths editor).
--- 3. No load-time driver dependency: every collaborator is a port, so the module
---    loads in a test that builds no driver paths.
--- ==============================================================================

local Shared = require("updater.config_backup")

local M = {}





-- ==============================
-- ==============================
-- ======= 1/ Public API ========
-- ==============================
-- ==============================

--- Builds one driver's backup binding.
--- @param ports table {
---   logger        table     The driver's logger.
---   log           string    Tag passed as the logger's first argument.
---   defaults      function  () -> decoded updater defaults | nil, reason.
---   json          table     { encode(value) -> string, decode(text) -> value | nil, err }.
---   file_ports    function  () -> the owner's io table (list/read/make_dir/create/replace).
---   clock         function  () -> { stamp, iso }, UTC wall-clock time of a backup.
---   default_roots function  () -> roots | nil, reason, log_text. The roots of
---                           this driver; log_text is the one error line of a refusal.
---   overrides     function  () -> table | nil. Test seam: { roots, io, clock }.
--- }
--- @return table binding { owner = function() -> owner | nil, reason }
function M.new(ports)
	assert(type(ports) == "table" and type(ports.logger) == "table" and type(ports.log) == "string",
		"config_backup_binding needs a logger and a log tag")
	assert(type(ports.defaults) == "function" and type(ports.file_ports) == "function"
		and type(ports.clock) == "function" and type(ports.default_roots) == "function"
		and type(ports.overrides) == "function", "config_backup_binding needs its ports")
	assert(type(ports.json) == "table", "config_backup_binding needs a JSON codec")

	local binding = {}

	--- Builds the owner over the current configuration folder.
	--- @return table|nil owner
	--- @return string|nil error
	function binding.owner()
		local decoded, defaults_err = ports.defaults()
		local rules, err
		if decoded == nil then
			err = defaults_err
		else
			rules, err = Shared.rules(decoded)
		end
		if not rules then
			ports.logger.error(ports.log, "Configuration backup unavailable: %s.", tostring(err))
			return nil, err
		end
		local overrides = ports.overrides() or {}
		local roots = overrides.roots
		if not roots then
			local reason, log_text
			roots, reason, log_text = ports.default_roots()
			if not roots then
				ports.logger.error(ports.log, "%s", tostring(log_text or reason))
				return nil, reason
			end
		end
		return Shared.new({
			rules = rules,
			roots = roots,
			io = overrides.io or ports.file_ports(),
			json = ports.json,
			clock = overrides.clock or ports.clock,
			logger = ports.logger,
			log = ports.log,
		}), nil
	end

	return binding
end

return M
