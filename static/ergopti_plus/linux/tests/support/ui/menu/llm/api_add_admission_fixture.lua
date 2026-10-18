--- tests/support/ui/menu/llm/api_add_admission_fixture.lua

--- ==============================================================================
--- MODULE: Native API Add Admission Fixture
--- DESCRIPTION:
--- Exercises actual menu, engine, preference and private API source owners.
--- Only dialogs, log reentrance and the HTTP acquisition boundary are authored.
--- ==============================================================================

local M = {}

--- Runs a single isolated callback with real POSIX private files.
--- @param body function Receives native owners and explicit callback controls.
function M.run(body)
	local uv = require("luv")
	local scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-api-admission-XXXXXX"))
	local saved, environment = {}, {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	for _, name in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME" }) do
		environment[name] = os.getenv(name); assert(uv.os_setenv(name, scratch .. "/" .. name))
	end
	for _, name in ipairs({ "ui.menu.llm_backend_rows", "modules.llm.prediction_engine", "modules.llm.api_entries",
		"modules.llm.api_remote", "infra.llm_preferences", "infra.config_paths", "adapters.storage", "adapters.http_client",
		"modules.llm.profiles", "modules.llm.settings", "modules.llm.trigger_settings", "modules.llm.display_settings",
		"modules.llm.agent_settings", "modules.llm.profile_settings", "modules.llm.navigation_settings" }) do package.loaded[name] = nil end
	local Logger = require("logger.shim")
	local old_log = { info = Logger.info, debug = Logger.debug, error = Logger.error }
	local rename = os.rename
	local function write(path, text)
		local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
	end
	local function read(path)
		local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
	end
	local function remove_tree(path)
		local scan = assert(uv.fs_scandir(path))
		while true do
			local name, kind = uv.fs_scandir_next(scan)
			if not name then break end
			local child = path .. "/" .. name
			if kind == "directory" then remove_tree(child) else assert(uv.fs_unlink(child)) end
		end
		assert(uv.fs_rmdir(path))
	end
	local ok, why = xpcall(function()
		local Json, Paths = require("json"), require("infra.config_paths")
		assert(uv.fs_mkdir(Paths.config_home(), 448)); assert(uv.fs_mkdir(Paths.get_config_dir(), 448))
		local state = { requests = {}, errors = {}, infos = {}, stages = 0, writes = 0, changed = 0, paused = false, owners = {},
			api_path = scratch .. "/api.json", config_path = Paths.config("config.toml"), read = read, write = write, json = Json }
		state.config = '[llm.models]\nselected = "api"\n'
		write(state.config_path, state.config)
		state.original = Json.encode({ version = 1, active_id = "before", entries = Json.array({
			{ id = "before", provider = "cerebras", label = "before", token = "synthetic-before", model = "before-model", base_url = "" },
			{ id = "successor", provider = "cerebras", label = "successor", token = "synthetic-successor", model = "successor-model", base_url = "" },
		}) })
		write(state.api_path, state.original); assert(uv.fs_chmod(state.api_path, 384))
		local Entries, Http = require("modules.llm.api_entries"), require("adapters.http_client")
		Entries._set_path_for_test(state.api_path)
		Entries._set_private_create_for_test(function(path, text)
			state.stages = state.stages + 1
			local fd, detail = uv.fs_open(path, "wx", 384)
			if not fd then return false, detail end
			local count = uv.fs_write(fd, text, -1)
			local synced, closed = uv.fs_fsync(fd), uv.fs_close(fd)
			assert(count == #text and synced == true and closed == true)
			if state.on_stage then state.on_stage() end
			return true
		end)
		os.rename = function(from, to)
			local accepted, detail = rename(from, to)
			if to == state.api_path and accepted then
				state.writes = state.writes + 1
				if state.on_renamed then state.on_renamed() end
			end
			return accepted, detail
		end
		Http.post = function(url, headers, payload, done, options)
			if state.on_http_admission then state.on_http_admission() end
			if options.authorized and options.authorized() ~= true then return false end
			state.requests[#state.requests + 1] = { url = url, headers = headers, payload = payload, done = done, options = options }
			if not state.hold_http then
				done({ ok = true, status = 200, body = Json.encode({ choices = Json.array({ { message = { content = "synthetic answer" } } }) }) })
			end
			return true
		end
		local Engine = require("modules.llm.prediction_engine")
		Engine.init({ is_paused = function()
			if state.on_pause then state.on_pause() end
			return state.paused
		end })
		state.engine, state.entries, state.remote = Engine, Entries, require("modules.llm.api_remote")
		state.preferences = require("infra.llm_preferences")
		function state.scope()
			local owner = { pending = function() return false end }
			local acquired = Engine.acquire_configuration(owner)
			if acquired then state.owners[#state.owners + 1] = owner end
			return acquired
		end
		local add = Entries.add
		Entries.add = function(...)
			if state.on_add then state.on_add() end
			return add(...)
		end
		for _, level in ipairs({ "info", "debug", "error" }) do
			Logger[level] = function(tag, format, ...)
				if state.on_log then state.on_log(level, tostring(format)) end
				return old_log[level](tag, format, ...)
			end
		end
		local prompts = 0
		local dialogs = {
			prompt = function()
				prompts = prompts + 1
				if state.on_prompt then state.on_prompt(prompts) end
				return prompts == 1 and "synthetic-new-key" or "new-model"
			end,
			error = function(text) state.errors[#state.errors + 1] = text end,
			info = function(_, text) state.infos[#state.infos + 1] = text end,
			confirm = function() return true end,
		}
		local rows = require("ui.menu.llm_backend_rows").rows(Engine, dialogs, function()
			state.changed = state.changed + 1
			if state.on_changed then state.on_changed() end
		end, function() return {} end)
		local function find(records)
			for _, row in ipairs(records) do
				if row.label == "➕ Cerebras" then return row.action end
				if row.items or row.submenu then local found = find(row.items or row.submenu); if found then return found end end
			end
		end
		state.action = assert(find(rows), "the actual Add Cerebras menu callback must exist")
		body(state)
		for _, owner in ipairs(state.owners) do assert(Engine.release_configuration(owner)) end
	end, debug.traceback)
	os.rename = rename
	for level, original in pairs(old_log) do Logger[level] = original end
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	for _, name in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME" }) do
		if environment[name] == nil then assert(uv.os_unsetenv(name)) else assert(uv.os_setenv(name, environment[name])) end
	end
	remove_tree(scratch)
	if not ok then error(why, 0) end
end

return M
