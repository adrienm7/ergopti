--- tests/unit/infra/test_tap_hold_scope.lua

--- ==============================================================================
--- MODULE: Tap-Hold Scope Transaction (Linux)
--- DESCRIPTION:
--- The Tap-Holds « restore recommended » and « clear » run through the shared
--- scope transaction with the real manager, loader and renderer on real files.
--- A restore must write the shipped preset explicitly and make the engine run
--- exactly what inheriting it would; a clear must leave the keyboard neutral;
--- both keep unknown data, back up both files and compensate every refusal.
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

--- What the engine runs for a decoded user document.
local function effective(document)
	return require("platform.remap.tap_hold_loader").load_document(DEFAULTS, document)
end

helpers.describe("Linux tap-hold scope: restore recommended", function()
	helpers.it("writes the shipped preset explicitly and runs exactly what inheriting it would", function()
		with_scope(nil, nil, function(s)
			s.parameters.state.params = {}
			local ok, detail = s.owner().apply("recommended")
			helpers.assert_eq(ok, true, detail)
			local stored = Codec.decode(read(s.tap_path))
			helpers.assert_nil(stored.tap_hold.inherit_defaults, "no inheritance stands in for the preset")
			helpers.assert_eq(stored.tap_hold.enabled, require("infra.manifest_reader").recommended_for("tap_holds.enabled"))
			local preset = require("platform.remap.tap_hold_loader").preset_keys(DEFAULTS)
			helpers.assert_true(next(preset) ~= nil, "the shipped preset has keys")
			helpers.assert_eq(stored.tap_hold.keys, preset)
			local inherited = effective({ tap_hold = { inherit_defaults = true, enabled = true } })
			helpers.assert_eq(effective(stored).keys, inherited.keys)
			helpers.assert_eq(s.manager.keys(), inherited.keys, "the engine acknowledged the candidate")
			helpers.assert_eq(s.manager.is_active(), true)
			helpers.assert_nil(read(s.config_path), "no tap-hold row lives in config.toml, so none is created")
			helpers.assert_nil(read(s.tap_path .. ".bak"), "an absent source has nothing to back up")
		end)
	end)

	helpers.it("replaces owned fields, keeps unknown ones and backs up the exact source", function()
		local source = '[tap_hold]\nenabled = false\ninherit_defaults = false\nfuture = "keep"\n'
			.. '[tap_hold.keys.left_shift]\ntap_action = "paste"\nenabled = false\n'
			.. '[tap_hold.keys.left_shift.custom]\nnote = "keep"\n'
			.. '[tap_hold.keys.future_key]\ntap_action = "future"\n'
			.. '[other]\nvalue = 17\n'
		with_scope(source, nil, function(s)
			helpers.assert_eq(s.owner().apply("recommended"), true)
			local stored = Codec.decode(read(s.tap_path))
			helpers.assert_eq(stored.tap_hold.future, "keep")
			helpers.assert_eq(stored.other.value, 17)
			helpers.assert_eq(stored.tap_hold.keys.left_shift.custom.note, "keep")
			helpers.assert_eq(stored.tap_hold.keys.left_shift.tap_action, "copy")
			helpers.assert_nil(stored.tap_hold.keys.left_shift.enabled)
			helpers.assert_eq(stored.tap_hold.keys.future_key.tap_action, "future")
			helpers.assert_eq(read(s.tap_path .. ".bak"), source)
			helpers.assert_eq(s.manager.keys().left_shift.tap_action, "copy")
		end)
	end)
end)

helpers.describe("Linux tap-hold scope: clear to system", function()
	-- The clear once removed [tap_hold] enabled with the keys, so the next key
	-- the user set did nothing until the switch was found again.
	helpers.it("(tap-hold-clear-keeps-switch) removes every owned field and leaves the switch as it is", function()
		for _, switch in ipairs({ true, false }) do
			local source = '[tap_hold]\nenabled = ' .. tostring(switch) .. '\ninherit_defaults = true\nfuture = "keep"\n'
				.. '[tap_hold.keys.left_shift]\ntap_action = "paste"\nhold_modifier = "shift"\n'
				.. 'time_activation_seconds = 0.3\n[tap_hold.keys.left_shift.custom]\nnote = "keep"\n'
				.. '[tap_hold.keys.left_ctrl]\ntap_action = "copy"\n'
			with_scope(source, nil, function(s)
				helpers.assert_eq(s.manager.is_active(), switch)
				helpers.assert_eq(s.owner().apply("clear"), true)
				local stored = Codec.decode(read(s.tap_path))
				helpers.assert_eq(stored.tap_hold, { enabled = switch, future = "keep",
					keys = { left_shift = { custom = { note = "keep" } } } })
				helpers.assert_eq(s.manager.file_enabled(), switch, "the clear owns the keys, not the switch")
				for key_id, key in pairs(s.manager.keys()) do
					helpers.assert_true(key.tap_action == nil and key.hold_modifier == nil and key.hold_layer == nil,
						"no tap or hold remains on " .. key_id)
				end
			end)
		end
	end)

	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("removes tap-hold action parameters in " .. mode .. " and keeps every other one", function()
			local config = '[gesture_parameters]\ntap_hold__open_url = "https://tap.example"\n'
				.. 'tap_4__open_url = "https://keep.example"\nfuture = "keep"\n'
			with_scope(nil, config, function(s)
				helpers.assert_eq(s.owner().apply(mode), true)
				local stored = Codec.decode(read(s.config_path)).gesture_parameters
				helpers.assert_nil(stored.tap_hold__open_url)
				helpers.assert_eq(stored.tap_4__open_url, "https://keep.example")
				helpers.assert_eq(stored.future, "keep")
				helpers.assert_eq(read(s.config_path .. ".bak"), config)
				helpers.assert_eq(s.parameters.state.params, { tap_4__open_url = "https://keep.example" })
				helpers.assert_nil(s.parameters.state.owner, "the parameter owner is released")
			end)
		end)
	end
end)

helpers.describe("Linux tap-hold scope: refusals and revert", function()
	helpers.it("refuses while paused without touching a file or the engine", function()
		local source = '[tap_hold]\nenabled = true\ninherit_defaults = true\n'
		with_scope(source, nil, function(s)
			s.paused = true
			local before = s.manager.keys()
			helpers.assert_eq(s.owner().apply("clear"), false)
			helpers.assert_eq(read(s.tap_path), source)
			helpers.assert_eq(s.manager.keys(), before)
		end)
	end)

	helpers.it("keeps an external edit and restores the engine and parameters", function()
		local source = '[tap_hold]\nenabled = true\ninherit_defaults = true\n'
		local config = '[gesture_parameters]\ntap_hold__open_url = "https://tap.example"\n'
		with_scope(source, config, function(s)
			local before = s.manager.keys()
			local external = '[tap_hold]\nenabled = false\n# edited by hand\n'
			s.controls.before_publish = function(path)
				if path == s.tap_path then write(s.tap_path, external) end
			end
			local owner = s.owner()
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(read(s.tap_path), external, "the later edit is never overwritten")
			helpers.assert_eq(read(s.config_path), config)
			helpers.assert_eq(s.manager.keys(), before, "the engine runs its previous configuration")
			helpers.assert_eq(s.parameters.state.params.tap_hold__open_url, "https://tap.example")
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	helpers.it("puts the preset file back when config.toml publication is refused", function()
		local source = '[tap_hold]\nenabled = true\ninherit_defaults = true\n'
		local config = '[gesture_parameters]\ntap_hold__open_url = "https://tap.example"\n'
		with_scope(source, config, function(s)
			s.controls.refuse = s.config_path
			helpers.assert_eq(s.owner().apply("clear"), false)
			helpers.assert_eq(read(s.tap_path), source)
			helpers.assert_eq(read(s.config_path), config)
			helpers.assert_eq(s.manager.file_enabled(), true)
		end)
	end)

	helpers.it("reverts a committed restore: both files, the engine and the parameters", function()
		local config = '[gesture_parameters]\ntap_hold__open_url = "https://tap.example"\n'
		with_scope(nil, config, function(s)
			local owner = s.owner()
			helpers.assert_eq(owner.apply("recommended"), true)
			helpers.assert_eq(s.manager.is_active(), true)
			local reverted, detail = owner.revert()
			helpers.assert_eq(reverted, true, detail)
			helpers.assert_nil(read(s.tap_path), "the created tap_hold.toml is removed again")
			helpers.assert_eq(read(s.config_path), config)
			helpers.assert_eq(s.manager.is_active(), false)
			helpers.assert_eq(s.parameters.state.params.tap_hold__open_url, "https://tap.example")
			helpers.assert_nil(s.parameters.state.owner)
		end)
	end)
end)

-- A fresh install has no layers.toml, and an absent file binds no key: the
-- restored left_alt entered an empty navigation layer. The restore now brings
-- Ergopti's recommended layer along, never over a file the user has.
helpers.describe("Linux tap-hold scope: the recommended navigation layer", function()
	local PRESET = read(require("infra.paths").shared("keymap/layers.recommended.toml"))

	helpers.it("(nav-layer-fresh-install-default) a restore creates layers.toml and the engine runs its layer", function()
		with_scope(nil, nil, function(s)
			helpers.assert_true(type(PRESET) == "string" and PRESET ~= "", "the shipped preset is readable")
			helpers.assert_eq(s.owner().apply("recommended"), true)
			helpers.assert_eq(read(s.dir .. "/layers.toml"), PRESET, "the preset's exact bytes")
			local engine = s.installed[#s.installed]
			helpers.assert_true(type(engine) == "table" and next(engine.nav_layer) ~= nil,
				"the engine the restore installs binds the navigation layer")
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) an existing layers.toml is kept byte for byte", function()
		for label, text in pairs({ edited = '[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"KeyJ" = "keystroke:ArrowDown"\n',
			empty = "" }) do
			with_scope(nil, nil, function(s)
				write(s.dir .. "/layers.toml", text)
				helpers.assert_eq(s.owner().apply("recommended"), true, label)
				helpers.assert_eq(read(s.dir .. "/layers.toml"), text, label .. ": the user's file stays")
			end)
		end
	end)

	helpers.it("(nav-layer-fresh-install-default) clear neither creates nor removes a layer file", function()
		with_scope(nil, nil, function(s)
			helpers.assert_eq(s.owner().apply("clear"), true)
			helpers.assert_nil(read(s.dir .. "/layers.toml"))
		end)
		with_scope(nil, nil, function(s)
			write(s.dir .. "/layers.toml", PRESET)
			helpers.assert_eq(s.owner().apply("clear"), true)
			helpers.assert_eq(read(s.dir .. "/layers.toml"), PRESET)
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) a refused restore removes only the layer it created", function()
		local config = '[gesture_parameters]\ntap_hold__open_url = "https://tap.example"\n'
		with_scope(nil, config, function(s)
			s.controls.refuse = s.config_path
			helpers.assert_eq(s.owner().apply("recommended"), false)
			helpers.assert_nil(read(s.dir .. "/layers.toml"), "no layer file outlives a refused restore")
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) a reverted restore removes the layer it created", function()
		with_scope(nil, nil, function(s)
			local owner = s.owner()
			helpers.assert_eq(owner.apply("recommended"), true)
			helpers.assert_eq(read(s.dir .. "/layers.toml"), PRESET)
			helpers.assert_eq(owner.revert(), true)
			helpers.assert_nil(read(s.dir .. "/layers.toml"), "the created layer file is removed again")
		end)
	end)
end)

return true
