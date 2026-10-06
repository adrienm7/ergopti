--- _shared/lua/test/number_row_policy_contract.lua

--- ==============================================================================
--- MODULE: Number Row Policy Contract
--- DESCRIPTION:
--- Replays independently authored source-level and capability expectations.
--- Physical emission and durable native publication remain adapter-owned.
--- ==============================================================================

local M = {}
local Policy = require("layout.number_row_policy")
local Json = require("json")

--- Registers typed modes, source descriptors and retained-owner regressions.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string Canonical shared independent corpus path.
function M.run(helpers, corpus_path)
	local file = assert(io.open(corpus_path, "rb"))
	local content = file:read("*a")
	assert(file:close())
	local corpus = Json.decode(content)
	helpers.describe("Shared number-row typed policy", function()
		helpers.it("rejects unsupported modes and revoked source owners", function()
			helpers.assert_eq(#corpus.capabilities, 18, "complete independent capability vectors")
			helpers.assert_eq(#corpus.symbols, 13, "complete descriptor vectors")
			helpers.assert_eq(#corpus.invalid_modes, 12, "complete malformed mode vectors")
			for _, row in ipairs(corpus.capabilities) do
				helpers.assert_eq(Policy.capable(row.platform, row.mode, row.symbols), row.expected,
					row.platform .. ":" .. row.mode)
			end
			for _, row in ipairs(corpus.symbols) do
				local shift = Policy.symbols_shift(row.digit, row.plain, row.shifted)
				helpers.assert_eq(shift ~= nil, row.supported, "descriptor supported")
				if row.supported then helpers.assert_eq(shift, row.shift, "descriptor level") end
			end
			for _, value in ipairs(corpus.invalid_modes) do
				helpers.assert_eq(Policy.mode(value), nil, "typed mode")
			end
			local owner, source, native_owner = {}, {}, {}
			local function snapshot()
				return { owner = owner, source = source, native_owner = native_owner,
					generation = 2, lifecycle = 3, hkl = 4, platform = "ahk", mode = "native",
					symbols = true, master = true, paused = false, blocked = false, caps = false }
			end
			for _, mode in ipairs({ "native", "digits", "symbols" }) do
				helpers.assert_eq(Policy.intent(snapshot(), snapshot(), mode), true, "fresh mode")
			end
			local invalid = {
				owner = { false, 0, "" }, source = { false, 0, "" }, native_owner = { false, 0, "" },
				generation = { -1, 1.5, "2", 9007199254740992 }, lifecycle = { -1, 1.5, "3" },
				hkl = { 0, 1.5, "4" }, master = { false, 0, "true" }, paused = { true, 0, "false" },
				blocked = { true, 0, "false" }, symbols = { 0, "true" }, caps = { 0, "false" },
				mode = { true, "future", "Native" }
			}
			for field, values in pairs(invalid) do
				for _, value in ipairs(values) do
					local current = snapshot()
					current[field] = value
					helpers.assert_eq(Policy.intent(snapshot(), current, "digits"), false, "invalid " .. field)
				end
			end
			for _, field in ipairs({ "owner", "source", "native_owner", "generation", "lifecycle",
				"hkl", "mode", "symbols", "caps" }) do
				local current = snapshot()
				local old = current[field]
				if type(old) == "table" then current[field] = {}
				elseif type(old) == "number" then current[field] = old + 1
				elseif type(old) == "boolean" then current[field] = not old
				else current[field] = "digits" end
				helpers.assert_eq(Policy.intent(snapshot(), current, "native"), false, "changed " .. field)
			end
			local signed, same = snapshot(), snapshot()
			signed.hkl, signed.source = -268435447, -268435447
			same.hkl, same.source = signed.hkl, signed.source
			helpers.assert_eq(Policy.intent(signed, same, "digits"), true, "signed native HKL identity")
			local withdrawn = snapshot()
			withdrawn.lifecycle = withdrawn.lifecycle + 1
			helpers.assert_eq(Policy.intent(snapshot(), withdrawn, "digits"), false,
				"pause then resume retains epoch")

		end)
		helpers.it("uses the real renderer for native-only posture and translated disabled choices", function()
			local Renderer = require("menu.renderer")
			local shared = corpus_path:gsub("tests/corpus/layouts/number_row_policy%.json$", "")
			local function read(path)
				local stream = assert(io.open(path, "rb"))
				local text = stream:read("*a")
				assert(stream:close())
				return Json.decode(text)
			end
			local translations = read(shared .. "data/locales/en.json")
			local i18n = { get = function(key) return translations[key] or key end,
				section = function(key) return translations[key] or key end }
			for _, platform in ipairs({ "hs", "linux" }) do
				local renderer = assert(Renderer.new({ platform = platform,
					manifest_path = function() return shared .. "modules/menu/menu_manifest.json" end,
					json_decode = Json.decode, i18n = i18n,
					logger = { warn = function() end, error = function() end } }))
				local attempts = 0
				local commands = { ["number_row_mode"] = function()
					attempts = attempts + 1
					return false
				end }
				local choice_row = renderer.choice_row
				local borrowed
				renderer.choice_row = function(key, id, actual_commands, getters)
					borrowed = actual_commands
					return choice_row(key, id, actual_commands, getters)
				end
				local rows = Policy.native_rows(renderer, commands)
				helpers.assert_eq(borrowed, commands, "actual canonical command owner")
				helpers.assert_eq(commands["number_row_mode"]("digits"), false, "readonly owner never acknowledges a write")
				helpers.assert_eq(attempts, 1)
				helpers.assert_eq(#Policy.native_rows(renderer), 0, "missing driver command refuses")
				helpers.assert_eq(#Policy.native_rows(renderer, { number_row_mode = true }), 0, "noncallable command refuses")
				helpers.assert_eq(#rows, 1, "one canonical head")
				helpers.assert_eq(rows[1].label, "Number row")
				local expected = { "Native order", "Digits first", "Symbols first" }
				for index, item in ipairs(rows[1].items) do
					helpers.assert_eq(item.label, expected[index])
					helpers.assert_eq(item.checked, index == 1, "native posture")
					helpers.assert_eq(item.disabled, true, "read-only status is never a write ACK")
					helpers.assert_eq(item.action, nil, "unsupported drivers acquire no event or writer")
					if index ~= 1 then helpers.assert_eq(item.disabled_reason_key,
						"platform_reason.number_row_override_unsupported") end
				end
				local native = renderer.render_rows(rows)
				helpers.assert_eq(#native[1].menu, 3)
				for index, item in ipairs(native[1].menu) do
					helpers.assert_eq(item.disabled, true)
					if index ~= 1 then helpers.assert_eq(item.title:find("Unsupported", 1, true) ~= nil, true) end
				end
				local old = translations["menu.layout.number_row_symbols"]
				translations["menu.layout.number_row_symbols"] = "Changed canonical caption"
				helpers.assert_eq(Policy.native_rows(renderer, commands)[1].items[3].label, "Changed canonical caption")
				translations["menu.layout.number_row_symbols"] = old
				local get_array = renderer.get_array
				renderer.get_array = function(key)
					local data = get_array(key)
					data[1].choices[3].value = "future"
					return data
				end
				helpers.assert_eq(#Policy.native_rows(renderer, commands), 0, "unknown shared choices refuse without a local replacement")
			end
		end)


		helpers.it("replays the shipped typed migration through the actual Lua planner", function()
			local Migrate = require("config_migrate")
			local Codec = require("toml_codec")
			local shared = corpus_path:gsub("tests/corpus/layouts/number_row_policy%.json$", "")
			local function read(path)
				local stream = assert(io.open(path, "rb"))
				local bytes = stream:read("*a")
				assert(stream:close())
				return bytes
			end
			local registry = assert(Migrate.load_registry(shared .. Migrate.REGISTRY_PATH))
			helpers.assert_eq(registry.current, 11, "the actual shipped registry includes the common-family migration")
			local replays = 0
			for index = 0, 10 do
				local directory = shared .. "tests/corpus/config_migrations/shipped_number_row_typed_" .. index .. "/"
				local meta = Codec.decode(read(directory .. "case.toml")).case
				local source = read(directory .. "input.toml")
				local expected = read(directory .. "expected.toml")
				for _, driver in ipairs(meta.drivers) do
					local planned = Migrate.plan(source, registry, driver)
					helpers.assert_eq(planned.outcome, "migrated", driver .. ": typed migration")
					helpers.assert_eq(planned.candidate, expected, driver .. ": exact independent expected bytes")
					helpers.assert_eq(planned.candidate:find('future = "kept" # independently retained', 1, true) ~= nil, true)
					local replay = Migrate.plan(planned.candidate, registry, driver)
					helpers.assert_eq(replay.outcome, "current", driver .. ": idempotent native plan")
					helpers.assert_eq(replay.candidate, nil, "current sources acquire no rewrite")
					replays = replays + 1
				end
			end
			helpers.assert_eq(replays, 21, "every declared driver vector executed")
		end)

	end)
end

return M
