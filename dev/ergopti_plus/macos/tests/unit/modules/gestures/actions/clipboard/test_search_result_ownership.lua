--- tests/unit/modules/gestures/actions/clipboard/test_search_result_ownership.lua

--- ==============================================================================
--- MODULE: Search Result Clipboard Ownership
--- DESCRIPTION:
--- Composes real Actions and Clipboard with the canonical native-shaped board.
--- Ownership after the selection result must not overwrite a later user copy.
--- The first asynchronous copy's writer is deliberately not inferred here.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
require("logger")

local function it(name, scenario)
	helpers.it(name, function()
		helpers.with_stub_scope({ "adapters.window_manager", "native_app_switcher_owner", "adapters.clipboard" }, function()
			Fixture.with_fixture(function(fresh)
				local actions, calls = fresh()
				local f = { restores = 0 }
				local native = assert(loadfile(assert(package.searchpath("tests.stubs.hs", package.path))))().pasteboard
				local write, count, read = native.writeAllData, native.changeCount, native.getContents
				f.original = { ["public.utf8-plain-text"] = "original", ["public.html"] = "<b>original</b>" }
				f.external = function(text) return write({ ["public.utf8-plain-text"] = text, ["public.html"] = "<b>" .. text .. "</b>" }) end
				write(f.original)
				native.writeAllData = function(snapshot)
					f.restores = f.restores + 1
					if f.restore_mode == "false" then return false end
					if f.restore_mode == "clear-false" then native.clearContents(); return false end
					if f.restore_mode == "mutating-throw" then native.clearContents(); error("RESTORE_MUTATED_THEN_THROW") end
					return write(snapshot)
				end
				native.changeCount = function()
					if f.count_mode == "nil" then return nil end
					if f.count_mode == "throw" then error("COUNT_UNAVAILABLE") end
					return count()
				end
				native.getContents = function()
					local text = read()
					if f.on_read then local callback = f.on_read; f.on_read = nil; callback() end
					return text
				end
				calls.hs.pasteboard = native
				local synthetic = package.loaded["adapters.synthetic_input"]
				local emit = synthetic.emit_key_stroke
				synthetic.emit_key_stroke = function(mods, key, ...)
					local accepted = emit(mods, key, ...)
					if accepted == true and key == "c" then native.setContents(calls.clipboard_text()) end
					return accepted
				end
				function f.start()
					if f.started then helpers.assert_true(actions.resume_after_cleanup("gestures"))
					else actions.init({ action_params = {} }); f.started = true end
					helpers.assert_true(actions.set_action_parameter("tap_3", "search_web", "https://example.test/?q=%s"))
					helpers.assert_true(actions.execute_single("search_web", "tap_3"))
				end
				function f.fire() calls.hs.timer.__timers[#calls.hs.timer.__timers]:fire() end
				f.board, f.actions, f.calls = native, actions, calls
				scenario(f)
			end)
		end)
	end)
end

helpers.describe("search result retains only its exact native clipboard generation", function()
	it("keeps the healthy selected-text search and all-type restoration", function(f)
		f.start(); f.fire()
		helpers.assert_eq(f.board.readAllData(), f.original)
		helpers.assert_eq(f.calls.opened_urls, { "https://example.test/?q=selected%20words" })
		helpers.assert_eq(f.restores, 1)
		helpers.assert_true(f.actions.force_cleanup("gestures"))
	end)

	for _, text in ipairs({ "USER COPY", "selected words" }) do
		it("preserves a later user copy during recovery even when its text is " .. text, function(f)
			f.restore_mode = "false"
			f.start(); f.fire()
			helpers.assert_true(#f.calls.errors > 0)
			local errors = #f.calls.errors
			f.restore_mode = nil
			f.external(text)
			local generation = f.board.changeCount()
			f.fire()
			helpers.assert_eq(f.board.getContents(), text)
			helpers.assert_eq(f.board.changeCount(), generation, "revocation must perform no clipboard write")
			helpers.assert_eq(f.restores, 1)
			helpers.assert_eq(#f.calls.errors, errors, "a normal clipboard ownership change is not a restore error")
			helpers.assert_true(f.actions.force_cleanup("gestures"), "revoked snapshot must leave no restore retry debt")
			f.start(); f.fire()
			helpers.assert_eq(f.board.getContents(), text, "healthy successor snapshots the actual user clipboard")
		end)
	end

	for _, refusal in ipairs({ "clear-false", "mutating-throw" }) do
		it("keeps the receipt captured before a reentrant error diagnostic after " .. refusal, function(f)
			f.restore_mode = refusal
			local logger = package.loaded["infra.logger"]
			local log_error = logger.error
			logger.error = function(...)
				log_error(...)
				if f.restore_mode ~= nil then
					f.restore_mode = nil
					f.external("COPY DURING DIAGNOSTIC")
				end
			end
			f.start(); f.fire(); f.fire()
			helpers.assert_eq(f.board.getContents(), "COPY DURING DIAGNOSTIC")
			helpers.assert_eq(f.restores, 1)
			helpers.assert_true(f.actions.force_cleanup("gestures"))
		end)
	end

	for _, refusal in ipairs({ "nil", "throw" }) do
		it("retains explicit recovery debt while native count is unavailable: " .. refusal, function(f)
			f.restore_mode = "false"
			f.start(); f.fire()
			f.restore_mode, f.count_mode = nil, refusal
			f.fire()
			helpers.assert_eq(f.restores, 1, "unreadable metadata cannot authorize another write")
			helpers.assert_eq(f.actions.force_cleanup("gestures"), false)
			helpers.assert_true(#f.calls.errors > 0)
			f.count_mode = nil
			f.external("NEW COPY AFTER COUNT ERROR")
			helpers.assert_true(f.actions.force_cleanup("gestures"))
			helpers.assert_eq(f.board.getContents(), "NEW COPY AFTER COUNT ERROR")
		end)
	end

	it("does not adopt a copy arriving during the native selected-text read", function(f)
		f.start()
		f.on_read = function() f.external("COPY DURING READ") end
		f.fire()
		helpers.assert_eq(f.board.getContents(), "COPY DURING READ")
		helpers.assert_eq(f.restores, 0)
		helpers.assert_eq(#f.calls.opened_urls, 0)
		helpers.assert_true(f.actions.force_cleanup("gestures"))
	end)

	it("does not publish an old receipt after selected-text reading opens a successor", function(f)
		f.start()
		local cleaned, resumed, dispatched
		f.on_read = function()
			cleaned = f.actions.force_cleanup("gestures")
			f.external("SUCCESSOR PRIOR COPY")
			resumed = f.actions.resume_after_cleanup("gestures")
			dispatched = f.actions.execute_single("search_web", "tap_3")
		end
		f.fire()
		helpers.assert_true(cleaned)
		helpers.assert_true(resumed)
		helpers.assert_true(dispatched)
		helpers.assert_eq(f.board.getContents(), "selected words")
		helpers.assert_eq(#f.calls.opened_urls, 0, "the revoked old capture must not publish a URL")
		helpers.assert_eq(#f.calls.keys, 2)
		helpers.assert_true(f.actions.force_cleanup("gestures"))
		helpers.assert_eq(f.board.getContents(), "SUCCESSOR PRIOR COPY", "an old receipt must not replace the successor's cleanup owner")
		f.start(); f.fire()
		helpers.assert_eq(f.board.getContents(), "SUCCESSOR PRIOR COPY")
		helpers.assert_eq(f.calls.opened_urls, { "https://example.test/?q=selected%20words" })
		helpers.assert_true(f.actions.force_cleanup("gestures"))
	end)

	for _, refusal in ipairs({ "nil", "throw" }) do
		it("never adopts a later count when the initial result observation is unavailable: " .. refusal, function(f)
			f.start()
			f.count_mode = refusal
			f.fire()
			helpers.assert_eq(f.restores, 0)
			helpers.assert_eq(#f.calls.opened_urls, 0)
			helpers.assert_true(#f.calls.errors > 0)
			f.count_mode = nil
			f.external("UNATTRIBUTED LATER COPY")
			helpers.assert_eq(f.actions.force_cleanup("gestures"), false)
			helpers.assert_eq(f.board.getContents(), "UNATTRIBUTED LATER COPY")
			helpers.assert_eq(f.restores, 0, "recovery cannot invent an ownership receipt")
		end)
	end

	it("fences a successor opened by the ownership revocation diagnostic", function(f)
		f.restore_mode = "false"
		f.start(); f.fire()
		f.restore_mode = nil
		f.external("COPY BEFORE REVOCATION LOG")
		local admitted, business = {}, {}
		local logger = package.loaded["infra.logger"]
		local callback = logger.callback
		logger.callback = function(...)
			local ok, result = callback(...)
			business[#business + 1] = { ok = ok, result = result }
			return ok, result
		end
		local info = logger.info
		logger.info = function(...)
			info(...)
			admitted[#admitted + 1] = f.actions.execute_single("search_web", "tap_3")
		end
		f.fire()
		-- execute_single owns a registered dispatch even when its handler refuses.
		helpers.assert_eq(admitted, { true })
		helpers.assert_eq(business, { { ok = true, result = false } }, "the old release frame must not adopt a new search")
		helpers.assert_eq(f.board.getContents(), "COPY BEFORE REVOCATION LOG")
		helpers.assert_eq(#f.calls.keys, 1)
		helpers.assert_true(f.actions.force_cleanup("gestures"))
	end)

	it("does not queue or publish after the restore-failure diagnostic opens a successor", function(f)
		f.restore_mode = "false"
		local logger = package.loaded["infra.logger"]
		local log_error = logger.error
		local reentered, dispatched = false, nil
		logger.error = function(module, message, ...)
			log_error(module, message, ...)
			if not reentered and message:find("search_web clipboard restore refused", 1, true) then
				reentered = true
				f.restore_mode = nil
				dispatched = f.actions.execute_single("search_web", "tap_3")
			end
		end
		f.start(); f.fire()
		helpers.assert_true(reentered)
		helpers.assert_true(dispatched)
		helpers.assert_eq(#f.calls.keys, 2)
		helpers.assert_eq(#f.calls.opened_urls, 0, "the retired capture must not publish after its diagnostic")
		f.fire()
		helpers.assert_eq(f.calls.opened_urls, { "https://example.test/?q=selected%20words" })
		helpers.assert_eq(f.board.readAllData(), f.original)
		helpers.assert_true(f.actions.force_cleanup("gestures"))
	end)

	it("revokes the old snapshot on cleanup instead of retrying a later user copy", function(f)
		f.restore_mode = "false"
		f.start(); f.fire()
		f.restore_mode = nil
		f.external("COPY BEFORE CLEANUP")
		helpers.assert_true(f.actions.force_cleanup("gestures"))
		helpers.assert_eq(f.board.getContents(), "COPY BEFORE CLEANUP")
		helpers.assert_eq(f.restores, 1)
		for _, timer in ipairs(f.calls.hs.timer.__timers) do timer:fire() end
		helpers.assert_eq(f.board.getContents(), "COPY BEFORE CLEANUP", "late timer cannot resurrect revoked restoration")
	end)
	it("uses native-shaped generations for the legacy fixture's private clipboard", function()
		-- The fixture's own board remains coherent for existing search scenarios.
		helpers.with_stub_scope({ "adapters.window_manager", "native_app_switcher_owner" }, function()
			Fixture.with_fixture(function(fresh)
				local actions, calls = fresh()
				local board = calls.hs.pasteboard
				local initial = board.changeCount()
				board.readAllData(); board.getContents()
				helpers.assert_eq(board.changeCount(), initial)
				board.writeAllData({ ["public.utf8-plain-text"] = "original" })
				helpers.assert_true(board.changeCount() > initial, "identical writes still transfer ownership")
				local copied = board.changeCount()
				actions.init({ action_params = {} })
				helpers.assert_true(actions.set_action_parameter("tap_3", "search_web", "https://example.test/?q=%s"))
				helpers.assert_true(actions.execute_single("search_web", "tap_3"))
				helpers.assert_true(board.changeCount() > copied, "clear and native-shaped copy advance the board")
				calls.hs.timer.__timers[1]:fire()
				helpers.assert_eq(calls.clipboard_text(), "original")
				helpers.assert_true(actions.force_cleanup("gestures"))
			end)
		end)
	end)

end)
