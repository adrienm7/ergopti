--- tests/unit/ui/editors/test_layout_editor_source_store.lua

--- ==============================================================================
--- MODULE: Layout Editor Source Store
--- DESCRIPTION:
--- The unified layout editor saves its files from the layout manager window
--- through the shared store (_shared/lua/layouts/source_store.lua) and the
--- shared bridge (_shared/lua/layouts/manager_bridge.lua). These tests pin the
--- store's bounds (plain names, allowed types, UTF-8, size), reopening the last
--- saved source, the bridge's routing and refusals, and the Linux bridge
--- forwarding both operations to the real registry module.
--- ==============================================================================

local helpers = require("tests.helpers")

local SourceStore = require("layouts.source_store")
local ManagerBridge = require("layouts.manager_bridge")

local DEFAULTS_PATH = "modules/layouts/defaults.json"

--- The store's settings from the shared defaults, as the registries read them.
--- @return table
local function settings()
	local Json = require("json")
	local Paths = require("infra.paths")
	local handle = assert(io.open(Paths.shared(DEFAULTS_PATH), "r"))
	local text = handle:read("*a")
	handle:close()
	return assert(SourceStore.settings(Json.decode(text)))
end

--- A store over an in-memory disk.
--- @return table operations, table disk, table logs
local function store(overrides)
	local disk, logs = {}, {}
	local env = {
		settings = settings(),
		config_dir = "/config/",
		read = function(path) return disk[path] end,
		exists = function(path) return disk[path] ~= nil end,
		write = function(path, text) disk[path] = text; return true end,
		log = function(level, message) logs[#logs + 1] = level .. ": " .. message end,
	}
	for key, value in pairs(overrides or {}) do env[key] = value end
	return SourceStore.new(env), disk, logs
end

helpers.describe("layout editor source store", function()
	helpers.it("reads its bounds from the shared layout defaults and refuses a broken table", function()
		local s = settings()
		helpers.assert_eq(s.folder, "layout_sources")
		helpers.assert_true(s.max_file_bytes > 0 and s.max_name_length > 0)
		local _, err = SourceStore.settings({ source = { folder = "../x", last_file = "l",
			max_file_bytes = 1, max_name_length = 1 } })
		helpers.assert_contains(err, "folder")
		_, err = SourceStore.settings({})
		helpers.assert_contains(err, "no source table")
	end)

	helpers.it("saves a source in its folder and reopens it as the last one", function()
		local operations, disk = store()
		local results = {}
		operations.save({ filename = "my_layout.toml", text = "format = \"ergopti-layout\"\n" },
			function(...) results[#results + 1] = { ... } end)
		helpers.assert_true(results[1][1])
		helpers.assert_eq(results[1][4], "my_layout.toml")
		helpers.assert_eq(disk["/config/layout_sources/my_layout.toml"], "format = \"ergopti-layout\"\n")
		helpers.assert_eq(disk["/config/layout_sources/last_source"], "my_layout.toml\n")
		local opened
		operations.open(function(data) opened = data end)
		helpers.assert_eq(opened.filename, "my_layout.toml")
		helpers.assert_eq(opened.text, "format = \"ergopti-layout\"\n")
	end)

	helpers.it("keeps the last source when an export is saved", function()
		local operations, disk = store()
		local noop = function() end
		operations.save({ filename = "mine.toml", text = "a = 1\n" }, noop)
		operations.save({ filename = "layers.toml", text = "[_meta]\n" }, noop)
		operations.save({ filename = "mine.keylayout", text = "<keyboard/>" }, noop)
		helpers.assert_eq(disk["/config/layout_sources/last_source"], "mine.toml\n")
		helpers.assert_eq(disk["/config/layout_sources/mine.keylayout"], "<keyboard/>")
	end)

	helpers.it("refuses paths, other file types, empty, oversized and non-UTF-8 files", function()
		local operations, disk, logs = store()
		local refused = {}
		local function save(filename, text)
			operations.save({ filename = filename, text = text }, function(ok, code)
				refused[#refused + 1] = (not ok) and code or "accepted"
			end)
		end
		save("../evil.toml", "x")
		save("sub/dir.toml", "x")
		save("Upper.toml", "x")
		save("script.sh", "x")
		save("empty.toml", "")
		save("big.toml", string.rep("x", settings().max_file_bytes + 1))
		save("latin1.toml", "caf\233")
		save("surrogate.toml", "\237\160\128")
		for index, code in ipairs(refused) do
			helpers.assert_eq(code, SourceStore.FAILURE_INVALID, "refusal " .. index)
		end
		helpers.assert_eq(#refused, 8)
		helpers.assert_eq(next(disk), nil, "nothing was written")
		helpers.assert_true(#logs == 8)
	end)

	helpers.it("reports a failed write with its detail instead of claiming success", function()
		local operations = store({ write = function() return false, "disk full" end })
		local result
		operations.save({ filename = "a.toml", text = "x" }, function(...) result = { ... } end)
		helpers.assert_eq(result[1], false)
		helpers.assert_eq(result[2], SourceStore.FAILURE_WRITE)
		helpers.assert_eq(result[3], "disk full")
	end)

	helpers.it("opens nothing when the pointer names a missing or foreign file", function()
		local operations, disk, logs = store()
		disk["/config/layout_sources/last_source"] = "../../etc/passwd\n"
		local opened
		operations.open(function(data) opened = data end)
		helpers.assert_eq(opened.text, nil)
		helpers.assert_eq(opened.folder, "/config/layout_sources/")
		helpers.assert_true(#logs == 1)
	end)

	helpers.it("accepts multi-byte UTF-8 and refuses overlong forms", function()
		helpers.assert_true(SourceStore.is_utf8("ffi🦆 ễ"))
		helpers.assert_true(not SourceStore.is_utf8("\192\175"))
		helpers.assert_true(not SourceStore.is_utf8("\244\144\128\128"))
	end)
end)

helpers.describe("layout manager bridge routes the layout editor", function()
	--- A controller over a registry with or without the source operations.
	local function controller(with_source)
		local pushes, saved = {}, {}
		local registry = {
			snapshot = function() return { platform = "linux", installed = {} } end,
			refresh = function() end,
		}
		if with_source then
			registry.source_open = function(on_done) on_done({ text = "a = 1\n", filename = "a.toml" }) end
			registry.source_save = function(payload, on_done)
				saved[#saved + 1] = payload
				on_done(true, nil, "/config/layout_sources/" .. payload.filename, payload.filename)
			end
		end
		local bridge = ManagerBridge.new({
			registry = registry,
			push = function(name, payload) pushes[#pushes + 1] = { name = name, payload = payload } end,
			strings = function() return {} end,
			log = function() end,
			open_url = function() end,
			close = function() end,
		})
		return bridge, pushes, saved
	end

	helpers.it("tells the page whether the host stores the editor's files", function()
		local bridge, pushes = controller(true)
		bridge.on_message({ action = "ready" })
		helpers.assert_eq(pushes[1].name, "initData")
		helpers.assert_eq(pushes[1].payload.source_editor, true)
		local plain, plain_pushes = controller(false)
		plain.on_message({ action = "ready" })
		helpers.assert_eq(plain_pushes[1].payload.source_editor, false)
		helpers.assert_eq(plain.on_message({ action = "source_open" }), false)
	end)

	helpers.it("opens and saves through the registry and pushes each result", function()
		local bridge, pushes, saved = controller(true)
		helpers.assert_true(bridge.on_message({ action = "source_open" }))
		helpers.assert_eq(pushes[1].name, "sourceData")
		helpers.assert_eq(pushes[1].payload.filename, "a.toml")
		helpers.assert_true(bridge.on_message({ action = "source_save", filename = "b.toml", text = "x", extra = 1 }))
		helpers.assert_eq(saved[1].filename, "b.toml")
		helpers.assert_eq(saved[1].extra, nil, "only the file name and text reach the store")
		helpers.assert_eq(pushes[2].name, "sourceResult")
		helpers.assert_eq(pushes[2].payload.ok, true)
		helpers.assert_eq(bridge.on_message({ action = "source_save", filename = "b.toml" }), false)
	end)

	helpers.it("forwards both operations through the Linux bridge to its registry", function()
		local Bridge = helpers.load_module("ui.layout_manager.bridge")
		Bridge._reset()
		local pushes, calls = {}, {}
		local daemon_state = {
			webview_manager = {
				eval_js = function(_, js) pushes[#pushes + 1] = js; return true end,
				hide = function() return true end,
			},
			i18n = { get = function(key) return key end },
			layout_registry = {
				snapshot = function() return { platform = "linux", installed = {} } end,
				refresh = function() end,
				install = function() end,
				uninstall = function() end,
				select = function() end,
				source_open = function(on_done) calls[#calls + 1] = "open"; on_done({ folder = "/c/" }) end,
				source_save = function(payload, on_done)
					calls[#calls + 1] = "save " .. payload.filename
					on_done(true, nil, "/c/" .. payload.filename, payload.filename)
				end,
			},
		}
		helpers.assert_true(Bridge.on_message({ action = "source_open" }, daemon_state).handled)
		helpers.assert_true(Bridge.on_message({ action = "source_save", filename = "a.toml", text = "x" },
			daemon_state).handled)
		helpers.assert_eq(table.concat(calls, ","), "open,save a.toml")
		helpers.assert_contains(pushes[1], "window.sourceData(")
		helpers.assert_contains(pushes[2], "window.sourceResult(")
	end)
end)
