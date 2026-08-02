--- tests/unit/modules/diagnostics/test_crash_reporter_no_modal.lua

--- ==============================================================================
--- MODULE: Regression — the crash reporter never opens a blocking modal
--- DESCRIPTION:
--- crash_reporter.prompt_user ended in dialog_util.block_alert, i.e.
--- hs.dialog.blockAlert. A modal alert runs a NESTED RUN LOOP: the main thread
--- stops dead — every event tap, timer and hotkey in the driver with it — until a
--- human clicks the button. infra/dialog_util.lua:57-58 documents exactly this
--- ("Modal dialogs block the main thread and its default runloop, meaning
--- hs.timer.doAfter will NOT fire until AFTER the dialog is dismissed").
---
--- ROOT CAUSE ENCODED: a reporter that freezes the driver is worse than the
--- failure it reports, and it freezes it precisely when something has already
--- gone wrong. The outcome is now announced with a non-blocking notification that
--- names the saved report path — the same single piece of information, delivered
--- without stopping the run loop.
---
--- FEATURES & RATIONALE:
--- 1. Two independent tripwires: hs.dialog.blockAlert AND lib.dialog_util.
---    block_alert both set a flag and RAISE. Either one being reached fails the
---    test even if a future refactor swaps which layer is called.
--- 2. Notification capture: lib.notifications is stubbed so the dispatched title
---    and body are inspectable, proving the user is still told what happened.
--- 3. Both outcomes covered: a save that succeeds (path must be named) and a save
---    that fails (must still notify, still no modal).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a directory and every missing ancestor, on both POSIX and Windows.
--- hs.fs.mkdir is stubbed under the headless harness and creates nothing, so a
--- test that wants M.save() to actually succeed must build the tree itself.
--- @param path string Absolute directory path.
local function mkdir_p(path)
	if package.config:sub(1, 1) == "\\" then
		os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
	else
		os.execute('mkdir -p "' .. path .. '"')
	end
end

--- Loads crash_reporter under stubs that make any modal call explode and record
--- every notification dispatched.
--- @param config_dir string|nil Config dir the report should be written under.
--- @return table, table, table The module, the modal tripwire state, the notifications.
local function load_with_tripwires(config_dir)
	local modal = { opened = false }
	local notifications = {}

	local hs_overrides = {
		dialog = {
			blockAlert = function()
				modal.opened = true
				error("hs.dialog.blockAlert must never be reached from the crash reporter")
			end,
			alert          = function() return "OK" end,
			textPrompt     = function() return "OK", "" end,
			chooseFromList = function() return nil end,
		},
	}

	package.loaded["modules.diagnostics.crash_reporter"] = nil
	local CrashReporter = helpers.load_with_stubs("modules.diagnostics.crash_reporter", hs_overrides)

	-- dialog_util is the only route the module ever used to reach blockAlert; a
	-- raising stub makes a lingering modal call impossible to miss.
	package.loaded["infra.dialog_util"] = {
		block_alert = function()
			modal.opened = true
			error("lib.dialog_util.block_alert must never be reached from the crash reporter")
		end,
	}

	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind)
			notifications[#notifications + 1] = { title = title, body = body, kind = kind }
		end,
	}

	if config_dir then
		package.loaded["infra.config_paths"] = {
			get_config_dir = function() return config_dir end,
		}
	end

	return CrashReporter, modal, notifications
end

helpers.describe("crash_reporter — the outcome is announced without a blocking modal", function()
	helpers.it("notifies with the saved report path instead of opening an alert", function()
		local unique     = tostring(os.time()) .. "_" .. tostring(math.random(100000))
		local config_dir = "/tmp/ergopti_test_crash_no_modal_" .. unique .. "/"
		pcall(function() mkdir_p(config_dir .. "hammerspoon/crash_reports/") end)

		local CrashReporter, modal, notifications = load_with_tripwires(config_dir)

		local ok = pcall(CrashReporter.prompt_user, { timestamp = "2026-07-20T10:00:00Z" })

		helpers.assert_true(ok, "prompt_user must not throw")
		helpers.assert_true(not modal.opened,
			"prompt_user must NOT open a blocking modal — it stalls the main thread and its runloop "
			.. "until a human clicks, freezing the whole driver right after something already failed")
		helpers.assert_true(#notifications >= 1,
			"the user must still be told the outcome — via a non-blocking notification")

		local names_path = false
		for _, n in ipairs(notifications) do
			if type(n.body) == "string" and n.body:find("crash_reports", 1, true) then
				names_path = true
				break
			end
		end
		helpers.assert_true(names_path,
			"the notification must name the saved report path — it is the only actionable detail")

		package.loaded["infra.config_paths"] = nil
	end)

	helpers.it("still notifies without a modal when the report cannot be saved", function()
		-- An unwritable directory: hs.fs.mkdir is a no-op stub, so io.open fails and
		-- M.save() returns nil, driving prompt_user's failure branch.
		local CrashReporter, modal, notifications =
			load_with_tripwires("/tmp/ergopti_test_crash_unwritable_dir_that_does_not_exist/")

		local ok = pcall(CrashReporter.prompt_user, {})

		helpers.assert_true(ok, "prompt_user must not throw on a failed save")
		helpers.assert_true(not modal.opened,
			"the failure path must not open a blocking modal either — that was the second blockAlert call site")
		helpers.assert_true(#notifications >= 1,
			"a failed save must still be surfaced to the user")

		package.loaded["infra.config_paths"] = nil
	end)
end)
