--- _shared/lua/test/script_binding_publication_contract.lua

--- ==============================================================================
--- MODULE: Script Binding Publication Contract
--- DESCRIPTION:
--- Pins the independent script identity vectors and actual native publication,
--- read/mark/setter and private-file preservation owners without hardware claims.
--- ==============================================================================

local M = {}
local SLOTS = {
	script_altgr_enter = true, script_altgr_backspace = true,
	script_altgr_delete = true, script_altgr_escape = true,
}

local function bytes(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a")); assert(file:close())
	return content
end

local function scope(body)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local previous_open, previous_hs = io.open, _G.hs
	local okay, detail = xpcall(body, debug.traceback)
	io.open, _G.hs = previous_open, previous_hs
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not okay then error(detail, 0) end
end

--- Registers actual native publication and configuration ownership controls.
--- @param helpers table Native registered test API.
--- @param driver string macos or linux.
function M.register(helpers, driver)
	local native = driver == "macos" and "infra.script_chord_catalogue" or "modules.shortcuts.script_chords"
	local policy = require("config_binding_identity")
	local function fresh_catalogue()
		package.loaded[native] = nil
		return require(native)
	end
	local function publish(owner)
		return driver == "macos" and owner.get() or owner.catalogue()
	end
	local function shared_file(relative)
		if driver == "macos" then return helpers.shared(relative) end
		return require("infra.paths").shared(relative)
	end
	local vectors = assert(require("json").decode(bytes(shared_file("tests/corpus/config_binding_identity/script_vectors.json"))))
	helpers.describe("script-binding: shared identity and native publication", function()
		for _, vector in ipairs(vectors) do
			local row = vector
			helpers.it(row.name, function()
				local fits = policy.script_binding_fits(row.binding, { prefix = "script__", slots = SLOTS })
				if row.expected == "unjudged" then helpers.assert_nil(fits) else helpers.assert_eq(fits, row.expected) end
				helpers.assert_nil(policy.script_binding_fits(row.binding, nil), "unpublished never proves retirement")
			end)
		end
		helpers.it("refuses malformed or empty published script receipts without judging another owner", function()
			for _, malformed in ipairs({ false, {}, { prefix = "keyboard__", slots = SLOTS },
				{ prefix = "script__", slots = {} }, { prefix = "script__", slots = { invalid = false } },
				{ prefix = "script__", slots = { ["nested__slot"] = true } } }) do
				local okay, detail = pcall(policy.script_binding_fits, "script__removed", malformed)
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "config_binding_identity: invalid published")
			end
		end)
		helpers.it("keeps the cold accessor effect-free and publishes detached actual source identities", function()
			scope(function()
				local owner = fresh_catalogue()
				local previous_open = io.open
				io.open = function() error("a pure accessor must not read") end
				helpers.assert_nil(owner.published_binding_catalogue())
				io.open = previous_open
				helpers.assert_true(type(publish(owner)) == "table")
				local received = owner.published_binding_catalogue()
				helpers.assert_eq(received, { prefix = "script__", slots = SLOTS })
				received.slots.script_altgr_enter = nil
				received.slots.removed_script_slot = true
				helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "script__", slots = SLOTS })
				owner._reset()
				helpers.assert_nil(owner.published_binding_catalogue())
			end)
		end)
		for _, invalid in ipairs({
			'{"slots":[],"paused_actions":["script_reload"]}',
			'{"slots":[{"id":"same","linux":28},{"id":"same","linux":14}],"paused_actions":["script_reload"]}',
			'{"slots":[{"id":"nested__slot","linux":28}],"paused_actions":["script_reload"]}',
		}) do
			local source = invalid
			helpers.it("refuses malformed native source before publishing: " .. source, function()
				scope(function()
					local owner = fresh_catalogue()
					local original_open, closes = io.open, 0
					io.open = function()
						return { read = function() return source end, close = function() closes = closes + 1; return true end }
					end
					local okay, detail = pcall(publish, owner)
					io.open = original_open
					helpers.assert_eq(okay, false)
					helpers.assert_true(tostring(detail):find("script chords:", 1, true) ~= nil
						or tostring(detail):find("config_binding_identity: invalid published", 1, true) ~= nil)
					helpers.assert_eq(closes, 1)
					helpers.assert_nil(owner.published_binding_catalogue())
					helpers.assert_true(type(publish(owner)) == "table")
					helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "script__", slots = SLOTS })
				end)
			end)
		end
		for _, failure in ipairs({ "read_throw", "read_nil", "read_false", "read_number", "close_throw", "close_nil", "close_false", "close_truthy" }) do
			local mode = failure
			helpers.it("does not publish after " .. mode .. " and retries the actual source", function()
				scope(function()
					local owner = fresh_catalogue()
					local source = bytes(shared_file("modules/actions/script_chords.json"))
					local original_open, closes = io.open, 0
					io.open = function()
						return {
							read = function()
								if mode == "read_throw" then error("controlled read failure") end
								if mode == "read_nil" then return nil end
								if mode == "read_false" then return false end
								if mode == "read_number" then return 1 end
								return source
							end,
							close = function()
								closes = closes + 1
								if mode == "close_throw" then error("controlled close failure") end
								if mode == "close_nil" then return nil end
								if mode == "close_false" then return false end
								if mode == "close_truthy" then return 1 end
								return true
							end,
						}
					end
					local okay, detail = pcall(publish, owner)
					io.open = original_open
					helpers.assert_eq(okay, false)
					helpers.assert_contains(tostring(detail), "cannot complete read")
					helpers.assert_eq(closes, 1, "failed read still retires its exact handle")
					helpers.assert_nil(owner.published_binding_catalogue())
					helpers.assert_true(type(publish(owner)) == "table")
					helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "script__", slots = SLOTS })
				end)
			end)
		end
	end)

	local function with_file(published, body)
		scope(function()
			local parameters, preferences, logger
			if driver == "macos" then
				package.loaded["modules.gestures"], package.loaded["modules.gestures.actions"] = nil, nil
				helpers.load_with_stubs("modules.gestures")
				parameters = require("modules.gestures.actions")
				logger = helpers.make_logger_stub()
				package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
				preferences = helpers.load_with_stubs("infra.preferences")
			else
				parameters = helpers.load_module("modules.gestures.manager")
				logger = require("logger.shim")
			end
			local warn, error_log = logger.warn, logger.error
			local warnings, errors = {}, {}
			logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
			local owner = driver == "macos" and require(native) or fresh_catalogue()
			owner._reset()
			if published then publish(owner) end
			local section = driver == "macos" and "gestures.action_parameters" or "gesture_parameters"
			local source = "# Independent complete file.\n[_meta]\nschema_version = 11\n[" .. section .. "]\n"
				.. 'script__removed_script_slot__open_url = "https://obsolete.example" # explicit cleanup owns this\n'
				.. 'script__script_altgr_enter__open_url = "https://current.example"\n'
				.. 'keyboard__future_unjudged__open_url = "https://unjudged.example"\n'
				.. '[future]\nnumber = 0.12345678901234566\nlarge = 9223372036854775807\n'
				.. 'when = 1979-05-27T07:32:00-08:00\n"literal.dot" = [[1], [2, 3]]\n'
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local okay, detail = xpcall(function()
				local state, marks, reports = {}, {}, nil
				local outdated = require("config_outdated"); outdated.reset_for_tests()
				if driver == "macos" then state = preferences.load(path)
				else parameters.init({ persist = true, config_path = path, enabled = false }) end
				local decoded, shapes = require("toml_codec.leaf_rows").decode_source(source)
				reports = outdated.collect_reports(function()
					local mark = function(...) marks[require("toml_codec.key_path").render({ ... })] = true end
					if driver == "macos" then preferences.mark_config_reads(decoded, mark, shapes)
					else parameters.mark_config_reads(decoded, mark) end
				end)
				body({ parameters = parameters, preferences = preferences, state = state, marks = marks,
					reports = reports, warnings = warnings, errors = errors, path = path, source = source, section = section,
					read = function() return bytes(path) end,
					save = function()
						return preferences.save(path, state, {}, { gestures = parameters })
					end,
				})
			end, debug.traceback)
			logger.warn, logger.error = warn, error_log
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end
	local function stored(f)
		if driver == "macos" then return f.state.gesture_action_parameters end
		return f.parameters.get_all_action_parameters()
	end
	helpers.describe("script-binding: actual source ownership", function()
		helpers.it("ignores a proven retired binding, leaves it unread and warns once", function()
			with_file(true, function(f)
				helpers.assert_nil(stored(f).script__removed_script_slot__open_url)
				helpers.assert_nil(f.marks[f.section .. ".script__removed_script_slot__open_url"])
				helpers.assert_eq(f.reports[f.section .. ".script__removed_script_slot__open_url"], true)
				helpers.assert_eq(#f.warnings, 1)
				helpers.assert_contains(f.warnings[1], f.section .. ".script__removed_script_slot__open_url")
				helpers.assert_contains(f.warnings[1], policy.RETIRED_SCRIPT)
				helpers.assert_eq(#f.errors, 0)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("retains current and other-owner entries without inventing judgments", function()
			with_file(true, function(f)
				helpers.assert_eq(stored(f).script__script_altgr_enter__open_url, "https://current.example")
				helpers.assert_eq(stored(f).keyboard__future_unjudged__open_url, "https://unjudged.example")
				helpers.assert_eq(f.marks[f.section .. ".script__script_altgr_enter__open_url"], true)
				helpers.assert_eq(f.marks[f.section .. ".keyboard__future_unjudged__open_url"], true)
			end)
		end)
		helpers.it("keeps unpublished script choices active, consumed and unmodified", function()
			with_file(false, function(f)
				helpers.assert_eq(stored(f).script__removed_script_slot__open_url, "https://obsolete.example")
				helpers.assert_eq(f.marks[f.section .. ".script__removed_script_slot__open_url"], true)
				helpers.assert_eq(#f.warnings, 0)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("refuses an ordinary retired setter before native publication", function()
			with_file(true, function(f)
				local before = f.parameters.get_all_action_parameters()
				helpers.assert_eq(f.parameters.set_action_parameter("script__removed_script_slot", "open_url", "https://must-not-write.example"), false)
				helpers.assert_eq(f.parameters.get_all_action_parameters(), before)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("keeps exact compensation snapshots independent of ordinary script admission", function()
			with_file(true, function(f)
				local inverse = { script__removed_script_slot__open_url = "https://inverse.example",
					script__script_altgr_enter__open_url = "https://current.example" }
				if driver == "macos" then
					helpers.assert_eq(f.parameters.replace_action_parameters(inverse), true)
				else
					local token = {}
					helpers.assert_eq(f.parameters.acquire_parameter_configuration(token), true)
					helpers.assert_eq(f.parameters.apply_parameter_configuration(token, inverse), true)
					helpers.assert_eq(f.parameters.parameter_configuration_snapshot(token), inverse)
					helpers.assert_eq(f.parameters.release_parameter_configuration(token), true)
				end
				helpers.assert_eq(f.parameters.get_all_action_parameters(), inverse)
				helpers.assert_eq(f.parameters.set_action_parameter("script__removed_script_slot", "open_url", "https://must-not-write.example"), false)
				helpers.assert_eq(f.parameters.get_all_action_parameters(), inverse)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("treats a withdrawn publication accessor as unjudged without lazy IO", function()
			with_file(true, function(f)
				local owner = require(native)
				local previous = owner.published_binding_catalogue
				owner.published_binding_catalogue = nil
				local okay, detail = pcall(function()
					helpers.assert_nil(f.parameters.action_parameter_binding_fits("script__removed_script_slot"))
					helpers.assert_eq(f.parameters.set_action_parameter("script__removed_script_slot", "open_url", "https://unjudged-new.example"), true)
				end)
				owner.published_binding_catalogue = previous
				if not okay then error(detail, 0) end
			end)
		end)
		helpers.it("preserves obsolete raw source and typed future neighbors during a current edit", function()
			with_file(true, function(f)
				if driver == "macos" then
					for key, value in pairs(stored(f)) do
						local binding, action = f.parameters.split_action_parameter_key(key)
						helpers.assert_eq(f.parameters.set_action_parameter(binding, action, value), true)
					end
				end
				helpers.assert_eq(f.parameters.set_action_parameter("script__script_altgr_enter", "open_url", "https://changed.example"), true)
				if driver == "macos" then helpers.assert_eq(f.save(), true) end
				local changed = f.read()
				helpers.assert_contains(changed, 'script__removed_script_slot__open_url = "https://obsolete.example" # explicit cleanup owns this')
				helpers.assert_contains(changed, f.source:match("(%[future%].*)"), "all future typed source bytes remain exact")
				local decoded = require("toml_codec").decode(changed)
				local parameters = driver == "macos" and decoded.gestures.action_parameters or decoded.gesture_parameters
				helpers.assert_eq(parameters, {
					script__removed_script_slot__open_url = "https://obsolete.example",
					script__script_altgr_enter__open_url = "https://changed.example",
					keyboard__future_unjudged__open_url = "https://unjudged.example",
				}, "complete handwritten preserved parameter model")
			end)
		end)
		for _, equality_spoof in ipairs({ false, true }) do
			local spoof = equality_spoof
			helpers.it("withdraws a replaced native publisher by raw identity, equality spoof=" .. tostring(spoof), function()
				with_file(true, function(f)
					local owner, equalities = require(native), 0
					local successor = { published_binding_catalogue = function() return nil end }
					if spoof then setmetatable(successor, { __eq = function() equalities = equalities + 1; return true end }) end
					package.loaded[native] = successor
					local open = io.open
					io.open = function() error("classification cannot lazily read or boot a successor") end
					local okay, detail = pcall(function()
						helpers.assert_nil(f.parameters.action_parameter_binding_fits("script__removed_script_slot"))
						package.loaded[native] = nil
						helpers.assert_nil(f.parameters.action_parameter_binding_fits("script__removed_script_slot"))
					end)
					io.open, package.loaded[native] = open, owner
					if not okay then error(detail, 0) end
					helpers.assert_eq(equalities, 0, "metamethods cannot authenticate a successor")
					helpers.assert_eq(f.parameters.action_parameter_binding_fits("script__removed_script_slot"), false,
						"restoring the exact published owner restores judgment")
					helpers.assert_eq(f.read(), f.source)
				end)
			end)
		end
	end)
end

return M
