--- tests/unit/updater/engine/install/test_owned_smoke_deadline.lua

--- ==============================================================================
--- MODULE: Owned Install Child Deadlines (Linux)
--- DESCRIPTION:
--- Runs the actual async installer over a real standalone tree whose updated
--- wrapper answers `--help` slowly, or whose ownership owner (the previous
--- installation's install/ownership.sh, which hashes the whole new payload)
--- is slow. Both children used to run through os.execute on the event loop:
--- no timer fired while they waited and the install deadline was observed only
--- after they returned. The ownership owner took 9 s on a real installed tree,
--- with the daemon's keyboard grabbed. Now the event loop keeps ticking, the
--- deadline kills the child's process group, and the previous installation is
--- restored. Only the archive reader factory is modeled.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv = require("luv")
local Installer = require("updater.engine.installer")
local Fixture = require("tests.support.updater.engine.installer_native_fixture")
local Budget = require("updater.engine.install_budget")

local function now() return uv.hrtime() / 1e6 end

--- Runs one async install whose new wrapper first runs `body`.
--- @param body string Shell lines of the updated wrapper before it exits 0.
--- @param budget_ms number Original install deadline.
--- @param owner_body string|nil Shell lines the ownership owner runs first.
--- @return table outcome { ok, detail, elapsed_ms, ticks, fixture }.
local function install_with_wrapper(body, budget_ms, owner_body)
	local f = Fixture.create(Installer)
	if owner_body then
		local owner = f.installed .. "/linux/install/ownership.sh"
		local text = assert(Fixture.read(owner))
		local shebang, rest = text:match("^(#![^\n]*\n)(.*)$")
		Fixture.write(owner, shebang .. owner_body .. rest)
	end
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
	local last_tick = nil
	outcome.max_gap_ms = 0
	heartbeat:start(10, 10, function()
		local tick = now()
		if last_tick then outcome.max_gap_ms = math.max(outcome.max_gap_ms, tick - last_tick) end
		last_tick, outcome.ticks = tick, outcome.ticks + 1
	end)
	local watchdog = assert(uv.new_timer())
	watchdog:start(10000, 0, function() uv.stop() end)
	-- Started from a timer, as the daemon's update window does: a child run
	-- synchronously would otherwise finish before the loop could observe it.
	local starter = assert(uv.new_timer())
	local operation
	uv.update_time()
	starter:start(30, 0, function()
		local started = now()
		operation = assert(Installer.install_owned({ factory = factory, reservation = reservation,
			context = f.context, expected_version = "1.2.3" }, function(ok, detail)
			outcome.ok, outcome.detail, outcome.elapsed_ms = ok, detail, now() - started
			uv.stop()
		end))
	end)
	uv.run("default")
	heartbeat:stop(); heartbeat:close(); watchdog:stop(); watchdog:close(); starter:close()
	uv.run("nowait")
	outcome.settled = operation ~= nil and operation:is_settled()
	return outcome
end

helpers.describe("Owned install child deadlines", function()
	helpers.it("keeps the event loop running and kills a wrapper past the install deadline (install-owned-smoke-deadline)",
		function()
		-- 2 s: the synchronous moves and receipt checks before the smoke take a
		-- good part of a small budget on a slow runner; the smoke sleeps 5 s.
		local outcome = install_with_wrapper("sleep 5\n", 2000)
		local f = outcome.fixture
		local ok, err = pcall(function()
			helpers.assert_true(outcome.elapsed_ms ~= nil, "the install completed")
			helpers.assert_true(outcome.elapsed_ms < 4500, "the deadline bounded the smoke: " .. tostring(outcome.elapsed_ms))
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

	helpers.it("keeps the event loop running while the ownership owner hashes the payload (install-owned-ownership-loop)",
		function()
		local outcome = install_with_wrapper("", 5000, "sleep 0.8\n")
		local f = outcome.fixture
		local ok, err = pcall(function()
			helpers.assert_eq(outcome.ok, true, "a slow owner still installs: " .. tostring(outcome.detail))
			helpers.assert_true(outcome.elapsed_ms >= 800, "the owner ran: " .. tostring(outcome.elapsed_ms))
			helpers.assert_true(outcome.max_gap_ms < 400,
				"no heartbeat gap while the owner ran: " .. tostring(outcome.max_gap_ms) .. " ms")
			helpers.assert_true(Fixture.read(f.installed .. "/linux/new.marker") ~= nil, "the new installation is active")
		end)
		Fixture.remove(f.root)
		assert(ok, err)
	end)

	helpers.it("kills an ownership owner past the install deadline (install-owned-ownership-deadline)", function()
		local outcome = install_with_wrapper("", 400, "sleep 5\n")
		local f = outcome.fixture
		local ok, err = pcall(function()
			helpers.assert_true(outcome.elapsed_ms ~= nil, "the install completed")
			helpers.assert_true(outcome.elapsed_ms < 3000, "the deadline bounded the owner: " .. tostring(outcome.elapsed_ms))
			helpers.assert_eq(outcome.ok, false, "an owner past the deadline fails the install")
			helpers.assert_true(Fixture.read(f.installed .. "/old.marker") ~= nil, "the previous installation is kept")
			helpers.assert_true(Fixture.read(f.installed .. "/linux/new.marker") == nil, "the candidate never activated")
			helpers.assert_true(outcome.settled, "the operation settled once")
		end)
		Fixture.remove(f.root)
		assert(ok, err)
	end)
end)
