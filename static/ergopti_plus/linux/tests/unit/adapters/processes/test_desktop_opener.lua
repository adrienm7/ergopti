--- tests/unit/adapters/processes/test_desktop_opener.lua

--- ==============================================================================
--- MODULE: Desktop Confirmation Lifetime Tests (Linux)
--- DESCRIPTION:
--- The real desktop adapter owns helpers until independently controlled close
--- receipts arrive. Desktop GUI lifetime is intentionally outside that claim.
--- ==============================================================================

local h = require("tests.helpers")

--- Runs a fresh adapter with explicit native constructor and settlement ports.
--- @param options table
--- @param body function Receives adapter and observations.
local function with_opener(options, body)
	local name = "adapters.desktop_opener"
	local previous = package.loaded[name]
	package.loaded[name] = nil
	local Open = require(name)
	local state = { native = {}, callbacks = 0, preparation = {}, constructing = false }
	local function boundary(label)
		state.preparation[#state.preparation + 1] = label
		if options.stop_at == label then state.early_ack = Open.shutdown() end
		if options.throw_at == label then error("controlled preparation refusal") end
	end
	Open._set_deps_for_test({
		exepath = function()
			boundary("exepath")
			if not options.no_exepath then return "/native/lua" end
		end,
		worker = function() boundary("worker"); return "/driver/adapters/desktop_opener_worker.lua" end,
		timeout = function()
			boundary("timeout")
			return options.timeout_value or (options.float_timeout and 30000.0 or 30000)
		end,
		update_time = function() boundary("clock") end,
		start = function(executable, argv, settings, complete)
			state.constructing = true
			state.executable, state.argv, state.settings = executable, argv, settings
			if options.refuse then state.constructing = false; return nil end
			local settled, listeners = false, {}
			local op = { started = not options.failed_start, cancels = 0 }
			function op:is_settled() return settled end
			function op:on_settled(listener)
				listeners[#listeners + 1] = listener
				return options.refuse_observer ~= true
			end
			function op:cancel()
				self.cancels = self.cancels + 1
				if options.on_cancel then options.on_cancel(state, op) end
				return settled
			end
			function op:logical() complete({ ok = true, exit_code = 0 }) end
			function op:ack()
				settled = true
				for _, listener in ipairs(listeners) do listener() end
			end
			function op:notify() for _, listener in ipairs(listeners) do listener() end end
			state.native[#state.native + 1] = op
			if options.stop_at == "constructor" then state.early_ack = Open.shutdown() end
			if options.throw_at == "constructor" then error("controlled post-acquisition throw") end
			if options.inline then op:logical(); op:ack() end
			state.constructing = false
			if options.invalid ~= nil then return options.invalid end
			if options.missing_port then op[options.missing_port] = nil end
			return op
		end,
	})
	function state.open(authorized)
		return Open.open("/literal/report ; é.txt", function(result)
			state.callbacks = state.callbacks + 1
			state.result, state.callback_during_constructor = result, state.constructing
		end, authorized)
	end
	local ok, err = pcall(body, Open, state)
	package.loaded[name] = previous
	if not ok then error(err, 0) end
end

h.describe("desktop-confirmation physical admission", function()
	h.it("desktop-confirmation refuses malformed targets and ports before any native preparation", function()
		with_opener({}, function(Open, s)
			for _, target in ipairs({ false, "", "bad\0target" }) do
				h.assert_eq(nil, Open.open(target, function() end))
			end
			h.assert_eq(nil, Open.open(nil, function() end))
			h.assert_eq(nil, Open.open("/target", false))
			h.assert_eq(nil, Open.open("/target", function() end, {}))
			h.assert_eq(0, #s.preparation)
			h.assert_eq(true, Open.shutdown())
		end)
	end)
	h.it("desktop-confirmation preserves literal argv and the canonical deadline without preloading native libraries", function()
		with_opener({}, function(_, s)
			local request = assert(s.open())
			h.assert_eq("/native/lua", s.executable)
			h.assert_eq({ "/driver/adapters/desktop_opener_worker.lua", "/literal/report ; é.txt", "30000" }, s.argv)
			h.assert_eq(30000, s.settings.timeout_ms)
			h.assert_eq("clock", s.preparation[#s.preparation])
			h.assert_eq(false, request.is_settled())
			s.native[1]:logical(); h.assert_eq(0, s.callbacks)
			s.native[1]:ack(); h.assert_eq(1, s.callbacks)
			h.assert_eq(true, s.result.ok)
			h.assert_eq(true, request.is_settled())
			s.native[1]:logical(); s.native[1]:ack(); h.assert_eq(1, s.callbacks)
		end)
	end)
	h.it("desktop-confirmation refuses a deadline above the shared timer ceiling before acquisition (timer-delay-ceiling)", function()
		for _, case in ipairs({ { value = 2 ^ 53, admitted = true }, { value = 2 ^ 53 + 2, admitted = false },
			{ value = 2 ^ 63, admitted = false } }) do
			with_opener({ timeout_value = case.value }, function(Open, s)
				local request, reason = s.open()
				h.assert_eq(case.admitted, request ~= nil)
				h.assert_eq(case.admitted and 1 or 0, #s.native, "a refused deadline never reaches the helper")
				if not case.admitted then h.assert_contains(tostring(reason), "timer ceiling") end
				h.assert_eq(case.admitted, Open.shutdown() == false)
			end)
		end
	end)
	for _, label in ipairs({ "exepath", "worker", "timeout", "clock" }) do
		h.it("desktop-confirmation parks shutdown during " .. label .. " and never acquires afterward", function()
			with_opener({ stop_at = label }, function(Open, s)
				local request = assert(s.open())
				h.assert_eq(false, s.early_ack)
				h.assert_eq(0, #s.native)
				h.assert_eq(true, request.is_settled())
				h.assert_eq(true, Open.shutdown())
				h.assert_eq(nil, s.open())
				h.assert_eq(0, s.callbacks)
			end)
		end)
	end
	h.it("desktop-confirmation rechecks page authority after every preparation boundary", function()
		local calls = 0
		with_opener({}, function(Open, s)
			local request = assert(s.open(function() calls = calls + 1; return calls < 3 end))
			h.assert_eq(0, #s.native)
			h.assert_eq(true, request.is_settled())
			h.assert_eq(true, Open.shutdown())
		end)
	end)
	h.it("desktop-confirmation handles pre-acquisition refusal without inventing native cleanup", function()
		with_opener({ refuse = true }, function(Open, s)
			h.assert_eq(nil, s.open())
			h.assert_eq(true, Open.shutdown())
			h.assert_eq(0, s.callbacks)
		end)
	end)
	for _, fault in ipairs({ "exepath", "worker", "timeout", "clock" }) do
		h.it("desktop-confirmation preparation throw in " .. fault .. " retires only the empty frame", function()
			with_opener({ throw_at = fault }, function(Open, s)
				h.assert_eq(nil, s.open())
				h.assert_eq(0, #s.native)
				h.assert_eq(true, Open.shutdown())
			end)
		end)
	end
	h.it("desktop-confirmation missing native executable is refused before dispatch", function()
		with_opener({ no_exepath = true }, function(Open, s)
			h.assert_eq(nil, s.open())
			h.assert_eq(0, #s.native)
			h.assert_eq(true, Open.shutdown())
		end)
	end)
	h.it("desktop-confirmation serializes an integral floating deadline as strict decimal argv", function()
		with_opener({ float_timeout = true }, function(_, s)
			local request = assert(s.open())
			h.assert_eq("30000", s.argv[3])
			s.native[1]:ack(); h.assert_eq(true, request.is_settled())
		end)
	end)
	h.it("desktop-confirmation retains a failed-start operation until its exact close ACK", function()
		with_opener({ failed_start = true }, function(Open, s)
			local request = assert(s.open())
			h.assert_eq(false, request.cancel())
			h.assert_eq(false, Open.shutdown())
			s.native[1]:ack()
			h.assert_eq(true, Open.shutdown())
			h.assert_eq(0, s.callbacks)
		end)
	end)
	h.it("desktop-confirmation inline completion waits for the constructor frame to return", function()
		with_opener({ inline = true }, function(_, s)
			local request = assert(s.open())
			h.assert_eq(1, s.callbacks)
			h.assert_eq(false, s.callback_during_constructor)
			h.assert_eq(true, request.is_settled())
		end)
	end)
end)

h.describe("desktop-confirmation revocation and native debt", function()
	h.it("desktop-confirmation a non-table constructor result retains inconclusive debt", function()
		with_opener({ invalid = false }, function(Open, s)
			local request = assert(s.open())
			h.assert_eq(false, request.is_settled())
			h.assert_eq(false, Open.shutdown())
		end)
	end)
	h.it("desktop-confirmation refused settlement subscription cannot fabricate closure", function()
		with_opener({ refuse_observer = true }, function(Open, s)
			local request = assert(s.open())
			s.native[1]:ack()
			h.assert_eq(false, request.is_settled())
			h.assert_eq(false, Open.shutdown())
		end)
	end)
	h.it("desktop-confirmation shutdown fences all owners before the first native cancellation", function()
		with_opener({ on_cancel = function(s) s.native[2]:logical(); s.native[2]:ack() end }, function(Open, s)
			local first, second = assert(s.open()), assert(s.open())
			h.assert_eq(false, Open.shutdown())
			h.assert_eq(0, s.callbacks)
			h.assert_eq(true, second.is_settled())
			h.assert_eq(false, first.is_settled())
			s.native[1]:ack()
			h.assert_eq(true, Open.shutdown())
		end)
	end)
	h.it("desktop-confirmation shutdown inside native construction retains the returned physical owner", function()
		with_opener({ stop_at = "constructor" }, function(Open, s)
			local request = assert(s.open())
			h.assert_eq(false, s.early_ack)
			h.assert_eq(false, request.is_settled())
			h.assert_true(s.native[1].cancels > 0)
			s.native[1]:logical(); h.assert_eq(0, s.callbacks)
			s.native[1]:ack(); h.assert_eq(true, Open.shutdown())
		end)
	end)
	h.it("desktop-confirmation a post-acquisition throw cannot release unknown debt", function()
		with_opener({ throw_at = "constructor" }, function(Open, s)
			local request = assert(s.open())
			h.assert_eq(false, request.is_settled())
			h.assert_eq(false, Open.shutdown())
			h.assert_eq(nil, s.open())
			h.assert_eq(0, s.callbacks)
		end)
	end)
	for _, port in ipairs({ "cancel", "is_settled", "on_settled" }) do
		h.it("desktop-confirmation missing " .. port .. " retains its exact malformed operation", function()
			with_opener({ missing_port = port }, function(Open, s)
				local request = assert(s.open())
				h.assert_eq(false, request.is_settled())
				h.assert_eq(false, Open.shutdown())
			end)
		end)
	end
	h.it("desktop-confirmation public mutation and method replacement cannot forge physical retirement", function()
		with_opener({}, function(Open, s)
			local request = assert(s.open())
			local actual = s.native[1]
			actual.cancel, actual.is_settled, actual.on_settled = function() return true end, function() return true end, function() return true end
			request.settled = true
			h.assert_eq(false, Open.shutdown())
			actual:notify(); h.assert_eq(false, request.is_settled())
			actual:ack(); h.assert_eq(true, Open.shutdown())
			h.assert_eq(0, s.callbacks)
		end)
	end)
	h.it("desktop-confirmation cancellation publishes settlement only after actual ACK", function()
		with_opener({}, function(_, s)
			local request, settled = assert(s.open()), 0
			h.assert_eq(true, request.on_settled(function() settled = settled + 1 end))
			h.assert_eq(false, request.cancel())
			h.assert_eq(0, settled)
			s.native[1]:ack(); h.assert_eq(1, settled)
			h.assert_eq(true, request.cancel()); h.assert_eq(1, settled)
		end)
	end)
end)

h.describe("desktop-confirmation worker pure validation", function()
	h.it("desktop-confirmation worker load and malformed argv never require a native module", function()
		local loaded, preload = package.loaded.luv, package.preload.luv
		local calls = 0
		package.loaded.luv = nil
		package.preload.luv = function() calls = calls + 1; error("native worker load refused") end
		local ok, err = pcall(function()
			local worker = assert(loadfile(h.driver_root() .. "/adapters/desktop_opener_worker.lua"))()
			for _, argv in ipairs({ false, {}, { "" }, { "bad\0target", "30000" }, { "target", "extra" },
				{ "target", "0" }, { "target", "-1" }, { "target", "1.5" }, { "target", "30000", "extra" },
				{ "target", "30000", field = "extra" }, { "target", [3] = "extra" } }) do
				h.assert_eq(64, worker.run(argv))
			end
			h.assert_eq(64, worker.run(nil))
			h.assert_eq(0, calls)
		end)
		package.loaded.luv, package.preload.luv = loaded, preload
		if not ok then error(err, 0) end
	end)
end)
