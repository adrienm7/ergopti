--- tests/support/ui/menu/llm/numeric_configuration_fixture.lua

--- ==============================================================================
--- MODULE: Numeric Configuration Ownership Fixture
--- DESCRIPTION:
--- Runs the original menu, prompt, settings and persistence over two private
--- folders. Only native windows and desktop notifications are controlled.
--- ==============================================================================

local M = {}
local helpers = require("tests.helpers")
local uv = require("luv")

--- Opens one isolated original configuration stack.
--- @param body function Receives menu actions, native windows and disk readers.
function M.with_configuration(body)
	local journal = {}
	for name, value in pairs(package.loaded) do journal[name] = value end
	local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-numeric-owner-XXXXXX"))
	local xdg_keys = { "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME" }
	local environment = {}
	for _, key in ipairs(xdg_keys) do environment[key] = { value = uv.os_getenv(key) } end
	local parent_paths = helpers.load_module("infra.config_paths")
	local parent_bootstrap = parent_paths.config_home() .. "/ergopti_plus/storage.json"
	local function bootstrap_snapshot()
		local info, detail, code = uv.fs_lstat(parent_bootstrap)
		if not info then assert(code == "ENOENT", detail); return { present = false } end
		assert(info.type == "file", "the parent bootstrap must remain a regular file")
		local file = assert(io.open(parent_bootstrap, "rb"))
		local bytes = assert(file:read("*a")); assert(file:close())
		return { present = true, mode = info.mode, bytes = bytes }
	end
	local parent_source = bootstrap_snapshot()
	local function write(path, bytes)
		local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
	end
	local function read(path)
		local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
	end
	local ok, err = xpcall(function()
		for index, key in ipairs(xdg_keys) do
			local directory = root .. "/xdg-" .. index
			assert(uv.fs_mkdir(directory, 448)); assert(uv.os_setenv(key, directory))
		end
		for name in pairs(package.loaded) do
			if name:match("^modules%.llm%.") or name:match("^infra%.llm_") or name == "infra.config_paths"
				or name == "adapters.storage" or name == "ui.menu.menu_builder" or name == "ui.numeric_prompt.bridge"
				or name == "ui.paths_editor.bridge" then package.loaded[name] = nil end
		end
		local Json, Codec = require("json"), require("toml_codec")
		local dirs = { a = root .. "/a", b = root .. "/b" }
		local initial = {}
		for id, dir in pairs(dirs) do
			assert(uv.fs_mkdir(dir, 448))
			initial[id] = "# private " .. id .. "\n[llm]\nenabled = true\n[llm.generation]\ntemperature = "
				.. (id == "a" and "0.7" or "0.3") .. "\ncontext_length = 1600\nmin_words = 3\nmax_words = 10\n"
				.. "[llm.trigger]\ndebounce_ms = 300\n[independent]\nkeep = \"" .. id .. "\"\n"
			write(dir .. "/config.toml", initial[id])
		end
		local Paths = require("infra.config_paths"); assert(Paths.set_config_dir(dirs.a))
		local windows, received, notifications, serial = {}, {}, {}, 0
		local host = {}
		function host.show(name)
			if not windows[name] then serial = serial + 1; windows[name] = serial end
			return true
		end
		function host.hide(name, epoch)
			if not windows[name] or epoch ~= nil and windows[name] ~= epoch then return false end
			windows[name] = nil; return true
		end
		function host.current_epoch(name) return windows[name] end
		function host.page_current(name, epoch) return windows[name] ~= nil and windows[name] == epoch end
		function host.is_visible(name) return windows[name] ~= nil end
		function host.eval_js(name, code)
			if not windows[name] then return false end
			local encoded = code:match("receive_prompt%((.*)%)$")
			if encoded then received[#received + 1] = assert(Json.decode(encoded)) end
			return true
		end
		package.loaded["ui.webview_manager"] = host
		package.loaded["adapters.notifier"] = { send = function(message) notifications[#notifications + 1] = message; return true end }
		local i18n = require("infra.i18n"); i18n.init()
		local prompt = require("ui.numeric_prompt.bridge")
		local builder = require("ui.menu.menu_builder")
		local function find(rows, predicate)
			for _, row in ipairs(rows or {}) do
				if predicate(row) then return row end
				local found = find(row.menu, predicate); if found then return found end
			end
		end
		local ctx = { _version = "0.0.0-dev.12", paused = false, is_paused = function() return false end,
			llm = { is_enabled = function() return Codec.decode(read(Paths.config("config.toml"))).llm.enabled end },
			webview = host, on_quit = function() error("quit is outside this fixture") end }
		local f = { paths = Paths, dirs = dirs, initial = initial, prompt = prompt, host = host,
			preferences = require("infra.llm_preferences"), settings = require("modules.llm.settings"),
			trigger = require("modules.llm.trigger_settings"), notifications = notifications, received = received, writer = require("toml_codec.writer") }
		function f.bytes(id) return read(dirs[id] .. "/config.toml") end
		function f.document(id) return Codec.decode(f.bytes(id)) end
		function f.switch(id)
			host.show("paths_editor")
			local result = require("ui.paths_editor.bridge").on_message({ action = "save", configDir = dirs[id] },
				{ config_paths = Paths, webview_manager = host, on_reload = function() end })
			assert(result.saved and Paths.get_config_dir() == dirs[id])
		end
		function f.open(name, before_click)
			local key = name == "debounce_ms" and "menu.llm.debounce_label" or "menu.llm.generation." .. name
			if name == "min_words" or name == "max_words" then key = "menu.llm." .. name .. "_label" end
			local prefix = i18n.get(key):match("^(.-)%%[ds]") or i18n.get(key)
			local rows = builder.build(ctx)
			local picker = assert(find(rows, function(row)
				return type(row.title) == "string" and row.title:sub(1, #prefix) == prefix and type(row.menu) == "table"
			end), "numeric picker is present: " .. name)
			local row = assert(find(picker.menu, function(item)
				return item.title == i18n.get("menu.llm.generation.custom_value") and type(item.fn) == "function"
			end), "custom numeric action is present")
			local prior = #received
			if before_click then before_click() end
			row.fn()
			return #received > prior and received[#received] or nil
		end
		function f.save(value)
			local request = assert(received[#received], "a real prompt request was published")
			return prompt.on_message({ action = "save", value = value, request_epoch = request.request_epoch }, {})
		end
		body(f)
	end, debug.traceback)
	for _, key in ipairs(xdg_keys) do
		local value = environment[key].value
		if value == nil then assert(uv.os_unsetenv(key)) else assert(uv.os_setenv(key, value)) end
		helpers.assert_eq(uv.os_getenv(key), value, "restore each original XDG value, including absence")
	end
	for name in pairs(package.loaded) do if journal[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(journal) do package.loaded[name] = value end
	-- The runner's locator must be intact before its old A/B directories disappear.
	helpers.assert_eq(bootstrap_snapshot(), parent_source, "preserve parent bootstrap bytes, mode and existence")
	local function remove(path)
		local info = assert(uv.fs_lstat(path))
		if info.type == "directory" then
			local scan = assert(uv.fs_scandir(path))
			while true do local name = uv.fs_scandir_next(scan); if not name then break end; remove(path .. "/" .. name) end
			assert(uv.fs_rmdir(path))
		else assert(os.remove(path)) end
	end
	remove(root)
	if not ok then error(err, 0) end
end

return M
