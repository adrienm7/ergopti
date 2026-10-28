--- _shared/lua/test/config_backup_binding_contract.lua

--- ==============================================================================
--- MODULE: Configuration Backup Binding Contract
--- DESCRIPTION:
--- Pins what both drivers' modules/updater/config_backup.lua share through
--- updater/config_backup_binding.lua: the rules come from the shared updater
--- defaults, an unusable rule block or an unresolvable root is refused with one
--- logged error and no guess, the test seam wins over the driver's own ports, and
--- the owner is rebuilt on every call because the configuration folder can move.
--- It also replays, through each driver's own listing port, the classification
--- of folder entries: a link to a folder is reported and never walked, a link to
--- a file is a file, a FIFO (or a link to one) and a dangling link are "other", and an absent folder is reported as absent.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
--- @param env table {
---   defaults = decoded _shared/modules/updater/defaults.json,
---   listing  = function(entries, body): builds the driver's real listing port
---              over entries { { name, kind } } (kind: "file", "dir", "link_file",
---              "link_dir", "fifo", "link_fifo", "link_dangling", "link_loop") and calls body(list, root).
--- }
function M.register(helpers, env)
	local Binding = require("updater.config_backup_binding")

	local function logger()
		local double = { errors = {} }
		for _, level in ipairs({ "start", "success", "info", "warn", "debug", "done", "trace" }) do
			double[level] = function() end
		end
		double.error = function(_, fmt, ...) double.errors[#double.errors + 1] = string.format(fmt, ...) end
		return double
	end

	local function io_double()
		local double = {}
		for _, name in ipairs({ "list", "read", "make_dir", "create", "replace" }) do
			double[name] = function() return nil, "absent" end
		end
		return double
	end

	--- Builds a binding over scripted ports; `calls` counts each port use.
	local function build(options)
		options = options or {}
		local log = logger()
		local calls = { defaults = 0, roots = 0, file_ports = 0 }
		local state = { overrides = options.overrides }
		local binding = Binding.new({
			logger = log,
			log = "TEST",
			defaults = function()
				calls.defaults = calls.defaults + 1
				if options.defaults_error then return nil, options.defaults_error end
				return options.defaults or env.defaults
			end,
			json = { encode = function() return "{}" end, decode = function() return {} end },
			file_ports = function()
				calls.file_ports = calls.file_ports + 1
				return io_double()
			end,
			clock = function() return { stamp = "20260101-000000", iso = "2026-01-01T00:00:00Z" } end,
			default_roots = function()
				calls.roots = calls.roots + 1
				if options.roots_error then return nil, "roots unknown", options.roots_error end
				return options.roots or { { id = "config", dir = "/cfg" } }
			end,
			overrides = function() return state.overrides end,
		})
		return binding, log, calls, state
	end

	helpers.describe("configuration backup binding (config-backup-binding-contract)", function()
		helpers.it("(config-backup-binding-contract) is built only from complete ports", function()
			helpers.assert_throws(function() Binding.new({}) end)
			helpers.assert_throws(function() Binding.new({ logger = logger(), log = "T" }) end)
		end)

		helpers.it("(config-backup-binding-contract) builds the owner over the driver's roots and the shared rules", function()
			local binding, log, calls = build()
			local owner, err = binding.owner()
			helpers.assert_nil(err)
			helpers.assert_eq(owner.folder, "/cfg/" .. env.defaults.config_backup.folder)
			helpers.assert_eq(#log.errors, 0)
			helpers.assert_eq(calls.file_ports, 1)
		end)

		helpers.it("(config-backup-binding-contract) refuses an unreadable or ruleless defaults file with one logged error", function()
			local binding, log, calls = build({ defaults_error = "defaults unreadable" })
			local owner, err = binding.owner()
			helpers.assert_nil(owner)
			helpers.assert_eq(err, "defaults unreadable")
			helpers.assert_eq(#log.errors, 1)
			helpers.assert_contains(log.errors[1], "Configuration backup unavailable")
			helpers.assert_eq(calls.roots + calls.file_ports, 0, "nothing else is resolved after a refusal")

			local ruleless, ruleless_log = build({ defaults = {} })
			local none, reason = ruleless.owner()
			helpers.assert_nil(none)
			helpers.assert_contains(reason, "config_backup")
			helpers.assert_eq(#ruleless_log.errors, 1)
		end)

		helpers.it("(config-backup-binding-contract) refuses an unresolvable root with the driver's own line", function()
			local binding, log, calls = build({ roots_error = "the folder is unknown" })
			local owner, err = binding.owner()
			helpers.assert_nil(owner)
			helpers.assert_eq(err, "roots unknown")
			helpers.assert_eq(log.errors[1], "the folder is unknown")
			helpers.assert_eq(calls.file_ports, 0)
		end)

		helpers.it("(config-backup-binding-contract) lets the test seam replace the roots and skip the driver's", function()
			local binding, _, calls = build({ roots_error = "unreachable" })
			local state_roots = { { id = "config", dir = "/seam" } }
			local seamed = Binding.new({
				logger = logger(), log = "T",
				defaults = function() return env.defaults end,
				json = { encode = function() return "{}" end, decode = function() return {} end },
				file_ports = function() calls.file_ports = calls.file_ports + 1; return io_double() end,
				clock = function() return { stamp = "s", iso = "i" } end,
				default_roots = function() calls.roots = calls.roots + 1; return nil, "x", "unreachable" end,
				overrides = function() return { roots = state_roots, io = io_double() } end,
			})
			local owner = assert(seamed.owner())
			helpers.assert_eq(owner.folder, "/seam/" .. env.defaults.config_backup.folder)
			helpers.assert_eq(calls.roots, 0, "an overridden root never consults the driver's")
			helpers.assert_eq(calls.file_ports, 0, "an overridden io is used instead of the driver's")
			helpers.assert_nil(binding.owner())
		end)

		helpers.it("(config-backup-binding-contract) rebuilds the owner on each call so a moved folder is followed", function()
			local roots = { { id = "config", dir = "/first" } }
			local binding = build({ roots = roots })
			helpers.assert_eq(binding.owner().folder, "/first/" .. env.defaults.config_backup.folder)
			roots[1] = { id = "config", dir = "/second" }
			helpers.assert_eq(binding.owner().folder, "/second/" .. env.defaults.config_backup.folder)
		end)

		helpers.it("(config-backup-binding-contract) classifies entries, never walks a link to a folder and never reads a special file", function()
			env.listing({
				{ name = "config.toml", kind = "file" },
				{ name = "hotstrings", kind = "dir" },
				{ name = "linked.toml", kind = "link_file" },
				{ name = "loop", kind = "link_dir" },
				{ name = "pipe.toml", kind = "fifo" },
				{ name = "linked_pipe.toml", kind = "link_fifo" },
				{ name = "dangling.toml", kind = "link_dangling" },
			}, function(list, root)
				local kinds = {}
				for _, entry in ipairs(assert(list(root))) do kinds[entry.name] = entry.kind end
				helpers.assert_eq(kinds["config.toml"], "file")
				helpers.assert_eq(kinds["hotstrings"], "dir")
				helpers.assert_eq(kinds["linked.toml"], "file")
				helpers.assert_eq(kinds["loop"], "other")
				-- Opening a FIFO blocks forever: only a regular file is ever read.
				helpers.assert_eq(kinds["pipe.toml"], "other")
				helpers.assert_eq(kinds["linked_pipe.toml"], "other")
				-- A dangling link holds no configuration: reading it would fail the snapshot.
				helpers.assert_eq(kinds["dangling.toml"], "other")
			end)
		end)

		helpers.it("(config-backup-binding-contract) refuses a listing whose link target cannot be classified", function()
			-- A looping (or denied) target may hide configuration: the snapshot refuses
			-- rather than omitting it, unlike a dangling link, which holds nothing.
			env.listing({
				{ name = "config.toml", kind = "file" },
				{ name = "looping.toml", kind = "link_loop" },
			}, function(list, root)
				local entries, reason = list(root)
				helpers.assert_nil(entries)
				helpers.assert_true(type(reason) == "string" and reason:find("looping.toml", 1, true) ~= nil,
					"the refusal names the unclassifiable link: " .. tostring(reason))
			end)
		end)

		helpers.it("(config-backup-binding-contract) reports an absent folder as absent and a file as no folder", function()
			env.listing({ { name = "config.toml", kind = "file" } }, function(list, root)
				local absent, reason = list(root .. "/nothing")
				helpers.assert_nil(absent)
				helpers.assert_eq(reason, "absent")
				local not_folder, why = list(root .. "/config.toml")
				helpers.assert_nil(not_folder)
				helpers.assert_true(why ~= nil and why ~= "absent", "a file is not an absent folder")
			end)
		end)
	end)
end

return M
