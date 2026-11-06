--- _shared/lua/test/keylayout_emulation_contract.lua

--- ==============================================================================
--- MODULE: Keylayout Emulation Contract
--- DESCRIPTION:
--- Replays the cross-OS keystroke oracle against `layouts.keylayout_emulation`:
--- keylayout_vectors.json, which the Windows emulation replays too
--- (windows/tests/unit/modules/keymap/test_keylayout_emulation.ahk), so the
--- three drivers type the same text for the same physical keys, and
--- emulation_vectors.json, the [layout] options around it. Both Lua drivers
--- register it with their own paths.
--- ==============================================================================

local M = {}

--- Reads a whole file.
local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
--- @param shared function Resolves a path under _shared.
function M.register(helpers, shared)
	local Json = require("json")
	local Emulation = require("layouts.keylayout_emulation")

	local keycodes = Json.decode(read_all(shared("modules/layouts/mac_keycodes.json")))
	local registry = Json.decode_lossless(read_all(shared("data/keycodes/physical_keys.json")))
	local index = Json.decode(read_all(shared("../../layouts/registry/index.json")))
	local rows = Emulation.row_map(registry, Json.is_null)
	local by_scan = {}
	for code, key in pairs(registry.keys) do
		if type(key.ahk) == "string" then by_scan[key.ahk] = code end
	end
	local models = {}

	--- The compiled model of a shipped registry layout.
	local function model(id)
		if models[id] then return models[id] end
		for _, entry in ipairs(index.layouts) do
			if entry.id == id then
				models[id] = Emulation.load(read_all(shared("../../layouts/registry/" .. entry.file)),
					keycodes, entry.keycode_convention)
				return models[id]
			end
		end
		error("The registry ships no layout " .. tostring(id))
	end

	--- A session configured with the defaults and a vector's overrides.
	local function session(id, overrides)
		overrides = overrides or {}
		local layout = { emulate_number_row = true, emulate_top_row = true, emulate_home_row = true,
			emulate_bottom_row = true }
		for key, value in pairs(overrides) do
			if key:match("^emulate_") then layout[key] = value end
		end
		local live = Emulation.new_session(model(id), rows)
		local function pick(value, default) if value == nil then return default end return value end
		Emulation.configure(live, {
			base = pick(overrides.base, true), alt_gr = pick(overrides.alt_gr, true), layout = layout,
			number_row = overrides.number_row or "native", edges = overrides.edges == true,
			magic_code = overrides.magic_key and by_scan[overrides.magic_key] or nil,
		})
		return live
	end

	--- Decides one press written "mod mod SCnnn [native=text]".
	local function press(live, text)
		local mods, scan, native = {}, nil, nil
		for word in text:gmatch("%S+") do
			if word:match("^native=") then native = word:sub(8)
			elseif word:match("^SC%x%x%x$") then scan = word
			else mods[word] = true end
		end
		local code = by_scan[scan]
		if code == nil then error("Unknown scan code in a vector: " .. tostring(scan)) end
		return Emulation.decide(live, code, mods.shift == true, mods.caps == true, mods.altgr == true,
			mods.ctrl == true, mods.alt == true, mods.win == true, native)
	end

	helpers.describe("keylayout emulation (shared contract)", function()
		helpers.it("types every shared keystroke vector as the Windows emulation does", function()
			local corpus = Json.decode(read_all(shared("tests/corpus/layouts/keylayout_vectors.json")))
			local replayed, layouts = 0, {}
			for _, vector in ipairs(corpus.vectors) do
				local live = session(vector.layout)
				layouts[vector.layout] = true
				if vector.press then
					local typed = ""
					for _, step in ipairs(vector.press) do
						local decision, text = press(live, step)
						helpers.assert_eq(decision, Emulation.TYPE, vector.id .. ": " .. step .. " is emulated")
						typed = typed .. text
					end
					helpers.assert_eq(typed, vector.types, vector.id)
				else
					local decision, text = press(live, "ctrl " .. vector.shortcut)
					local sent = decision == Emulation.SHORTCUT and text or ""
					helpers.assert_eq(sent, vector.sends, vector.id)
				end
				replayed = replayed + 1
			end
			helpers.assert_eq(replayed, #corpus.vectors, "every vector is replayed")
			helpers.assert_true(layouts.ergol and layouts.ergopti and layouts.ergopti_plus,
				"both the ansi and the iso conventions are covered")
		end)

		helpers.it("starts a dead key on every shared reset seed", function()
			local corpus = Json.decode(read_all(shared("tests/corpus/layouts/keylayout_vectors.json")))
			helpers.assert_true(#corpus.dead_reset_seeds >= 5, "the seeds are replayed")
			for _, seed in ipairs(corpus.dead_reset_seeds) do
				local live = session(seed.layout)
				local decision, text = press(live, seed.press)
				helpers.assert_eq(decision, Emulation.TYPE, seed.press)
				helpers.assert_eq(text, "", seed.layout .. " " .. seed.press .. " types nothing yet")
				helpers.assert_true(Emulation.pending(live), seed.press .. " leaves a dead key pending")
				helpers.assert_eq((press(live, "SC00E")), Emulation.PASS, "Backspace passes")
				helpers.assert_true(not Emulation.pending(live), "Backspace drops the dead key")
			end
		end)

		helpers.it("applies the [layout] options as the Windows emulation does", function()
			local corpus = Json.decode(read_all(shared("tests/corpus/layouts/emulation_vectors.json")))
			helpers.assert_true(#corpus.vectors >= 12, "the options corpus holds its vectors")
			for _, vector in ipairs(corpus.vectors) do
				local live = session(vector.layout, vector.settings)
				for position, step in ipairs(vector.steps) do
					local label = vector.id .. " #" .. position .. " (" .. step.press .. ")"
					local decision, text = press(live, step.press)
					helpers.assert_eq(decision, step.decides, label)
					if step.text ~= nil then helpers.assert_eq(text, step.text, label) end
				end
			end
		end)

		helpers.it("refuses an unknown convention and an uncompiled session", function()
			local ok = pcall(Emulation.mac_codes, keycodes, "jis")
			helpers.assert_true(not ok, "an unknown convention raises")
			ok = pcall(Emulation.new_session, {}, rows)
			helpers.assert_true(not ok, "a session needs a compiled model")
			local live = Emulation.new_session(model("ergol"), rows)
			ok = pcall(Emulation.decide, live, "KeyQ", false, false, false, false, false, false)
			helpers.assert_true(not ok, "an unconfigured session raises")
		end)

		helpers.it("tells printable outputs from control placeholders", function()
			helpers.assert_true(Emulation.printable("é"), "a letter")
			helpers.assert_true(not Emulation.printable(""), "empty")
			helpers.assert_true(not Emulation.printable("\16"), "Kalamine's U+0010")
			helpers.assert_true(not Emulation.printable("\194\133"), "a C1 control")
			helpers.assert_true(Emulation.printable(" !"), "a multi-character output")
		end)
	end)
end

return M
