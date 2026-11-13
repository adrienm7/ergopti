--- tests/unit/core/lifecycle/test_webkit_gc_signal.lua

--- ==============================================================================
--- MODULE: WebKit Garbage-Collector Signal Reservation
--- DESCRIPTION:
--- JavaScriptCore suspends threads for its collector with SIGUSR1 unless
--- JSC_SIGNAL_FOR_GC names another signal, and it installs its handler over the
--- daemon's. The reload request rings SIGUSR1, so a daemon with a WebView open
--- died with SIGSEGV (tests/hardware/layouts/phys_live_guest.sh, reproduced by
--- tests/hardware/run_webkit_gc_signal.lua). The daemon reserves another signal
--- before anything can load WebKit.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read(rel)
	local fh = assert(io.open(helpers.driver_root() .. "/" .. rel, "r"))
	local text = fh:read("*a")
	fh:close()
	return text
end

helpers.describe("WebKit GC signal reservation", function()
	helpers.it("moves the collector off the reload signal (webkit-gc-signal-value)", function()
		local Signals = helpers.load_module("core.lifecycle.engine.shutdown.signal_handlers")
		local seen = {}
		local reserved = Signals.reserve_webkit_gc_signal(function(name, value)
			seen[#seen + 1] = name .. "=" .. value
			return true
		end)
		helpers.assert_true(reserved, "the reservation is admitted")
		helpers.assert_eq(seen[1], "JSC_SIGNAL_FOR_GC=" .. Signals.WEBKIT_GC_SIGNAL, "the variable WebKit reads")
		for _, handled in ipairs({ 1, 2, 15, Signals.RELOAD_SIGNAL }) do
			helpers.assert_true(Signals.WEBKIT_GC_SIGNAL ~= handled, "the collector signal is not one the daemon handles")
		end
	end)

	helpers.it("refuses when the environment cannot be written (webkit-gc-signal-refusal)", function()
		local Signals = helpers.load_module("core.lifecycle.engine.shutdown.signal_handlers")
		local reserved, why = Signals.reserve_webkit_gc_signal(function() return false end)
		helpers.assert_eq(reserved, false, "a refused setenv is not a reservation")
		helpers.assert_true(type(why) == "string", "the refusal names its reason")
	end)

	helpers.it("writes the process environment natively (webkit-gc-signal-native)", function()
		local Signals = helpers.load_module("core.lifecycle.engine.shutdown.signal_handlers")
		helpers.assert_true(Signals.reserve_webkit_gc_signal(), "the native reservation is admitted")
		helpers.assert_eq(os.getenv("JSC_SIGNAL_FOR_GC"), tostring(Signals.WEBKIT_GC_SIGNAL), "getenv sees it")
	end)

	helpers.it("the daemon reserves it before anything loads WebKit (webkit-gc-signal-order)", function()
		local source = read("ergopti_hotstrings.lua")
		local reserve = source:find("reserve_webkit_gc_signal()", 1, true)
		helpers.assert_true(reserve ~= nil, "the daemon reserves the signal")
		for _, loader in ipairs({ "require(\"lgi\")", "optional_require(\"ui.", "require(\"ui.", "gui_stack" }) do
			local first = source:find(loader, 1, true)
			helpers.assert_true(first == nil or reserve < first, "the reservation precedes " .. loader)
		end
	end)
end)
