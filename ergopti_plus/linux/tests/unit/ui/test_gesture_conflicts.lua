--- tests/unit/ui/test_gesture_conflicts.lua

--- ==============================================================================
--- MODULE: Desktop Gesture Conflict Behavior
--- DESCRIPTION:
--- Checks cached menu status, actual reader posture, and explicit dismissal at
--- the shell and modal boundaries without starting a desktop or grabbing input.
--- ==============================================================================

local h = require("tests.helpers")

--- Executes one isolated notice scenario and restores every module boundary.
--- @param choice string Simulated list selection; empty means cancellation.
--- @param body function Assertions against the real module and observed effects.
--- @param strings table|nil Canonical translation input for the owned renderer.
local function scenario(choice, body, strings)
	local names = { "ui.gesture_conflicts", "infra.i18n", "adapters.storage", "adapters.shell_runner",
		"logger.shim", "adapters.event_loop", "ui.modal", "infra.manifest_menu", "menu.renderer", "infra.paths", "json" }
	local saved, store, queued = {}, {}, {}
	local observed = { shells = 0, modals = 0, dialogs = 0 }
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	package.loaded["infra.i18n"] = { get = function(key)
		if strings then return strings[key] or key end
		if key == "gestures.system.slot_unknown_caption" then return "%s — gestures.system.unknown" end
		return key
	end, section = function(key) return strings and strings[key] or key end }
	package.loaded["adapters.storage"] = { get = function(key) return store[key] end,
		set = function(key, value) store[key] = value; return true end }
	package.loaded["adapters.shell_runner"] = {
		quote = function(value) return "'" .. value .. "'" end,
		has_command = function() observed.shells = observed.shells + 1; return false end,
		run = function() observed.shells = observed.shells + 1; return true end,
		exec_checked = function() observed.dialogs = observed.dialogs + 1; return choice ~= "", choice end,
	}
	package.loaded["logger.shim"] = { warn = function() end, error = function() end }
	package.loaded["adapters.event_loop"] = { defer = function(fn) queued[#queued + 1] = fn; return true end }
	package.loaded["ui.modal"] = { run = function(fn) observed.modals = observed.modals + 1; return fn() end }
	local ok, err = xpcall(function() body(require("ui.gesture_conflicts"), observed, store, queued) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

h.describe("system gesture conflicts", function()
	h.it("builds status from the real reader without shell probes and deduplicates groups", function()
		scenario("", function(module, observed)
			local gestures = { DEFAULT_GESTURES = { swipe_3_left = "none", swipe_3_right = "none", tap_2 = "none" },
				is_enabled = function() return true end, is_reading = function() return false end,
				get_action = function(slot) return slot == "tap_2" and "none" or "tab_next" end }
			h.assert_eq(#module.groups(gestures), 1)
			local rows = module.rows(gestures)
			h.assert_eq(rows[1].label, "gestures.system.unknown")
			h.assert_eq(rows[1].items[1].label, "menu.gestures.reading_off")
			h.assert_eq(observed.shells, 0)
			gestures.is_reading = function() return true end
			h.assert_eq(module.rows(gestures)[1].items[1].label, "menu.gestures.reading_on")
			gestures.is_enabled = function() return false end
			h.assert_eq(#module.groups(gestures), 0)
		end)
	end)
	for _, choice in ipairs({ "", "gestures.system.dismiss" }) do
		h.it("persists only explicit dismissal: " .. choice, function()
			scenario(choice, function(module, observed, store, queued)
				local group = { key = "swipe_3", slot = "swipe_3_left" }
				module.show(group)
				h.assert_eq(observed.dialogs, 0)
				table.remove(queued, 1)()
				h.assert_eq(observed.dialogs, 1)
				h.assert_eq(observed.modals, 1)
				h.assert_eq(store["gesture_conflict_dismissed.swipe_3"], choice ~= "" and true or nil)
				module.show({ key = "swipe_3", slot = "swipe_3_right" })
				h.assert_eq(#queued, choice ~= "" and 0 or 1)
			end)
		end)
	end
	h.it("maps only supported touchpad panels", function()
		scenario("", function(module)
			h.assert_eq(module.settings_command("GNOME"), "gnome-control-center mouse")
			h.assert_eq(module.settings_command("KDE"), "systemsettings kcm_touchpad")
			h.assert_eq(module.settings_command("unknown"), nil)
		end)
	end)
end)


--- Reads an independently stored caption corpus or canonical source translation.
--- @param relative string Shared-tree source path.
--- @return table
local function status_json(relative)
	local file = assert(io.open(h.driver_root() .. "/../_shared/" .. relative, "rb"))
	local parsed = require("json").decode(file:read("*a"))
	file:close()
	return parsed
end

--- Actual runtime manager boundary with one deduplicated potential-overlap group.
--- @return table
local function cached_status_manager()
	return { DEFAULT_GESTURES = { swipe_3_left = "none", swipe_3_right = "none", tap_2 = "none" },
		is_enabled = function() return true end, is_reading = function() return false end,
		get_action = function(slot) return slot == "tap_2" and "none" or "tab_next" end }
end

h.describe("desktop gesture status uses genuine shared frames", function()
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		h.it("keeps prior unknown posture and native reader captions: " .. locale, function()
			local strings = status_json("data/locales/" .. locale .. ".json")
			local prior = status_json("tests/corpus/menus/gesture_system_status_captions.json").captions[locale]
			scenario("", function(module, observed)
				local native = cached_status_manager()
				module.settings_command = function() return "supported-native-panel" end
				local rows = module.rows(native)
				h.assert_eq(#rows, 1)
				h.assert_eq(rows[1].label, prior.unknown)
				h.assert_eq(#rows[1].items, 2, "only native reader and actual potential overlap remain")
				h.assert_eq(rows[1].items[1].label, strings["menu.gestures.reading_off"])
				h.assert_eq(rows[1].items[1].disabled, true)
				h.assert_eq(rows[1].items[2].label, strings["gesture.slots.swipe_3_left"] .. " — " .. prior.unknown)
				native.is_reading = function() return true end
				h.assert_eq(module.rows(native)[1].items[1].label, strings["menu.gestures.reading_on"])
				native.is_enabled = function() return false end
				module.settings_command = function() return nil end
				rows = module.rows(native)
				h.assert_eq(rows[1].label, prior.unknown, "an empty inventory cannot certify native compositor policy")
				h.assert_eq(#rows[1].items, 2)
				h.assert_eq(rows[1].items[2].label, prior.unknown)
				h.assert_eq(rows[1].items[2].disabled, true)
				h.assert_eq(observed.shells, 0)
				h.assert_eq(observed.dialogs, 0)
				h.assert_eq(observed.modals, 0)
			end, strings)
		end)
	end

	for _, section in ipairs({ "gesture_system_status_linux_frame", "gesture_system_status_unknown",
		"gesture_system_linux_children", "gesture_system_linux_reading_frame", "gesture_system_slot_linux_frame" }) do
		h.it("refuses withdrawn " .. section .. " without shell or modal effects", function()
			scenario("", function(module, observed)
				local renderer = require("infra.manifest_menu")
				renderer.get_root()[section] = {}
				h.assert_eq(module.rows(cached_status_manager()), {})
				h.assert_eq(observed.shells, 0)
				h.assert_eq(observed.dialogs, 0)
				h.assert_eq(observed.modals, 0)
			end)
		end)
	end

	for _, getter in ipairs({ "gesture_system_reader_active", "gesture_system_settings_unavailable" }) do
		for _, refusal in ipairs({ "missing", "non_boolean", "throw" }) do
			h.it("refuses " .. refusal .. " actual desktop predicate " .. getter, function()
				scenario("", function(module, observed)
					local renderer = require("infra.manifest_menu")
					local template = renderer.template_rows
					renderer.template_rows = function(key, commands, getters, children)
						if getters and getters[getter] then
							if refusal == "missing" then getters[getter] = nil
							elseif refusal == "non_boolean" then getters[getter] = function() return "true" end
							else getters[getter] = function() error("independent desktop predicate refusal", 0) end end
						end
						return template(key, commands, getters, children)
					end
					h.assert_eq(module.rows(cached_status_manager()), {})
					h.assert_eq(observed.shells, 0)
					h.assert_eq(observed.dialogs, 0)
				end)
			end)
		end
	end

	h.it("retains the actual overlap Settings callback and its refusal", function()
		scenario("", function(module, observed)
			local calls, replacements = 0, 0
			module.settings_command = function() return "supported-native-panel" end
			module.open_settings = function() calls = calls + 1; return false end
			local held = module.rows(cached_status_manager())[1].items[2].action
			module.open_settings = function() replacements = replacements + 1; return true end
			h.assert_eq(held(), false)
			h.assert_eq(calls, 1)
			h.assert_eq(replacements, 0)
			h.assert_eq(observed.shells, 0)
		end)
	end)
end)
