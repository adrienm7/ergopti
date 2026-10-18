--- tests/unit/ui/menu/metrics/test_privacy_toggle_publication.lua

--- ==============================================================================
--- MODULE: Metrics Privacy Menu Publication
--- DESCRIPTION:
--- Executes real rendered privacy actions against the collector and private
--- TOML files. Native checks may change only through the authoritative rebuild,
--- including when a setter returns false for an acknowledged encryption OFF.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv = require("luv")
local ConfigPaths = require("infra.config_paths")
local Preferences = require("infra.metrics_preferences")
local I18n = require("infra.i18n")

local FILTERS = {
	{ id = "filter_private", path = "private_filter_enabled", setter = "set_private_filter_enabled" },
	{ id = "filter_secure", path = "secure_filter_enabled", setter = "set_secure_filter_enabled" },
	{ id = "filter_sysauth", path = "system_auth_filter_enabled", setter = "set_system_auth_filter_enabled" },
}

--- Selects a real manifest-rendered Metrics row without scanning source text.
--- @param menu table Current actual menu image.
--- @param id string Metrics row id.
--- @return table
local function find_row(menu, id)
	local key = id == "encryption" and "menu.metrics.encrypt_toggle" or "menu.metrics." .. id
	for _, parent in ipairs(menu) do
		if parent.title == I18n.get("menu.metrics.title") then
			for _, row in ipairs(parent.menu or {}) do
				if row.title == I18n.get(key) then return row end
			end
		end
	end
	error("Actual Metrics privacy action is absent: " .. id)
end

--- Isolates only the destination path; collector, writer and TOML reader are real.
--- @param body function Receives fresh collector and menu modules.
local function with_private_config(body)
	local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-menu-privacy-XXXXXX"))
	local config = ConfigPaths.config
	ConfigPaths.config = function(name) return directory .. "/" .. name end
	local ok, err = xpcall(function()
		local collector = assert(loadfile(helpers.driver_root() .. "/modules/keylogger/keylogger.lua"))()
		local menu = assert(loadfile(helpers.driver_root() .. "/ui/menu/menu_builder.lua"))()
		assert(collector.set_enabled(true))
		body(collector, menu)
	end, debug.traceback)
	ConfigPaths.config = config
	local scan = assert(uv.fs_scandir(directory))
	while true do
		local name, kind = uv.fs_scandir_next(scan)
		if not name then break end
		assert(kind == "file", "fixture must not create nested resources")
		assert(uv.fs_unlink(directory .. "/" .. name))
	end
	assert(uv.fs_rmdir(directory))
	if not ok then error(err, 0) end
end

helpers.describe("metrics privacy menu publication", function()
	for _, spec in ipairs(FILTERS) do
		for _, initial in ipairs({ false, true }) do
			for _, refused in ipairs({ false, true }) do
				helpers.it("(metrics-privacy-publication) " .. spec.id .. " initial=" .. tostring(initial)
					.. " refused=" .. tostring(refused), function()
					with_private_config(function(collector, menu)
						assert(collector[spec.setter](initial))
						local scope = { pending = function() return false end }
						local acquired = false
						local ok, err = xpcall(function()
							if refused then assert(Preferences.acquire(scope)); acquired = true end
							local expected, rebuilds = initial, 0
							if not refused then expected = not initial end
							local context = { keylogger = collector }
							context.on_menu_changed = function()
								rebuilds = rebuilds + 1
								helpers.assert_eq(collector.get_privacy_state()[spec.path], expected,
									"the observer must see the acknowledged live posture")
								helpers.assert_eq(Preferences.get("metrics." .. spec.path), expected,
									"the observer must see the same durable TOML choice")
								helpers.assert_eq(find_row(menu.build(context), spec.id).checked, expected)
							end
							local action = find_row(menu.build(context), spec.id)
							helpers.assert_eq(action.checked, initial)
							helpers.assert_eq(action.disabled, nil)
							local result = action.fn()
							helpers.assert_eq(collector.get_privacy_state()[spec.path], expected)
							helpers.assert_eq(Preferences.get("metrics." .. spec.path), expected)
							if spec.id == "filter_private" then
								helpers.assert_eq(collector.is_context_protected("firefox", "Synthetic — Private Browsing"), expected)
							end
							helpers.assert_eq(rebuilds, 1, "every completed attempt republishes the actual state once")
							helpers.assert_eq(result, not refused, "preserve the filter setter's acknowledgement")
						end, debug.traceback)
						if acquired then assert(Preferences.release(scope)) end
						if not ok then error(err, 0) end
					end)
				end)
			end
		end
	end

	for _, initial in ipairs({ false, true }) do
		for _, refused in ipairs({ false, true }) do
			helpers.it("(metrics-privacy-publication) encryption posture initial=" .. tostring(initial)
				.. " refused=" .. tostring(refused), function()
				local value, rebuilds, writes = initial, 0, 0
				local menu = assert(loadfile(helpers.driver_root() .. "/ui/menu/menu_builder.lua"))()
				local context = { keylogger = {
					is_enabled = function() return true end,
					get_privacy_state = function() return { encrypt = value } end,
					-- The real encryption setter returns its posture, not a write ACK.
					set_encrypt_enabled = function(wanted)
						writes = writes + 1
						if refused then return false end
						value = wanted
						return value
					end,
				} }
				local expected = initial
				if not refused then expected = not initial end
				context.on_menu_changed = function()
					rebuilds = rebuilds + 1
					helpers.assert_eq(find_row(menu.build(context), "encryption").checked, expected)
				end
				local result = find_row(menu.build(context), "encryption").fn()
				helpers.assert_eq(value, expected)
				helpers.assert_eq({ writes, rebuilds }, { 1, 1 })
				helpers.assert_eq(result, not refused and expected or false)
			end)
		end
	end

	for _, spec in ipairs(FILTERS) do
		helpers.it("(metrics-privacy-publication) " .. spec.id .. " without optional observer", function()
			with_private_config(function(collector, menu)
				assert(collector[spec.setter](true))
				local result = find_row(menu.build({ keylogger = collector }), spec.id).fn()
				helpers.assert_eq(collector.get_privacy_state()[spec.path], false)
				helpers.assert_eq(Preferences.get("metrics." .. spec.path), false)
				helpers.assert_eq(result, true)
			end)
		end)
	end
end)

return helpers
