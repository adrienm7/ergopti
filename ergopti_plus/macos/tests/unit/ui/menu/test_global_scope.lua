--- tests/unit/ui/menu/test_global_scope.lua

--- ==============================================================================
--- MODULE: Global Scope (macOS)
--- DESCRIPTION:
--- Configuration › « Restore recommended values » and « Clear all » compose
--- the scoped config.toml owners and the remap engine's asynchronous scope in
--- the manifest's global order, at once: neither asks (the maintainer retired
--- the clear's question on 2026-09-30). A refusal reverts every committed
--- category, the remap one through its settings snapshot, and a category
--- without an available owner is skipped.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A scoped owner double journaling into a shared trace.
local function scoped_owner(trace, name, refuse)
	local owner = { committed = false }
	function owner.apply(mode, ...)
		-- A second argument was the retired « already asked » flag.
		trace[#trace + 1] = name .. ":" .. mode .. (select("#", ...) > 0 and ":extra" or "")
		owner.committed = not refuse
		return owner.committed
	end
	function owner.revert()
		trace[#trace + 1] = name .. ":revert"
		local reverted = owner.committed
		owner.committed = false
		return reverted
	end
	function owner.release() trace[#trace + 1] = name .. ":release" end
	function owner.pending() return false end
	function owner.retry_restore() return true end
	return owner
end

--- A remap facade double whose terminals the test settles.
local function remap_double(trace, enabled)
	local remap = { terminals = {}, requests = {} }
	function remap.get_enabled() return enabled end
	function remap.snapshot_settings() return { marker = "before" } end
	function remap.apply_scope(request, on_done)
		trace[#trace + 1] = "remap:" .. request.scope .. ":" .. request.mode
		remap.requests[#remap.requests + 1] = request
		remap.terminals[#remap.terminals + 1] = on_done
		return true
	end
	function remap.restore_settings(snapshot, on_done)
		trace[#trace + 1] = "remap:restore:" .. snapshot.marker
		on_done(true, "ready")
		return true
	end
	function remap.settings_pending() return false end
	function remap.retry_settings_recovery() return true end
	--- Settles the latest remap request.
	function remap.settle(ok) return remap.terminals[#remap.terminals](ok, ok and "ready" or "refused", 0, { status = "kept" }) end
	return remap
end

--- Builds the global owner over doubles.
local function build(trace, options)
	options = options or {}
	local observed = { refreshes = {} }
	local owners = {}
	for _, name in ipairs({ "gestures", "shortcuts", "keyboard_layout", "llm", "metrics" }) do
		local owner = options.missing ~= name and scoped_owner(trace, name, options.refuse == name) or nil
		owners[name] = function() return owner end
	end
	observed.deferred = {}
	local global = require("ui.menu.global_scope").new({
		owners = owners,
		remap = options.remap,
		backup_path = function(scope) return "/remap.toml.global-" .. scope end,
		defer = function(continuation)
			if options.refuse_defer then return false end
			observed.deferred[#observed.deferred + 1] = continuation
			return true
		end,
		paused = function() return options.paused == true end,
		refresh = function(committed, report) observed.refreshes[#observed.refreshes + 1] = { committed, report } end,
	})
	return global, observed
end

helpers.describe("macOS global scope", function()
	helpers.it("restores at once, composing the remap and scoped owners in manifest order", function()
		local trace = {}
		local remap = remap_double(trace, true)
		local global, observed = build(trace, { remap = remap })
		helpers.assert_eq(global.apply("recommended"), true)
		helpers.assert_eq(trace, { "remap:tap_holds:recommended" }, "the next category waits for the terminal")
		helpers.assert_eq(global.pending(), true)
		remap.settle(true)
		helpers.assert_eq(#trace, 1, "the next category never runs on the Karabiner terminal's stack")
		table.remove(observed.deferred, 1)()
		helpers.assert_eq(trace[2], "shortcuts:recommended")
		helpers.assert_eq(trace[3], "remap:shortcuts:recommended", "the chords follow the shortcut preferences")
		remap.settle(true)
		table.remove(observed.deferred, 1)()
		helpers.assert_eq({ trace[4], trace[5], trace[6], trace[7] }, { "gestures:recommended",
			"keyboard_layout:recommended", "llm:recommended", "metrics:recommended" })
		helpers.assert_eq(remap.requests[1].backup_path, "/remap.toml.global-tap_holds")
		helpers.assert_eq(#observed.refreshes, 1)
		local committed, report = observed.refreshes[1][1], observed.refreshes[1][2]
		helpers.assert_eq(committed, true)
		helpers.assert_eq(report.skipped, { "hotstrings", "global" })
		helpers.assert_eq(global.pending(), false)
	end)

	helpers.it("reverts every committed category, the remap one through its snapshot", function()
		local trace = {}
		local remap = remap_double(trace, true)
		local global, observed = build(trace, { remap = remap, refuse = "llm", refuse_defer = true })
		helpers.assert_eq(global.apply("clear"), true, "a clear applies at once")
		remap.settle(true)
		remap.settle(true)
		local tail = {}
		for index = 7, #trace do tail[#tail + 1] = trace[index] end
		helpers.assert_eq(trace[6], "llm:clear")
		helpers.assert_eq(tail, { "keyboard_layout:revert", "gestures:revert", "remap:restore:before",
			"shortcuts:revert", "remap:restore:before" })
		helpers.assert_eq(observed.refreshes[1][1], false)
		helpers.assert_eq(observed.refreshes[1][2].failed, "llm")
		helpers.assert_eq(observed.refreshes[1][2].reverted, true)
	end)

	helpers.it("refuses a question port: neither mode asks", function()
		local ok, err = pcall(require("ui.menu.global_scope").new, { owners = {},
			backup_path = function() end, defer = function() end, paused = function() return false end,
			refresh = function() end, confirm = function() return true end })
		helpers.assert_eq(ok, false, "a caller still wiring a question must be refused")
		helpers.assert_true(tostring(err):find("asks no question", 1, true) ~= nil, tostring(err))
	end)

	helpers.it("does nothing while paused, and skips an unavailable owner", function()
		local trace = {}
		for _, mode in ipairs({ "clear", "recommended" }) do
			local paused = build(trace, { paused = true })
			helpers.assert_eq(paused.apply(mode), false)
		end
		helpers.assert_eq(trace, {})
		local partial, partial_observed = build(trace, { missing = "llm", remap = remap_double(trace, false) })
		helpers.assert_eq(partial.apply("clear"), true)
		local report = partial_observed.refreshes[1][2]
		helpers.assert_eq(report.skipped, { "tap_holds", "hotstrings", "llm", "global" })
		for _, entry in ipairs(trace) do
			helpers.assert_true(not entry:find("remap", 1, true), "a disabled remap engine is not composed")
		end
	end)
end)

return true
