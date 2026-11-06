--- tests/unit/modules/updater/install/test_install_owned_smoke_deadline.lua

--- ==============================================================================
--- MODULE: Owned Install Smoke Deadline (Linux)
--- DESCRIPTION:
--- Runs the actual async installer over a real standalone tree whose updated
--- wrapper answers `--help` slowly. The smoke used to run os.execute on the
--- event loop: no timer fired while it waited and the install deadline was
--- observed only after it returned. Now the event loop keeps ticking, the
--- deadline kills the wrapper's process group, and the previous installation
--- is restored. Only the archive reader factory is modeled.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv = require("luv")
local Installer = require("modules.updater.installer")
local Fixture = require("tests.support.modules.updater.installer_native_fixture")
local Budget = require("updater.install_budget")

local function now() return uv.hrtime() / 1e6 end

--- Runs one async install whose new wrapper first runs `body`.
--- @param body string Shell lines of the updated wrapper before it exits 0.
--- @param budget_ms number Original install deadline.
--- @return table outcome { ok, detail, elapsed_ms, ticks, fixture }.
local function install_with_wrapper(body, budget_ms)
	local f = Fixture.create(Installer)
	local payload = f.root .. "/payload/bin/ergopti-hotstrings"
	Fixture.write(payload, "#!/bin/sh\n" .. body .. "exit 0\n")
	assert(uv.fs_chmod(payload, 493))
	local token = assert(Budget.capture({ release_install = { install_timeout_ms = budget_ms } }, now()))
	local reservation = {}
	local function child(done, result)
		local operation = {}
		function operation:is_settled() return true end
		function operation:request_cancel() return true end
		function operation:on_settled(listener) listener(); return true end
		done(result)
		return operation
	end
	local factory = {}
	function factory.install_current(r) assert(r == reservation); return Budget.admit(token, now()) end
	function factory.install_feed(r, kind, dir, done)
		assert(r == reservation)
		if kind == "extract" then return child(done, { ok = f.ops.extract(f.archive, dir) }) end
		return child(done, { ok = true, stdout = kind == "names" and "linux/\n_shared/\nbin/\ninstall.sh\n"
			or "drwxr-xr-x linux/\n-rwxr-xr-x install.sh\n" })
	end
	function factory.finish_install(r, _, done) assert(r == reservation); return child(done, { ok = true }) end
	local outcome = { fixture = f, ticks = 0 }
	local heartbeat = assert(uv.new_timer())
	heartbeat:start(10, 10, function() outcome.ticks = outcome.ticks + 1 end)
	local watchdog = assert(uv.new_timer())
	watchdog:start(10000, 0, function() uv.stop() end)
	uv.update_time()
	local started = now()
	local operation = assert(Installer.install_owned({ factory = factory, reservation = reservation,
		context = f.context, expected_version = "1.2.3" }, function(ok, detail)
		outcome.ok, outcome.detail, outcome.elapsed_ms = ok, detail, now() - started
		uv.stop()
	end))
	if outcome.elapsed_ms == nil then uv.run("default") end
	heartbeat:stop(); heartbeat:close(); watchdog:stop(); watchdog:close()
	uv.run("nowait")
	outcome.settled = operation:is_settled()
	return outcome
end

helpers.describe("Owned install smoke deadline", function()
	helpers.it("keeps the event loop running and kills a wrapper past the install deadline (install-owned-smoke-deadline)",
		function()
		local outcome = install_with_wrapper("sleep 5\n", 400)
		local f = outcome.fixture
		local ok, err = pcall(function()
			helpers.assert_true(outcome.elapsed_ms ~= nil, "the install completed")
			helpers.assert_true(outcome.elapsed_ms < 3000, "the deadline bounded the smoke: " .. tostring(outcome.elapsed_ms))
			helpers.assert_true(outcome.ticks >= 5, "the event loop kept running during the smoke: " .. outcome.ticks)
			helpers.assert_eq(outcome.ok, false, "a smoke past the deadline fails the install")
			helpers.assert_true(Fixture.read(f.installed .. "/old.marker") ~= nil, "the previous installation is restored")
			helpers.assert_true(outcome.settled, "the operation settled once")
		end)
		Fixture.remove(f.root)
		assert(ok, err)
	end)

	helpers.it("installs when the updated wrapper answers in time (install-owned-smoke-healthy)", function()
		local outcome = install_with_wrapper("", 5000)
		local f = outcome.fixture
		local ok, err = pcall(function()
			helpers.assert_eq(outcome.ok, true, "a healthy smoke installs: " .. tostring(outcome.detail))
			helpers.assert_true(Fixture.read(f.installed .. "/linux/new.marker") ~= nil, "the new installation is active")
		end)
		Fixture.remove(f.root)
		assert(ok, err)
	end)
end)
