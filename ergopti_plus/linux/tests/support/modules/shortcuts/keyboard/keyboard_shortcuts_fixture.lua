--- tests/support/modules/shortcuts/keyboard/keyboard_shortcuts_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_keyboard_shortcuts
--- DESCRIPTION:
--- Prelude shared by the test_keyboard_shortcuts_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local Sandbox = require("test.config_unused_keys_contract").sandbox

local Codec = require("toml_codec")

local Fakes = helpers.load_module("tests.fakes")

local _displaced = { storage = nil, chatgpt = nil, module = nil, paths = nil, held = false }

local _files = {}

--- Loads the module over a real canonical config and separate legacy storage.
--- @param initial table|nil Pre-existing stored values.
--- @param writes_fail boolean|nil Whether mutations fail.
--- @param chatgpt table|nil ChatGPT shortcut seam.
--- @return table shortcuts, table storage
local function load_over_config(initial, writes_fail, chatgpt)
	if not _displaced.held then
		_displaced.storage = package.loaded["adapters.storage"]
		_displaced.chatgpt = package.loaded["modules.shortcuts.chatgpt"]
		_displaced.module = package.loaded["modules.shortcuts.keyboard_shortcuts"]
		_displaced.paths = package.loaded["infra.config_paths"]
		_displaced.held = true
	end
	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	package.loaded["adapters.storage"] = storage
	local path = os.tmpname()
	_files[#_files + 1] = path
	local lines = { "[shortcuts.keyboard]" }
	for key, value in pairs(initial or {}) do
		lines[#lines + 1] = key:match("([^.]+)$") .. " = " .. string.format("%q", value)
	end
	Sandbox.write_bytes(path, table.concat(lines, "\n") .. "\n")
	package.loaded["infra.config_paths"] = { config = function() return path end }
	if writes_fail then require("toml_codec.writer").refuse_writes(path, "injected persistence refusal") end
	package.loaded["modules.shortcuts.chatgpt"] = chatgpt or { open = function() return true end }
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
	shortcuts._reset()
	local function values()
		local decoded = Codec.decode(Sandbox.read_bytes(path) or "")
		return decoded.shortcuts and decoded.shortcuts.keyboard or {}
	end
	return shortcuts, {
		path = path,
		get = function(key) return values()[key:match("([^.]+)$")] end,
		has = function(key) return values()[key:match("([^.]+)$")] ~= nil end,
		keys = function()
			local keys = {}
			for key in pairs(values()) do keys[#keys + 1] = "shortcuts.keyboard." .. key end
			return keys
		end,
	}
end

--- Puts back exactly what was there.
local function drop_config()
	package.loaded["adapters.storage"] = _displaced.storage
	package.loaded["modules.shortcuts.chatgpt"] = _displaced.chatgpt
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = _displaced.module
	package.loaded["infra.config_paths"] = _displaced.paths
	_displaced.held = false
	for _, path in ipairs(_files) do os.remove(path) os.remove(path .. ".tmp") end
	_files = {}
end

--- What the hook reports for one chord.
--- @param key string
--- @param mods table
--- @return table
local function chord(key, mods)
	return { key = key, mods = mods }
end

return {
	helpers = helpers,
	Sandbox = Sandbox,
	Codec = Codec,
	Fakes = Fakes,
	_displaced = _displaced,
	_files = _files,
	load_over_config = load_over_config,
	drop_config = drop_config,
	chord = chord,
}
