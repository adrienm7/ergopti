--- tests/unit/modules/gestures/config/test_gestures_manager_gesture_parameter_binding.lua

--- ==============================================================================
--- MODULE: Gestures Manager Tests
--- Tests the Linux gestures module — action registry, slot management,
--- enable/disable, menu integration.
--- ==============================================================================

package.loaded["tests.support.modules.gestures.config.gestures_manager_fixture"] = nil
local Fixture = require("tests.support.modules.gestures.config.gestures_manager_fixture")
local helpers, binding_source_fixture =
	Fixture.helpers, Fixture.binding_source_fixture




helpers.describe("gesture parameter binding publication with the real script owner", function()
	helpers.it("binding-identity: actual script publication distinguishes current and retired qualified domains", function()
		local owner = require("modules.shortcuts.script_chords")
		owner.catalogue()
		local publication = owner.published_binding_catalogue()
		helpers.assert_true(type(publication) == "table")
		helpers.assert_eq(publication.slots.script_altgr_enter, true)
		helpers.assert_nil(publication.slots.reload)
		local manager = helpers.load_module("modules.gestures.manager")
		helpers.assert_eq(manager.action_parameter_binding_fits("script__script_altgr_enter"), true)
		helpers.assert_eq(manager.action_parameter_binding_fits("script__reload"), false)
		helpers.assert_nil(manager.action_parameter_binding_fits("tap_hold__future_unjudged"))
		manager.init({ persist = false, enabled = false })
		helpers.assert_true(manager.set_action_parameter("script__script_altgr_enter", "open_url", "https://current.example"))
		helpers.assert_eq(manager.set_action_parameter("script__reload", "open_url", "https://must-not-activate.example"), false)
		helpers.assert_eq(manager.get_action_parameter("script__script_altgr_enter", "open_url"), "https://current.example")
		helpers.assert_eq(manager.get_action_parameter("script__reload", "open_url"), "")
	end)
end)




require("test.tap_binding_publication_contract").register(require("tests.helpers"), "linux")




require("test.binding_publication_authority_contract").register(require("tests.helpers"), "linux")




require("test.keyboard_binding_publication_contract").register(require("tests.helpers"), "linux")




require("test.script_binding_publication_contract").register_late(require("tests.helpers"), "linux")




-- Genuine constructor/source withdrawal controls are additive. The earlier
-- public-copy, malformed constructor, writer and cleanup assertions stay exact.
helpers.describe("gesture private generated publication authority", function()
	local owner_name, source_name = "modules.gestures.manager", "_generated.action_catalogue"
	local function clone(value)
		local copy = {}
		for key, item in next, value do copy[key] = item end
		return copy
	end
	local function owned(body)
		local saved, undo = {}, {}
		for name, value in next, package.loaded do saved[name] = value end
		local previous_open = io.open
		local logger, previous_warn
		local function defer(callback) undo[#undo + 1] = callback end
		local okay, detail = xpcall(function()
			logger = require("logger.shim"); previous_warn = logger.warn
			local manager = helpers.load_module(owner_name)
			local source = require(source_name)
			helpers.assert_true(rawequal(rawget(package.loaded, owner_name), manager))
			helpers.assert_eq(manager.action_parameter_binding_fits("tap_3"), true)
			helpers.assert_eq(manager.action_parameter_binding_fits("swipe_3_horiz"), true)
			helpers.assert_eq(manager.action_parameter_binding_fits("removed_gesture_slot"), false)
			body(manager, source, defer)
		end, debug.traceback)
		local cleanup = {}
		for index = #undo, 1, -1 do
			local restored, error_text = pcall(undo[index])
			if not restored then cleanup[#cleanup + 1] = tostring(error_text) end
		end
		io.open = previous_open
		if logger then logger.warn = previous_warn end
		for name in next, package.loaded do if saved[name] == nil then rawset(package.loaded, name, nil) end end
		for name, value in next, saved do rawset(package.loaded, name, value) end
		if not okay then error(detail .. (#cleanup > 0 and "\nOwned cleanup failed: " .. table.concat(cleanup, "\n") or ""), 0) end
		if #cleanup > 0 then error(table.concat(cleanup, "\n"), 0) end
	end
	local function dry(body)
		local previous_open, effects = io.open, 0
		io.open = function() effects = effects + 1; error("classification must not read or initialize") end
		local okay, detail = xpcall(body, debug.traceback)
		io.open = previous_open
		helpers.assert_eq(effects, 0, "published classification performs no IO")
		if not okay then error(detail, 0) end
	end
	local function unavailable(manager, getter)
		dry(function()
			helpers.assert_nil(manager.action_parameter_binding_fits("tap_3"))
			helpers.assert_nil(manager.action_parameter_binding_fits("removed_gesture_slot"))
			helpers.assert_nil(getter(), "the retained genuine getter cannot borrow changed authority")
		end)
	end
	local function repaired(manager)
		dry(function()
			helpers.assert_eq(manager.action_parameter_binding_fits("tap_3"), true)
			helpers.assert_eq(manager.action_parameter_binding_fits("removed_gesture_slot"), false)
			helpers.assert_eq(manager.action_parameter_binding_fits("Tap_3"), false)
			helpers.assert_nil(manager.action_parameter_binding_fits("tap_hold__future_unjudged"))
		end)
	end

	helpers.it("binding-identity: constructor publication is detached from returned rows and public runtime copies", function()
		owned(function(manager, source, defer)
			local getter = manager.published_binding_catalogue
			local genuine_single, genuine_axis = clone(source.slots.single), clone(source.slots.axis)
			helpers.assert_true(type(getter) == "function")
			local publication = getter()
			helpers.assert_eq(publication.prefix, "")
			helpers.assert_eq(publication.slots.tap_3, true)
			helpers.assert_eq(publication.slots.swipe_3_horiz, true)
			helpers.assert_nil(publication.slots.removed_gesture_slot)
			publication.slots.tap_3, publication.slots.removed_gesture_slot = nil, true
			manager.DEFAULT_GESTURES.removed_gesture_slot = "none"
			manager.SINGLE_SLOTS[#manager.SINGLE_SLOTS + 1] = "removed_gesture_slot"
			manager.AXIS_SLOTS = { "removed_gesture_slot" }
			repaired(manager)
			local again = getter()
			helpers.assert_true(not rawequal(again, publication) and not rawequal(again.slots, publication.slots))
			helpers.assert_eq(again.slots.tap_3, true)
			helpers.assert_nil(again.slots.removed_gesture_slot)
			helpers.assert_eq(source.slots.single, genuine_single, "public copies do not mutate the genuine single source")
			helpers.assert_eq(source.slots.axis, genuine_axis, "public copies do not mutate the genuine axis source")
		end)
	end)

	for _, vector in ipairs({ "missing", "false", "equal clone", "proxy" }) do
		local kind = vector
		helpers.it("binding-identity: genuine package withdrawal stays unjudged for " .. kind, function()
			owned(function(manager, source, defer)
				local getter, effects = manager.published_binding_catalogue, 0
				local successor
				if kind == "false" then successor = false
				elseif kind == "equal clone" then successor = clone(manager)
				elseif kind == "proxy" then successor = setmetatable({}, {
					__index = function() effects = effects + 1; return getter end,
					__eq = function() effects = effects + 1; return true end }) end
				package.loaded[owner_name] = successor
				unavailable(manager, getter)
				helpers.assert_eq(effects, 0, "a foreign package's equality/accessors cannot certify a native owner")
				package.loaded[owner_name] = manager
				repaired(manager)
			end)
		end)
	end

	helpers.it("binding-identity: a retained manager cannot borrow a genuine successor constructor", function()
		owned(function(manager, source, defer)
			local getter = manager.published_binding_catalogue
			local successor = helpers.load_module(owner_name)
			helpers.assert_true(not rawequal(manager, successor))
			helpers.assert_eq(successor.action_parameter_binding_fits("tap_3"), true)
			helpers.assert_eq(successor.action_parameter_binding_fits("removed_gesture_slot"), false)
			unavailable(manager, getter)
			package.loaded[owner_name] = manager
			repaired(manager)
		end)
	end)

	helpers.it("binding-identity: withdrawn and proxy accessors never execute replacements", function()
		owned(function(manager, source, defer)
			local getter, effects = manager.published_binding_catalogue, 0
			defer(function() setmetatable(manager, nil); manager.published_binding_catalogue = getter end)
			manager.published_binding_catalogue = nil
			unavailable(manager, getter)
			manager.published_binding_catalogue = function() effects = effects + 1; return getter() end
			unavailable(manager, getter)
			manager.published_binding_catalogue = nil
			setmetatable(manager, { __index = function() effects = effects + 1; return getter end })
			unavailable(manager, getter)
			helpers.assert_eq(effects, 0)
			setmetatable(manager, nil); manager.published_binding_catalogue = getter
			repaired(manager)
		end)
	end)

	for _, vector in ipairs({ "missing", "false", "equal clone", "proxy" }) do
		local kind = vector
		helpers.it("binding-identity: actual generated package withdrawal stays unjudged for " .. kind, function()
			owned(function(manager, source, defer)
				local getter, effects = manager.published_binding_catalogue, 0
				local successor
				if kind == "false" then successor = false
				elseif kind == "equal clone" then successor = clone(source)
				elseif kind == "proxy" then successor = setmetatable({}, {
					__index = function() effects = effects + 1; return source.slots end,
					__eq = function() effects = effects + 1; return true end }) end
				package.loaded[source_name] = successor
				unavailable(manager, getter)
				helpers.assert_eq(effects, 0)
				package.loaded[source_name] = source
				repaired(manager)
			end)
		end)
	end

	for _, vector in ipairs({ "slots container", "single array", "axis array", "scalar", "order", "append", "hole", "foreign key", "array proxy", "source proxy" }) do
		local kind = vector
		helpers.it("binding-identity: genuine private generated source withdraws on " .. kind, function()
			owned(function(manager, source, defer)
				local getter, slots = manager.published_binding_catalogue, source.slots
				local single, axis, first, second = slots.single, slots.axis, slots.single[1], slots.single[2]
				local effects, restore = 0, nil
				local function retain(callback) restore = callback; defer(callback) end
				if kind == "slots container" then
					retain(function() source.slots = slots end); source.slots = clone(slots)
				elseif kind == "single array" then
					retain(function() slots.single = single end); slots.single = clone(single)
				elseif kind == "axis array" then
					retain(function() slots.axis = axis end); slots.axis = clone(axis)
				elseif kind == "scalar" then
					retain(function() single[1] = first end); single[1] = "removed_gesture_slot"
				elseif kind == "order" then
					helpers.assert_true(type(first) == "string" and type(second) == "string" and first ~= second)
					retain(function() single[1], single[2] = first, second end); single[1], single[2] = second, first
				elseif kind == "append" then
					local index = #single + 1; retain(function() single[index] = nil end); single[index] = "removed_gesture_slot"
				elseif kind == "hole" then
					retain(function() single[1] = first end); single[1] = nil
				elseif kind == "foreign key" then
					helpers.assert_nil(rawget(single, "owned_test_extra")); retain(function() single.owned_test_extra = nil end)
					single.owned_test_extra = "removed_gesture_slot"
				elseif kind == "array proxy" then
					retain(function() setmetatable(single, nil) end)
					setmetatable(single, { __pairs = function() effects = effects + 1; error("source proxy must not run") end,
						__index = function() effects = effects + 1; return first end })
				else
					retain(function() setmetatable(source, nil) end)
					setmetatable(source, { __pairs = function() effects = effects + 1; error("source proxy must not run") end })
				end
				unavailable(manager, getter)
				helpers.assert_eq(effects, 0, "source withdrawal checks raw identities and scalars")
				helpers.assert_true(type(restore) == "function", "the actual source mutator owns its exact inverse")
				restore()
				repaired(manager)
			end)
		end)
	end

	helpers.it("binding-identity: withdrawn genuine classification consumes parameters without offering source cleanup", function()
		owned(function(manager, source, defer)
			-- Private fresh reporting/cleanup owners retain the preexisting singleton's
			-- warning state. Their production bodies are unchanged and later restored.
			package.loaded.config_outdated, package.loaded.config_unused_keys = nil, nil
			local outdated = require("config_outdated")
			local cleanup = require("config_unused_keys")
			manager = helpers.load_module(owner_name)
			local content = [[# Independently written real cleanup source
[linux.action_parameters]
removed_gesture_slot__open_url = "https://owned-legacy.example"
tap_3__open_url = "https://owned-current.example"
[gesture_parameters]
removed_gesture_slot__open_url = "https://owned-current-retired.example"
swipe_3_horiz__open_url = "https://owned-axis.example"
]]
			binding_source_fixture(content, function(loaded, path, read)
				manager = loaded
				local function scan() return cleanup.find_in_source(content, function(document, mark) manager.mark_config_reads(document, mark) end) end
				local active = scan()
				helpers.assert_eq(active.status, "ok"); helpers.assert_eq(#active.keys, 2)
				local getter = manager.published_binding_catalogue
				package.loaded[owner_name] = nil
				unavailable(manager, getter)
				local reports = outdated.collect_reports(function()
					local pending = scan()
					helpers.assert_eq(pending.status, "ok"); helpers.assert_eq(pending.keys, {})
				end)
				helpers.assert_eq(reports, {}, "unavailable publication is not retirement evidence")
				package.loaded[owner_name] = manager
				repaired(manager)
				local again = scan()
				helpers.assert_eq(again.status, "ok"); helpers.assert_eq(#again.keys, 2)
				helpers.assert_eq(read(), content, "classification and preview never publish or alter the owned file")
			end)
		end)
	end)
end)

