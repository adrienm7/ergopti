--- tests/unit/diagnostics/adapters/test_runtime_owner_ports.lua

--- ==============================================================================
--- MODULE: Owned Runtime Ports
--- DESCRIPTION:
--- Pins how diagnostics/adapters/runtime_owner_ports.lua turns command results into the
--- owner's answers: only read-only commands run, an unknown exit status is an
--- unknown answer (never "not loaded" or "none running"), and the shipped
--- manifest pins the artifact the owner admits.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the ports over a scripted command runner.
--- @param script function fn(executable, args) -> code, output.
--- @return table ports
--- @return table calls Recorded { executable, args }.
local function load_ports(script)
	local calls = {}
	package.loaded["diagnostics.adapters.field_check_ports"] = {
		exec = function(executable, args, _, callback)
			calls[#calls + 1] = { executable = executable, args = args }
			callback(script(executable, args))
		end,
	}
	package.loaded["diagnostics.adapters.runtime_owner_ports"] = nil
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	local ports = helpers.load_with_stubs("diagnostics.adapters.runtime_owner_ports", {
		processInfo = { processID = 777 },
	}).new()
	return ports, calls
end

--- Captures a callback's single argument.
--- @param register function fn(callback).
--- @return any value
local function answer(register)
	local value = "never called"
	register(function(result) value = result end)
	return value
end

helpers.describe("owned runtime ports", function()
	helpers.it("reads a job with a read-only print and maps the unknown-service status to not loaded", function()
		local ports, calls = load_ports(function() return 113, "" end)
		helpers.assert_eq(answer(function(cb) ports.launchd.loaded("com.ergoptiplus.runtime.core", cb) end), false)
		helpers.assert_eq(calls[1], { executable = "/bin/launchctl", args = { "print", "system/com.ergoptiplus.runtime.core" } })
	end)

	helpers.it("reports a loaded job and treats any other status or a timeout as unknown", function()
		local ports = load_ports(function() return 0, "" end)
		helpers.assert_eq(answer(function(cb) ports.launchd.loaded("x", cb) end), true)
		for _, code in ipairs({ 1, 5 }) do
			local other = load_ports(function() return code, "" end)
			helpers.assert_eq(answer(function(cb) other.launchd.loaded("x", cb) end), nil)
		end
		local timed_out = load_ports(function() return nil, "" end)
		helpers.assert_eq(answer(function(cb) timed_out.launchd.loaded("x", cb) end), nil)
	end)

	helpers.it("returns the extension listing only when the tool succeeded", function()
		local ports, calls = load_ports(function() return 0, "listing" end)
		helpers.assert_eq(answer(ports.system_extensions.listing), "listing")
		helpers.assert_eq(calls[1].args, { "list" })
		local failed = load_ports(function() return 1, "listing" end)
		helpers.assert_eq(answer(failed.system_extensions.listing), nil)
	end)

	helpers.it("counts the official user-side processes and distinguishes none from unknown", function()
		local several = load_ports(function() return 0, "11\n12\n" end)
		helpers.assert_eq(answer(several.coexistence.detect), 2)
		local none = load_ports(function() return 1, "" end)
		helpers.assert_eq(answer(none.coexistence.detect), 0)
		local broken = load_ports(function() return 2, "" end)
		helpers.assert_eq(answer(broken.coexistence.detect), nil)
		local timed_out = load_ports(function() return nil, "" end)
		helpers.assert_eq(answer(timed_out.coexistence.detect), nil)
	end)

	helpers.it("binds the consented closer and the capture owner, and no process of its own", function()
		local ports = load_ports(function() return 0, "" end)
		helpers.assert_type(ports.coexistence.close, "function")
		helpers.assert_type(ports.capture.start, "function")
		helpers.assert_type(ports.capture.on_lost, "function")
		helpers.assert_type(ports.timer.after, "function")
		helpers.assert_nil(ports.process, "the Console belongs to the launcher's installed-source role")
	end)

	helpers.it("raises one notice for the first block the user can act on, and none otherwise", function()
		-- An owned boot runs no setup wizard, so a missing runtime was silent.
		local ports = load_ports(function() return 0, "" end)
		helpers.assert_type(ports.observer, "function")
		local Ports = package.loaded["diagnostics.adapters.runtime_owner_ports"]
		local shown = {}
		local observe = Ports.block_notice(function(text) shown[#shown + 1] = text end)
		observe("starting")
		observe("ready")
		observe("failed", "capture_lost")
		helpers.assert_eq(#shown, 0)
		observe("unavailable", "runtime_not_installed")
		helpers.assert_eq(shown, { "notify.karabiner.owned_blocked" })
		observe("unavailable", "other_karabiner_running")
		observe("failed", "close_other_failed")
		helpers.assert_eq(#shown, 1, "one notice per launch")
		local later = Ports.block_notice(function(text) shown[#shown + 1] = text end)
		later("failed", "close_other_failed")
		helpers.assert_eq(#shown, 2)
	end)

	helpers.it("offers the first install once by itself and leaves other blocks to the notice", function()
		-- WP8: a missing runtime waited for the user to find a submenu row.
		load_ports(function() return 0, "" end)
		local Ports = package.loaded["diagnostics.adapters.runtime_owner_ports"]
		local saved = {}
		for _, name in ipairs({ "keyboard.engine", "core.timing.engine.deferred_work", "ai.ui.owned_runtime_install" }) do
			saved[name] = package.loaded[name]
		end
		local offers, deferred, shown = 0, {}, {}
		package.loaded["keyboard.engine"] = { OWNED_INSTALL_REASONS = { runtime_not_installed = true } }
		package.loaded["core.timing.engine.deferred_work"] = { after = function(_, fn) deferred[#deferred + 1] = fn; return true end }
		package.loaded["ai.ui.owned_runtime_install"] = { open = function() offers = offers + 1; return true end }
		local ok, failure = pcall(function()
			local observe = Ports.automatic_observer(function(text) shown[#shown + 1] = text end)
			observe("unavailable", "runtime_not_installed")
			helpers.assert_eq(#deferred, 1, "the offer waits for the scheduler, never inside the observer")
			helpers.assert_eq(offers, 0)
			deferred[1]()
			helpers.assert_eq(offers, 1)
			helpers.assert_eq(#shown, 0, "the offer is the notice")
			observe("unavailable", "runtime_not_installed")
			helpers.assert_eq(#deferred, 1, "one offer per launch")
			helpers.assert_eq(shown, { "notify.karabiner.owned_blocked" })
		end)
		for name, value in pairs(saved) do package.loaded[name] = value end
		assert(ok, failure)
	end)

	-- The owner judges the system extension listing, which reports the driver
	-- extension's version (1.8.0), never pqrs' package version (8.5.0).
	helpers.it("hands the owner the shipped pin: the driver extension version and the capture declaration", function()
		local ports = load_ports(function() return 0, "" end)
		local pinned, reason = ports.artifact.pinned()
		helpers.assert_nil(reason)
		helpers.assert_eq(pinned.virtual_hid_version, "1.8.0")
		helpers.assert_contains(pinned.capture.requirement, 'identifier "com.ergoptiplus.app"')
		helpers.assert_true(pinned.capture.batch_limit >= 1)
	end)

	helpers.it("names the shipped driver version and no unpinned field from the same manifest", function()
		load_ports(function() return 0, "" end)
		local Ports = package.loaded["diagnostics.adapters.runtime_owner_ports"]
		helpers.assert_eq(Ports.virtual_hid_version(), "8.5.0")
		helpers.assert_eq(Ports.virtual_hid_extension_version(), "1.8.0")
		helpers.assert_eq(Ports.unpinned_count(), 0)
	end)
end)
