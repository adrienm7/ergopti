--- _shared/lua/test/tap_binding_publication_contract.lua

--- ==============================================================================
--- MODULE: Tap-Key Binding Publication Contract
--- DESCRIPTION:
--- Pins the independent tap-key identity vectors and actual native publication,
--- read/mark/setter and private-file preservation owners without hardware claims.
--- ==============================================================================

local M = {}
local SLOTS = {
	number_row_left = true, number_row_right_1 = true, number_row_right_2 = true,
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
	local native = "modules.shortcuts.tap_keys"
	local policy = require("config_binding_identity")
	local function fresh_catalogue()
		package.loaded[native] = nil
		return require(native)
	end
	local function publish(owner)
		return owner.keys()
	end
	local function shared_file(relative)
		if driver == "macos" then return helpers.shared(relative) end
		return require("infra.paths").shared(relative)
	end
	local vectors = assert(require("json").decode(bytes(shared_file("tests/corpus/config_binding_identity/tap_vectors.json"))))
	helpers.describe("tap-binding: shared identity and native publication", function()
		for _, vector in ipairs(vectors) do
			local row = vector
			helpers.it(row.name, function()
				local fits = policy.tap_binding_fits(row.binding, { prefix = "tap_key__", slots = SLOTS })
				if row.expected == "unjudged" then helpers.assert_nil(fits) else helpers.assert_eq(fits, row.expected) end
				helpers.assert_nil(policy.tap_binding_fits(row.binding, nil), "unpublished never proves retirement")
			end)
		end
		helpers.it("refuses malformed or empty published tap-key receipts without judging another owner", function()
			for _, malformed in ipairs({ false, {}, { prefix = "keyboard__", slots = SLOTS },
				{ prefix = "tap_key__", slots = {} }, { prefix = "tap_key__", slots = { invalid = false } },
				{ prefix = "tap_key__", slots = { ["nested__slot"] = true } } }) do
				local okay, detail = pcall(policy.tap_binding_fits, "tap_key__removed", malformed)
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
				helpers.assert_eq(received, { prefix = "tap_key__", slots = SLOTS })
				received.slots.number_row_left = nil
				received.slots.removed_tap_key = true
				helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "tap_key__", slots = SLOTS })
				owner._reset()
				helpers.assert_nil(owner.published_binding_catalogue())
			end)
		end)
		helpers.it("withdraws a changed native key census without reads and restores exact source", function()
			scope(function()
				local owner = fresh_catalogue()
				local keys = publish(owner)
				local original = keys[1].id
				keys[1].id = "foreign_valid_key"
				local original_open = io.open
				io.open = function() error("a pure census must not read") end
				local okay, detail = pcall(function() helpers.assert_nil(owner.published_binding_catalogue()) end)
				io.open = original_open
				keys[1].id = original
				if not okay then error(detail, 0) end
				helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "tap_key__", slots = SLOTS })
			end)
		end)
		helpers.it("refuses forged metatable and sparse native identity projections", function()
			for _, keys in ipairs({ { [2] = { id = "slot" } }, { { id = "same" }, { id = "same" } },
				setmetatable({ { id = "slot" } }, { __pairs = function() error("forged enumeration ran") end }),
				{ setmetatable({}, { __index = { id = "slot" } }) } }) do
				local okay, detail = pcall(policy.tap_binding_catalogue, keys)
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "invalid native tap-key catalogue")
			end
			helpers.assert_eq(policy.tap_binding_catalogue({ { id = "one" }, { id = "two" } }),
				{ prefix = "tap_key__", slots = { one = true, two = true } })
		end)
		for _, invalid in ipairs({
			'{"keys":[]}',
			'{"keys":[{"id":"same","hs":[50],"linux":41},{"id":"same","hs":[27],"linux":12}]}',
			'{"keys":[{"id":"nested__slot","hs":[50],"linux":41}]}',
		}) do
			local source = invalid
			helpers.it("refuses malformed actual native source before publishing: " .. source, function()
				scope(function()
					local owner = fresh_catalogue()
					local original_open, closes = io.open, 0
					io.open = function()
						return { read = function() return source end, close = function() closes = closes + 1; return true end }
					end
					local okay, detail = pcall(publish, owner)
					io.open = original_open
					helpers.assert_eq(okay, false)
					helpers.assert_true(tostring(detail):find("tap_keys:", 1, true) ~= nil
						or tostring(detail):find("config_binding_identity: invalid", 1, true) ~= nil)
					helpers.assert_eq(closes, 1)
					helpers.assert_nil(owner.published_binding_catalogue())
					helpers.assert_true(type(publish(owner)) == "table")
				end)
			end)
		end
		helpers.it("refuses an actual duplicate-ID file and publishes only after manual repair", function()
			scope(function()
				local owner = fresh_catalogue()
				local paths = require("infra.paths")
				local original_shared = paths.shared
				local path = os.tmpname()
				local invalid = '{"keys":[{"id":"same","hs":[50],"linux":41},{"id":"same","hs":[27],"linux":12}]}'
				local file = assert(io.open(path, "wb")); assert(file:write(invalid)); assert(file:close())
				paths.shared = function(relative)
					if relative == "modules/actions/tap_keys.json" then return path end
					return original_shared(relative)
				end
				local okay, detail = pcall(function()
					local admitted, reason = pcall(publish, owner)
					helpers.assert_eq(admitted, false)
					helpers.assert_contains(tostring(reason), "invalid native tap-key catalogue")
					helpers.assert_nil(owner.published_binding_catalogue())
					helpers.assert_eq(bytes(path), invalid, "classification never repairs the actual source")
					local actual = bytes(original_shared("modules/actions/tap_keys.json"))
					file = assert(io.open(path, "wb")); assert(file:write(actual)); assert(file:close())
					publish(owner)
					helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "tap_key__", slots = SLOTS })
					helpers.assert_eq(bytes(path), actual)
				end)
				paths.shared = original_shared
				os.remove(path)
				if not okay then error(detail, 0) end
			end)
		end)
		for _, failure in ipairs({ "read_throw", "read_nil", "read_false", "read_number", "close_throw", "close_nil", "close_false", "close_truthy" }) do
			local mode = failure
			helpers.it("does not publish after " .. mode .. " and retries the actual source", function()
				scope(function()
					local owner = fresh_catalogue()
					local source = bytes(shared_file("modules/actions/tap_keys.json"))
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
					helpers.assert_true(tostring(detail):find("cannot complete read", 1, true) ~= nil
						or tostring(detail):find("unreadable or malformed", 1, true) ~= nil)
					helpers.assert_eq(closes, 1, "failed read still retires its exact handle")
					helpers.assert_nil(owner.published_binding_catalogue())
					helpers.assert_true(type(publish(owner)) == "table")
					helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "tap_key__", slots = SLOTS })
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
			local owner = driver == "macos" and require(native) or fresh_catalogue()
			owner._reset()
			if published then publish(owner) end
			local section = driver == "macos" and "gestures.action_parameters" or "gesture_parameters"
			local source = "# Independent complete file.\n[_meta]\nschema_version = 11\n[" .. section .. "]\n"
				.. 'tap_key__removed_tap_key__open_url = "https://obsolete.example" # explicit cleanup owns this\n'
				.. 'tap_key__number_row_left__open_url = "https://current.example"\n'
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
	helpers.describe("tap-binding: actual source ownership", function()
		helpers.it("ignores a proven retired binding, leaves it unread and warns once", function()
			with_file(true, function(f)
				helpers.assert_nil(stored(f).tap_key__removed_tap_key__open_url)
				helpers.assert_nil(f.marks[f.section .. ".tap_key__removed_tap_key__open_url"])
				helpers.assert_eq(f.reports[f.section .. ".tap_key__removed_tap_key__open_url"], true)
				helpers.assert_eq(#f.warnings, 1)
				helpers.assert_contains(f.warnings[1], f.section .. ".tap_key__removed_tap_key__open_url")
				helpers.assert_contains(f.warnings[1], policy.RETIRED_TAP)
				helpers.assert_eq(#f.errors, 0)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("retains current and other-owner entries without inventing judgments", function()
			with_file(true, function(f)
				helpers.assert_eq(stored(f).tap_key__number_row_left__open_url, "https://current.example")
				helpers.assert_eq(stored(f).tap_hold__future_unjudged__open_url, "https://unjudged.example")
				helpers.assert_eq(f.marks[f.section .. ".tap_key__number_row_left__open_url"], true)
				helpers.assert_eq(f.marks[f.section .. ".tap_hold__future_unjudged__open_url"], true)
			end)
		end)
		helpers.it("keeps unpublished tap-key choices active, consumed and unmodified", function()
			with_file(false, function(f)
				helpers.assert_eq(stored(f).tap_key__removed_tap_key__open_url, "https://obsolete.example")
				helpers.assert_eq(f.marks[f.section .. ".tap_key__removed_tap_key__open_url"], true)
				helpers.assert_eq(#f.warnings, 0)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("refuses an ordinary retired setter before native publication", function()
			with_file(true, function(f)
				local before = f.parameters.get_all_action_parameters()
				helpers.assert_eq(f.parameters.set_action_parameter("tap_key__removed_tap_key", "open_url", "https://must-not-write.example"), false)
				helpers.assert_eq(f.parameters.get_all_action_parameters(), before)
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
		helpers.it("keeps exact compensation snapshots independent of ordinary tap-key admission", function()
			with_file(true, function(f)
				local inverse = { tap_key__removed_tap_key__open_url = "https://inverse.example",
					tap_key__number_row_left__open_url = "https://current.example" }
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
				helpers.assert_eq(f.parameters.set_action_parameter("tap_key__removed_tap_key", "open_url", "https://must-not-write.example"), false)
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
					helpers.assert_nil(f.parameters.action_parameter_binding_fits("tap_key__removed_tap_key"))
					helpers.assert_eq(f.parameters.set_action_parameter("tap_key__removed_tap_key", "open_url", "https://unjudged-new.example"), true)
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
				helpers.assert_eq(f.parameters.set_action_parameter("tap_key__number_row_left", "open_url", "https://changed.example"), true)
				if driver == "macos" then helpers.assert_eq(f.save(), true) end
				local changed = f.read()
				helpers.assert_contains(changed, 'tap_key__removed_tap_key__open_url = "https://obsolete.example" # explicit cleanup owns this')
				helpers.assert_contains(changed, f.source:match("(%[future%].*)"), "all future typed source bytes remain exact")
				local decoded = require("toml_codec").decode(changed)
				local parameters = driver == "macos" and decoded.gestures.action_parameters or decoded.gesture_parameters
				helpers.assert_eq(parameters, {
					tap_key__removed_tap_key__open_url = "https://obsolete.example",
					tap_key__number_row_left__open_url = "https://changed.example",
					tap_hold__future_unjudged__open_url = "https://unjudged.example",
				}, "complete handwritten preserved parameter model")
			end)
		end)
		helpers.it("late genuine publication neutralizes a carried retired runtime parameter", function()
			with_file(false, function(f)
				if driver == "macos" then
					for key, value in pairs(stored(f)) do
						local binding, action = f.parameters.split_action_parameter_key(key)
						helpers.assert_eq(f.parameters.set_action_parameter(binding, action, value), true)
					end
				end
				helpers.assert_eq(f.parameters.get_action_parameter("tap_key__removed_tap_key", "open_url"), "https://obsolete.example")
				publish(f.owner)
				helpers.assert_eq(f.parameters.get_action_parameter("tap_key__removed_tap_key", "open_url"), "")
				helpers.assert_eq(f.parameters.get_action_parameter("tap_key__removed_tap_key", "open_url"), "")
				helpers.assert_eq(#f.warnings, 1, "late publication warns once on the actual carried read")
				helpers.assert_eq(f.parameters.get_action_parameter("tap_key__number_row_left", "open_url"), "https://current.example")
				helpers.assert_eq(stored(f).tap_key__removed_tap_key__open_url, "https://obsolete.example",
					"read policy does not mutate exact compensation snapshots")
				helpers.assert_eq(f.read(), f.source)
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
						helpers.assert_nil(f.parameters.action_parameter_binding_fits("tap_key__removed_tap_key"))
						package.loaded[native] = nil
						helpers.assert_nil(f.parameters.action_parameter_binding_fits("tap_key__removed_tap_key"))
					end)
					io.open, package.loaded[native] = open, owner
					if not okay then error(detail, 0) end
					helpers.assert_eq(equalities, 0, "metamethods cannot authenticate a successor")
					helpers.assert_eq(f.parameters.action_parameter_binding_fits("tap_key__removed_tap_key"), false,
						"restoring the exact published owner restores judgment")
					helpers.assert_eq(f.read(), f.source)
				end)
			end)
		end

		for _, equality_spoof in ipairs({ false, true }) do
			local spoof = equality_spoof
			helpers.it("withdraws an inherited accessor on a distinct registered successor, equality spoof=" .. tostring(spoof), function()
				with_file(true, function(f)
					local owner, equalities = require(native), 0
					local metatable = { __index = owner }
					if spoof then metatable.__eq = function() equalities = equalities + 1; return true end end
					local successor = setmetatable({}, metatable)
					package.loaded[native] = successor
					local open = io.open
					io.open = function() error("inherited publication cannot lazily read or initialize") end
					local okay, detail = pcall(function()
						helpers.assert_nil(successor.published_binding_catalogue(), "an inherited method cannot borrow old authority")
						helpers.assert_nil(owner.published_binding_catalogue(), "a captured method requires its exact registered owner")
						helpers.assert_nil(f.parameters.action_parameter_binding_fits("tap_key__removed_tap_key"))
						helpers.assert_nil(f.parameters.action_parameter_binding_fits("tap_key__number_row_left"))
					end)
					io.open, package.loaded[native] = open, owner
					if not okay then error(detail, 0) end
					helpers.assert_eq(equalities, 0, "equality metamethods cannot authenticate a registered owner")
					helpers.assert_eq(owner.published_binding_catalogue(), { prefix = "tap_key__", slots = SLOTS })
					helpers.assert_eq(f.parameters.action_parameter_binding_fits("tap_key__removed_tap_key"), false)
					helpers.assert_eq(f.parameters.action_parameter_binding_fits("tap_key__number_row_left"), true)
					helpers.assert_eq(f.read(), f.source, "withdrawal and restoration preserve exact source bytes")
				end)
			end)
		end
	end)
end

return M
