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
local function load_editor(writer, reader, file_system)
	local hs_stub = require("tests.stubs.hs")
	local dispatch
	local state = { notifications = 0, reloads = 0, javascript = {} }
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, resizable = 8, miniaturizable = 4 }
	hs_stub.webview.usercontent.new = function()
		return { setCallback = function(_, callback) dispatch = callback end }
	end
	_G.hs = hs_stub
	package.loaded["adapters.file_system"] = file_system
	package.loaded["infra.toml.writer"] = writer
	package.loaded["toml_codec.writer"] = nil
	package.loaded["infra.toml.reader"] = reader
	package.loaded["infra.notifications"] = {
		notify = function() state.notifications = state.notifications + 1 end,
	}
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 800, height = 700 } end,
		get_centered_frame = function(width, height) return { w = width, h = height } end,
		force_focus = function() end,
		show_webview = function(options)
			state.webview_options = options
			return {
				evaluateJavaScript = function(_, source)
					state.javascript[#state.javascript + 1] = source
				end,
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
	helpers.it("sends strict-case state to the shared frontend", function()
		local path = "/virtual/personal_hotstrings.toml"
		local source = "[[_meta]]\n"
		local editor, dispatch, state = load_editor({}, {
			parse = function()
				return {
					sections_order = { "strict" },
					sections = {
						strict = {
							description = "Strict",
							entries = {
								{
									trigger = "Case",
									output = "exact",
									is_case_sensitive = true,
									is_case_sensitive_strict = true,
								},
							},
						},
					},
				}, true
			end,
		}, {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				return source, "ok"
			end,
		})
		editor.init(path, { PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
		editor.open("menu")
		dispatch({ action = "ready" })

		helpers.assert_contains(table.concat(state.javascript, "\n"),
			'"is_case_sensitive_strict":true',
			"a strict entry must reach the frontend before any edit can preserve it")
		package.loaded["ui.hotstring_editor"] = nil
	end)

	helpers.it("preserves unknown brace groups when loading the shared frontend", function()
		local path = "/virtual/personal_hotstrings.toml"
		local source = "[[_meta]]\n"
		local editor, dispatch, state = load_editor({}, {
			parse = function()
				return {
					sections_order = { "literal" },
					sections = {
						literal = {
							description = "Literal",
							entries = {
								{
									trigger = "brace",
									output = "voir {N.B.} et {fooBAR}; {ENTER}/{bs}",
								},
							},
						},
					},
				}, true
			end,
		}, {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				return source, "ok"
			end,
		})
		editor.init(path, { PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
		editor.open("menu")
		dispatch({ action = "ready" })

		local javascript = table.concat(state.javascript, "\n")
		helpers.assert_contains(javascript, "voir {N.B.} et {fooBAR}; {Enter}/{BackSpace}",
			"the editor may canonicalize known aliases but must preserve unknown braces")
		package.loaded["ui.hotstring_editor"] = nil
	end)

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
				create_if_absent = function() writes = writes + 1; return true end,
			}, {
				parse = function() reader_calls = reader_calls + 1; return {} end,
			}, {
				read_with_status = function(candidate)
					helpers.assert_eq(candidate, path)
					return nil, "error", "Permission denied"
				end,
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
		local disk = nil
		local reader_calls = 0
		with_cleanup(function()
			io.open = function(candidate, mode)
				if candidate == path and mode == "r" then return nil, "missing", 2 end
				return original_open(candidate, mode)
			end
			local editor, dispatch = load_editor({
				create_if_absent = function(candidate)
					writes = writes + 1
					helpers.assert_eq(candidate, path, "the baseline must target the configured path")
					disk = "[_meta]\nsections_order = []\n"
					return true
				end,
			}, { parse = function()
				reader_calls = reader_calls + 1
				return { sections = {}, sections_order = {} }, true
			end }, {
				read_with_status = function(candidate)
					helpers.assert_eq(candidate, path)
					if disk == nil then return nil, "absent" end
					return disk, "ok"
				end,
			})
			editor.init(path, { PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
			editor.open("menu")
			dispatch({ action = "ready" })
			helpers.assert_eq(writes, 1, "exact absence must publish exactly one baseline")
			helpers.assert_true(reader_calls > 0,
				"the committed baseline must read back and unlock the real editor data path")
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
				create_if_absent = function() writes = writes + 1; return true end,
			}, {
				parse = function() error("PRIVATE-PARSE-FAILURE", 0) end,
			}, {
				read_with_status = function(candidate)
					helpers.assert_eq(candidate, path)
					return "[_meta]\nsections_order = []\n", "ok"
				end,
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

	helpers.it("requires an exact committed parser result before enabling Save", function()
		for _, parse_status in ipairs({ false, "nil" }) do
			local path = os.tmpname()
			local file = assert(io.open(path, "wb"))
			assert(file:write("[_meta]\nsections_order = []\n"))
			assert(file:close())
			local writes = 0
			with_cleanup(function()
				local editor, dispatch = load_editor({
					write = function() writes = writes + 1; return true end,
				}, {
					parse = function()
						local data = { sections = {}, sections_order = {} }
						if parse_status == "nil" then return data end
						return data, false
					end,
				}, {
					read_with_status = function(candidate)
						helpers.assert_eq(candidate, path)
						return "[_meta]\nsections_order = []\n", "ok"
					end,
				})
				editor.init(path, { PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
				editor.open("menu")
				dispatch({ action = "ready" })
				dispatch({ action = "save", data = { sections = {}, sections_order = {} } })
				helpers.assert_eq(writes, 0,
					"parser status " .. tostring(parse_status) .. " must keep Save fenced")
			end, function()
				os.remove(path)
				package.loaded["ui.hotstring_editor"] = nil
			end)
		end
	end)

	helpers.it("routes a real editor save through the symlink-safe macOS writer", function()
		local path = "/virtual/personal_hotstrings.toml"
		local writes = 0
		local file_system = {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				return "[_meta]\nsections_order = []\n", "ok"
			end,
			write = function()
				error("the editor must not downgrade an exact snapshot to an unconditional write", 0)
			end,
			write_if_unchanged = function(candidate, content, expected_source)
				writes = writes + 1
				helpers.assert_eq(candidate, path,
					"the writer must keep the requested symlink pathname for adapter resolution")
				helpers.assert_true(type(content) == "string" and content:find("%[_meta%]") ~= nil,
					"the real TOML writer must pass its complete serialized payload")
				helpers.assert_eq(expected_source, {
					status = "ok",
					content = "[_meta]\nsections_order = []\n",
				}, "the exact editor snapshot must cross the filesystem boundary")
				return true
			end,
		}
		local editor, dispatch = load_editor(nil, {
			parse = function() return { sections = {}, sections_order = {} }, true end,
		}, file_system)
		editor.init(path, {
			PERSONAL_GROUP_NAME = "personal",
			reload_toml = function() return true end,
		}, function() end, 50)
		editor.open("menu")
		dispatch({ action = "save", data = { sections = {}, sections_order = {} } })
		helpers.assert_eq(writes, 1,
			"a save through a readable symlink must publish conditionally exactly once")
		package.loaded["ui.hotstring_editor"] = nil
	end)

	helpers.it("preserves an external edit that wins while the editor is open", function()
		local path = "/virtual/personal_hotstrings.toml"
		local initial = "[_meta]\nsections_order = []\n"
		local external = "[_meta]\nsections_order = []\n# external winner\n"
		local disk = initial
		local publications = 0
		local file_system = {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				return disk, "ok"
			end,
			-- Causal old-code seam: unconditional publication erases B.
			write = function(_candidate, content)
				publications = publications + 1
				disk = external
				disk = content
				return true
			end,
			write_if_unchanged = function(_candidate, _content, expected_source)
				publications = publications + 1
				helpers.assert_eq(expected_source,
					{ status = "ok", content = initial },
					"the exact bytes used by the open editor must reach publication")
				disk = external
				return false, "source changed"
			end,
		}
		local editor, dispatch, state = load_editor(nil, {
			parse = function() return { sections = {}, sections_order = {} }, true end,
		}, file_system)
		local reloads = 0
		local keymap = {
			PERSONAL_GROUP_NAME = "personal",
			disable_group = function() reloads = reloads + 1 end,
			load_toml = function() reloads = reloads + 1 end,
			enable_group = function() reloads = reloads + 1 end,
		}
		editor.init(path, keymap, function() end, 50)
		editor.open("menu")
		dispatch({ action = "save", data = { sections = {}, sections_order = {} } })

		helpers.assert_eq(publications, 1)
		helpers.assert_eq(disk, external,
			"the external winner must survive byte-for-byte")
		helpers.assert_eq(reloads, 0,
			"a stale editor candidate must not replace the live hotstring group")
		helpers.assert_true(state.notifications > 0,
			"the rejected stale save must remain visible to the user")
		package.loaded["ui.hotstring_editor"] = nil
	end)

	helpers.it("keeps the previous live group and reports a post-save reload refusal", function()
		local path = "/virtual/personal_hotstrings.toml"
		local initial = "[_meta]\nsections_order = []\n"
		local reloads = 0
		local menu_updates = 0
		local editor, dispatch, state = load_editor({
			write_if_unchanged = function(_candidate, _data, expected_source)
				helpers.assert_eq(expected_source, { status = "ok", content = initial })
				return true, nil, "[_meta]\nsections_order = []\n# saved\n"
			end,
		}, {
			parse = function() return { sections = {}, sections_order = {} }, true end,
		}, {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				return initial, "ok"
			end,
		})
		local keymap = {
			PERSONAL_GROUP_NAME = "personal",
			reload_toml = function(group, candidate)
				reloads = reloads + 1
				helpers.assert_eq(group, "personal")
				helpers.assert_eq(candidate, path)
				return false
			end,
			disable_group = function()
				error("the editor must not own a half-transactional disable step", 0)
			end,
			load_toml = function()
				error("the editor must use the atomic reload boundary", 0)
			end,
		}
		editor.init(path, keymap, function() menu_updates = menu_updates + 1 end, 50)
		editor.open("menu")
		dispatch({ action = "save", data = { sections = {}, sections_order = {} } })

		helpers.assert_eq(reloads, 1,
			"a durable save must request exactly one atomic live-group replacement")
		helpers.assert_true(state.notifications > 0,
			"a refused live replacement must be visible instead of looking successful")
		helpers.assert_eq(menu_updates, 0,
			"the menu must not publish a new live state after registry rollback")
		package.loaded["ui.hotstring_editor"] = nil
	end)

	helpers.it("logs a deferred menu-refresh callback failure after a committed save", function()
		local path = "/virtual/personal_hotstrings.toml"
		local initial = "[_meta]\nsections_order = []\n"
		local editor, dispatch = load_editor({
			write_if_unchanged = function()
				return true, nil, "[_meta]\nsections_order = []\n# saved\n"
			end,
		}, {
			parse = function() return { sections = {}, sections_order = {} }, true end,
		}, {
			read_with_status = function() return initial, "ok" end,
		})
		editor.init(path, {
			PERSONAL_GROUP_NAME = "personal",
			reload_toml = function() return true end,
		}, function()
			error("injected deferred menu refresh failure", 0)
		end, 50)
		local Logger = require("infra.logger")
		local lines = {}
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		local timers_before = #_G.hs.timer.__timers
		editor.open("menu")
		dispatch({ action = "save", data = { sections = {}, sections_order = {} } })
		helpers.assert_eq(#_G.hs.timer.__timers, timers_before + 1)
		_G.hs.timer.__timers[#_G.hs.timer.__timers]:fire()
		Logger.set_sink(nil)

		helpers.assert_contains(table.concat(lines, "\n"), "Deferred menu refresh failed",
			"an async callback throw must reach the file-logger pipeline")
		package.loaded["ui.hotstring_editor"] = nil
	end)

	helpers.it("logs throwing preference and focus controllers exactly once (HS-198)", function()
		local editor, dispatch, state = load_editor({}, {
			parse = function() return { sections = {}, sections_order = {} }, true end,
		}, {
			read_with_status = function() return "[_meta]\nsections_order = []\n", "ok" end,
		})
		local pref_calls = 0
		local focus_values = {}
		editor.init("/virtual/personal_hotstrings.toml",
			{ PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
		editor.set_update_pref(function()
			pref_calls = pref_calls + 1
			error("preference controller exploded", 0)
		end)
		editor.set_on_focus_change(function(focused)
			focus_values[#focus_values + 1] = focused
			error("focus controller exploded: " .. tostring(focused), 0)
		end)
		editor.open("menu")

		local Logger = require("infra.logger")
		local lines = {}
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		local ok, err = xpcall(function()
			dispatch({ action = "save_pref", data = { key = "compact_view", value = true } })
			dispatch({ action = "window_focus", data = { focused = true } })
			state.webview_options.on_close()
		end, debug.traceback)
		Logger.set_sink(nil)

		helpers.assert_true(ok, "controller throws must stay inside the UI boundary: " .. tostring(err))
		helpers.assert_eq(pref_calls, 1)
		helpers.assert_eq(focus_values, { true, false },
			"bridge focus and native close must each notify exactly once")
		local log = table.concat(lines, "\n")
		helpers.assert_contains(log, "Hotstring preference update")
		helpers.assert_contains(log, "preference controller exploded")
		helpers.assert_contains(log, "Hotstring focus change")
		helpers.assert_contains(log, "focus controller exploded: true")
		helpers.assert_contains(log, "focus controller exploded: false")
		package.loaded["ui.hotstring_editor"] = nil
	end)

	helpers.it("never invokes the writer for a dangling symlink", function()
		local writes = 0
		local editor, dispatch = load_editor({
			write = function() writes = writes + 1; return true end,
			create_if_absent = function() writes = writes + 1; return true end,
		}, { parse = function() return {} end }, {
			read_with_status = function()
				return nil, "error", "dangling final symlink"
			end,
		})
		editor.init("/virtual/dangling.toml", { PERSONAL_GROUP_NAME = "personal" }, function() end, 50)
		editor.open("menu")
		dispatch({ action = "save", data = { sections = {}, sections_order = {} } })
		helpers.assert_eq(writes, 0, "a dangling destination must authorize neither baseline nor save")
		package.loaded["ui.hotstring_editor"] = nil
	end)
end)

return true
