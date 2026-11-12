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

	--- A layout registry snapshot listing the shipped index.
	local function index_snapshot() return { index = index, installed = {} } end

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

		helpers.it("(leh-001-emulated-legends) a legend is what the key types unshifted from rest", function()
			local checked = 0
			for _, case in ipairs({
				{ layout = "ergopti" }, { layout = "ergol" },
				{ layout = "ergopti", settings = { number_row = "digits" } },
				{ layout = "ergopti", settings = { emulate_top_row = false } },
			}) do
				for code in pairs(rows) do
					local live = session(case.layout, case.settings)
					local legend = Emulation.legend(live, code)
					helpers.assert_true(not Emulation.pending(live), code .. ": a legend leaves no dead key")
					local decision, text = Emulation.decide(live, code, false, false, false, false, false, false, nil)
					if decision == Emulation.PASS then
						helpers.assert_eq(legend, "", case.layout .. " " .. code .. " is the system layout's")
					elseif text ~= "" then
						helpers.assert_eq(legend, text, case.layout .. " " .. code)
						checked = checked + 1
					else
						helpers.assert_true(Emulation.pending(live) and legend ~= "",
							case.layout .. " " .. code .. ": a dead key shows its terminator")
					end
				end
			end
			helpers.assert_true(checked >= 100, "only " .. checked .. " legends compared")
			local off = session("ergopti", { emulate_top_row = false })
			helpers.assert_eq(Emulation.legend(off, "KeyQ"), "", "a row switched off is the system layout's")
			helpers.assert_true(Emulation.legend(session("ergopti"), "KeyQ") ~= "", "the top row is emulated")
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

		helpers.it("reads the [layout] settings the way Windows selects the layout", function()
			local Settings = require("layouts.emulation_settings")
			local default_for = require("infra.manifest_reader").default_for
			local reported = {}
			local function report(segments) reported[#reported + 1] = table.concat(segments, ".") end
			local empty = Settings.resolve({}, default_for, report)
			helpers.assert_true(not Settings.active(empty), "an empty configuration emulates nothing")
			local builtin = Settings.resolve({ layout = { ergopti_base = true } }, default_for, report)
			helpers.assert_eq(builtin.id, "ergopti", "the built-in variant none types Ergopti")
			local plus = Settings.resolve({ layout = { ergopti_base = true, ergopti_variant = "ergopti_plus" } },
				default_for, report)
			helpers.assert_eq(plus.id, "ergopti_plus", "the plus variant")
			local registry = Settings.resolve({ layout = { emulated_layout = "bepo", ergopti_variant = "ergopti_plus",
				ergopti_alt_gr = true, emulate_top_row = false, direct_access_digits = "digits" } }, default_for, report)
			helpers.assert_eq(registry.id, "bepo", "a registry layout supersedes the variant")
			helpers.assert_true(Settings.active(registry), "AltGr alone keeps it active")
			helpers.assert_eq(registry.layout.emulate_top_row, false, "a row switch")
			helpers.assert_eq(registry.number_row, "digits", "the number-row ordering")
			local outdated = Settings.resolve({ layout = { ergopti_base = "yes", emulated_layout = "Bad Id" } },
				default_for, report)
			helpers.assert_true(not Settings.active(outdated), "outdated leaves read as their defaults")
			helpers.assert_eq(#reported, 2, "each outdated leaf is reported")
			helpers.assert_eq(Settings.choice_values("ergopti_plus")["layout.ergopti_variant"], "ergopti_plus",
				"a built-in choice writes the variant")
			helpers.assert_eq(Settings.choice_values("bepo")["layout.emulated_layout"], "bepo", "a registry choice")
			helpers.assert_eq(Settings.choice_values("none")["layout.ergopti_base"], false, "none clears the base layer")
			helpers.assert_nil(Settings.choice_values("Not An Id"), "an invalid choice")
		end)

		helpers.it("lists the emulation choices with the current one ticked", function()
			local Settings = require("layouts.emulation_settings")
			local Menu = require("layouts.emulation_menu")
			local default_for = require("infra.manifest_reader").default_for
			local chosen
			local function rows_for(layout, status)
				return Menu.choice_rows({ t = function(key) return key end,
					settings = Settings.resolve({ layout = layout }, default_for),
					status = status or { active = true }, snapshot = index_snapshot(),
					choose = function(choice) chosen = choice end })
			end
			local rows = rows_for({ emulated_layout = "bepo", ergopti_base = true })
			helpers.assert_eq(#rows, 1, "one submenu")
			local checked, labels = {}, {}
			for _, item in ipairs(rows[1].items) do
				labels[#labels + 1] = item.label
				if item.checked then checked[#checked + 1] = item.label end
			end
			helpers.assert_eq(checked, { "bépo" }, "the registry layout is ticked")
			helpers.assert_eq(labels[1], "onboarding.layout.emulated_none", "none comes first")
			rows[1].items[1].action()
			helpers.assert_eq(chosen, "none", "a row chooses its value")
			local off = rows_for({})
			helpers.assert_true(off[1].items[1].checked, "nothing emulated ticks none")
			local failed = rows_for({ emulated_layout = "missing", ergopti_base = true }, { error = "unreadable" })
			helpers.assert_true(failed[1].label:find("menu.layout.emulation_failed", 1, true) ~= nil,
				"a layout that cannot be emulated says so")
			local switch = Menu.switch_row({ t = function(key) return key end, label_key = "k", checked = true,
				toggle = function(value) chosen = value end })
			switch.action()
			helpers.assert_eq(chosen, false, "a switch row toggles its value")
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
