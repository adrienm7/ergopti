--- tests/support/onboarding_finish_fixture.lua

--- ==============================================================================
--- MODULE: Onboarding Finish Fixture
--- DESCRIPTION:
--- Drives the real onboarding finish-message handler with controlled
--- persistence boundaries: the language store, the destination read, the
--- configuration writer, the folder resolver, the remap owner that imports
--- the tap-hold keys and the layer file the navigation layer owner writes.
--- Everything else (the catalogue, the manifest reader, the answers contract,
--- the config migration, the shipped tap-hold presets and the rule that a
--- key's preset enters the navigation layer) is the production code.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

local MODULE_NAMES = {
	"adapters.file_system",
	"infra.deferred_work",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.paths",
	"infra.text_utils",
	"infra.toml.codec",
	"infra.toml.writer",
	"infra.config_paths",
	"infra.termination_coordinator",
	"platform.remap",
	"platform.remap.defaults",
	"platform.remap.nav_layer",
	"ui.menu.menu_paths",
	"ui.onboarding",
	"onboarding_publication",
	"config_file_inverse",
}

-- Where the doubled path resolver puts the remap settings.
M.KARABINER_CONFIG_PATH = "/virtual/hammerspoon/config_karabiner.toml"
-- The configuration folder it resolves, which holds layers.toml.
M.CONFIG_DIR = "/virtual/"

--- Returns one named upvalue and its numeric slot.
--- @param fn function
--- @param target string
--- @return any value
--- @return integer|nil index
local function named_upvalue(fn, target)
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == target then return value, index end
	end
	return nil, nil
end

--- Uses the real migration engine with the fixture's explicit reader seam.
--- Virtual IO cannot advertise the default native initializer. This context
--- grants no native destination admission and restores both constructor owners.
--- @param scenario function
--- @return any result
function M.with_migration_reader(scenario)
	local saved_migration = package.loaded["config_migrate"]
	local saved_writer = package.loaded["toml_codec.writer"]
	local migration, boot
	local ok, result = xpcall(function()
		package.loaded["config_migrate"] = nil
		package.loaded["toml_codec.writer"] = nil
		migration = require("config_migrate")
		boot = migration.boot
		migration.boot = function(options)
			local controlled = {}
			for key, value in pairs(options) do controlled[key] = value end
			local adapter = options.file_adapter
			local read = type(adapter) == "table" and rawget(adapter, "read_with_status")
			assert(type(read) == "function", "the migration fixture needs its explicit reader")
			controlled.read = function(path) return read(path) end
			return boot(controlled)
		end
		return scenario()
	end, debug.traceback)
	if migration then migration.boot = boot end
	package.loaded["config_migrate"] = saved_migration
	package.loaded["toml_codec.writer"] = saved_writer
	if not ok then error(result, 0) end
	return result
end

--- Reconstructs genuine schema/writer owners without changing native boot.
--- The canonical FileSystem issuer must grant its own admitted ports.
--- @param scenario function Actual host Finish replay.
--- @return any result
local function with_native_configuration_context(scenario)
	local saved_migration = package.loaded["config_migrate"]
	local saved_writer = package.loaded["toml_codec.writer"]
	package.loaded["config_migrate"] = nil
	package.loaded["toml_codec.writer"] = nil
	local called, result = xpcall(scenario, debug.traceback)
	package.loaded["config_migrate"] = saved_migration
	package.loaded["toml_codec.writer"] = saved_writer
	if not called then error(result, 0) end
	return result
end

--- Runs one finish message through the production handler.
--- @param opts table `{ answers, locale = "true"|"false"|"nil"|"throw",
---   write = "true"|"false"|"nil"|"throw", read = function(path)|nil,
---   native_writer = function(path, rows, source)|nil, native_files = table|nil,
---   prepare_destination = function(path)|nil (generic receiving replay only),
---   canonical_files = table|nil, config_path = string|nil (actual canonical
---   native provider with real scratch bytes and unchanged boot),
---   remap = { initialized, running, hold_import, import_ok, save_ok, report }|nil,
---   reload = "accepted"|"refused"|nil, menu_paths = table|nil,
---   layer = "fail"|nil }`. The navigation layer file is recorded in
---   state.layer_imports (config folders) and state.layer_undos, never written. A held
---   import leaves its callback in state.import_callbacks for the scenario to
---   settle; `report` is what the owner reports of the tap-hold keys in force
---   (nil: unreadable). Deferred work is recorded in state.pending, never run,
---   so a scenario runs it with M.run_deferred. Without `answers` no message
---   runs, for a scenario that reads through the module.
--- @param scenario function scenario(state, onboarding) with the recorded side effects.
function M.with_finish(opts, scenario)
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local state = {
		alerts = {},
		deferred = 0,
		pending = {},
		reloads = {},
		locale_persists = 0,
		locale_switches = 0,
		notifications = 0,
		writes = {},
	}
	local function noop() end
	-- The shipped presets and the layer rule, read before the path doubles.
	local RealDefaults = require("platform.remap.defaults")
	local RealNavLayer = require("platform.remap.nav_layer")
	state.layer_imports, state.layer_undos = {}, {}
	package.loaded["platform.remap.defaults"] = RealDefaults
	package.loaded["platform.remap.nav_layer"] = setmetatable({
		import_recommended = function(options)
			state.layer_imports[#state.layer_imports + 1] = options.config_dir
			if opts.layer == "fail" then return nil, "disk full" end
			return { status = "imported", path = options.config_dir .. "layers.toml" }
		end,
		undo_import = function(import)
			if import ~= nil then state.layer_undos[#state.layer_undos + 1] = import end
			return true
		end,
	}, { __index = RealNavLayer })
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.paths"] = { shared = opts.canonical_files and helpers.shared
		or function() return "/virtual/shared" end }
	package.loaded["infra.text_utils"] = { applescript_format = string.format }
	package.loaded["infra.toml.codec"] = { decode = function() return {} end }
	package.loaded["adapters.file_system"] = opts.canonical_files or {
		read_with_status = opts.read or function() return nil, "absent" end,
	}
	-- Additional actual inverse ports let receipt tests drive the shared writer.
	for name, method in pairs(opts.native_files or {}) do
		package.loaded["adapters.file_system"][name] = method
	end
	package.loaded["infra.toml.writer"] = {
		batch_write = function(path, rows, expected_source)
			state.writes[#state.writes + 1] = { path = path, rows = rows }
			if type(opts.native_writer) == "function" then return opts.native_writer(path, rows, expected_source) end
			local mode = opts.write or "true"
			if mode == "throw" then error("disk on fire") end
			if mode == "nil" then return nil end
			if mode == "false" then return false, "rename failed" end
			return true
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function() state.notifications = state.notifications + 1; return true end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(delay, fn, label)
			state.deferred = state.deferred + 1
			state.pending[#state.pending + 1] = { delay = delay, fn = fn, label = label }
			return true
		end,
	}
	-- The owned reload: it records the request and its abort callback.
	package.loaded["infra.termination_coordinator"] = {
		is_initialized = function() return true end,
		request_reload_owned = function(reason, on_aborted)
			state.reloads[#state.reloads + 1] = { reason = reason, on_aborted = on_aborted }
			return opts.reload ~= "refused"
		end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = function(title, body, button)
			state.alerts[#state.alerts + 1] = { title = title, body = body, button = button }
			return true
		end,
	}
	-- The remap owner: a running bridge takes the import in its settings
	-- transaction and answers through a callback; otherwise it saves the file.
	-- Either way the request names the backup the owner takes first.
	local remap = opts.remap or {}
	state.imports, state.saves, state.import_callbacks, state.backups, state.reports = {}, {}, {}, {}, {}
	package.loaded["platform.remap"] = {
		-- An initialized bridge may have stopped: only a running one takes
		-- a transaction.
		is_initialized = function() return remap.initialized == true end,
		is_running = function() return remap.running == true end,
		recommended_key_report = function(path)
			state.reports[#state.reports + 1] = path
			if remap.report == nil then return nil, "the settings file is unsafe" end
			return remap.report
		end,
		import_recommended_keys = function(request, on_done)
			state.imports[#state.imports + 1] = request.keys
			state.backups[#state.backups + 1] = request.backup_path
			if remap.hold_import then
				state.import_callbacks[#state.import_callbacks + 1] = on_done
				return true
			end
			local ok = remap.import_ok ~= false
			on_done(ok, ok and "ready" or "activation-failed", #request.keys)
			return ok
		end,
		save_recommended_keys = function(request)
			state.saves[#state.saves + 1] = { keys = request.keys, path = request.path }
			state.backups[#state.backups + 1] = request.backup_path
			if remap.save_ok == false then return false, "the settings file is unsafe" end
			return true
		end,
	}
	package.loaded["infra.config_paths"] = {
		get = function(key)
			assert(key == "KarabinerConfigPath", "unexpected path key " .. tostring(key))
			return M.KARABINER_CONFIG_PATH
		end,
		get_config_dir = function() return M.CONFIG_DIR end,
	}
	if opts.menu_paths then package.loaded["ui.menu.menu_paths"] = opts.menu_paths end
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		set_locale_no_reload = function()
			state.locale_switches = state.locale_switches + 1
			return true
		end,
		persist_locale = function()
			state.locale_persists = state.locale_persists + 1
			local mode = opts.locale or "true"
			if mode == "throw" then error("injected locale persistence failure") end
			if mode == "nil" then return nil end
			return mode == "true"
		end,
	}
	local context = opts.canonical_files and with_native_configuration_context or M.with_migration_reader
	local ok, err = xpcall(context, debug.traceback, function()
		if opts.canonical_files then
			assert(opts.prepare_destination == nil, "native Finish must keep its actual boot preparation")
			if opts.fresh_writer_after_inverse then
				state.previous_shared_writer = require("toml_codec.writer")
				state.retained_inverse_module = require("config_file_inverse")
				package.loaded["toml_codec.writer"] = nil
				state.current_shared_writer = require("toml_codec.writer")
				helpers.assert_true(not rawequal(state.previous_shared_writer, state.current_shared_writer),
					"the canonical host must use a genuinely reloaded shared writer")
				helpers.assert_eq(package.loaded["config_file_inverse"], state.retained_inverse_module,
					"the genuine inverse module remains cached from the prior helper cohort")
			end
			package.loaded["infra.toml.writer"] = nil
			require("infra.toml.writer")
		end
		local onboarding = require("ui.onboarding")
		if not opts.canonical_files then require("tests.support.onboarding_shared_data").install() end
		local handle_message = named_upvalue(onboarding.run, "handle_message")
		helpers.assert_type(handle_message, "function",
			"the fixture must drive the production onboarding message handler")
		if type(opts.prepare_destination) == "function" then
			-- Generic exact-byte receiving controls need no migration. This seam
			-- installs no configuration journal, native issuer or READY receipt.
			-- Native configuration admission must be qualified separately.
			local commit = named_upvalue(handle_message, "commit")
			helpers.assert_type(commit, "function", "the real Finish dispatch must own commit")
			local commit_owned = named_upvalue(commit, "commit_owned")
			helpers.assert_type(commit_owned, "function", "the real claimed Finish must own its commit body")
			local _, prepare_index = named_upvalue(commit_owned, "prepare_destination")
			helpers.assert_not_nil(prepare_index, "the generic control must replace only destination preparation")
			debug.setupvalue(commit_owned, prepare_index, opts.prepare_destination)
		end
		local _, config_path_index = named_upvalue(onboarding.run, "_config_path")
		helpers.assert_not_nil(config_path_index,
			"the fixture must assign the real commit destination upvalue")
		debug.setupvalue(onboarding.run, config_path_index, opts.config_path or "/virtual/onboarding-config.toml")
		state.finish = function(answers) return handle_message({ action = "finish", answers = answers }) end
		if opts.answers ~= nil then state.finish(opts.answers) end
		scenario(state, onboarding)
	end)
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Runs the first recorded deferred work with a label, once.
--- @param state table Fixture state.
--- @param label string DeferredWork label.
--- @return boolean ran False when no such work is pending.
function M.run_deferred(state, label)
	for index, work in ipairs(state.pending) do
		if work.label == label then
			table.remove(state.pending, index)
			work.fn()
			return true
		end
	end
	return false
end

--- Counts the recorded deferred work with a label.
--- @param state table Fixture state.
--- @param label string DeferredWork label.
--- @return integer count
function M.count_deferred(state, label)
	local count = 0
	for _, work in ipairs(state.pending) do
		if work.label == label then count = count + 1 end
	end
	return count
end

return M
