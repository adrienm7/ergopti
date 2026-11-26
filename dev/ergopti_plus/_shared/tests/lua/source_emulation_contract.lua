--- _shared/tests/lua/source_emulation_contract.lua

--- ==============================================================================
--- MODULE: Layout Source Emulation Contract
--- DESCRIPTION:
--- Replays the shared typing vectors of the layout source emulation
--- (_shared/tests/corpus/layouts/source/emulation_vectors.json) against
--- `layouts.source_emulation`, on the golden table the source compiler writes
--- for each platform (emulation.json). The web engine replays the same vectors
--- (tools/test/test-layout-source-emulation.cjs), so a custom modifier, a
--- shortcut or a tap-hold does the same on macOS, Linux and the site. Both Lua
--- drivers register it with their own paths.
--- ==============================================================================

local M = {}

--- Reads a whole file.
local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- A canonical text of a value, keys sorted, so two decodings compare as text.
local function canonical(value)
	if type(value) ~= "table" then return string.format("%q", tostring(value)) end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. canonical(value[key]) end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- A set of the modifier ids a vector step holds.
local function held_set(list)
	local set = {}
	for _, id in ipairs(list or {}) do set[id] = true end
	return set
end

--- Replays the steps of one case on a fresh session.
--- @return string|nil mismatch The first difference, nil when all steps match.
local function replay(Engine, model, steps)
	local session = Engine.new_session(model)
	for index, step in ipairs(steps) do
		local consumed, actions
		if step.press ~= nil then
			consumed, actions = Engine.press(session, step.press, held_set(step.held), step.at, step.before)
		elseif step.release ~= nil then
			consumed, actions = Engine.release(session, step.release, step.at)
		elseif step.tick ~= nil then
			actions = Engine.tick(session, step.tick)
		else
			actions = Engine.reset(session)
		end
		if step.consumed ~= nil and consumed ~= step.consumed then
			return "step " .. index .. ": consumed " .. tostring(consumed)
		end
		if canonical(actions) ~= canonical(step.actions) then
			return "step " .. index .. ": " .. canonical(actions) .. " ~= " .. canonical(step.actions)
		end
	end
	return nil
end

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
--- @param shared function Resolves a path under _shared.
function M.register(helpers, shared)
	local Json = require("core.text.engine.json")
	local Engine = require("layouts.engine.composer.source_emulation")
	local corpus = "tests/corpus/layouts/source/"
	local vectors = Json.decode(read_all(shared(corpus .. "emulation_vectors.json")))
	local golden = Json.decode(read_all(shared(corpus .. vectors.table)))

	helpers.describe("layout source emulation (shared contract)", function()
		helpers.it("types every shared emulation vector as the web engine does", function()
			local replayed = 0
			for _, platform in ipairs(vectors.platforms) do
				local model = Engine.compile(golden[platform])
				helpers.assert_true(Engine.has_records(model), platform .. ": the table has records")
				for _, case in ipairs(vectors.cases) do
					helpers.assert_eq(replay(Engine, model, case.steps), nil, platform .. ": " .. case.name)
					replayed = replayed + 1
				end
			end
			helpers.assert_true(replayed >= 2 * 18, "every vector is replayed on both platforms")
		end)

		-- layout-levels-emulation: Neo 2's Mod3 and Mod4 on Caps Lock and AltGr, ¡ ¿
		-- and the dead keys of those levels, as the web and AutoHotkey engines type them.
		helpers.it("types Neo 2's own levels and their dead keys as the web engine does", function()
			local neo_vectors = Json.decode(read_all(shared(corpus .. "neo2_vectors.json")))
			local neo = Json.decode(read_all(shared(corpus .. neo_vectors.table)))
			local replayed = 0
			for _, platform in ipairs(neo_vectors.platforms) do
				local model = Engine.compile(neo[platform])
				helpers.assert_true(Engine.holds_modifier_key(model, "AltRight"), platform .. ": AltGr holds Mod4")
				helpers.assert_eq(Engine.holds_modifier_key(model, "CapsLock"), platform ~= "macos",
					platform .. ": Caps Lock holds Mod3 where the hook sees it held")
				for _, case in ipairs(neo_vectors.cases) do
					local listed = case.platforms == nil
					for _, name in ipairs(case.platforms or {}) do listed = listed or name == platform end
					if listed then
						helpers.assert_eq(replay(Engine, model, case.steps), nil, platform .. ": " .. case.name)
						replayed = replayed + 1
					end
				end
			end
			helpers.assert_true(replayed >= 3 * 16, "every Neo vector is replayed on the three platforms")
		end)

		-- layout-context-keys-emulation: a layout's own repeat and magic keys type
		-- from the text typed before, as the web and AutoHotkey engines type them.
		helpers.it("types a layout's repeat and magic keys from the text typed before", function()
			local context_vectors = Json.decode(read_all(shared(corpus .. "context_vectors.json")))
			local context = Json.decode(read_all(shared(corpus .. context_vectors.table)))
			local replayed = 0
			for _, platform in ipairs(context_vectors.platforms) do
				local model = Engine.compile(context[platform])
				helpers.assert_true(Engine.has_records(model), platform .. ": the table has records")
				for _, case in ipairs(context_vectors.cases) do
					helpers.assert_eq(replay(Engine, model, case.steps), nil, platform .. ": " .. case.name)
					replayed = replayed + 1
				end
				local ok, err = pcall(Engine.press, Engine.new_session(model), "Quote", {}, 0)
				helpers.assert_true(not ok and tostring(err):find("needs the text typed before it", 1, true) ~= nil,
					platform .. ": a magic key without the text before is refused")
			end
			helpers.assert_true(replayed >= 3 * 7, "every context vector is replayed on the three platforms")
		end)

		helpers.it("types what the shared magic vectors say", function()
			local magic_vectors = Json.decode(read_all(shared("tests/corpus/layouts/magic_vectors.json")))
			local checked = 0
			for _, vector in ipairs(magic_vectors.vectors) do
				local mapping = vector.action.magic ~= nil and { magic = vector.action.magic }
					or { ["repeat"] = vector.action["repeat"] }
				helpers.assert_eq(Engine.context_text(magic_vectors.magic, mapping, vector.before), vector.types,
					canonical(vector.action) .. " after " .. vector.before)
				checked = checked + 1
			end
			helpers.assert_true(checked >= 20, "every magic vector is checked")
		end)

		-- ergopti-emulation-unchanged: a layout holding no custom modifier on Caps
		-- Lock or AltGr leaves both keys to the OS and emulates no dead key.
		helpers.it("leaves Caps Lock and AltGr to the OS for the Ergopti layouts", function()
			local pinned = Json.decode(read_all(shared(corpus .. "ergopti_emulation.json")))
			local checked = 0
			for file, tables in pairs(pinned) do
				for platform, table_ in pairs(tables) do
					local where = file .. " on " .. platform
					helpers.assert_eq(table_.dead_keys, nil, where .. ": no dead key is emulated")
					local model = Engine.compile(table_)
					for _, key in ipairs({ "CapsLock", "AltRight" }) do
						helpers.assert_true(not Engine.holds_modifier_key(model, key), where .. ": " .. key .. " keeps its role")
						local consumed, actions = Engine.press(Engine.new_session(model), key, {}, 0)
						helpers.assert_true(consumed == false and #actions == 0, where .. ": " .. key .. " goes to the OS")
					end
					checked = checked + 1
				end
			end
			helpers.assert_true(checked >= 5 * 3, "every Ergopti table is checked on the three platforms")
		end)

		helpers.it("sees a changed expectation", function()
			local model = Engine.compile(golden.linux)
			local steps = {
				{ press = "IntlBackslash", held = {}, at = 0, consumed = true, actions = {} },
				{ press = "KeyA", held = {}, at = 1, consumed = true, actions = { { type = "text", text = "a" } } },
			}
			helpers.assert_true(replay(Engine, model, steps) ~= nil, "a wrong text is a mismatch")
		end)

		helpers.it("refuses a malformed table when compiled", function()
			local function mutated(change)
				local table_ = Json.decode(read_all(shared(corpus .. vectors.table))).linux
				change(table_)
				return table_
			end
			for label, change in pairs({
				format = function(t) t.format = "other" end,
				version = function(t) t.version = 2 end,
				layer_modifier = function(t) table.insert(t.layers[3].selectors[1].required, "unknown") end,
				hold_layer = function(t) t.tap_holds[1].hold_layer = "missing" end,
				two_holds = function(t) t.tap_holds[1].hold_modifier = "shift" end,
				threshold = function(t) t.tap_holds[1].threshold_ms = 0 end,
				-- The shared value schema's declaration (value-validation).
				threshold_past_maximum = function(t) t.tap_holds[1].threshold_ms = 10001 end,
				threshold_fraction = function(t) t.tap_holds[1].threshold_ms = 150.5 end,
				threshold_string = function(t) t.tap_holds[1].threshold_ms = "150" end,
				threshold_nan = function(t) t.tap_holds[1].threshold_ms = 0 / 0 end,
				mapping = function(t) t.layers[1].keys.KeyX = { dead_key = "undeclared" } end,
				magic_unknown = function(t) t.layers[1].keys.KeyX = { magic = "undeclared" } end,
				repeat_far = function(t) t.layers[1].keys.KeyX = { ["repeat"] = 3 } end,
				shared_key = function(t) table.insert(t.modifiers[2].keys, "IntlBackslash") end,
			}) do
				helpers.assert_true(not pcall(Engine.compile, mutated(change)), label .. " is refused")
			end
		end)

		helpers.it("matches selectors by family, never across sides", function()
			local match = Engine.selector_matches
			helpers.assert_true(match({ required = { "alt" }, optional = {} }, { "alt_right" }), "alt covers AltGr")
			helpers.assert_true(match({ required = { "alt_right" }, optional = {} }, { "alt" }),
				"an unsided Option covers alt_right")
			helpers.assert_true(not match({ required = { "shift_left" }, optional = {} }, { "shift_right" }),
				"two sides never match")
			helpers.assert_true(not match({ required = {}, optional = {} }, { "shift" }), "a held one must be allowed")
			helpers.assert_true(not match({ required = { "roya_left" }, optional = {} }, { "roya" }),
				"a custom id has no sides")
		end)
	end)
end

return M
