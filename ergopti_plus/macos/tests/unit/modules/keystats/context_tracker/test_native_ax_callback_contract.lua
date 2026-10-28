--- tests/unit/modules/keystats/context_tracker/test_native_ax_callback_contract.lua

--- Uses the native observer argument order at actual public persistence boundaries.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.context_tracker.ax_native_callback_fixture")

local function sink(runtime, expected)
	local accepted, snapshots = runtime.sink()
	helpers.assert_eq(runtime.engine.may_persist(), expected)
	helpers.assert_eq(accepted, expected, "The public sink must follow the native focus notification")
	helpers.assert_eq(snapshots, expected and 1 or 0)
end

local function healthy(runtime)
	helpers.assert_eq(#runtime.observation.logs, 0)
	helpers.assert_eq(#runtime.ax_native.failures, 0)
end

local function secure(runtime, axis)
	runtime.native.field_role = axis == "role" and "AXSecureTextField" or "AXTextField"
	runtime.native.field_subrole = axis == "subrole" and "AXSecureTextField" or nil
end

local function ordinary(runtime)
	runtime.native.field_role, runtime.native.field_subrole = "AXTextField", nil
end

local function autocorrect(runtime, watcher)
	runtime.state.last_time = 0 -- The last physical key predates this native correction.
	runtime.native.field_value = "short"
	runtime.ax_native.emit("AXValueChanged", watcher)
	runtime.native.field_value = "substantially longer"
	runtime.ax_native.emit("AXValueChanged", watcher)
end

helpers.describe("Native AX observer callback contract", function()
	helpers.it("(native-ax-callback) keeps healthy ordinary focus admitted", function()
		Fixture.with_runtime(function(runtime)
			runtime.ax_native.emit("AXFocusedUIElementChanged")
			helpers.assert_eq(runtime.state.is_secure_field, false)
			sink(runtime, true); healthy(runtime)
		end)
	end)
	for _, axis in ipairs({ "role", "subrole" }) do
		helpers.it("(native-ax-callback) denies a secure focused " .. axis .. " in the same application", function()
			Fixture.with_runtime(function(runtime)
				secure(runtime, axis)
				runtime.ax_native.emit("AXFocusedUIElementChanged")
				helpers.assert_eq(runtime.state.is_secure_field, true)
				sink(runtime, false); healthy(runtime)
			end)
		end)
	end
	helpers.it("(native-ax-callback) recovers only through the current ordinary focus event", function()
		Fixture.with_runtime(function(runtime)
			secure(runtime, "subrole"); runtime.ax_native.emit("AXFocusedUIElementChanged")
			sink(runtime, false)
			ordinary(runtime); runtime.ax_native.emit("AXFocusedUIElementChanged")
			helpers.assert_eq(runtime.state.is_secure_field, false)
			sink(runtime, true); healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) delivers a real native value change to the autocorrect writer", function()
		Fixture.with_runtime(function(runtime)
			local before = #runtime.observation.context_rows
			autocorrect(runtime)
			helpers.assert_eq(#runtime.observation.context_rows, before + 1)
			helpers.assert_eq(runtime.observation.context_rows[before + 1].type, "sys_autocorrect")
			healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) keeps native value changes silent while paused", function()
		Fixture.with_runtime(function(runtime)
			runtime.native.field_value = "short"; runtime.ax_native.emit("AXValueChanged")
			runtime.pause()
			local before = #runtime.observation.context_rows
			runtime.native.field_value = "substantially longer"; runtime.ax_native.emit("AXValueChanged")
			helpers.assert_eq(#runtime.observation.context_rows, before)
			sink(runtime, false); healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) rejects a foreign observer before changing privacy", function()
		Fixture.with_runtime(function(runtime)
			secure(runtime, "subrole"); runtime.ax_native.emit("AXFocusedUIElementChanged", {})
			helpers.assert_eq(runtime.state.is_secure_field, false)
			sink(runtime, true); healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) rejects a replaced observer's retained callback", function()
		Fixture.with_runtime(function(runtime)
			local previous = runtime.state.ax_observer
			local callback = assert(previous.observer_callback)
			helpers.assert_eq(runtime.tracker.update_ax_observer(runtime.native.pid), true)
			helpers.assert_true(not rawequal(runtime.state.ax_observer, previous))
			secure(runtime, "subrole")
			runtime.ax_native.emit("AXFocusedUIElementChanged", previous, nil, callback)
			helpers.assert_eq(runtime.state.is_secure_field, false)
			sink(runtime, true); healthy(runtime)
		end)
	end)
	for _, axis in ipairs({ "role", "subrole" }) do
		helpers.it("(native-ax-callback) accepts an equal native wrapper while physically bound: " .. axis, function()
			Fixture.with_runtime(function(runtime)
				runtime.ax_native.bind()
				local owner = runtime.state.ax_observer
				local alias = runtime.ax_native.alias(owner)
				helpers.assert_true(not rawequal(alias, owner)); helpers.assert_true(alias == owner)
				secure(runtime, axis); runtime.ax_native.emit("AXFocusedUIElementChanged", alias)
				helpers.assert_eq(runtime.state.is_secure_field, true)
				helpers.assert_true(#runtime.ax_native.records > 1, "The real physical context writer must receive the focus boundary")
				sink(runtime, false); healthy(runtime)
			end)
		end)
	end
	helpers.it("(native-ax-callback) admits an ordinary equal native wrapper while physically bound", function()
		Fixture.with_runtime(function(runtime)
			runtime.ax_native.bind(); local alias = runtime.ax_native.alias()
			runtime.ax_native.emit("AXFocusedUIElementChanged", alias)
			helpers.assert_eq(runtime.state.is_secure_field, false)
			helpers.assert_true(#runtime.ax_native.records > 1)
			sink(runtime, true); healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) rejects a foreign wrapper without publishing physical receipts", function()
		Fixture.with_runtime(function(runtime)
			runtime.ax_native.bind(); runtime.ax_native.alias()
			local foreign = runtime.ax_native.alias({})
			local before = #runtime.ax_native.records
			secure(runtime, "subrole"); runtime.ax_native.emit("AXFocusedUIElementChanged", foreign)
			helpers.assert_eq(runtime.state.is_secure_field, false)
			helpers.assert_eq(#runtime.ax_native.records, before)
			sink(runtime, true); healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) rejects a stale native wrapper after physical observer replacement", function()
		Fixture.with_runtime(function(runtime)
			runtime.ax_native.bind()
			local previous = runtime.state.ax_observer
			local callback, alias = assert(previous.observer_callback), runtime.ax_native.alias(previous)
			helpers.assert_eq(runtime.tracker.update_ax_observer(runtime.native.pid), true)
			local before = #runtime.ax_native.records
			secure(runtime, "subrole")
			runtime.ax_native.emit("AXFocusedUIElementChanged", alias, nil, callback)
			helpers.assert_eq(runtime.state.is_secure_field, false)
			helpers.assert_eq(#runtime.ax_native.records, before)
			sink(runtime, true); healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) delivers value changes through an equal physical observer wrapper", function()
		Fixture.with_runtime(function(runtime)
			runtime.ax_native.bind(); local alias = runtime.ax_native.alias()
			local before = #runtime.observation.context_rows
			autocorrect(runtime, alias)
			helpers.assert_eq(#runtime.observation.context_rows, before + 1)
			helpers.assert_eq(runtime.observation.context_rows[before + 1].type, "sys_autocorrect")
			healthy(runtime)
		end)
	end)
	helpers.it("(native-ax-callback) restores aliases, field ports and cache owners after a forced body failure", function()
		local original_hs = rawget(_G, "hs")
		local original_tracker = package.loaded["modules.keystats.context_tracker"]
		local owner, field, original_attribute
		local ok, detail = pcall(Fixture.with_runtime, function(runtime)
			runtime.ax_native.bind(); owner = runtime.state.ax_observer
			field = runtime.ax_native.field
			original_attribute = runtime.ax_native.original_attribute
			runtime.ax_native.alias(owner)
			error("forced native callback fixture failure", 0)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(detail):find("forced native callback fixture failure", 1, true) ~= nil)
		helpers.assert_nil(getmetatable(owner))
		helpers.assert_true(rawequal(field.attributeValue, original_attribute))
		helpers.assert_true(rawequal(rawget(_G, "hs"), original_hs))
		helpers.assert_true(rawequal(package.loaded["modules.keystats.context_tracker"], original_tracker))
	end)
end)
