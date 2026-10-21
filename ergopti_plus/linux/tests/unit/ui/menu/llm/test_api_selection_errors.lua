--- tests/unit/ui/menu/llm/test_api_selection_errors.lua

--- ==============================================================================
--- MODULE: API Selection Save Error Publication
--- DESCRIPTION:
--- Exercises real tray callbacks, prediction preferences and private API files.
--- A refused selection preserves the acknowledged entry and reports its failure.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs one menu callback against isolated real configuration and API files.
--- @param body function Receives the native owners, files and visible dialog observations.
local function isolated(body)
	local uv = require("luv")
	local scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-api-selection-XXXXXX"))
	local saved_modules, saved_environment = {}, {}
	for name, value in pairs(package.loaded) do saved_modules[name] = value end
	for _, name in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME" }) do
		saved_environment[name] = os.getenv(name)
		assert(uv.os_setenv(name, scratch .. "/" .. name))
	end
	for _, name in ipairs({ "ui.menu.llm_backend_rows", "modules.llm.prediction_engine", "modules.llm.api_entries",
		"modules.llm.api_remote", "infra.llm_preferences", "infra.config_paths", "adapters.storage" }) do
		package.loaded[name] = nil
	end
	local function write(path, content)
		local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
	end
	local function read(path)
		local file = assert(io.open(path, "rb")); local content = file:read("*a"); assert(file:close()); return content
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
		local Json = require("json")
		local Paths = require("infra.config_paths")
		assert(uv.fs_mkdir(Paths.config_home(), 448))
		assert(uv.fs_mkdir(Paths.get_config_dir(), 448))
		local config_path, api_path = Paths.config("config.toml"), scratch .. "/api.json"
		local config = '[llm.models]\nselected = "api"\n'
		write(config_path, config)
		local original = Json.encode({ version = 1, active_id = "before", entries = Json.array({
			{ id = "before", provider = "cerebras", label = "before", token = "synthetic-before", model = "before-model", base_url = "" },
			{ id = "after", provider = "cerebras", label = "after", token = "synthetic-after", model = "after-model", base_url = "" },
		}) })
		write(api_path, original); assert(uv.fs_chmod(api_path, 384))
		local Entries = require("modules.llm.api_entries")
		Entries._set_path_for_test(api_path)
		if not pcall(require, "ffi") then
			-- PUC lacks the daemon's libc FFI. Only private creation is injected;
			-- actual exclusive mode0600, fsync, CAS and native rename remain exercised.
			Entries._set_private_create_for_test(function(path, text)
				local fd, error_text = uv.fs_open(path, "wx", 384)
				if not fd then return false, error_text end
				local count, detail = uv.fs_write(fd, text, -1)
				local synced, closed = uv.fs_fsync(fd), uv.fs_close(fd)
				return count == #text and synced == true and closed == true, detail
			end)
		end
		local Engine = require("modules.llm.prediction_engine")
		local Rows = require("ui.menu.llm_backend_rows")
		local seen = { errors = {}, changed = 0 }
		local dialogs = {
			error = function(text, title) seen.errors[#seen.errors + 1] = { text = text, title = title } end,
			prompt = function() error("selection must not prompt") end,
			info = function() error("selection must not test a provider") end,
			confirm = function() error("selection must not request confirmation") end,
		}
		local function select()
			local rows = Rows.rows(Engine, dialogs, function() seen.changed = seen.changed + 1 end, function() return {} end)
			for _, row in ipairs(rows) do
				if row.label == "cerebras/after-model" then return row.action end
			end
			error("the actual provider entry row is missing")
		end
		body({ entries = Entries, engine = Engine, seen = seen, select = select, api_path = api_path,
			config_path = config_path, config = config, original = original, read = read, write = write, uv = uv, json = Json })
	end, debug.traceback)
	for name in pairs(package.loaded) do if saved_modules[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved_modules) do package.loaded[name] = value end
	for _, name in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME" }) do
		if saved_environment[name] == nil then assert(uv.os_unsetenv(name))
		else assert(uv.os_setenv(name, saved_environment[name])) end
	end
	remove_tree(scratch)
	if not ok then error(why, 0) end
end

--- Verifies the visible failure and the preserved authoritative state together.
--- @param state table Actual callback fixture.
--- @param expected string Expected private file bytes after the attempted action.
local function assert_refused(state, expected)
	helpers.assert_eq(state.entries.active().id, "before")
	helpers.assert_eq(state.read(state.api_path), expected)
	helpers.assert_eq(state.engine.get_backend(), "api")
	helpers.assert_eq(state.read(state.config_path), state.config)
	helpers.assert_eq(state.seen.changed, 0)
	helpers.assert_eq(#state.seen.errors, 1, "the refused selection must reach the native error dialog")
	local i18n = require("infra.i18n")
	helpers.assert_eq(state.seen.errors[1].text, i18n.get("dialog.bulk_toggle.save_failed"))
	helpers.assert_eq(state.seen.errors[1].title, i18n.get("common.error_title"))
end

helpers.describe("API menu selection persistence errors", function()
	helpers.it("(api-selection-errors) reports a physical source conflict and preserves the external winner", function()
		isolated(function(state)
			local action = state.select()
			local external = state.original .. "\n"
			state.write(state.api_path, external)
			helpers.assert_eq(action(), false)
			assert_refused(state, external)
		end)
	end)

	helpers.it("(api-selection-errors) reports a native private-file staging refusal without changing either source", function()
		isolated(function(state)
			local action = state.select()
			assert(state.uv.fs_mkdir(state.api_path .. ".tmp", 448))
			state.write(state.api_path .. ".tmp/owned-blocker", "owned staging collision")
			helpers.assert_eq(action(), false)
			assert_refused(state, state.original)
		end)
	end)

	helpers.it("(api-selection-errors) publishes one successful real selection without an error dialog", function()
		isolated(function(state)
			helpers.assert_eq(state.select()(), true)
			helpers.assert_eq(state.entries.active().id, "after")
			helpers.assert_eq(state.json.decode(state.read(state.api_path)).active_id, "after")
			helpers.assert_eq(state.seen.changed, 1)
			helpers.assert_eq(#state.seen.errors, 0)
		end)
	end)

	helpers.it("(api-selection-errors) recovers after a source conflict with a fresh authoritative menu", function()
		isolated(function(state)
			local action = state.select()
			local external = state.original .. "\n"
			state.write(state.api_path, external)
			helpers.assert_eq(action(), false)
			assert_refused(state, external)
			state.entries._set_path_for_test(state.api_path)
			helpers.assert_eq(state.select()(), true)
			helpers.assert_eq(state.entries.active().id, "after")
			helpers.assert_eq(state.seen.changed, 1)
			helpers.assert_eq(#state.seen.errors, 1)
		end)
	end)
end)
