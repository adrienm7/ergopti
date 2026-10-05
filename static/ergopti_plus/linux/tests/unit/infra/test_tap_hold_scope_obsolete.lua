--- tests/unit/infra/test_tap_hold_scope_obsolete.lua

--- ==============================================================================
--- MODULE: Tap-Hold Scope Obsolete Shape Admission
--- DESCRIPTION:
--- Real native scope, manager and file controls retain obsolete namespaces and
--- exact inverses while the canonical source receipt separates arrays from maps.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")
local MODULES = { "platform.remap.tap_hold_manager", "platform.remap.tap_hold_loader",
	"platform.remap.tap_hold_writer", "infra.tap_hold_scope", "config_scope_transaction" }

local function read(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

local function write(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- A parameter owner double speaking the gesture manager's configuration API.
--- @param initial table Runtime parameters, binding__action -> value.
local function fake_parameters(initial)
	local state = { params = initial, owner = nil }
	local port = { state = state }
	function port.split_action_parameter_key(key)
		local binding = key:match("^(.*)__open_url$")
		if binding then return binding, "open_url" end
		return nil, nil
	end
	function port.get_action_parameter_spec(action) return action == "open_url" and "url" or nil end
	function port.acquire_parameter_configuration(owner)
		if state.owner ~= nil then return false end
		state.owner = owner
		return true
	end
	function port.release_parameter_configuration(owner)
		if state.owner ~= owner then return false end
		state.owner = nil
		return true
	end
	function port.parameter_configuration_snapshot(owner)
		if state.owner ~= owner then return nil end
		local copy = {}
		for key, value in pairs(state.params) do copy[key] = value end
		return copy
	end
	function port.apply_parameter_configuration(owner, params)
		if state.owner ~= owner then return false end
		local copy = {}
		for key, value in pairs(params) do copy[key] = value end
		state.params = copy
		return true
	end
	function port.parameter_configuration_inventory(document, recognizes)
		local paths = {}
		for key in pairs(type(document.gesture_parameters) == "table" and document.gesture_parameters or {}) do
			if recognizes(port.split_action_parameter_key(key)) then paths[#paths + 1] = "gesture_parameters." .. key end
		end
		for key in pairs(state.params) do
			if recognizes(port.split_action_parameter_key(key)) then paths[#paths + 1] = "gesture_parameters." .. key end
		end
		return paths, {}
	end
	return port
end

--- Runs body(s) with a real manager on a private folder holding both files.
--- @param tap_text string|nil Initial tap_hold.toml, nil for absent.
--- @param config_text string|nil Initial config.toml, nil for absent.
local function with_scope(tap_text, config_text, body)
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local tap_path, config_path = dir .. "/tap_hold.toml", dir .. "/config.toml"
	if tap_text then write(tap_path, tap_text) end
	if config_text then write(config_path, config_text) end
	local installed = {}
	local Manager = require("platform.remap.tap_hold_manager")
	Manager.init({
		keyboard_hook = { set_remapper = function(engine) installed[#installed + 1] = engine or false end,
			key_text = function() return nil end, held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end },
		execute_action = function() end,
		on_text_injected = function() end,
		action_names = function() return { "open_url" } end,
		defaults_path = DEFAULTS,
		user_path = tap_path,
	})
	local s = { dir = dir, tap_path = tap_path, config_path = config_path, manager = Manager,
		installed = installed, paused = false, controls = {} }
	s.parameters = fake_parameters({ tap_hold__open_url = "https://tap.example", tap_4__open_url = "https://keep.example" })
	local files = require("adapters.file_system")
	s.files = setmetatable({
		write_if_unchanged = function(path, content, expected)
			if s.controls.before_publish then s.controls.before_publish(path) end
			if s.controls.refuse == path then return false, "refused by the test" end
			return files.write_if_unchanged(path, content, expected)
		end,
	}, { __index = files })
	function s.owner()
		return require("infra.tap_hold_scope").new({
			path = config_path, backup_path = config_path .. ".bak",
			tap_hold_path = tap_path, tap_hold_backup_path = tap_path .. ".bak",
			is_paused = function() return s.paused end, parameters = s.parameters, files = s.files,
		})
	end
	local ok, err = pcall(body, s)
	Manager._reset_for_test()
	for _, name in ipairs({ "tap_hold.toml", "tap_hold.toml.bak", "config.toml", "config.toml.bak", "layers.toml" }) do
		os.remove(dir .. "/" .. name)
	end
	os.execute('rmdir "' .. dir .. '"')
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end


-- Shape receipts come from the same source read as transaction planning. Empty
-- arrays must not become dictionaries between decode, render and engine apply.
helpers.describe("Linux tap-hold scope: obsolete namespaces", function()
	for _, case in ipairs({
		{ name = "scalar root", text = 'tap_hold = "opaque"\n' },
		{ name = "empty array root", text = 'tap_hold = []\n' },
		{ name = "scalar keys", text = '[tap_hold]\nkeys = "opaque"\n' },
		{ name = "empty array keys", text = '[tap_hold]\nkeys = []\n' },
		{ name = "scalar binding", text = '[tap_hold.keys]\ncaps_lock = "opaque"\n' },
		{ name = "empty array binding", text = '[tap_hold.keys]\ncaps_lock = []\n' },
		{ name = "nested inline empty array", text = 'tap_hold = { keys = { caps_lock = [] } }\n' },
	}) do
		helpers.it("refuses recommended over " .. case.name .. " before primary backup, publication or apply", function()
			with_scope(case.text, '[future]\nkeep = 9\n', function(s)
				local parameters = s.parameters.state.params
				local loaded = s.manager.configuration_snapshot().loaded
				local installed = #s.installed
				local called, accepted = pcall(s.owner().apply, "recommended")
				helpers.assert_eq(called, true)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(read(s.tap_path), case.text)
				helpers.assert_eq(read(s.config_path), '[future]\nkeep = 9\n')
				helpers.assert_nil(read(s.tap_path .. ".bak"))
				helpers.assert_nil(read(s.config_path .. ".bak"))
				helpers.assert_nil(read(s.dir .. "/layers.toml"), "existing layer inverse settles its provisional import")
				helpers.assert_eq(s.manager.configuration_snapshot().loaded, loaded)
				helpers.assert_eq(s.parameters.state.params, parameters)
				helpers.assert_eq(#s.installed, installed, "invalid source never reaches engine admission")
				helpers.assert_nil(s.parameters.state.owner)
			end)
		end)
	end

	for _, literal in ipairs({ '"opaque"', 'false', '7', '1.23456789012345', '1.2345678901234567', '-1.23456789012345e-120', '9007199254740993', '9223372036854775807', '1.0', '1.2345678901234567e+42', '9_223_372_036_854_775_807', '[]', '[1, 2]' }) do
		helpers.it("clear carries outdated binding " .. literal .. " and never applies it as a key", function()
			local source = '[tap_hold]\nenabled = true\n[tap_hold.keys]\ncaps_lock = ' .. literal
				.. '\n[tap_hold.keys.left_shift]\ntap_action = "copy"\n[future]\nempty = []\n'
			with_scope(source, '[future]\nkeep = 9\n', function(s)
				local owner = s.owner()
				local accepted, detail = owner.apply("clear")
				helpers.assert_eq(accepted, true, detail)
				local bytes = read(s.tap_path)
				if literal:match("^[%d%-+]") then
					helpers.assert_true(bytes:find("caps_lock = " .. literal .. "\n", 1, true) ~= nil, "scope keeps exact unchanged numeric token")
				end
				helpers.assert_eq(Codec.decode(bytes).tap_hold.keys.caps_lock, Codec.decode('value = ' .. literal).value)
				if literal == '[]' then helpers.assert_true(bytes:find("caps_lock = []", 1, true) ~= nil) end
				helpers.assert_true(bytes:find("empty = []", 1, true) ~= nil)
				helpers.assert_nil(s.manager.keys().caps_lock, "candidate shape receipt reaches actual manager/loader")
				helpers.assert_nil(s.manager.keys().left_shift)
				helpers.assert_eq(read(s.tap_path .. ".bak"), source)
				helpers.assert_eq(owner.revert(), true)
				helpers.assert_eq(read(s.tap_path), source, "the original complete image is the retained inverse")
			end)
		end)
	end
end)
