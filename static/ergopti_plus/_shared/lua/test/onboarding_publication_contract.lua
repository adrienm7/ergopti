--- _shared/lua/test/onboarding_publication_contract.lua

--- ==============================================================================
--- MODULE: Wizard Publication Receiving Contract
--- DESCRIPTION:
--- Handwritten native-port fault controls replay the actual shared receiver and
--- conditional file inverse. The controlled adapter measures policy and exact
--- effect custody; it does not qualify a real Mac mutex or installed wizard.
--- ==============================================================================

local M = {}
local BEFORE = '[sample]\nslot = "before"\n'
local CANDIDATE = '[sample]\nslot = "after"\n'
local FOREIGN = '[sample]\nslot = "foreign"\n'
local PATH = "/virtual/onboarding-cleanup-contract.toml"

--- Constructs a controlled native boundary with handwritten source images.
local function fixture(helpers, options)
	options = options or {}
	local f = { bytes = BEFORE, writes = 0, inverses = 0,
		cleanups = 0, inverse_cleanups = 0, admitted = true, settled = false,
		effect = options.published == true, scalar_calls = 0 }
	if options.absent then f.bytes = nil end
	local files = {}
	function files.read_with_status(path)
		helpers.assert_eq(path, PATH)
		return f.bytes, f.bytes == nil and "absent" or "ok"
	end
	function files.write_if_unchanged(path, content, expected)
		helpers.assert_eq(path, PATH)
		helpers.assert_eq(content, BEFORE, "the inverse is the handwritten captured original")
		helpers.assert_eq(expected, { status = "ok", content = CANDIDATE })
		if f.bytes ~= CANDIDATE then return false, "foreign source" end
		f.inverses = f.inverses + 1
		f.bytes = content
		if options.inverse_debt and f.inverses == 1 then
			return false, "inverse release pending", function()
				f.inverse_cleanups = f.inverse_cleanups + 1
				return f.inverse_settled == true, nil, true
			end
		end
		return true
	end
	function files.remove_if_unchanged(path, expected)
		helpers.assert_eq(path, PATH)
		helpers.assert_eq(expected, { status = "ok", content = CANDIDATE })
		if f.bytes ~= CANDIDATE then return false, "foreign source" end
		f.inverses = f.inverses + 1
		f.bytes = options.foreign_removal and FOREIGN or nil
		if options.removal_debt then
			return false, "removal release pending", function()
				f.removal_cleanups = (f.removal_cleanups or 0) + 1
				return f.removal_settled == true, nil, true
			end
		end
		return true
	end
	local receiver
	local function cleanup()
		f.cleanups = f.cleanups + 1
		if f.cleanup_throw then error("native release refused") end
		if f.cleanup_hook then f.cleanup_hook() end
		if f.reenter then
			helpers.assert_eq(receiver.ready(), false, "a nested request cannot borrow the active cleanup")
			helpers.assert_eq(receiver.write(PATH, {}), false)
		end
		return f.settled, nil, f.effect
	end
	receiver = require("onboarding_publication").new({ files = files,
		current = function() return f.admitted end,
		write = function(path, _, expected)
			f.writes = f.writes + 1
			helpers.assert_eq(path, PATH)
			helpers.assert_eq(expected, options.absent and { status = "absent" }
				or { status = "ok", content = BEFORE }, "the same original is carried into native publication")
			if options.drift then f.bytes = FOREIGN end
			if f.bytes ~= expected.content then return false, "native source changed" end
			if options.throw then error("native writer outcome is unknown") end
			if options.success then
				f.bytes = CANDIDATE
				if options.withdraw_success then f.admitted = false end
				return true, nil, CANDIDATE
			end
			if f.effect then f.bytes = CANDIDATE end
			return false, "native release pending", nil, options.opaque and {} or cleanup, CANDIDATE
		end,
	})
	f.receiver, f.files = receiver, files
	return f
end

--- Registers independent effect, compensation and source-authority controls.
--- @param helpers table Driver's unchanged assertion owner.
function M.register(helpers)
	helpers.describe("wizard native publication receiving", function()
		helpers.it("retires only a completed owner without lending its withdrawn provider", function()
			local f = fixture(helpers, { success = true })
			local token = f.receiver.begin()
			helpers.assert_eq(f.receiver.can_retire(), false, "an active host stack cannot be replaced")
			helpers.assert_eq(f.receiver.write(PATH, {}), true)
			helpers.assert_eq(f.receiver.finish(token), true)
			f.admitted = false
			helpers.assert_eq(f.receiver.ready(), false, "retirement does not re-admit the old provider")
			helpers.assert_eq(f.receiver.can_retire(), true)
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			helpers.assert_eq(f.writes, 1)
			local debt = fixture(helpers)
			helpers.assert_eq(debt.receiver.write(PATH, {}), false)
			debt.admitted = false
			helpers.assert_eq(debt.receiver.can_retire(), false, "withdrawal cannot discard actual physical debt")
		end)

		helpers.it("pins current helpers when constructing a successor and preserves the previous helper owner", function()
			local previous = package.loaded["toml_codec.writer"]
			local old = fixture(helpers, { success = true })
			package.loaded["toml_codec.writer"] = nil
			local called, failure = xpcall(function()
				local current = require("toml_codec.writer")
				helpers.assert_true(not rawequal(previous, current), "the real helper module is freshly constructed")
				helpers.assert_eq(old.receiver.ready(), false, "the held owner cannot borrow a successor helper")
				local successor = fixture(helpers, { success = true })
				helpers.assert_eq(successor.receiver.ready(), true)
				helpers.assert_eq(successor.receiver.write(PATH, {}), true)
				helpers.assert_eq(old.writes, 0)
			end, debug.traceback)
			package.loaded["toml_codec.writer"] = previous
			if not called then error(failure, 0) end
		end)

		helpers.it("claims scalar callbacks before a forward writer and refuses a cloned completion token", function()
			local f = fixture(helpers, { success = true })
			local token = f.receiver.begin()
			helpers.assert_type(token, "table")
			helpers.assert_eq(f.receiver.begin(), nil)
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.receiver.finish({}), false)
			helpers.assert_eq(f.receiver.write(PATH, {}), true)
			helpers.assert_eq(f.receiver.finish(token), true)
			helpers.assert_eq(f.receiver.finish(token), false)
			helpers.assert_eq(f.receiver.ready(), true)
		end)

		helpers.it("retains the actual callback through repeated refused release", function()
			local f = fixture(helpers)
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			helpers.assert_eq(f.receiver.pending(), true)
			for _ = 1, 2 do helpers.assert_eq(f.receiver.ready(), false) end
			helpers.assert_eq(f.cleanups, 2)
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			helpers.assert_eq(f.writes, 1, "retrying does not publish another forward image")
			helpers.assert_eq(f.inverses, 0)
		end)

		helpers.it("settles no-effect cleanup while preserving a foreign successor", function()
			local f = fixture(helpers)
			f.receiver.write(PATH, {})
			f.bytes, f.settled = FOREIGN, true
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.bytes, FOREIGN)
			helpers.assert_eq(f.inverses, 0)
			helpers.assert_eq(f.receiver.pending(), false)
		end)

		helpers.it("restores one published image only after exact release settlement", function()
			local f = fixture(helpers, { published = true })
			f.receiver.write(PATH, {})
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.bytes, CANDIDATE)
			helpers.assert_eq(f.inverses, 0)
			f.settled = true
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.bytes, BEFORE)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.cleanups, 2, "an acknowledged cleanup is never replayed")
		end)

		helpers.it("restores proven original absence after published cleanup", function()
			local f = fixture(helpers, { published = true, absent = true })
			f.receiver.write(PATH, {})
			f.settled = true
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_nil(f.bytes)
			helpers.assert_eq(f.inverses, 1)
		end)

		helpers.it("refuses a published inverse over foreign source and retains the request", function()
			local f = fixture(helpers, { published = true })
			f.receiver.write(PATH, {})
			f.bytes, f.settled = FOREIGN, true
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.bytes, FOREIGN)
			helpers.assert_eq(f.inverses, 0)
			helpers.assert_eq(f.receiver.pending(), true)
			f.bytes = CANDIDATE
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.bytes, BEFORE)
			helpers.assert_eq(f.cleanups, 1)
		end)

		helpers.it("retains an inverse's own release without repeating the accepted inverse", function()
			local f = fixture(helpers, { published = true, inverse_debt = true })
			f.receiver.write(PATH, {})
			f.settled = true
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.bytes, BEFORE)
			helpers.assert_eq(f.receiver.ready(), false)
			f.inverse_settled = true
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.inverse_cleanups, 2)
		end)

		helpers.it("rejects nil or textual effect flags and keeps the exact callback", function()
			for _, effect in ipairs({ "true", "false", "missing" }) do
				local f = fixture(helpers)
				f.receiver.write(PATH, {})
				f.settled, f.effect = true, effect
				if effect == "missing" then f.effect = nil end
				helpers.assert_eq(f.receiver.ready(), false)
				helpers.assert_eq(f.receiver.pending(), true)
				helpers.assert_eq(f.receiver.write(PATH, {}), false)
				helpers.assert_eq(f.writes, 1)
				f.effect = false
				helpers.assert_eq(f.receiver.ready(), true)
				helpers.assert_eq(f.cleanups, 2)
			end
		end)

		helpers.it("retains a throwing cleanup rather than admitting another publication", function()
			local f = fixture(helpers)
			f.receiver.write(PATH, {})
			f.cleanup_throw = true
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.receiver.pending(), true)
			f.cleanup_throw, f.settled = false, true
			helpers.assert_eq(f.receiver.ready(), true)
		end)

		helpers.it("refuses an unbound opaque native object instead of invoking methods", function()
			local f = fixture(helpers, { opaque = true })
			f.receiver.write(PATH, {})
			f.settled = true
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.receiver.pending(), true)
			helpers.assert_eq(f.cleanups, 0)
		end)

		helpers.it("passes the exact captured preimage into a drifting native batch", function()
			local f = fixture(helpers, { drift = true })
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			helpers.assert_eq(f.bytes, FOREIGN)
			helpers.assert_eq(f.inverses, 0)
			helpers.assert_eq(f.receiver.pending(), false)
		end)

		helpers.it("rejects reentrant Finish while settling the retained native callback", function()
			local f = fixture(helpers)
			f.receiver.write(PATH, {})
			f.reenter, f.settled = true, true
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.cleanups, 1)
			helpers.assert_eq(f.writes, 1)
		end)

		helpers.it("settles native release before a retained scalar rollback callback", function()
			local f = fixture(helpers)
			f.receiver.write(PATH, {})
			helpers.assert_eq(f.receiver.compensate(function()
				f.scalar_calls = f.scalar_calls + 1
				return f.scalar_settled == true
			end), true)
			helpers.assert_eq(f.receiver.compensate(function() error("replacement") end), false)
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.scalar_calls, 0)
			f.settled = true
			helpers.assert_eq(f.receiver.ready(), false)
			f.scalar_settled = true
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.scalar_calls, 2)
			helpers.assert_eq(f.cleanups, 2)
		end)

		helpers.it("refuses withdrawn providers without preventing exact release-only cleanup", function()
			local f = fixture(helpers, { published = true })
			f.receiver.write(PATH, {})
			f.admitted, f.settled = false, true
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.cleanups, 1)
			helpers.assert_eq(f.inverses, 0)
			f.admitted = true
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.cleanups, 1)
		end)

		helpers.it("refuses a native callback that withdraws the genuine shared compensation helpers", function()
			local inverse, writer = require("config_file_inverse"), require("toml_codec.writer")
			local original = { settle = inverse.settle_publication, restore = inverse.restore,
				retry = writer.retry_publication_cleanup, read = writer.read_classified,
				module = package.loaded["config_file_inverse"] }
			for _, seam in ipairs({ "settle", "restore", "retry", "reader", "module" }) do
				local f = fixture(helpers, { published = true })
				f.receiver.write(PATH, {})
				f.settled = true
				f.cleanup_hook = function()
					if seam == "settle" then inverse.settle_publication = function() return true end end
					if seam == "restore" then inverse.restore = function() return true end end
					if seam == "retry" then writer.retry_publication_cleanup = function() return true, nil, true end end
					if seam == "reader" then writer.read_classified = function() return BEFORE, "ok" end end
					if seam == "module" then package.loaded["config_file_inverse"] = {} end
				end
				local called, detail = xpcall(function()
					helpers.assert_eq(f.receiver.ready(), false)
					helpers.assert_eq(f.receiver.pending(), true)
					helpers.assert_eq(f.bytes, CANDIDATE, "forged helper success cannot restore the original")
					helpers.assert_eq(f.inverses, 0)
				end, debug.traceback)
				inverse.settle_publication, inverse.restore = original.settle, original.restore
				writer.retry_publication_cleanup, writer.read_classified = original.retry, original.read
				package.loaded["config_file_inverse"] = original.module
				if not called then error(detail, 0) end
				f.cleanup_hook = nil
				helpers.assert_eq(f.receiver.ready(), true)
				helpers.assert_eq(f.bytes, BEFORE)
				helpers.assert_eq(f.cleanups, 1, "reinstatement spends the already accepted cleanup phase only once")
			end
		end)

		helpers.it("refuses a replaced admitted native inverse before granting source mutation", function()
			for _, name in ipairs({ "write_if_unchanged_admitted", "remove_if_unchanged_admitted" }) do
				local f = fixture(helpers, { published = true })
				f.receiver.write(PATH, {})
				f.files[name] = function() error("a replacement cannot acquire the pending inverse") end
				f.settled = true
				helpers.assert_eq(f.receiver.ready(), false)
				helpers.assert_eq(f.cleanups, 1, "the original release still settles")
				helpers.assert_eq(f.inverses, 0)
				helpers.assert_eq(f.bytes, CANDIDATE)
				helpers.assert_eq(f.receiver.pending(), true)
				f.files[name] = nil
				helpers.assert_eq(f.receiver.ready(), true)
				helpers.assert_eq(f.bytes, BEFORE)
				helpers.assert_eq(f.cleanups, 1, "recovery must not repeat accepted native release")
			end
		end)

		helpers.it("requires literal native settlement as well as literal effect", function()
			for _, settled in ipairs({ "true", "false", 1 }) do
				local f = fixture(helpers)
				f.receiver.write(PATH, {})
				f.settled = settled
				helpers.assert_eq(f.receiver.ready(), false)
				helpers.assert_eq(f.receiver.pending(), true)
				helpers.assert_eq(f.writes, 1)
				f.settled = true
				helpers.assert_eq(f.receiver.ready(), true)
				helpers.assert_eq(f.cleanups, 2)
			end
		end)

		helpers.it("keeps an unknown throwing writer outcome retained without synthesizing an effect", function()
			local f = fixture(helpers, { throw = true })
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			helpers.assert_eq(f.receiver.pending(), true)
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.cleanups, 0)
			helpers.assert_eq(f.inverses, 0)
		end)

		helpers.it("preserves a foreign successor after an inverse was published with outstanding release", function()
			local f = fixture(helpers, { published = true, inverse_debt = true })
			f.receiver.write(PATH, {})
			f.settled = true
			helpers.assert_eq(f.receiver.ready(), false)
			f.bytes, f.inverse_settled = FOREIGN, true
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.receiver.pending(), true)
			helpers.assert_eq(f.bytes, FOREIGN)
			helpers.assert_eq(f.inverses, 1)
			f.bytes = BEFORE
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.inverse_cleanups, 1)
		end)

		helpers.it("keeps the native callback stack claimed until its exact handler returns", function()
			local gate = require("onboarding_publication").callback_gate()
			local claim = gate.enter()
			helpers.assert_type(claim, "table")
			helpers.assert_eq(gate.busy(), true)
			helpers.assert_nil(gate.enter())
			helpers.assert_eq(gate.leave({}), false)
			helpers.assert_eq(gate.busy(), true)
			helpers.assert_eq(gate.leave(claim), true)
			helpers.assert_eq(gate.busy(), false)
			helpers.assert_eq(gate.leave(claim), false)
		end)

		helpers.it("verifies original absence after acknowledged success withdraws its native owner", function()
			local f = fixture(helpers, { absent = true, success = true,
				withdraw_success = true, foreign_removal = true })
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			helpers.assert_eq(f.receiver.pending(), true)
			helpers.assert_eq(f.bytes, CANDIDATE)
			f.admitted = true
			helpers.assert_eq(f.receiver.ready(), false, "an accepted removal does not prove absence after a successor")
			helpers.assert_eq(f.bytes, FOREIGN)
			helpers.assert_eq(f.receiver.pending(), true)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.inverses, 1, "accepted removal cannot delete the foreign successor on retry")
			f.bytes = nil
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.receiver.pending(), false)
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.inverses, 1)
		end)

		helpers.it("verifies absence after the withdrawn success removal's own cleanup settles", function()
			local f = fixture(helpers, { absent = true, success = true,
				withdraw_success = true, foreign_removal = true, removal_debt = true })
			helpers.assert_eq(f.receiver.write(PATH, {}), false)
			f.admitted = true
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.removal_cleanups, 1)
			f.removal_settled = true
			helpers.assert_eq(f.receiver.ready(), false, "literal removal cleanup still owes actual absence verification")
			helpers.assert_eq(f.bytes, FOREIGN)
			helpers.assert_eq(f.receiver.pending(), true)
			helpers.assert_eq(f.removal_cleanups, 2)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.receiver.ready(), false)
			helpers.assert_eq(f.removal_cleanups, 2, "accepted removal cleanup must not replay")
			f.bytes = nil
			helpers.assert_eq(f.receiver.ready(), true)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.removal_cleanups, 2)
		end)

		helpers.it("keeps ordinary successful writes compatible with the existing commit gateway", function()
			local f = fixture(helpers, { success = true })
			helpers.assert_eq(f.receiver.write(PATH, {}), true)
			helpers.assert_eq(f.receiver.pending(), false)
			helpers.assert_eq(f.bytes, CANDIDATE)
			helpers.assert_eq(f.cleanups, 0)
			helpers.assert_eq(f.inverses, 0)
		end)
	end)
end

return M
