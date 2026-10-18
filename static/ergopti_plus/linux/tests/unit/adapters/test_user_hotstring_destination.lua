--- tests/unit/adapters/test_user_hotstring_destination.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Destination Tests
--- DESCRIPTION:
--- Exercises the real bounded AT-SPI adapter and its cached destination receipt.
--- Labels cannot substitute for a native bus and accessible object identity.
--- ==============================================================================

local helpers = require("tests.helpers")
local Atspi = require("adapters.atspi_focus")
local Destination = require("adapters.user_hotstring_destination")

local function response(bus, path, active, role)
	return 'FOCUS:' .. require("json").encode({ role = role or 61, name = "Identical document",
		attributes = {}, native_bus_name = bus, native_object_path = path, active_scope = active })
end

local function with_snapshot(body)
	local state = { bus = ":1.42", path = "/org/a11y/atspi/accessible/7", active = true, role = 61 }
	Atspi._set_backend_for_test(nil)
	Atspi._set_command_runner_for_test(function(command)
		state.probes = (state.probes or 0) + 1
		helpers.assert_contains(command, "timeout -s KILL", "real helper isolation remains in use")
		if state.raise then error("controlled native helper failure") end
		if state.timeout then return false, "FOCUS:{}" end
		return true, response(state.bus, state.path, state.active, state.role)
	end)
	local ok, problem = xpcall(function() body(state) end, debug.traceback)
	Atspi._set_command_runner_for_test(nil)
	if not ok then error(problem, 0) end
end

--- Constructs the production focus adapter on a compositor without window IPC.
--- Native accessibility still uses the bounded helper owned above.
--- @return table WindowInfo
local function unsupported_wayland()
	local names = { "adapters.window_info", "adapters.shell_runner", "infra.display_server" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	package.loaded["infra.display_server"] = {
		is_wayland = function() return true end, is_x11 = function() return false end,
		desktop = function() return "GNOME" end,
	}
	package.loaded["adapters.shell_runner"] = { has_command = function() return false end }
	local ok, adapter = pcall(helpers.load_module, "adapters.window_info")
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(adapter, 0) end
	return adapter
end

helpers.describe("programmable native Linux destination", function()
	helpers.it("(linux-ai-text-identity) queries the exact active field freshly without compositor identity", function()
		with_snapshot(function(s)
			local window = unsupported_wayland()
			local first = window.focused_text_identity()
			helpers.assert_eq(first, "atspi::1.42:/org/a11y/atspi/accessible/7")
			helpers.assert_eq(s.probes, 1, "one target read must issue exactly one bounded helper probe")
			s.path = "/org/a11y/atspi/accessible/8"
			helpers.assert_eq(window.focused_text_identity(), "atspi::1.42:/org/a11y/atspi/accessible/8",
				"two controls in one native window must have different AI destinations")
			helpers.assert_eq(s.probes, 2, "a new target read must not reuse an earlier native result")
			s.timeout = true
			helpers.assert_nil(window.focused_text_identity(), "cached evidence cannot replace a fresh field observation")
			s.timeout, s.raise = false, true
			helpers.assert_nil(window.focused_text_identity(), "a native helper exception cannot authorize text output")
		end)
	end)
	helpers.it("(linux-ai-text-identity) refuses private, inactive and non-native fields", function()
		with_snapshot(function(s)
			local window = unsupported_wayland()
			for _, field in ipairs({ "active", "bus", "path", "role" }) do
				local saved = s[field]
				s[field] = ({ active = false, bus = "org.editor", path = "7", role = 40 })[field]
				helpers.assert_nil(window.focused_text_identity(), field .. " cannot own AI text output")
				s[field] = saved
			end
		end)
	end)
	helpers.it("(linux-atspi-focus-identity) preserves native targeting without compositor window IPC", function()
		with_snapshot(function(s)
			local window = unsupported_wayland()
			local first = window.focused_identity()
			helpers.assert_eq(first, "atspi::1.42:/org/a11y/atspi/accessible/7")
			s.path = "/org/a11y/atspi/accessible/8"
			helpers.assert_eq(window.focused_identity(), "atspi::1.42:/org/a11y/atspi/accessible/8",
				"a fresh helper observation must detect programmatic focus changes")
			s.timeout = true
			helpers.assert_nil(window.focused_identity(), "a cached destination cannot authorize output after helper failure")
		end)
	end)
	helpers.it("(linux-atspi-focus-identity) rejects inactive, non-native and password destination identities", function()
		with_snapshot(function(s)
			local window = unsupported_wayland()
			for _, field in ipairs({ "active", "bus", "path", "role" }) do
				local saved = s[field]
				s[field] = ({ active = false, bus = "org.editor", path = "7", role = 40 })[field]
				helpers.assert_nil(window.focused_identity(), field .. " cannot authorize native focus output")
				s[field] = saved
			end
		end)
	end)
	helpers.it("(user-hotstrings-native) uses an exact detached bus/object receipt and rechecks actual focus", function()
		with_snapshot(function(s)
			helpers.assert_true(select(2, Atspi.get_snapshot()))
			local capture = Destination.capture()
			helpers.assert_eq(capture, { bus = ":1.42", path = "/org/a11y/atspi/accessible/7" })
			local snapshot = Atspi.cached_snapshot()
			snapshot.native_bus_name = ":1.999"
			helpers.assert_eq(Destination.capture(), capture, "caller mutation cannot alter cached native ownership")
			helpers.assert_true(Destination.current(capture))
			s.path = "/org/a11y/atspi/accessible/8"
			helpers.assert_eq(Destination.current(capture), false, "equal window labels cannot hide a field change")
		end)
	end)
	helpers.it("(user-hotstrings-native) rejects absent active scope, password controls and invalid native identities", function()
		with_snapshot(function(s)
			for _, field in ipairs({ "active", "bus", "path", "role" }) do
				local saved = s[field]
				s[field] = ({ active = false, bus = "org.editor", path = "7", role = 40 })[field]
				Atspi.get_snapshot()
				helpers.assert_nil(Destination.capture(), field .. " cannot own programmable execution")
				s[field] = saved
			end
		end)
	end)
	helpers.it("(user-hotstrings-native) retires the cached receipt when the actual bounded helper times out", function()
		with_snapshot(function(s)
			Atspi.get_snapshot()
			local capture = Destination.capture()
			helpers.assert_not_nil(capture)
			s.timeout = true
			helpers.assert_eq(Destination.current(capture), false)
			helpers.assert_nil(Atspi.cached_snapshot())
			helpers.assert_nil(Destination.capture())
		end)
	end)
end)
