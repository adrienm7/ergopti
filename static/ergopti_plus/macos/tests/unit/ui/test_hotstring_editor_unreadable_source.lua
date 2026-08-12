--- tests/unit/ui/test_hotstring_editor_unreadable_source.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Unreadable-Source Regression
--- DESCRIPTION:
--- Drives the real editor startup and message bridge while the personal TOML is
--- unreadable. Only exact absence may create a baseline; any other read or parse
--- failure keeps the editor read-only and preserves every committed byte.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================
-- =====================================
-- ======= 1/ Behavioral Harness =======
-- =====================================
-- =====================================

--- Runs cleanup even when one assertion fails.
--- @param callback function Test body.
--- @param cleanup function Cleanup body.
local function with_cleanup(callback, cleanup)
	local ok, err = xpcall(callback, debug.traceback)
	local cleanup_ok, cleanup_err = xpcall(cleanup, debug.traceback)
	if not ok then error(err, 0) end
	if not cleanup_ok then error(cleanup_err, 0) end
end

--- Reads exact fixture bytes.
--- @param path string Fixture path.
--- @return string contents Fixture bytes.
local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local contents = assert(file:read("*a"))
	assert(file:close())
	return contents
end

--- Loads one editor instance with observable writer and usercontent doubles.
--- @param writer table Controlled TOML writer.
--- @param reader table Controlled TOML reader.
--- @return table editor Real editor module.
--- @return function dispatch Sends one bridge message.
--- @return table state Observable side effects.
local function load_editor(writer, reader)
	local hs_stub = require("tests.stubs.hs")
	local dispatch
	local state = { notifications = 0, reloads = 0 }
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, resizable = 8, miniaturizable = 4 }
	hs_stub.webview.usercontent.new = function()
		return { setCallback = function(_, callback) dispatch = callback end }
	end
	_G.hs = hs_stub
	package.loaded["infra.toml.writer"] = writer
	package.loaded["infra.toml.reader"] = reader
	package.loaded["infra.notifications"] = {
		notify = function() state.notifications = state.notifications + 1 end,
	}
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 800, height = 700 } end,
		get_centered_frame = function(width, height) return { w = width, h = height } end,
		force_focus = function() end,
		show_webview = function()
			return {
				evaluateJavaScript = function() end,
				delete = function() end,
			}
		end,
	}
	package.loaded["ui.hotstring_editor"] = nil
	local editor = require("ui.hotstring_editor")
	return editor, function(body)
		helpers.assert_type(dispatch, "function", "the real editor bridge must be installed")
		dispatch({ body = body })
	end, state
end





-- ====================================================
-- ====================================================
-- ======= 2/ Existing Files Are Never Replaced =======
-- ====================================================
-- ====================================================

helpers.describe("hotstring editor: unreadable source fails closed", function()
	helpers.it("publishes neither a baseline nor a save after a refused read", function()
		local path = os.tmpname()
		local sentinel = "PRIVATE-PERSONAL-HOTSTRINGS-SENTINEL"
		local file = assert(io.open(path, "wb"))
		assert(file:write(sentinel))
		assert(file:close())
		local original_open = io.open
		local writes = 0
		local reader_calls = 0

		with_cleanup(function()
			io.open = function(candidate, mode)
				if candidate == path and mode == "r" then return nil, "PRIVATE-READ-FAILURE", 13 end
				return original_open(candidate, mode)
			end
			local editor, dispatch, state = load_editor({
				write = function() writes = writes + 1; return true end,
			}, {
				parse = function() reader_calls = reader_calls + 1; return {} end,
			})
			local keymap = {
				PERSONAL_GROUP_NAME = "personal",
				disable_group = function() state.reloads = state.reloads + 1 end,
				load_toml = function() state.reloads = state.reloads + 1 end,
				enable_group = function() state.reloads = state.reloads + 1 end,
			}
			editor.init(path, keymap, function() end, 50)
			editor.open("menu")
			dispatch({ action = "ready" })
			dispatch({ action = "save", data = { sections = {}, sections_order = {} } })

			helpers.assert_eq(writes, 0,
				"an unreadable existing file must authorize neither baseline nor user save")
			helpers.assert_eq(reader_calls, 0,
				"the parser must not receive a path whose readable ownership was not established")
			helpers.assert_eq(state.reloads, 0,
				"a rejected save must not reload an empty group over the live mapping")
			helpers.assert_true(state.notifications > 0,
				"the rejected save must remain visible to the user")
		end, function()
			io.open = original_open
			helpers.assert_eq(read_file(path), sentinel,
				"every failed editor action must preserve the exact committed bytes")
			os.remove(path)
			package.loaded["ui.hotstring_editor"] = nil
		end)
	end)

	helpers.it("creates a missing baseline only after an exact committed write", function()
		local path = os.tmpname()
		os.remove(path)
		local original_open = io.open
		local writes = 0
		with_cleanup(function()
			io.open = function(candidate, mode)
				if candidate == path and mode == "r" then return nil, "missing", 2 end
				return original_open(candidate, mode)
			end
			local editor = load_editor({
				write = function(candidate)
					writes = writes + 1
					helpers.assert_eq(candidate, path, "the baseline must target the configured path")
					return true
				end,
			}, { parse = function() return { sections = {}, sections_order = {} } end })
			editor.init(path, { PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
			helpers.assert_eq(writes, 1, "exact absence must publish exactly one baseline")
		end, function()
			io.open = original_open
			os.remove(path)
			package.loaded["ui.hotstring_editor"] = nil
		end)
	end)

	helpers.it("keeps a readable source read-only when parsing raises", function()
		local path = os.tmpname()
		local file = assert(io.open(path, "wb"))
		assert(file:write("[_meta]\nsections_order = []\n"))
		assert(file:close())
		local writes = 0
		with_cleanup(function()
			local editor, dispatch, state = load_editor({
				write = function() writes = writes + 1; return true end,
			}, {
				parse = function() error("PRIVATE-PARSE-FAILURE", 0) end,
			})
			editor.init(path, { PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
			editor.open("menu")
			dispatch({ action = "ready" })
			dispatch({ action = "save", data = { sections = {}, sections_order = {} } })
			helpers.assert_eq(writes, 0, "parse failure must fence every later save")
			helpers.assert_true(state.notifications > 0,
				"a save fenced by parse failure must be user-visible")
		end, function()
			os.remove(path)
			package.loaded["ui.hotstring_editor"] = nil
		end)
	end)
end)

return true
