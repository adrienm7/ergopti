--- _shared/lua/test/keyboard_binding_publication_contract.lua

--- ==============================================================================
--- MODULE: Keyboard Binding Publication Contract
--- DESCRIPTION:
--- Pins the independent keyboard identity vectors and actual native publication,
--- read/mark/setter and private-file preservation owners without hardware claims.
--- ==============================================================================

local M = {}

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

--- Registers the real native source and existing configuration consumer controls.
--- @param helpers table Registered native test API.
--- @param driver string macos or linux.
function M.register(helpers, driver)
	local native = "modules.shortcuts.keyboard_shortcuts"
	local policy = require("config_binding_identity")
	local known = driver == "macos" and "hs_ctrl_k" or "ctrl_k"
	local current = "keyboard__" .. known
	local current_key = current .. "__open_url"
	local retired = "keyboard__removed_keyboard_slot"
	local retired_key = retired .. "__open_url"
	local function fresh_catalogue()
		package.loaded[native] = nil
		return require(native)
	end
	local function publish(owner)
		return owner.available_slots(driver == "macos" and "hs_ctrl_" or "ctrl_")
	end
	local function with_file(published, body)
		scope(function()
			local parameters, preferences, logger
			if driver == "macos" then
				package.loaded["modules.gestures"], package.loaded["modules.gestures.actions"] = nil, nil
				helpers.load_with_stubs("modules.gestures")
				parameters = require("modules.gestures.actions")
				logger = assert(package.loaded["infra.logger"], "the actual Actions logger must be available")
				package.loaded["logger.shim"] = logger
				preferences = helpers.load_with_stubs("infra.preferences")
			else
				parameters = helpers.load_module("modules.gestures.manager")
				logger = require("logger.shim")
			end
			local warn, error_log = logger.warn, logger.error
			local warnings, errors = {}, {}
			logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
			local owner = fresh_catalogue()
			if published then publish(owner) end
			local section = driver == "macos" and "gestures.action_parameters" or "gesture_parameters"
			local source = "# Independent complete file.\n[_meta]\nschema_version = 11\n[" .. section .. "]\n"
				.. 'keyboard__removed_keyboard_slot__open_url = "https://obsolete.example" # explicit cleanup owns this\n'
				.. current_key .. ' = "https://current.example"\n'
				.. 'tap_hold__future_unjudged__open_url = "https://unjudged.example"\n'
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
				body({ owner = owner, parameters = parameters, preferences = preferences, state = state, marks = marks,
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
	local function shared_file(relative)
		if driver == "macos" then return helpers.shared(relative) end
		return require("infra.paths").shared(relative)
	end
	local vectors = assert(require("json").decode(bytes(shared_file("tests/corpus/config_binding_identity/keyboard_vectors.json"))))
	helpers.describe("keyboard-binding: shared complete identity contract", function()
		helpers.it("replays the independent handwritten keyboard identity vectors", function()
			helpers.assert_eq(#vectors.vectors, 17)
			local catalogue = policy.keyboard_binding_catalogue(vectors.ids)
			vectors.ids[1] = "changed_after_capture"
			helpers.assert_eq(catalogue.slots.ctrl_k, true)
			helpers.assert_nil(catalogue.slots.changed_after_capture)
			for _, vector in ipairs(vectors.vectors) do
				local fits = policy.keyboard_binding_fits(vector.binding, catalogue)
				local status = fits == nil and "unjudged" or (fits and "current" or "retired")
				helpers.assert_eq(status, vector.expected, vector.name)
				helpers.assert_nil(policy.keyboard_binding_fits(vector.binding), vector.name .. ": unavailable authority")
			end
			helpers.assert_eq(policy.RETIRED_KEYBOARD, "no keyboard shortcut slot of this build has this name")
		end)
		helpers.it("uses complete published exact identities and keeps other domains unjudged", function()
			local ids = { "ctrl_k", "super_shift_k", "alt_shift_k", "future_literal" }
			local catalogue = policy.keyboard_binding_catalogue(ids)
			ids[1] = "changed_after_capture"
			helpers.assert_eq(catalogue, { prefix = "keyboard__", slots = {
				ctrl_k = true, super_shift_k = true, alt_shift_k = true, future_literal = true,
			} }, "independent complete detached catalogue")
			for _, binding in ipairs({ "keyboard__ctrl_k", "keyboard__super_shift_k", "keyboard__alt_shift_k" }) do
				helpers.assert_eq(policy.keyboard_binding_fits(binding, catalogue), true)
			end
			helpers.assert_eq(policy.keyboard_binding_fits("keyboard__removed", catalogue), false)
			helpers.assert_eq(policy.keyboard_binding_fits("keyboard__Ctrl_k", catalogue), false)
			helpers.assert_nil(policy.keyboard_binding_fits("tap_key__removed", catalogue))
			helpers.assert_nil(policy.keyboard_binding_fits("Keyboard__ctrl_k", catalogue))
			helpers.assert_nil(policy.keyboard_binding_fits("keyboard__removed", nil))
		end)
		helpers.it("refuses empty sparse duplicate or disguised native inventories", function()
			for _, ids in ipairs({ {}, { [2] = "ctrl_k" }, { "ctrl_k", "ctrl_k" }, { "" }, { "nested__id" },
				{ true }, { [1] = "ctrl_k", named = "ctrl_j" }, setmetatable({ "ctrl_k" }, {}) }) do
				local okay, detail = pcall(policy.keyboard_binding_catalogue, ids)
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "invalid native keyboard catalogue")
			end
		end)
		helpers.it("refuses malformed published keyboard metadata rather than inferring retirement", function()
			for _, catalogue in ipairs({ false, {}, { prefix = "script__", slots = { ctrl_k = true } },
				{ prefix = "keyboard__", slots = {} }, { prefix = "keyboard__", slots = { ctrl_k = false } } }) do
				local okay, detail = pcall(policy.keyboard_binding_fits, retired, catalogue)
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "config_binding_identity: invalid published")
			end
		end)
	end)
	helpers.describe("keyboard-binding: actual source ownership", function()
		helpers.it("ignores only actual published retirement and warns once without reading its source leaf", function()
			with_file(true, function(f)
				helpers.assert_nil(stored(f)[retired_key])
				helpers.assert_nil(f.marks[f.section .. "." .. retired_key])
				helpers.assert_eq(f.reports[f.section .. "." .. retired_key], true)
				helpers.assert_eq(#f.warnings, 1)
				helpers.assert_contains(f.warnings[1], f.section .. "." .. retired_key)
				helpers.assert_contains(f.warnings[1], policy.RETIRED_KEYBOARD)
				helpers.assert_eq(#f.errors, 0)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("retains actual current and other qualified domains", function()
			with_file(true, function(f)
				helpers.assert_eq(stored(f)[current_key], "https://current.example")
				helpers.assert_eq(stored(f).tap_hold__future_unjudged__open_url, "https://unjudged.example")
				helpers.assert_eq(f.parameters.action_parameter_binding_fits(current), true)
				helpers.assert_nil(f.parameters.action_parameter_binding_fits("tap_hold__future_unjudged"))
				helpers.assert_eq(f.marks[f.section .. "." .. current_key], true)
				helpers.assert_eq(f.marks[f.section .. ".tap_hold__future_unjudged__open_url"], true)
				helpers.assert_nil(f.reports[f.section .. "." .. current_key])
			end)
		end)
		helpers.it("does not invent retirement before a genuine source publication", function()
			with_file(false, function(f)
				helpers.assert_nil(f.owner.published_binding_catalogue())
				helpers.assert_nil(f.parameters.action_parameter_binding_fits(retired))
				helpers.assert_eq(stored(f)[retired_key], "https://obsolete.example")
				helpers.assert_eq(f.marks[f.section .. "." .. retired_key], true)
				helpers.assert_nil(f.reports[f.section .. "." .. retired_key])
				helpers.assert_eq(#f.warnings, 0)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("refuses retired ordinary setters before writing and preserves detached inverse records", function()
			with_file(true, function(f)
				helpers.assert_eq(f.parameters.set_action_parameter(retired, "open_url", "https://must-not-publish.example"), false)
				helpers.assert_eq(f.read(), f.source)
				helpers.assert_eq(f.parameters.get_action_parameter(retired, "open_url"), "")
				local exact = { [retired_key] = "https://inverse.example", [current_key] = "https://current.example" }
				if driver == "macos" then
					helpers.assert_eq(f.parameters.replace_action_parameters(exact), true)
				else
					local token = {}
					helpers.assert_eq(f.parameters.acquire_parameter_configuration(token), true)
					helpers.assert_eq(f.parameters.apply_parameter_configuration(token, exact), true)
					helpers.assert_eq(f.parameters.parameter_configuration_snapshot(token), exact)
					helpers.assert_eq(f.parameters.release_parameter_configuration(token), true)
				end
				helpers.assert_eq(f.parameters.get_all_action_parameters(), exact)
				helpers.assert_eq(f.parameters.get_action_parameter(retired, "open_url"), "")
				helpers.assert_eq(f.parameters.set_action_parameter(retired, "open_url", "https://must-not-publish.example"), false)
				helpers.assert_eq(f.parameters.get_all_action_parameters(), exact)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("preserves the complete handwritten obsolete and typed future model on a current edit", function()
			with_file(true, function(f)
				if driver == "macos" then
					for key, value in pairs(stored(f)) do
						local binding, action = f.parameters.split_action_parameter_key(key)
						helpers.assert_eq(f.parameters.set_action_parameter(binding, action, value), true)
					end
				end
				helpers.assert_eq(f.parameters.set_action_parameter(current, "open_url", "https://changed.example"), true)
				if driver == "macos" then helpers.assert_eq(f.save(), true) end
				local changed = f.read()
				helpers.assert_contains(changed, retired_key .. ' = "https://obsolete.example" # explicit cleanup owns this')
				helpers.assert_contains(changed, f.source:match("(%[future%].*)"))
				local decoded = require("toml_codec").decode(changed)
				helpers.assert_eq(driver == "macos" and decoded.gestures.action_parameters or decoded.gesture_parameters, {
					[retired_key] = "https://obsolete.example", [current_key] = "https://changed.example",
					tap_hold__future_unjudged__open_url = "https://unjudged.example",
				}, "independent complete persisted parameter model")
			end)
		end)
		helpers.it("neutralizes a carried retired parameter after actual late publication without mutating RAM or source", function()
			with_file(false, function(f)
				if driver == "macos" then
					for key, value in pairs(stored(f)) do
						local binding, action = f.parameters.split_action_parameter_key(key)
						helpers.assert_eq(f.parameters.set_action_parameter(binding, action, value), true)
					end
				end
				helpers.assert_eq(f.parameters.get_action_parameter(retired, "open_url"), "https://obsolete.example")
				publish(f.owner)
				helpers.assert_eq(f.parameters.get_action_parameter(retired, "open_url"), "")
				helpers.assert_eq(f.parameters.get_action_parameter(retired, "open_url"), "")
				helpers.assert_eq(#f.warnings, 1)
				helpers.assert_eq(f.parameters.get_action_parameter(current, "open_url"), "https://current.example")
				helpers.assert_eq(stored(f)[retired_key], "https://obsolete.example", "exact compensation source remains carried")
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		for _, equality_spoof in ipairs({ false, true }) do
			local spoof = equality_spoof
			helpers.it("withdraws inherited publication on a distinct current owner, equality spoof=" .. tostring(spoof), function()
				with_file(true, function(f)
					local owner, equalities = f.owner, 0
					local meta = { __index = owner }
					if spoof then meta.__eq = function() equalities = equalities + 1; return true end end
					package.loaded[native] = setmetatable({}, meta)
					local open = io.open
					io.open = function() error("classification cannot read or initialize a successor") end
					local okay, detail = pcall(function()
						helpers.assert_nil(f.parameters.action_parameter_binding_fits(retired))
					end)
					io.open, package.loaded[native] = open, owner
					if not okay then error(detail, 0) end
					helpers.assert_eq(equalities, 0)
					helpers.assert_eq(f.parameters.action_parameter_binding_fits(retired), false)
					helpers.assert_eq(f.parameters.action_parameter_binding_fits(current), true)
					helpers.assert_eq(f.read(), f.source)
				end)
			end)
		end

		helpers.it("withdraws a public getter replacement without invoking fabricated authority", function()
			with_file(true, function(f)
				local owner, calls = f.owner, 0
				local original, open = owner.published_binding_catalogue, io.open
				owner.published_binding_catalogue = function()
					calls = calls + 1
					return { prefix = "keyboard__", slots = { counterfeit = true } }
				end
				io.open = function() error("method withdrawal cannot load another catalogue") end
				local okay, detail = pcall(function()
					helpers.assert_nil(f.parameters.action_parameter_binding_fits(current))
					helpers.assert_nil(f.parameters.action_parameter_binding_fits(retired))
					helpers.assert_nil(original(), "the genuine getter itself admits only its current public identity")
				end)
				io.open, owner.published_binding_catalogue = open, original
				if not okay then error(detail, 0) end
				helpers.assert_eq(calls, 0, "a fabricated getter is never invoked")
				helpers.assert_eq(f.parameters.action_parameter_binding_fits(current), true)
				helpers.assert_eq(f.parameters.action_parameter_binding_fits(retired), false)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("never accepts a fabricated registered successor without genuine native construction", function()
			with_file(true, function(f)
				local owner, calls = f.owner, 0
				package.loaded[native] = { published_binding_catalogue = function()
					calls = calls + 1
					return { prefix = "keyboard__", slots = { counterfeit = true } }
				end }
				local okay, detail = pcall(function()
					helpers.assert_nil(f.parameters.action_parameter_binding_fits(current))
					helpers.assert_nil(f.parameters.action_parameter_binding_fits(retired))
				end)
				package.loaded[native] = owner
				if not okay then error(detail, 0) end
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(f.parameters.action_parameter_binding_fits(current), true)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("refuses replacement registrations before changing genuine callback authority", function()
			with_file(true, function(f)
				local publication = require("config_keyboard_publication")
				local calls = 0
				local fake = function() calls = calls + 1; return { prefix = "keyboard__", slots = { counterfeit = true } } end
				local okay, detail = pcall(publication.register, f.owner, fake)
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "invalid or repeated native registration")
				local other = { published_binding_catalogue = fake }
				okay, detail = pcall(publication.register, other, fake)
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "another native owner is registered")
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(f.parameters.action_parameter_binding_fits(current), true)
				helpers.assert_eq(f.parameters.action_parameter_binding_fits(retired), false)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
	end)
end

return M
