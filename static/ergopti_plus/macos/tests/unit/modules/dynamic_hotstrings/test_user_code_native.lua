--- tests/unit/modules/dynamic_hotstrings/test_user_code_native.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Native Tests (macOS)
--- DESCRIPTION:
--- Exercises physical tap admission and deferred callbacks through real keymap
--- owners, including native focus identity and consumed-input cancellation debt.
--- ==============================================================================
local helpers = require("tests.helpers")
local SyntheticStack = require("tests.support.synthetic_input_stack")

local OWNED = {
	"modules.keymap", "modules.keymap.state", "modules.keymap.expander", "modules.keymap.llm_bridge",
	"modules.keylogger", "modules.llm", "modules.llm.prediction_engine", "ui.tooltip",
	"modules.dynamic_hotstrings.user_code", "modules.dynamic_hotstrings.rules_engine",
	"modules.dynamic_hotstrings", "modules.dynamic_hotstrings.personal_info",
	"ui.menu.programmatic_hotstrings", "infra.dialog_util", "adapters.shell_runner",
	"infra.preferences",
	"adapters.notifier", "adapters.file_system", "infra.config_paths", "infra.i18n",
	"adapters.secure_field_detector",
	"modules.diagnostics.hid_diagnostic_mailbox",
}

local function physical(char, code)
	return { getProperty = function() return 0 end, getKeyCode = function() return code or 0 end,
		getFlags = function() return {} end, getCharacters = function() return char end }
end

local function watcher()
	return { start = function(self) return self end, stop = function(self) return self end }
end

local function drain(hs_stub)
	for _ = 1, 64 do
		local pending = {}
		local fixture = rawget(_G, "__USER_HOTSTRING_FIXTURE")
		local publishing = false
		for _, receipt in ipairs(fixture and fixture.output_receipts or {}) do
			if receipt.is_settled() ~= true then publishing = true end
		end
		for _, timer in ipairs(hs_stub.timer.__timers) do
			if timer.running and (timer.delay == 0 or publishing) then pending[#pending + 1] = timer end
		end
		if #pending == 0 then return end
		for _, timer in ipairs(pending) do if timer.running then timer:fire() end end
	end
	error("programmable callback fixture did not settle")
end

local function with_native(body)
	helpers.with_stub_scope(OWNED, function()
		local fixture = { calls = 0, factory_calls = 0, result = "0", now = 100, window_id = 42 }
		local original_test_state = rawget(_G, "__USER_HOTSTRING_FIXTURE")
		_G.__USER_HOTSTRING_FIXTURE = fixture
		local CoreState = require("modules.keymap.state")
		package.loaded["modules.keymap.state"] = { new = function(...)
			fixture.state = CoreState.new(...)
			return fixture.state
		end }
		package.loaded["modules.keylogger"] = setmetatable({}, { __index = function() return function() end end })
		package.loaded["modules.llm"] = { DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = false },
			check_modifiers = function() return false end }
		package.loaded["modules.llm.prediction_engine"] = setmetatable({
			init = function() return true end, get_llm_enabled = function() return false end,
			reset = function() return true end, is_visible = function() return false end,
		}, { __index = function() return function() end end })
		package.loaded["ui.tooltip"] = setmetatable({
			hide = function() return true end, hide_forced = function() return true end,
			hide_forced_silent = function() return true end, is_visible = function() return false end,
			is_hotstring_visible = function() return false end, tint = function() return {} end,
		}, { __index = function() return function() end end })
		package.loaded["tests.stubs.hs"] = nil
		local native_stub = require("tests.stubs.hs")
		local application_port = {}
		for key, value in pairs(native_stub.application) do application_port[key] = value end
		application_port.get = function(pid) return pid == 9001 and fixture.app or nil end
		local eventtap_port, event_port = {}, {}
		for key, value in pairs(native_stub.eventtap) do eventtap_port[key] = value end
		for key, value in pairs(native_stub.eventtap.event) do event_port[key] = value end
		fixture.native_posts = {}
		local make_key = event_port.newKeyEvent
		event_port.newKeyEvent = function(...)
			local event = make_key(...)
			local post = event.post
			event.post = function(self, target)
				fixture.native_posts[#fixture.native_posts + 1] = { key = self.key, unicode = self.unicode,
					is_down = self.isDown, target = target }
				if fixture.post_hook then fixture.post_hook(self) end
				return post(self, target)
			end
			return event
		end
		eventtap_port.event = event_port
		local Keymap, Synthetic = SyntheticStack.load("modules.keymap", {
			application = application_port, eventtap = eventtap_port })
		fixture.outputs, fixture.deletes = {}, 0
		local emit_text, emit_key = Synthetic.emit_key_strokes, Synthetic.emit_key_stroke
		Synthetic.emit_key_strokes = function(text, ...)
			fixture.outputs[#fixture.outputs + 1] = text
			return emit_text(text, ...)
		end
		Synthetic.emit_key_stroke = function(modifiers, key, ...)
			if key == "delete" then fixture.deletes = fixture.deletes + 1 end
			return emit_key(modifiers, key, ...)
		end
		local hs_stub = _G.hs
		local clipboard_count = 0
		for _, method in ipairs({ "setContents", "writeAllData", "clearContents" }) do
			local original = hs_stub.pasteboard[method]
			hs_stub.pasteboard[method] = function(...)
				local result = original(...)
				clipboard_count = clipboard_count + 1
				return result
			end
		end
		hs_stub.pasteboard.changeCount = function() return clipboard_count end
		local function element()
			return { attributeValue = function(_, key)
				if key == "AXRole" then return fixture.secure and "AXSecureTextField" or "AXTextField" end
				if key == "AXSubrole" then return "AXStandardWindow" end
				return nil
			end }
		end
		fixture.element = element()
		fixture.change_element = function() fixture.element = element() end
		local app = { pid = function() return 9001 end, name = function() return "Test Editor" end,
			newWatcher = function() return watcher() end }
		fixture.app = app
		local window = { id = function() return fixture.window_id end,
			application = function() return app end, title = function() return "Document" end,
			newWatcher = function() return watcher() end }
		hs_stub.timer.secondsSinceEpoch = function() return fixture.now end
		hs_stub.window.focusedWindow = function() return window end
		hs_stub.application.get = function(pid) return pid == 9001 and app or nil end
		hs_stub.axuielement.applicationElementForPID = function()
			return { attributeValue = function(_, key)
				if key == "AXFocusedUIElement" then
					if fixture.probe_hook then fixture.probe_hook() end
					return fixture.element
				end
			end }
		end
		helpers.assert_true(Keymap.start())
		drain(hs_stub)
		local FileSystem = require("adapters.file_system")
		FileSystem.read_with_status = function()
			if fixture.read_hook then fixture.read_hook() end
			if fixture.unreadable then return nil, "error", "fixture unreadable" end
			if fixture.absent then return nil, "absent" end
			return fixture.content, "ok"
		end
		package.loaded["infra.config_paths"] = { get_config_dir = function() return "/owned" end }
		package.loaded["adapters.notifier"] = { send = function() fixture.notified = true; return true end }
		fixture.content = [[return function()
			__USER_HOTSTRING_FIXTURE.factory_calls = __USER_HOTSTRING_FIXTURE.factory_calls + 1
			if __USER_HOTSTRING_FIXTURE.factory_mutate then __USER_HOTSTRING_FIXTURE.factory_mutate() end
			return {{id="custom",suffix="@u",preview="Custom",callback=function(ctx)
				local f=__USER_HOTSTRING_FIXTURE
				f.calls=f.calls+1
				if f.mutate then f.mutate() end
				return f.result
			end}}
		end]]
		local User = require("modules.dynamic_hotstrings.user_code")
		helpers.assert_true(User.start(Keymap))
		helpers.assert_eq(fixture.factory_calls, 0, "default-off startup must not execute the factory")
		local Rules = require("modules.dynamic_hotstrings.rules_engine")
		helpers.assert_true(Rules.inject_data({}, "★"))
		helpers.assert_true(Rules.start(Keymap))
		Keymap.enable_group("dynamichotstrings")
		helpers.assert_true(User.set_time_activation(0.5))
		helpers.assert_true(User.set_enabled(true))
		fixture.Keymap, fixture.User, fixture.Synthetic = Keymap, User, Synthetic
		fixture.output_transactions = {}
		local inject = Keymap.inject_dynamic
		Keymap.inject_dynamic = function(...)
			local accepted, transaction = inject(...)
			if transaction then fixture.output_transactions[#fixture.output_transactions + 1] = transaction end
			return accepted, transaction
		end
		fixture.output_receipts = {}
		local commit = Keymap.commit_user_hotstring
		Keymap.commit_user_hotstring = function(...)
			local accepted, receipt = commit(...)
			if receipt then fixture.output_receipts[#fixture.output_receipts + 1] = receipt end
			return accepted, receipt
		end
		fixture.hs = hs_stub
		for _, tap in ipairs(hs_stub.eventtap.__taps) do
			if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then fixture.tap = tap end
		end
		helpers.assert_not_nil(fixture.tap)
		function fixture.type_suffix()
			for _, char in ipairs({ "@", "u" }) do fixture.tap.fn(physical(char)) end
			drain(hs_stub)
		end
		local ok, problem = xpcall(function() body(fixture) end, debug.traceback)
		pcall(User.stop)
		if not fixture.held_clipboard_debt then drain(hs_stub) end
		pcall(User.stop)
		pcall(Rules.stop)
		pcall(Keymap.stop)
		_G.__USER_HOTSTRING_FIXTURE = original_test_state
		if not ok then error(problem, 0) end
	end)
end

helpers.describe("programmable native macOS hotstrings", function()
	local function run_queued_callback(f)
		local pending = {}
		for _, timer in ipairs(f.hs.timer.__timers) do
			if timer.running and timer.delay == 0 then pending[#pending + 1] = timer end
		end
		for _, timer in ipairs(pending) do if timer.running then timer:fire() end end
	end
	helpers.it("aborts every collected batch while retaining a committed guarded carrier", function()
		with_native(function(f)
			local S = f.Synthetic
			helpers.assert_true(S.enter_paced_collection())
			local tx = S.begin("guarded_abort", "replacement", {
				current = function() return false end, cached = function() return false end })
			S.with_transaction(tx, function()
				S.emit_key_stroke({}, "delete", 0); S.emit_key_strokes("unposted")
			end)
			local owner = S.prepare_collected_paced(tx, 1, 1000, f.app)
			helpers.assert_not_nil(owner); helpers.assert_true(S.seal(tx))
			helpers.assert_true(S.authorize_collected_paced(owner)); helpers.assert_true(S.commit_collected_paced(owner))
			local second = S.begin("ordinary_abort", "replacement")
			S.with_transaction(second, function() S.emit_key_strokes("discarded") end)
			local aborted, consume = S.abort_callback()
			helpers.assert_true(aborted); helpers.assert_true(consume)
			helpers.assert_true(second.cancelled)
			for _ = 1, 8 do if owner.timer and owner.timer.timer then owner.timer.timer:fire() end end
			helpers.assert_true(tx.completed); helpers.assert_eq(#f.native_posts, 0)
		end)
	end)
	helpers.it("retains the exact queued transaction when native settlement observation refuses", function()
		with_native(function(f)
			local Scheduler = require("adapters.timer_scheduler")
			local original, seen = Scheduler.onSettled, {}
			Scheduler.onSettled = function(handle, callback)
				seen[handle] = (seen[handle] or 0) + 1
				if seen[handle] == 2 then return false end
				return original(handle, callback)
			end
			f.type_suffix(); helpers.assert_true(f.tap.fn(physical("★"))); run_queued_callback(f)
			Scheduler.onSettled = original
			helpers.assert_eq(#f.output_receipts, 1)
			helpers.assert_eq(f.output_receipts[1].is_settled(), false)
			helpers.assert_eq(f.User.scope_snapshot().policy.quiescent, false)
			helpers.assert_eq(f.User.set_enabled(false), false)
			drain(f.hs)
			helpers.assert_true(f.output_receipts[1].is_settled())
			helpers.assert_true(f.User.set_enabled(false))
			for _, event in ipairs(f.native_posts) do helpers.assert_true(event.unicode ~= "0") end
		end)
	end)
	helpers.it("retains unprovable clipboard debt when payload mutation returns false", function()
		with_native(function(f)
			f.hs.pasteboard.setContents("original clipboard")
			local write, restore = f.hs.pasteboard.setContents, f.hs.pasteboard.writeAllData
			f.hs.pasteboard.setContents = function(value) write(value); return false end
			local restore_attempts = 0
			f.hs.pasteboard.writeAllData = function() restore_attempts = restore_attempts + 1; return false end
			f.result = "😀"; f.type_suffix(); helpers.assert_true(f.tap.fn(physical("★")))
			run_queued_callback(f)
			helpers.assert_eq(#f.output_receipts, 1)
			helpers.assert_eq(f.output_receipts[1].is_settled(), false)
			helpers.assert_eq(f.User.scope_snapshot().policy.quiescent, false)
			helpers.assert_eq(f.hs.pasteboard.getContents(), "😀")
			f.hs.pasteboard.setContents, f.hs.pasteboard.writeAllData = write, restore
			for _ = 1, 4 do
				helpers.assert_eq(f.User.set_enabled(false), false)
				helpers.assert_eq(f.output_receipts[1].is_settled(), false)
				helpers.assert_eq(f.hs.pasteboard.getContents(), "😀")
			end
			helpers.assert_eq(restore_attempts, 0, "unproven ownership must refuse before native restoration")
			f.held_clipboard_debt = true
		end)
	end)
	local function settle_paced_producer(f)
		for _ = 1, 8 do
			for _, transaction in ipairs(f.output_transactions) do
				for _, batch in ipairs(transaction.batches) do
					local owner = batch.paced_owner
					if owner and owner.timer and owner.timer.timer then owner.timer.timer:fire() end
				end
			end
		end
	end
	for _, phase in ipairs({ "before mutation", "after original restoration" }) do
		helpers.it("retains exact clipboard release refusal " .. phase, function()
			with_native(function(f)
				f.hs.pasteboard.setContents("original clipboard")
				local release, retain = f.Synthetic.release, f.Synthetic.retain
				local refused = true
				f.Synthetic.release = function(tx, token)
					if tx.owner == "clipboard_restore" and refused then return false end
					return release(tx, token)
				end
				if phase == "before mutation" then
					f.Synthetic.retain = function(tx)
						local token = retain(tx)
						if tx.owner == "clipboard_restore" then f.hs.pasteboard.setContents("foreign before mutation") end
						return token
					end
				end
				f.result = "😀"; f.type_suffix(); helpers.assert_true(f.tap.fn(physical("★")))
				run_queued_callback(f)
				if phase ~= "before mutation" then settle_paced_producer(f) end
				helpers.assert_eq(#f.output_receipts, 1)
				helpers.assert_eq(f.User.set_enabled(false), false)
				helpers.assert_eq(f.output_receipts[1].is_settled(), false)
				local expected = phase == "before mutation" and "foreign before mutation" or "original clipboard"
				helpers.assert_eq(f.hs.pasteboard.getContents(), expected)
				refused = false; f.Synthetic.retain = retain
				helpers.assert_true(f.User.set_enabled(false))
				helpers.assert_true(f.output_receipts[1].is_settled())
				helpers.assert_eq(f.hs.pasteboard.getContents(), expected)
				f.Synthetic.release = release
			end)
		end)
	end
	helpers.it("retains the exact clipboard timer after restoration until native stop acknowledges", function()
		with_native(function(f)
			f.hs.pasteboard.setContents("original clipboard")
			local Scheduler = require("adapters.timer_scheduler")
			local original, timer_stop, owned_handle = Scheduler.after, nil, nil
			local restore_delay = require("infra.timings").sec("debounce", "clipboard_restore_ms")
			Scheduler.after = function(delay, callback)
				local handle, committed = original(delay, callback)
				if delay == restore_delay and handle.timer then
					owned_handle = handle; timer_stop = handle.timer.stop
					handle.timer.stop = function() return false end
				end
				return handle, committed
			end
			f.result = "😀"; f.type_suffix(); helpers.assert_true(f.tap.fn(physical("★")))
			run_queued_callback(f)
			settle_paced_producer(f)
			Scheduler.after = original; helpers.assert_not_nil(owned_handle)
			helpers.assert_eq(f.User.set_enabled(false), false)
			helpers.assert_eq(f.hs.pasteboard.getContents(), "original clipboard")
			helpers.assert_eq(f.output_receipts[1].is_settled(), false)
			owned_handle.timer.stop = timer_stop
			helpers.assert_true(f.User.set_enabled(false))
			helpers.assert_true(f.output_receipts[1].is_settled())
		end)
	end)
	for _, foreign in ipairs({ "foreign clipboard", "😀" }) do
	helpers.it("preserves a foreign clipboard replacement across repeated guarded cancellation retries: " .. foreign, function()
		with_native(function(f)
			f.hs.pasteboard.setContents("original clipboard")
			f.result = "😀"; f.type_suffix(); helpers.assert_true(f.tap.fn(physical("★")))
			run_queued_callback(f)
			helpers.assert_eq(f.hs.pasteboard.getContents(), "😀")
			f.hs.pasteboard.setContents(foreign)
			f.held_clipboard_debt = true
			local foreign_count = f.hs.pasteboard.changeCount()
			f.content = f.content .. "\n-- source closes before native publication"
			for _ = 1, 8 do
				local pending = {}
				for _, timer in ipairs(f.hs.timer.__timers) do
					if timer.running then pending[#pending + 1] = timer end
				end
				for _, timer in ipairs(pending) do if timer.running then timer:fire() end end
				helpers.assert_eq(f.User.set_enabled(false), false)
				helpers.assert_eq(f.output_receipts[1].is_settled(), false)
				helpers.assert_eq(f.hs.pasteboard.getContents(), foreign)
				helpers.assert_eq(f.hs.pasteboard.changeCount(), foreign_count)
			end
			helpers.assert_nil(f.User.scope_snapshot(), "changed admitted source cannot grant an inverse snapshot")
			-- The isolated native fixture is discarded with honest unsettled debt;
			-- no monotonic receipt is reset and no successful settlement is claimed.
			f.held_clipboard_debt = true
		end)
	end)

	end
	for _, changed in ipairs({ "disable", "reload", "source", "window" }) do
		helpers.it("fences actual queued native publication after callback completion and " .. changed, function()
			with_native(function(f)
				f.type_suffix(); helpers.assert_eq(f.tap.fn(physical("★")), true)
				local pending = {}
				for _, timer in ipairs(f.hs.timer.__timers) do
					if timer.running and timer.delay == 0 then pending[#pending + 1] = timer end
				end
				for _, timer in ipairs(pending) do if timer.running then timer:fire() end end
				helpers.assert_eq(f.calls, 1)
				helpers.assert_eq(#f.output_receipts, 1)
				helpers.assert_eq(f.output_receipts[1].is_settled(), false)
				helpers.assert_eq(f.User.scope_snapshot().policy.quiescent, false)
				if changed == "disable" then helpers.assert_eq(f.User.set_enabled(false), false)
				elseif changed == "reload" then helpers.assert_eq(f.User.reload(), false)
				elseif changed == "source" then f.content = f.content .. "\n-- changed after callback completion"
				else f.window_id = 43 end
				drain(f.hs)
				helpers.assert_true(f.output_receipts[1].is_settled())
				for _, event in ipairs(f.native_posts) do
					helpers.assert_true(event.unicode ~= "0", "accepted construction must not deliver stale text")
				end
			end)
		end)
	end
	helpers.it("restores the owned clipboard when a queued paste publication loses its source", function()
		with_native(function(f)
			f.hs.pasteboard.setContents("original clipboard")
			f.result = "😀"
			f.type_suffix(); helpers.assert_eq(f.tap.fn(physical("★")), true)
			local pending = {}
			for _, timer in ipairs(f.hs.timer.__timers) do
				if timer.running and timer.delay == 0 then pending[#pending + 1] = timer end
			end
			for _, timer in ipairs(pending) do if timer.running then timer:fire() end end
			helpers.assert_eq(f.calls, 1); helpers.assert_eq(#f.output_receipts, 1)
			helpers.assert_eq(f.hs.pasteboard.getContents(), "😀")
			f.content = f.content .. "\n-- lost clipboard source"
			drain(f.hs)
			helpers.assert_true(f.output_receipts[1].is_settled())
			helpers.assert_eq(f.hs.pasteboard.getContents(), "original clipboard")
			for _, event in ipairs(f.native_posts) do helpers.assert_true(event.key ~= "v") end
		end)
	end)
	helpers.it("releases an owned native key-up when source admission closes after its key-down", function()
		with_native(function(f)
			local changed = false
			f.post_hook = function(event)
				if not changed and event.isDown then
					changed = true; f.content = f.content .. "\n-- changed after native key-down"
				end
			end
			f.type_suffix(); helpers.assert_eq(f.tap.fn(physical("★")), true); drain(f.hs)
			helpers.assert_true(changed)
			helpers.assert_eq(#f.native_posts, 2)
			helpers.assert_true(f.native_posts[1].is_down)
			helpers.assert_eq(f.native_posts[2].is_down, false)
			helpers.assert_eq(f.native_posts[1].key, f.native_posts[2].key)
			helpers.assert_true(f.output_receipts[1].is_settled())
		end)
	end)
	helpers.it("refuses absent active enable then admits only an explicitly created present source", function()
		with_native(function(f)
			helpers.assert_true(f.User.stop()); f.absent = true
			helpers.assert_true(f.User.start(f.Keymap)); helpers.assert_true(f.User.set_time_activation(0.5))
			helpers.assert_eq(f.User.set_enabled(true), false); helpers.assert_eq(f.User.is_enabled(), false)
			helpers.assert_true(f.notified)
			local FileSystem = require("adapters.file_system")
			FileSystem.write_if_unchanged = function(path, content, expected)
				helpers.assert_eq(path, f.User.source_path()); helpers.assert_eq(expected.status, "absent")
				f.content, f.absent = content, false; return true
			end
			helpers.assert_true(f.User.create_example()); helpers.assert_eq(f.User.is_enabled(), false)
			helpers.assert_true(f.User.set_enabled(true)); helpers.assert_eq(f.User.count(), 1)
			for char in ("@clock"):gmatch(".") do f.tap.fn(physical(char)) end
			drain(f.hs); helpers.assert_eq(f.tap.fn(physical("★")), true); drain(f.hs)
			helpers.assert_eq(#f.outputs, 1); helpers.assert_true(f.outputs[1]:match("^%d%d:%d%d$") ~= nil)
		end)
	end)
	helpers.it("admits a present valid empty factory without inventing callbacks", function()
		with_native(function(f)
			f.content = "return function() return {} end"
			helpers.assert_true(f.User.reload()); helpers.assert_true(f.User.is_enabled())
			helpers.assert_eq(f.User.count(), 0); helpers.assert_nil(f.User.preview("@u"))
		end)
	end)
	for _, unavailable in ipairs({ "absent", "unreadable" }) do
		helpers.it("quarantines admitted callbacks after " .. unavailable .. " source while retaining closed intent inverse", function()
			with_native(function(f)
				local callback = f.User.scope_snapshot().policy.rules[1].callback
				f[unavailable] = true
				helpers.assert_eq(f.User.reload(), false); helpers.assert_eq(f.User.is_enabled(), false)
				local snapshot = assert(f.User.scope_snapshot())
				helpers.assert_true(snapshot.closed_only); helpers.assert_true(snapshot.desired)
				helpers.assert_eq(snapshot.policy.ready, false)
				helpers.assert_eq(f.User.count(), 0)
				helpers.assert_eq(#snapshot.policy.rules, 1, "quarantined inverse retains metadata without reporting admission")
				helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
				helpers.assert_true(f.User.scope_restore(snapshot))
				local restored = assert(f.User.scope_snapshot())
				helpers.assert_true(restored.desired); helpers.assert_eq(restored.policy.ready, false)
				helpers.assert_eq(restored.policy.rules[1].callback, callback)
				helpers.assert_eq(f.User.count(), 0)
				helpers.assert_eq(f.User.is_enabled(), false); helpers.assert_eq(f.factory_calls, 1)
			end)
		end)
	end
	for _, changed in ipairs({ "absent", "unreadable", "edit" }) do
		helpers.it("re-proves admitted source on repeated enable after " .. changed, function()
			with_native(function(f)
				if changed == "edit" then f.content = "invalid Lua source!" else f[changed] = true end
				helpers.assert_eq(f.User.set_enabled(true), false)
				helpers.assert_eq(f.User.is_enabled(), false)
				helpers.assert_eq(f.User.scope_snapshot().policy.ready, false)
				helpers.assert_true(f.notified)
			end)
		end)
	end
	for _, changed in ipairs({ "absent", "edit" }) do
		helpers.it("refuses retained admitted checkpoint at a closed gate after " .. changed, function()
			with_native(function(f)
				helpers.assert_true(f.User.set_enabled(false))
				if changed == "edit" then f.content = f.content .. "\n-- foreign edit" else f.absent = true end
				helpers.assert_nil(f.User.scope_snapshot())
			end)
		end)
	end
	helpers.it("does not relabel an admitted empty factory as unavailable until strict quarantine", function()
		with_native(function(f)
			f.content = "return function() return {} end"
			helpers.assert_true(f.User.reload())
			helpers.assert_true(f.User.set_enabled(false))
			f.absent = true
			helpers.assert_nil(f.User.scope_snapshot())
			helpers.assert_eq(f.User.reload(), false)
			local snapshot = assert(f.User.scope_snapshot())
			helpers.assert_true(snapshot.closed_only); helpers.assert_eq(snapshot.policy.ready, false)
			helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
			helpers.assert_true(f.User.scope_restore(snapshot))
			helpers.assert_eq(f.User.is_enabled(), false)
		end)
	end)
	helpers.it("refuses an active checkpoint over callbacks from edited source", function()
		with_native(function(f)
			f.content = f.content .. "\n-- foreign source edit"
			helpers.assert_nil(f.User.scope_snapshot())
		end)
	end)
	helpers.it("keeps the mutator's own receipt when a factory makes a foreign scalar change", function()
		with_native(function(f)
			local snapshot = assert(f.User.scope_snapshot())
			helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
			f.factory_mutate = function()
				f.factory_mutate = nil
				helpers.assert_true(f.User.set_time_activation(0.75))
			end
			helpers.assert_eq(f.User.scope_adopt(snapshot, 0.125, true), false)
			helpers.assert_eq(f.User.scope_restore(snapshot), false)
			helpers.assert_eq(f.User.time_activation(), 0.75)
			helpers.assert_eq(f.User.is_enabled(), false)
		end)
	end)
	helpers.it("restores captured callbacks and controls without executing the source factory again", function()
		with_native(function(f)
			local snapshot = assert(f.User.scope_snapshot())
			local factories = f.factory_calls
			helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
			helpers.assert_eq(f.User.is_enabled(), false)
			helpers.assert_true(f.User.scope_restore(snapshot))
			helpers.assert_eq(f.User.time_activation(), 0.5)
			helpers.assert_true(f.User.is_enabled())
			helpers.assert_eq(f.factory_calls, factories)
			f.type_suffix(); helpers.assert_eq(f.tap.fn(physical("★")), true); drain(f.hs)
			helpers.assert_eq(f.outputs, { "0" })
		end)
	end)
	for _, boundary in ipairs({ "reload", "replace_owner", "source" }) do
		helpers.it("refuses the captured inverse after foreign " .. boundary, function()
			with_native(function(f)
				local snapshot = assert(f.User.scope_snapshot())
				helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
				if boundary == "reload" then helpers.assert_true(f.User.reload())
				elseif boundary == "replace_owner" then
					helpers.assert_true(f.User.stop()); helpers.assert_true(f.User.start(f.Keymap))
				else f.content = f.content .. "\n-- external change" end
				helpers.assert_eq(f.User.scope_restore(snapshot), false)
				helpers.assert_eq(f.User.is_enabled(), false)
			end)
		end)
	end
	for _, operation in ipairs({ "capture", "adopt" }) do
		helpers.it("refuses foreign configuration revision changed during source proof at " .. operation, function()
			with_native(function(f)
				local snapshot = assert(f.User.scope_snapshot())
				f.read_hook = function()
					f.read_hook = nil; helpers.assert_true(f.User.set_time_activation(0.75))
				end
				if operation == "capture" then helpers.assert_nil(f.User.scope_snapshot())
				else helpers.assert_eq(f.User.scope_adopt(snapshot, 0.125, false), false) end
				helpers.assert_eq(f.User.time_activation(), 0.75)
				helpers.assert_true(f.User.is_enabled())
			end)
		end)
	end
	helpers.it("retains configuration inverse debt until the actual consumed-input task retires", function()
		with_native(function(f)
			local snapshot = assert(f.User.scope_snapshot())
			f.type_suffix(); helpers.assert_eq(f.tap.fn(physical("★")), true)
			helpers.assert_eq(f.User.scope_adopt(snapshot, 0.125, false), false)
			helpers.assert_eq(f.User.scope_restore(snapshot), false)
			drain(f.hs)
			helpers.assert_eq(f.calls, 0); helpers.assert_eq(f.outputs, { "★" })
			helpers.assert_true(f.User.scope_restore(snapshot))
			helpers.assert_eq(f.User.time_activation(), 0.5); helpers.assert_true(f.User.is_enabled())
		end)
	end)
	helpers.it("captures unreadable default-off source only as a quiescent closed inverse", function()
		with_native(function(f)
			helpers.assert_true(f.User.stop()); f.unreadable = true
			helpers.assert_true(f.User.start(f.Keymap)); helpers.assert_true(f.User.set_time_activation(0.5))
			local snapshot = assert(f.User.scope_snapshot())
			helpers.assert_true(snapshot.closed_only)
			helpers.assert_eq(f.User.scope_adopt(snapshot, 0.125, true), false)
			helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
			helpers.assert_true(f.User.scope_restore(snapshot))
			helpers.assert_eq(f.User.is_enabled(), false); helpers.assert_eq(f.User.count(), 0)
			helpers.assert_eq(f.factory_calls, 1)
		end)
	end)
	helpers.it("keeps an absent closed inverse from authorizing active source after creation", function()
		with_native(function(f)
			helpers.assert_true(f.User.stop()); f.absent = true
			helpers.assert_true(f.User.start(f.Keymap)); helpers.assert_true(f.User.set_time_activation(0.5))
			local snapshot = assert(f.User.scope_snapshot())
			helpers.assert_true(snapshot.closed_only)
			helpers.assert_eq(f.User.scope_adopt(snapshot, 0.125, true), false)
			f.absent = false
			helpers.assert_eq(f.User.scope_adopt(snapshot, 0.125, true), false)
			helpers.assert_eq(f.User.is_enabled(), false); helpers.assert_eq(f.User.count(), 0)
			helpers.assert_eq(f.factory_calls, 1)
		end)
	end)
	for _, changed in ipairs({ "source", "generation" }) do
		helpers.it("fences " .. changed .. " changed during the final native AX owner probe", function()
			with_native(function(f)
				local changed_at_commit = false
				local commit = f.Keymap.commit_user_hotstring
				f.Keymap.commit_user_hotstring = function(result, ...)
					f.final_guard = result ~= false
					return commit(result, ...)
				end
				f.mutate = function()
					f.probe_hook = function()
						if not f.final_guard or changed_at_commit then return end
						changed_at_commit = true
						if changed == "source" then f.content = f.content .. "\n-- changed before emission"
						else helpers.assert_eq(f.User.invalidate("external lifecycle"), false) end
					end
				end
				f.type_suffix(); helpers.assert_eq(f.tap.fn(physical("★")), true); drain(f.hs)
				helpers.assert_true(changed_at_commit)
				helpers.assert_eq(f.calls, 1); helpers.assert_eq(f.deletes, 0)
				helpers.assert_eq(f.outputs, { "★" }, "only the original owner's consumed magic may retire")
				helpers.assert_true(f.notified)
			end)
		end)
	end
	helpers.it("defers the actual magic event then commits text at the original cursor", function()
		with_native(function(f)
			f.type_suffix()
			helpers.assert_eq(f.state.buffer, "@u")
			helpers.assert_eq(f.User.preview("@u"), "Custom")
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			helpers.assert_eq(f.calls, 0, "user code must never run in the eventtap")
			drain(f.hs)
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.outputs, { "0" })
			helpers.assert_eq(f.deletes, 2)
			helpers.assert_eq(f.state.buffer, "", "a completed replacement must suppress rescanning")
		end)
	end)
	for _, result in ipairs({ true, false }) do
		helpers.it("preserves suffix text for acknowledged action/cancellation " .. tostring(result), function()
			with_native(function(f)
				f.result = result
				f.type_suffix()
				helpers.assert_eq(f.tap.fn(physical("★")), true)
				drain(f.hs)
				helpers.assert_eq(f.calls, 1)
				helpers.assert_eq(f.outputs, result and {} or { "★" })
				helpers.assert_eq(f.deletes, 0)
				helpers.assert_eq(f.state.buffer, result and "@u" or "")
			end)
		end)
	end
	for _, transition in ipairs({ "focus", "privacy", "pause", "reload", "source" }) do
		helpers.it("rejects old callback ownership after " .. transition, function()
			with_native(function(f)
				f.type_suffix()
				helpers.assert_eq(f.tap.fn(physical("★")), true)
				if transition == "focus" then f.change_element()
				elseif transition == "privacy" then f.secure = true
				elseif transition == "pause" then f.Keymap.pause_processing()
				elseif transition == "reload" then helpers.assert_eq(f.User.reload(), false)
				elseif transition == "source" then f.content = f.content .. "\n-- changed" end
				drain(f.hs)
				helpers.assert_eq(f.calls, 0)
				if transition == "source" then helpers.assert_eq(f.outputs, { "★" }) end
			end)
		end)
	end
	helpers.it("rejects text when user code changes the actual focused AX element", function()
		with_native(function(f)
			f.mutate = f.change_element
			f.type_suffix()
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			drain(f.hs)
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.state.buffer, "@u")
			helpers.assert_eq(f.outputs, {}, "a callback that moves focus cannot emit driver replacement")
		end)
	end)
	helpers.it("retains swallowed magic retirement debt until the actual deferred task settles", function()
		with_native(function(f)
			f.type_suffix()
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			helpers.assert_eq(f.User.set_enabled(false), false, "queued consumed input still belongs to a live task")
			helpers.assert_eq(f.User.set_enabled(true), false, "execution cannot reopen before native retirement")
			drain(f.hs)
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.outputs, { "★" }, "owned cancellation replays exactly the swallowed magic")
			helpers.assert_true(f.User.set_enabled(true), "retry succeeds only after actual native cleanup")
			f.outputs = {}
			f.type_suffix()
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			drain(f.hs)
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.outputs, { "0" })
		end)
	end)
	helpers.it("keeps the dynamic facade closed until native user cleanup is acknowledged", function()
		with_native(function(f)
			local Dynamic = require("modules.dynamic_hotstrings")
			f.type_suffix()
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			helpers.assert_eq(Dynamic.stop(), false)
			helpers.assert_eq(Dynamic.start("/owned", f.Keymap), false,
				"a prospective start cannot claim an uncleared child generation")
			drain(f.hs)
			helpers.assert_eq(f.calls, 0)
			helpers.assert_true(Dynamic.stop(), "cleanup owner can retry only after the consumed task settles")
		end)
	end)
	helpers.it("keeps registered magic mappings ahead of executable user suffixes", function()
		with_native(function(f)
			f.Keymap.add("@u★", "Builtin", { auto_expand = true, is_case_sensitive = true })
			f.Keymap.sort_mappings()
			f.type_suffix()
			helpers.assert_eq(f.User.preview("@u"), nil)
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			drain(f.hs)
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.outputs, { "Builtin" })
		end)
	end)
	helpers.it("keeps ordinary saved preference synchronization from cancelling owned pending work", function()
		with_native(function(f)
			f.type_suffix()
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			helpers.assert_true(f.User.set_time_activation(0.5))
			helpers.assert_true(f.User.set_enabled(true))
			drain(f.hs)
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.outputs, { "0" })
		end)
	end)
	helpers.it("opens source through the actual menu adapter without loading or creating it", function()
		with_native(function(f)
			local admitted
			package.loaded["adapters.shell_runner"] = { run = function(executable, argv)
				admitted = { executable, argv }; return true
			end }
			local Menu = require("ui.menu.programmatic_hotstrings")
			local factories, content = f.factory_calls, f.content
			local rows = Menu.build({ state = { dynamichotstrings_user_code_enabled = true,
				dynamichotstrings_user_code_time_activation_seconds = 0.5 }, keymap = f.Keymap,
				updateMenu = function() end, save_prefs = function() return true end })
			helpers.assert_eq(#rows, 4)
			helpers.assert_true(rows[2].fn())
			helpers.assert_eq(admitted, { "/usr/bin/open", { "-e", "/owned/personal_dynamic_hotstrings.lua" } })
			helpers.assert_eq(f.factory_calls, factories)
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.content, content)
		end)
	end)
	helpers.it("saves declared preferences to disk then reloads them into actual native gate and timing", function()
		with_native(function(f)
			local path = os.tmpname()
			local FileSystem = require("adapters.file_system")
			local original_read, original_write = FileSystem.read_with_status, FileSystem.write_if_unchanged
			local function read_disk()
				local handle = assert(io.open(path, "r"))
				local content = handle:read("*a"); handle:close(); return content
			end
			local handle = assert(io.open(path, "w"))
			handle:write('[other]\nuntouched = "foreign"\n[hotstrings.dynamic.user_code]\nneighbor = "kept"\n')
			handle:close()
			-- The native Darwin publisher is a port fixture; real serializers,
			-- conditional source receipts, disk bytes, reload and keymap are exercised.
			FileSystem.read_with_status = function(requested)
				if requested == path then return read_disk(), "ok" end
				return original_read(requested)
			end
			FileSystem.write_if_unchanged = function(requested, content, expected)
				helpers.assert_eq(requested, path)
				helpers.assert_eq(expected.content, read_disk(), "publication must retain exact original bytes")
				local output = assert(io.open(path, "w")); output:write(content); output:close(); return true
			end
			local ok, problem = xpcall(function()
				local Preferences = require("infra.preferences")
				helpers.assert_eq(select(2, Preferences.load(path)), "ok")
				helpers.assert_true(Preferences.save(path, { dynamichotstrings_user_code_enabled = true,
					dynamichotstrings_user_code_time_activation_seconds = 0.125 }, {}, {}))
				local decoded = require("toml_codec").decode(read_disk())
				helpers.assert_eq(decoded.other.untouched, "foreign")
				helpers.assert_eq(decoded.hotstrings.dynamic.user_code.neighbor, "kept")
				package.loaded["infra.preferences"] = nil
				local restarted = require("infra.preferences")
				local saved, status = restarted.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_true(f.User.set_enabled(false))
				helpers.assert_true(f.User.set_time_activation(saved.dynamichotstrings_user_code_time_activation_seconds))
				helpers.assert_true(f.User.set_enabled(saved.dynamichotstrings_user_code_enabled))
				helpers.assert_eq(f.User.time_activation(), 0.125)
				helpers.assert_true(f.User.is_enabled())
				f.type_suffix(); helpers.assert_eq(f.tap.fn(physical("★")), true); drain(f.hs)
				helpers.assert_eq(f.outputs, { "0" })
			end, debug.traceback)
			FileSystem.read_with_status, FileSystem.write_if_unchanged = original_read, original_write
			os.remove(path)
			if not ok then error(problem, 0) end
		end)
	end)
	helpers.it("uses physical activation timing and permits a slow owned callback", function()
		with_native(function(f)
			f.type_suffix()
			f.now = f.now + 0.5
			helpers.assert_eq(f.tap.fn(physical("★")), false)
			drain(f.hs)
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.outputs, {})
		end)
		with_native(function(f)
			f.mutate = function() f.now = f.now + 5 end
			f.type_suffix()
			helpers.assert_eq(f.tap.fn(physical("★")), true)
			drain(f.hs)
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.outputs, { "0" })
		end)
	end)
end)

return true
