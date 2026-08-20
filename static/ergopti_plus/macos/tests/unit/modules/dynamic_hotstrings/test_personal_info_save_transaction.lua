--- tests/unit/modules/dynamic_hotstrings/test_personal_info_save_transaction.lua

--- ==============================================================================
--- MODULE: Personal Information Save Transaction Regression
--- DESCRIPTION:
--- Exercises the real personal-information save path across its preview fence,
--- canonical filesystem commit, live table publication, and editor callback. A rejected
--- transition must preserve the old in-memory and on-disk value, while the UI
--- remains open so the user can retry without losing the submitted form.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Transaction Test Tools =======
-- =========================================
-- =========================================

--- Reads a complete test file.
--- @param path string File path.
--- @return string content File contents.
local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

--- Runs cleanup even when the behavioral assertions fail.
--- @param callback function Test body.
--- @param cleanup function Cleanup body.
local function with_cleanup(callback, cleanup)
	local ok, err = xpcall(callback, debug.traceback)
	local cleanup_ok, cleanup_err = xpcall(cleanup, debug.traceback)
	if not ok then error(err, 0) end
	if not cleanup_ok then error(cleanup_err, 0) end
end

--- Runs one callback while selected adapter methods are replaced.
--- @param adapter table Adapter table captured by the module under test.
--- @param replacements table Replacement functions keyed by method name.
--- @param callback function Protected operation.
--- @return any result Callback result.
local function with_adapter_overrides(adapter, replacements, callback)
	local originals = {}
	for name, replacement in pairs(replacements) do
		originals[name] = adapter[name]
		adapter[name] = replacement
	end
	local ok, result = xpcall(callback, debug.traceback)
	for name, original in pairs(originals) do adapter[name] = original end
	if not ok then error(result, 0) end
	return result
end

--- Loads a fresh PersonalInfo instance with a controlled preview fence.
--- @param config_path string Existing personal_info.toml path.
--- @param logs string[] Captured privacy-safe diagnostic lines.
--- @return table personal_info Real module instance.
--- @return table fence Mutable fence state.
local function load_personal_info(config_path, logs)
	local previous_logger = package.loaded["infra.logger"]
	local Logger = helpers.make_logger_stub()
	local function capture(_log, format_string, ...)
		logs[#logs + 1] = string.format(format_string, ...)
	end
	Logger.warn = capture
	Logger.error = capture
	package.loaded["infra.logger"] = Logger
	package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
	local personal_info = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")
	package.loaded["infra.logger"] = previous_logger
	local fence = { allow = false, calls = 0, raises = false }
	local keymap = {
		get_trigger_char = function() return "★" end,
		register_interceptor = function() end,
		register_preview_provider = function() end,
		invalidate_hotstring_preview = function()
			fence.calls = fence.calls + 1
			if fence.raises then error(tostring(fence.raises), 0) end
			return fence.allow
		end,
	}
	personal_info.start("", keymap, config_path)
	return personal_info, fence
end

--- Loads the real editor with observable native-window test doubles.
--- @return table editor Real editor module.
--- @return function dispatch Sends one usercontent message.
--- @return table state Observable window and log counters.
local function load_editor()
	local hs_stub = require("tests.stubs.hs")
	local dispatch
	local state = { deletes = 0, focuses = 0, errors = {} }

	hs_stub.webview.windowMasks = { titled = 1, closable = 2 }
	hs_stub.webview.usercontent.new = function()
		return {
			setCallback = function(_, callback)
				dispatch = callback
			end,
		}
	end
	hs_stub.screen = {
		mainScreen = function()
			return { frame = function() return { w = 1440, h = 900 } end }
		end,
	}
	_G.hs = hs_stub

	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		error = function(_, message)
			state.errors[#state.errors + 1] = tostring(message)
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.paths"] = { shared = function() return "/shared/personal_info_editor" end }
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 800, height = 700 } end,
		get_centered_frame = function(width, height) return { w = width, h = height } end,
		force_focus = function() state.focuses = state.focuses + 1 end,
		show_webview = function()
			return {
				delete = function() state.deletes = state.deletes + 1 end,
			}
		end,
	}
	package.loaded["ui.personal_info_editor"] = nil
	local editor = require("ui.personal_info_editor")
	return editor, function(message)
		helpers.assert_type(dispatch, "function", "the editor must install its real usercontent callback")
		dispatch({ body = message })
	end, state, function()
		package.loaded["ui.personal_info_editor"] = nil
		package.loaded["ui.ui_builder"] = nil
		helpers.load_with_stubs("infra.logger")
	end
end





-- ===================================================
-- ===================================================
-- ======= 2/ Personal Information Save Commit =======
-- ===================================================
-- ===================================================

helpers.describe("PersonalInfo.save_info transaction (personal-info-save-commit-gate)", function()
	helpers.it("publishes neither memory nor disk until preview revocation and filesystem commit", function()
		local config_path = os.tmpname()
		with_cleanup(function()
			local private_sentinel = "PRIVATE-IBAN-SENTINEL"
			local logs = {}
			local initial = "[info]\nfirst_name = \"Alice\"\n\n[letters]\np = \"first_name\"\n"
			local file = assert(io.open(config_path, "wb"))
			assert(file:write(initial))
			assert(file:close())

			local personal_info, fence = load_personal_info(config_path, logs)
			local file_system = require("adapters.file_system")
			local live_info = personal_info.get_info()
			helpers.assert_eq(live_info.first_name, "Alice")

			local fence_result = personal_info.save_info({ first_name = "Bob" })
			helpers.assert_eq(fence_result, false,
				"a rejected preview revocation must reject the entire save")
			helpers.assert_true(personal_info.get_info() == live_info,
				"a rejected save must preserve the published table identity")
			helpers.assert_eq(live_info.first_name, "Alice",
				"a rejected save must preserve the old live expansion value")
			helpers.assert_eq(read_file(config_path), initial,
				"a rejected save must not touch the committed TOML")

			fence.allow = "truthy"
			helpers.assert_eq(personal_info.save_info({ first_name = "Bob" }), false,
				"a truthy non-boolean fence result must not authorize publication")
			helpers.assert_eq(read_file(config_path), initial,
				"a non-boolean fence result must preserve the committed TOML")

			fence.raises = private_sentinel
			helpers.assert_eq(personal_info.save_info({ first_name = "Bob" }), false,
				"a throwing preview fence must become an exact rejected save")
			helpers.assert_eq(live_info.first_name, "Alice",
				"a throwing preview fence must preserve the old live expansion value")
			helpers.assert_eq(read_file(config_path), initial,
				"a throwing preview fence must preserve the committed TOML")
			helpers.assert_true(not table.concat(logs, "\n"):find(private_sentinel, 1, true),
				"a preview exception may contain personal data and must stay out of logs")
			fence.raises = false

			fence.allow = true
			local writes = 0
			local rename_result = with_adapter_overrides(file_system, {
				write_if_unchanged = function(path, content, expected_source)
					writes = writes + 1
					helpers.assert_eq(path, config_path,
						"the rejected publication must target the configured TOML")
					helpers.assert_true(content:find('first_name = "Bob"', 1, true) ~= nil,
						"the rejected publication must receive the complete candidate")
					helpers.assert_eq(expected_source.content, initial,
						"the rejected publication must compare against the exact loaded bytes")
					return false, private_sentinel
				end,
			},
				function() return personal_info.save_info({ first_name = "Bob" }) end)
			helpers.assert_eq(rename_result, false,
				"a failed atomic publication must reject the entire save")
			helpers.assert_eq(writes, 1,
				"one save attempt must cross the filesystem publication boundary once")
			helpers.assert_eq(live_info.first_name, "Alice",
				"a publication failure must not publish the candidate in memory")
			helpers.assert_eq(read_file(config_path), initial,
				"a publication failure must preserve the previous committed TOML")
			helpers.assert_true(not table.concat(logs, "\n"):find(private_sentinel, 1, true),
				"a filesystem failure may contain personal data and must stay out of logs")

			local successful_writes = 0
			local committed = with_adapter_overrides(file_system, {
				write_if_unchanged = function(path, content, expected_source)
					successful_writes = successful_writes + 1
					helpers.assert_eq(path, config_path,
						"the accepted publication must target the configured TOML")
					helpers.assert_true(content:find('first_name = "Bob"', 1, true) ~= nil,
						"the filesystem port must receive the complete candidate")
					helpers.assert_eq(read_file(path), initial,
						"the old committed TOML must remain intact until the port accepts publication")
					helpers.assert_eq(expected_source.content, initial,
						"the accepted publication must compare against the exact loaded bytes")
					local target = assert(io.open(path, "wb"))
					assert(target:write(content))
					assert(target:close())
					return true
				end,
			},
				function() return personal_info.save_info({ first_name = "Bob" }) end)
			helpers.assert_eq(committed, true, "a complete transaction must report an exact commit")
			helpers.assert_eq(successful_writes, 1,
				"one accepted save must cross the filesystem publication boundary once")
			helpers.assert_true(personal_info.get_info() == live_info,
				"a successful save must preserve the shared live-table identity")
			helpers.assert_eq(live_info.first_name, "Bob",
				"memory must publish the candidate only after the file commit")
			helpers.assert_true(read_file(config_path):find('first_name = "Bob"', 1, true) ~= nil,
				"the committed TOML must contain the accepted candidate")
			helpers.assert_eq(fence.calls, 5, "every valid save attempt must cross the preview fence")
		end, function()
			os.remove(config_path)
			package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		end)
	end)

	helpers.it("preserves and adopts an external edit that wins after the loaded snapshot", function()
		local config_path = os.tmpname()
		with_cleanup(function()
			local initial = "[info]\nfirst_name = \"Alice\"\n\n[letters]\np = \"first_name\"\n"
			local external = "[info]\nfirst_name = \"Carol\"\n\n[letters]\np = \"first_name\"\n"
			local file = assert(io.open(config_path, "wb"))
			assert(file:write(initial))
			assert(file:close())

			local personal_info, fence = load_personal_info(config_path, {})
			local file_system = require("adapters.file_system")
			local live_info = personal_info.get_info()
			local publications = 0
			fence.allow = true

			local committed = with_adapter_overrides(file_system, {
				-- The old implementation crossed this unconditional boundary and
				-- overwrote the just-landed external version. Keeping this seam makes
				-- the regression test fail causally on that implementation.
				write = function(path, content)
					publications = publications + 1
					local competitor = assert(io.open(path, "wb"))
					assert(competitor:write(external))
					assert(competitor:close())
					local stale = assert(io.open(path, "wb"))
					assert(stale:write(content))
					assert(stale:close())
					return true
				end,
				write_if_unchanged = function(path, _content, expected_source)
					publications = publications + 1
					helpers.assert_eq(path, config_path,
						"conditional publication must target the loaded personal-info file")
					helpers.assert_eq(expected_source.status, "ok",
						"the save must carry an exact existing-source classification")
					helpers.assert_eq(expected_source.content, initial,
						"the exact loaded bytes must cross the publication boundary")
					local competitor = assert(io.open(path, "wb"))
					assert(competitor:write(external))
					assert(competitor:close())
					return false, "source changed"
				end,
			}, function()
				return personal_info.save_info({ first_name = "Bob" })
			end)

			helpers.assert_eq(committed, false,
				"a stale editor candidate must be rejected after an external edit")
			helpers.assert_eq(publications, 1,
				"one save attempt must cross exactly one publication boundary")
			helpers.assert_eq(read_file(config_path), external,
				"the external winner must survive byte-for-byte")
			helpers.assert_true(personal_info.get_info() == live_info,
				"adopting the winner must preserve the shared live-table identity")
			helpers.assert_eq(live_info.first_name, "Carol",
				"the live expansion source must adopt the validated external winner")
		end, function()
			os.remove(config_path)
			package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		end)
	end)

	helpers.it("fails closed when an existing configuration cannot be read", function()
		local config_path = os.tmpname()
		with_cleanup(function()
			local private_sentinel = "PRIVATE-EXISTING-CONFIG-SENTINEL"
			local read_failure = "PRIVATE-READ-FAILURE"
			local file = assert(io.open(config_path, "wb"))
			assert(file:write(private_sentinel))
			assert(file:close())

			local logs = {}
			local Logger = helpers.make_logger_stub()
			Logger.warn = function(_log, format_string, ...)
				logs[#logs + 1] = string.format(format_string, ...)
			end
			Logger.error = Logger.warn
			package.loaded["infra.logger"] = Logger
			package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
			local personal_info = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")
			local file_system = require("adapters.file_system")
			local registrations = 0
			local publications = 0
			local keymap = {
				get_trigger_char = function() return "★" end,
				register_interceptor = function() registrations = registrations + 1 end,
				register_preview_provider = function() registrations = registrations + 1 end,
			}

			local started = with_adapter_overrides(file_system, {
				read_with_status = function(path)
					helpers.assert_eq(path, config_path,
						"startup must classify the configured personal-info path")
					return nil, "error", read_failure
				end,
				create_if_absent = function()
					publications = publications + 1
					return true, "created"
				end,
			}, function()
				return personal_info.start("", keymap, config_path)
			end)

			helpers.assert_eq(started, false,
				"an existing-but-unreadable configuration must fail startup closed")
			helpers.assert_eq(registrations, 0,
				"failed configuration ownership must publish no keyboard callback")
			helpers.assert_eq(publications, 0,
				"an unreadable existing configuration must never reach publication")
			helpers.assert_eq(read_file(config_path), private_sentinel,
				"read failure must preserve the user's exact committed bytes")
			helpers.assert_true(not table.concat(logs, "\n"):find(read_failure, 1, true),
				"the read failure may contain personal data and must stay out of logs")
		end, function()
			os.remove(config_path)
			package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		end)
	end)

	helpers.it("requires exact default-file publication before registering callbacks", function()
		local config_path = os.tmpname()
		os.remove(config_path)
		with_cleanup(function()
			local write_failure = "PRIVATE-DEFAULT-WRITE-FAILURE"
			local logs = {}
			local Logger = helpers.make_logger_stub()
			Logger.warn = function(_log, format_string, ...)
				logs[#logs + 1] = string.format(format_string, ...)
			end
			Logger.error = Logger.warn
			package.loaded["infra.logger"] = Logger
			package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
			local personal_info = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")
			local file_system = require("adapters.file_system")
			local registrations = 0
			local publications = 0
			local keymap = {
				get_trigger_char = function() return "★" end,
				register_interceptor = function() registrations = registrations + 1 end,
				register_preview_provider = function() registrations = registrations + 1 end,
			}

			local started = with_adapter_overrides(file_system, {
				read_with_status = function(path)
					helpers.assert_eq(path, config_path,
						"startup must classify the configured personal-info path")
					return nil, "absent"
				end,
				create_if_absent = function(path, content)
					publications = publications + 1
					helpers.assert_eq(path, config_path,
						"default publication must target the configured TOML")
					helpers.assert_true(content:find("[info]", 1, true) ~= nil,
						"default publication must receive the complete configuration")
					return false, "error", write_failure
				end,
			}, function()
				return personal_info.start("", keymap, config_path)
			end)

			helpers.assert_eq(started, false,
				"a missing config is not initialized until default publication commits")
			helpers.assert_eq(registrations, 0,
				"a failed default publication must publish no keyboard callback")
			helpers.assert_eq(publications, 1,
				"a missing configuration must attempt exactly one create-only publication")
			helpers.assert_eq(io.open(config_path, "rb"), nil,
				"failed default publication must not create a committed config")
			helpers.assert_true(not table.concat(logs, "\n"):find(write_failure, 1, true),
				"the write failure may contain personal data and must stay out of logs")
		end, function()
			os.remove(config_path)
			package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Editor Save Commit Feedback =======
-- ==============================================
-- ==============================================

helpers.describe("Personal information editor save result (personal-info-editor-retry)", function()
	helpers.it("keeps the same editor open when the save callback refuses the commit", function()
		local editor, dispatch, state, cleanup = load_editor()
		with_cleanup(function()
			editor.open({}, function() return false end)
			dispatch({ action = "save", values = { first_name = "Bob" } })

			helpers.assert_eq(state.deletes, 0,
				"a rejected save must not delete the editor and discard the user's form")
			helpers.assert_true(#state.errors > 0,
				"a rejected save must leave a developer-visible diagnostic")

			editor.open({}, function() return "truthy" end)
			dispatch({ action = "save", values = { first_name = "Bob" } })
			helpers.assert_eq(state.deletes, 0,
				"a truthy non-boolean callback result must not close the editor")

			editor.open({}, function() error("simulated save callback crash") end)
			dispatch({ action = "save", values = { first_name = "Bob" } })
			helpers.assert_eq(state.deletes, 0,
				"a throwing save callback must not escape or close the editor")

			editor.open({}, function() return true end)
			helpers.assert_eq(state.focuses, 3,
				"reopening after rejected saves must focus the retained singleton")
			dispatch({ action = "save", values = { first_name = "Bob" } })
			helpers.assert_eq(state.deletes, 1,
				"the editor may close only after the callback reports an exact commit")
		end, cleanup)
	end)
end)

return true
