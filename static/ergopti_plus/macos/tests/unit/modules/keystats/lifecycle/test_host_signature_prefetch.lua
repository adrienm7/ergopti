--- tests/unit/modules/keystats/lifecycle/test_host_signature_prefetch.lua

--- ==============================================================================
--- MODULE: Keystats Host Signature Prefetch Tests
--- DESCRIPTION:
--- The first keystats start resolved the hardware UUID with a synchronous
--- `ioreg -d2` pipeline inside LogManager.init(), holding the main run loop
--- 151 ms at boot+1 s (field report 2026-11-03). The deferred boot start now
--- reads it in an ioreg child beforehand.
---
--- ROOT CAUSES ENCODED:
--- 1. (host-signature-off-main-thread) A prefetched UUID must reach the device
---    identity scan without any synchronous ioreg call.
--- 2. (host-signature-same-value) The asynchronous parse returns what the
---    `grep | awk` pipeline printed, or the same Mac gets a second identity.
--- 3. (host-signature-fail-to-sync) A failed or late probe publishes no value:
---    the start then reads the UUID synchronously, never a fallback identity.
--- 4. (host-signature-boot-waits) The deferred boot start asks for the
---    prefetch before LogManager.init() and resumes from its callback.
--- ==============================================================================

local helpers = require("tests.helpers")

local UUID = "12345678-ABCD-4EF0-9876-0123456789AB"

-- Shape of `ioreg -d2 -c IOPlatformExpertDevice` on a Mac, trimmed.
local IOREG_OUTPUT = table.concat({
	"+-o Root  <class IORegistryEntry, id 0x100000100, retain 31>",
	"  +-o J314sAP  <class IOPlatformExpertDevice, id 0x100000110, registered, matched>",
	"      {",
	'        "IOPlatformSerialNumber" = "C02XXXXXXXXX"',
	'        "IOPlatformUUID" = "' .. UUID .. '"',
	'        "model" = <"MacBookPro18,3">',
	"      }",
	"",
}, "\n")





-- ===================================
-- ===================================
-- ======= 1/ Prefetch Harness =======
-- ===================================
-- ===================================

--- Loads a fresh host_signature module with a scripted shell runner and timer.
--- @return table env { HostSignature, runs, timers }
local function load_prefetch()
	local env = { runs = {}, timers = {} }
	package.loaded["modules.keystats.host_signature"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.shell_runner"] = {
		run = function(executable, args, on_done)
			env.runs[#env.runs + 1] = { executable = executable, args = args, on_done = on_done }
			return true, {}
		end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(delay, callback, label)
			env.timers[#env.timers + 1] = { delay = delay, callback = callback, label = label }
			return true
		end,
	}
	env.HostSignature = require("modules.keystats.host_signature")
	return env
end

local PREFETCH_MODULES = {
	"modules.keystats.host_signature", "infra.logger",
	"adapters.shell_runner", "infra.deferred_work",
}

local function with_prefetch(run)
	helpers.with_fresh_modules(PREFETCH_MODULES, function() run(load_prefetch()) end)
end

helpers.describe("keystats host signature prefetch", function()
	helpers.it("(host-signature-same-value) parses what the grep | awk pipeline printed", function()
		with_prefetch(function(env)
			local HS = env.HostSignature
			helpers.assert_eq(HS.parse(IOREG_OUTPUT), UUID)
			helpers.assert_eq(HS.parse('  "IOPlatformUUID" = "' .. UUID .. '"\r'), UUID)
			helpers.assert_nil(HS.parse("+-o Root\n"), "no UUID line yields nothing")
			helpers.assert_nil(HS.parse('"IOPlatformUUID" = "short"'), "shorter than 8 is refused")
			helpers.assert_nil(HS.parse('"IOPlatformUUID"'), "a line without a fourth field is empty")
			helpers.assert_nil(HS.parse(nil))
		end)
	end)

	helpers.it("(host-signature-off-main-thread) spawns ioreg once and resumes every waiter", function()
		with_prefetch(function(env)
			local HS = env.HostSignature
			local woken = 0
			helpers.assert_eq(HS.prefetch(nil), false, "a fresh probe is pending")
			helpers.assert_eq(HS.prefetch(function() woken = woken + 1 end), false,
				"a second prefetch joins the pending probe")
			helpers.assert_eq(#env.runs, 1, "one ioreg child only")
			helpers.assert_eq(env.runs[1].executable, "/usr/sbin/ioreg")
			helpers.assert_eq(table.concat(env.runs[1].args, " "), "-d2 -c IOPlatformExpertDevice")
			helpers.assert_eq(HS.status(), "pending")
			helpers.assert_nil(HS.value())
			env.runs[1].on_done(true, IOREG_OUTPUT, "")
			helpers.assert_eq(woken, 1)
			helpers.assert_eq(HS.value(), UUID)
			helpers.assert_eq(HS.prefetch(function() error("a settled probe retains no waiter") end), true)
			env.timers[1].callback()
			helpers.assert_eq(HS.value(), UUID, "the expired bound of a settled probe changes nothing")
		end)
	end)

	helpers.it("(host-signature-fail-to-sync) failure, empty output and the bound publish no value", function()
		for _, outcome in ipairs({ "exit", "empty", "timeout" }) do
			with_prefetch(function(env)
				local HS = env.HostSignature
				local woken = 0
				HS.prefetch(function() woken = woken + 1 end)
				if outcome == "exit" then env.runs[1].on_done(false, nil, "boom")
				elseif outcome == "empty" then env.runs[1].on_done(true, "+-o Root", "")
				else
					env.timers[1].callback()
					env.runs[1].on_done(true, IOREG_OUTPUT, "")
				end
				helpers.assert_eq(woken, 1, outcome .. ": the waiter resumes once")
				helpers.assert_eq(HS.status(), "failed", outcome)
				helpers.assert_nil(HS.value(), outcome .. ": a late or failed read publishes nothing")
			end)
		end
	end)

	helpers.it("a launch that fails synchronously answers ready without running the callback", function()
		with_prefetch(function(env)
			package.loaded["adapters.shell_runner"].run = function(_, _, on_done)
				on_done(false, nil, nil)
				return false, nil
			end
			local HS = env.HostSignature
			helpers.assert_eq(HS.prefetch(function() error("the caller proceeds itself") end), true)
			helpers.assert_eq(HS.status(), "failed")
		end)
	end)

	helpers.it("cancel drops a pending probe and its late completion", function()
		with_prefetch(function(env)
			local HS = env.HostSignature
			HS.prefetch(function() error("a cancelled waiter must not run") end)
			HS.cancel()
			env.runs[1].on_done(true, IOREG_OUTPUT, "")
			helpers.assert_eq(HS.status(), "idle")
			helpers.assert_nil(HS.value())
		end)
	end)
end)





-- =======================================
-- =======================================
-- ======= 2/ Log Manager Consumer =======
-- =======================================
-- =======================================

local LOG_MANAGER_STUBS = {
	"modules.keystats.sqlite_writer",
	"modules.keystats.aggregator",
	"modules.keystats.rotation",
	"modules.keystats.export",
	"modules.keystats.host_signature",
	"metrics.engine.metrics",
	"core.fs.adapters.file_system",
	"core.events.timer_scheduler",
	"modules.keystats.log_manager",
}

--- Runs LogManager.init() up to its identity scan and counts ioreg calls.
--- The only device.json is corrupt, so init fails closed right after the host
--- signature was read: no SQLite, timer or ledger is reached.
--- @param prefetched string|nil Value the prefetch published, nil when none.
--- @return number ioreg_calls Synchronous ioreg pipelines run by init.
local function count_sync_ioreg(prefetched)
	local ioreg_calls = 0
	helpers.with_fresh_modules(LOG_MANAGER_STUBS, function()
		package.loaded["modules.keystats.sqlite_writer"] = { init = function() end, open_db = function() return false end }
		package.loaded["modules.keystats.aggregator"] = { init = function() end }
		package.loaded["modules.keystats.rotation"] = { init = function() end, is_initialized = function() return false end }
		package.loaded["modules.keystats.export"] = { init = function() end }
		package.loaded["modules.keystats.host_signature"] = {
			value = function() return prefetched end,
			status = function() return prefetched and "resolved" or "idle" end,
		}
		package.loaded["metrics.engine.metrics"] = {}
		package.loaded["core.fs.adapters.file_system"] = {
			read_with_status = function() return "{broken-device-json", "ok" end,
		}
		package.loaded["core.events.timer_scheduler"] = nil
		local LogManager = helpers.load_with_stubs("modules.keystats.log_manager", {
			execute = function(command)
				if command:find("ioreg", 1, true) then
					ioreg_calls = ioreg_calls + 1
					return UUID
				end
				return ""
			end,
			fs = {
				attributes = function() return "directory" end,
				dir = function()
					local entries = { ".", "..", "existing-device" }
					local index = 0
					return function()
						index = index + 1
						return entries[index]
					end
				end,
			},
		})
		local initialized = LogManager.init({ LOG_DIR = "/virtual/metrics", CACHE_DIR = "/virtual/cache" })
		helpers.assert_eq(initialized, false, "the corrupt identity stops init after the scan")
	end)
	return ioreg_calls
end

helpers.describe("log manager reads the prefetched host signature", function()
	helpers.it("(host-signature-off-main-thread) a prefetched UUID runs no synchronous ioreg", function()
		helpers.assert_eq(count_sync_ioreg(UUID), 0,
			"LogManager.init() must not hold the run loop on ioreg once the UUID was prefetched")
	end)

	helpers.it("(host-signature-fail-to-sync) without a prefetched UUID init reads it synchronously", function()
		helpers.assert_eq(count_sync_ioreg(nil), 1,
			"an unprefetched start keeps the synchronous resolver, never a fallback identity")
	end)
end)





-- ====================================
-- ====================================
-- ======= 3/ Boot Start Wiring =======
-- ====================================
-- ====================================

helpers.describe("the deferred boot start waits for the prefetch", function()
	helpers.it("(host-signature-boot-waits) prepare_start runs before kl.start and resumes it", function()
		local src = assert(helpers.read_driver_unit("\"menu_state.keystats_start\""))
		local prepare_def = src:find("local function prepare(resume)", 1, true)
		local activate_def = src:find("local function activate()", 1, true)
		local gate = src:find("if not prepare(activate) then return end", 1, true)
		local start_call = src:find('try("metrics", "keystats.start", kl.start', 1, true)
		local early = src:find("prepare(nil)\n", 1, true)
		local scheduled = src:find('DeferredWork.after(KEYSTATS_START_DELAY_SEC, activate', 1, true)
		helpers.assert_true(prepare_def and activate_def and prepare_def < activate_def,
			"prepare is declared before activate captures it")
		helpers.assert_true(gate and start_call and activate_def < gate and gate < start_call,
			"activate waits for the prefetch before keystats.start")
		helpers.assert_true(early and scheduled and early < scheduled,
			"the probe starts when the deferred start is scheduled, overlapping its delay")
		helpers.assert_true(src:find("kl.prepare_start, resume", 1, true) ~= nil,
			"the pending prefetch resumes activate itself")
	end)

	helpers.it("(host-signature-boot-waits) keystats exposes prepare_start through the prefetch owner", function()
		local src = assert(helpers.read_driver_unit("function M.prepare_start(on_ready)"))
		local def = src:find("function M.prepare_start(on_ready)", 1, true)
		helpers.assert_true(def ~= nil, "keystats.prepare_start exists")
		helpers.assert_true(src:find("return HostSignature.prefetch(on_ready)", def, true) ~= nil,
			"prepare_start delegates to the single prefetch owner")
	end)
end)
