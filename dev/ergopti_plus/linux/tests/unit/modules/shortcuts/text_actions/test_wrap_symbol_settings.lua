--- tests/unit/modules/shortcuts/text_actions/test_wrap_symbol_settings.lua

--- ==============================================================================
--- MODULE: Wrap Symbol Settings (Linux)
--- DESCRIPTION:
--- Linux manages its wrap pairs as Windows and macOS do: a catalogue pair can be
--- switched off, the user can add pairs of their own, and both are stored in
--- config.toml's shortcuts.wrap_symbols, macOS's store. The shortcuts manager
--- wraps only with the active pairs, and the menu draws the controls.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local function read(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

--- Runs body with a private config.toml holding `content` (nil: absent).
local function with_config(content, body)
	local directory = string.format("%s/ergopti_wrap_settings_%d_%d",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	assert(os.execute("mkdir -p '" .. directory .. "'"))
	local path = directory .. "/config.toml"
	if content then
		local handle = assert(io.open(path, "w"))
		handle:write(content)
		handle:close()
	end
	package.loaded["modules.shortcuts.wrap_symbol_settings"] = nil
	local ok, err = pcall(body, require("modules.shortcuts.wrap_symbol_settings"), path)
	os.remove(path)
	os.remove(path .. ".tmp")
	os.remove(directory)
	if not ok then error(err, 0) end
end

local CATALOGUE = { { left = "(", right = ")" }, { left = "[", right = "]" } }

helpers.describe("Linux wrap symbol settings", function()
	helpers.it("reads an absent store as every catalogue pair on, none added", function()
		with_config(nil, function(Settings, path)
			local view = Settings.read(path)
			helpers.assert_eq(view, { states = {}, custom = {} })
			local active = Settings.active_pairs(CATALOGUE, view)
			helpers.assert_eq(active["("], { left = "(", right = ")" })
			helpers.assert_eq(active["]"], { left = "[", right = "]" })
		end)
	end)

	helpers.it("switches a pair off, adds one, and keeps unknown neighbours", function()
		with_config('[shortcuts]\nenabled = true\n\n[other]\nvalue = 1\n', function(Settings, path)
			helpers.assert_true(Settings.commit(path, function(candidate)
				candidate.wrap_symbol_states["("] = false
				candidate.custom_wrap_symbols[#candidate.custom_wrap_symbols + 1] = { left = "§", right = "§" }
				return true
			end))
			local document = Codec.decode(read(path))
			helpers.assert_eq(document.shortcuts.wrap_symbols.states["("], false)
			helpers.assert_eq(document.shortcuts.wrap_symbols.custom, { { left = "§", right = "§" } })
			helpers.assert_eq(document.shortcuts.enabled, true)
			helpers.assert_eq(document.other.value, 1)
			local active = Settings.active_pairs(CATALOGUE, (Settings.read(path)))
			helpers.assert_nil(active["("], "a pair switched off wraps nothing")
			helpers.assert_nil(active[")"])
			helpers.assert_eq(active["["], { left = "[", right = "]" })
			helpers.assert_eq(active["§"], { left = "§", right = "§" })
		end)
	end)

	helpers.it("restores the recommended state by removing every choice", function()
		with_config('[shortcuts.wrap_symbols]\ncustom = [{ left = "§", right = "§" }]\n\n'
			.. '[shortcuts.wrap_symbols.states]\n"(" = false\n', function(Settings, path)
			helpers.assert_true(Settings.commit(path, function(candidate)
				candidate.wrap_symbol_states, candidate.custom_wrap_symbols = {}, {}
				return true
			end))
			helpers.assert_eq(Settings.read(path), { states = {}, custom = {} })
		end)
	end)

	helpers.it("writes nothing for a cancelled mutation", function()
		with_config('[other]\nvalue = 1\n', function(Settings, path)
			local before = read(path)
			local committed, reason = Settings.commit(path, function() return false end)
			helpers.assert_eq({ committed, reason }, { false, Settings.CANCELLED })
			helpers.assert_eq(read(path), before)
		end)
	end)

	helpers.it("lets the shortcuts manager wrap only with the active pairs", function()
		with_config(nil, function(_, path)
			package.loaded["modules.shortcuts.manager"] = nil
			local manager = helpers.load_module("modules.shortcuts.manager")
			manager.init({ enabled = true, persist = true, config_path = path })
			local catalogue = manager.get_wrap_pair_list()
			helpers.assert_true(#catalogue > 0, "the shared catalogue is loaded")
			local left = catalogue[1].left
			helpers.assert_true(manager.get_wrap_pair(left) ~= nil)
			helpers.assert_true(manager.commit_wrap_choices(function(candidate)
				candidate.wrap_symbol_states[left] = false
				candidate.custom_wrap_symbols[1] = { left = "§", right = "§" }
				return true
			end))
			helpers.assert_nil(manager.get_wrap_pair(left), "a pair switched off from the menu stops wrapping")
			helpers.assert_eq(manager.get_wrap_pair("§"), { left = "§", right = "§" })
			helpers.assert_eq(manager.get_wrap_choices().states[left], false)
			-- A restart reads the same choices back.
			manager.init({ enabled = true, persist = true, config_path = path })
			helpers.assert_nil(manager.get_wrap_pair(left))
			package.loaded["modules.shortcuts.manager"] = nil
		end)
	end)
end)
