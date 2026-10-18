--- tests/unit/adapters/synthetic_input/test_selection_write_owner.lua

--- ==============================================================================
--- MODULE: Selected Write Lifetime and Destination
--- DESCRIPTION:
--- Retains original action and field authority after consuming a read receipt,
--- through synchronous injection, reentrant cancellation and physical cleanup.
--- ==============================================================================
local helpers = require("tests.helpers")
local fixture = require("tests.support.adapters.synthetic_input.selection_write_fixture")

helpers.describe("selected writes retain field and action authority", function()
	for _, text in ipairs({ "ok", "☃" }) do
		helpers.it("commits a stable selected " .. text .. " only after cleanup", function()
			fixture.with(function(state, owner)
				local token = state.read()
				helpers.assert_true(state.replace(token, nil, text))
				helpers.assert_type(state.publication, "table")
				helpers.assert_eq(state.captured_focus, "atspi:" .. state.field.bus .. ":" .. state.field.path)
				helpers.assert_eq(state.resets, 1)
				helpers.assert_true(owner.is_settled())
				helpers.assert_eq(state.held, {})
				helpers.assert_eq(state.clipboard, "SAVED")
				helpers.assert_eq(state.replace(token), false, "consumed read authority is never revived")
			end)
		end)
	end
	for _, point in ipairs({ "read", "write", "settle", "lookup", "restore-wait", "reselect" }) do
		for _, change in ipairs({ "field", "password", "cancel" }) do
			helpers.it("refuses selected " .. change .. " at " .. point, function()
				fixture.with(function(state, owner)
					local token, moved = state.read(), false
					state.on_boundary = function(boundary)
						if boundary ~= point or moved then return end
						moved = true
						if change == "cancel" then state.allowed = false; helpers.assert_eq(owner.cancel(), false)
						else state.field.path = "/field/successor"; if change == "password" then state.field.role = 40 end end
					end
					helpers.assert_eq(state.replace(token), false)
					helpers.assert_true(moved, "the intended external boundary ran")
					helpers.assert_eq(state.resets, 0)
					helpers.assert_eq(state.held, {}, "owned UP cleanup remains permitted")
					helpers.assert_eq(state.clipboard, "SAVED")
					helpers.assert_true(owner.is_settled())
					local wire = table.concat(state.wire, " ")
					local expected = (point == "restore-wait" or point == "reselect") and "29:1 47:1 47:0 29:0" or ""
					helpers.assert_eq(wire, expected, "retirement permits no new paste or ShiftLeft DOWN")
				end)
			end)
		end
	end
	for _, at in ipairs({ "capture-owner", "emit:29:1", "restore", "reselect" }) do
		helpers.it("retains its writing slot during " .. at, function()
			fixture.with(function(state, owner)
				local token, checked = state.read(), false
				state.on_boundary = function(point)
					if point ~= at or checked then return end
					checked = true
					helpers.assert_eq(owner.is_settled(), false)
					helpers.assert_eq(owner.read("atspi:" .. state.field.bus .. ":" .. state.field.path, state.authorized, function() end), false)
					helpers.assert_eq(owner.replace(token, "nested", state.authorized, state.emit, function() end), false)
				end
				helpers.assert_true(state.replace(token))
				helpers.assert_true(checked)
				helpers.assert_eq(state.starts, 2, "no nested range capture starts")
				helpers.assert_true(owner.is_settled())
			end)
		end)
	end
	for _, action in ipairs({ "cancel", "stop" }) do
		helpers.it("revokes before " .. action .. " can acknowledge an emitting frame", function()
			fixture.with(function(state, owner)
				local token = state.read()
				helpers.assert_eq(state.replace(token, function(_, publication)
					helpers.assert_eq(owner[action](), false)
					helpers.assert_eq(owner.is_settled(), false)
					helpers.assert_eq(type(publication) == "table" and publication.current(), false)
					return { ok = true, cleanup_ok = true }
				end), false)
				helpers.assert_true(owner.is_settled(), "known completed cleanup retires only this write")
			end)
		end)
	end
	for _, fault in ipairs({ "throw", "nil", "boolean", "missing-cleanup", "cleanup-false", "clipboard-restoration" }) do
		helpers.it("retains inconclusive selected cleanup after " .. fault, function()
			fixture.with(function(state, owner)
				local token = state.read()
				helpers.assert_eq(state.replace(token, function()
					if fault == "throw" then error("controlled uncertain emitter") end
					if fault == "nil" then return nil end
					if fault == "boolean" then return true end
					if fault == "missing-cleanup" then return { ok = true } end
					return { ok = false, cleanup_ok = fault ~= "cleanup-false", failed_phase = fault == "clipboard-restoration" and "clipboard restoration" or "wire" }
				end), false)
				helpers.assert_eq(owner.is_settled(), false)
				helpers.assert_eq(owner.cancel(), false)
				helpers.assert_eq(owner.stop(), false)
				helpers.assert_eq(state.replace(token), false)
				helpers.assert_eq(owner.read("target", state.authorized, function() end), false)
				helpers.assert_eq(state.starts, 2)
			end)
		end)
	end
	helpers.it("keeps a real refused clipboard restore as debt despite native key cleanup", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.restore_refused = true
			helpers.assert_eq(state.replace(token), false)
			helpers.assert_eq(state.held, {})
			helpers.assert_eq(state.writes, { "☃", "SAVED" })
			helpers.assert_eq(owner.is_settled(), false)
			helpers.assert_eq(owner.stop(), false)
		end)
	end)
end)

helpers.describe("selected write admission reentry", function()
	for _, at in ipairs({ "capture-owner", "current", "cached", "authorized" }) do
		helpers.it("cannot adopt a new action after " .. at .. " revokes the original", function()
			fixture.with(function(state, owner)
				local token, revoked = state.read(), false
				local function revoke()
					if revoked then return end
					revoked = true
					helpers.assert_eq(owner.cancel(), false)
					helpers.assert_eq(owner.read("successor", function() return true end, function() end), false)
				end
				state.capture_override = function()
					return {
						current = function() if at == "current" then revoke() end; return true end,
						cached = function() if at == "cached" then revoke() end; return true end,
					}
				end
				state.on_boundary = function(point)
					if point == "capture-owner" and at == point then revoke() end
					if point == "authorized" and at == point and not owner.is_settled() then
						-- Only revoke inside the writer, not its native capture admission.
						if state.captured_focus then revoke() end
					end
				end
				helpers.assert_eq(state.replace(token), false)
				helpers.assert_true(revoked)
				helpers.assert_eq(state.emits, 0)
				helpers.assert_true(owner.is_settled(), "pre-emitter refusal acquired no output cleanup debt")
			end)
		end)
	end
	helpers.it("refuses recursive publication checks without borrowing their authorization", function()
		fixture.with(function(state, owner)
			local token = state.read()
			helpers.assert_true(state.replace(token, function(_, publication)
				local nested
				state.on_boundary = function(point)
					if point == "authorized" then nested = publication.current() end
				end
				helpers.assert_true(publication.current())
				helpers.assert_eq(nested, false)
				state.on_boundary = nil
				return { ok = true, cleanup_ok = true }
			end))
			helpers.assert_true(owner.is_settled())
		end)
	end)
	helpers.it("admits a fresh read after a completed output refusal without replaying its token", function()
		fixture.with(function(state, owner)
			local token = state.read()
			helpers.assert_eq(state.replace(token, function() return { ok = false, cleanup_ok = true } end), false)
			helpers.assert_true(owner.is_settled())
			helpers.assert_eq(state.replace(token), false)
			local fresh = state.read()
			helpers.assert_true(state.replace(fresh))
			helpers.assert_eq(state.resets, 1)
		end)
	end)
	helpers.it("retains outstanding physical key-UP debt after cancellation", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.on_boundary = function(point)
				if point == "emit:29:1" then state.allowed = false; state.refuse_up = 29 end
			end
			helpers.assert_eq(state.replace(token), false)
			helpers.assert_eq(state.held, { [29] = true })
			helpers.assert_eq(state.clipboard, "SAVED")
			helpers.assert_eq(owner.is_settled(), false)
			helpers.assert_eq(owner.cancel(), false)
		end)
	end)
end)

helpers.describe("Main selected write publication wiring", function()
	for _, moved in ipairs({ false, true }) do
		helpers.it("carries its private publication through the actual Main callback with moved=" .. tostring(moved), function()
			fixture.with(function(state)
				local token = state.read()
				local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
				local source = file:read("*a"); assert(file:close())
				local prefix = "replace_selection = function(text, receipt, authorized, callback)"
				local first = assert(source:find(prefix, 1, true))
				local last = assert(source:find("\n\t\t\tend,", first, true))
				local callback = source:sub(first + #"replace_selection = ", last + #"\n\t\t\tend" - 1)
				local compile = loadstring or load
				local factory = assert(compile("return function(injector,privacy_owners,opts,engine) local _undoable; return " .. callback .. " end"))()
				local argc, captured
				local replace = factory({ inject_selected = function(...)
					argc = select("#", ...)
					local text, private, publication = ...
					captured = publication
					return state.injector.inject_selected(text, private, publication)
				end }, { selection = state.owner }, { dry_run = false }, { reset = function() state.resets = state.resets + 1 end })
				if moved then state.on_boundary = function(point) if point == "settle" then state.field.role = 40 end end end
				local committed
				helpers.assert_true(replace("☃", token, state.authorized, function(value) committed = value end))
				state.deliver()
				helpers.assert_eq(argc, 3)
				helpers.assert_type(captured, "table")
				helpers.assert_eq(committed, not moved)
				helpers.assert_eq(state.resets, moved and 0 or 1)
			end)
		end)
	end
end)

helpers.describe("Main selected write owner construction", function()
	helpers.it("pins the resident field factory in the actual daemon constructor", function()
		fixture.with(function(state)
			local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
			local source = file:read("*a"); assert(file:close())
			local first = assert(source:find('\t\tprivacy_owners.selection = require("adapters.selection_transaction").new({', 1, true))
			local last = assert(source:find("\n\t\t})", first, true))
			local body = source:sub(first, last + #"\n\t\t})" - 1)
			local compile = loadstring or load
			local factory = assert(compile("return function(privacy_owners, secure_focus_guard) " .. body .. " return privacy_owners.selection end"))()
			state.owner = factory({}, state.guard)
			local token = state.read()
			helpers.assert_true(state.replace(token))
			helpers.assert_type(state.publication, "table")
		end)
	end)
end)

helpers.describe("selected write private final authority", function()
	helpers.it("cannot forge a retired write by replacing its emitter view", function()
		fixture.with(function(state, owner)
			local token, mutated = state.read(), false
			helpers.assert_eq(state.replace(token, function(_, publication)
				helpers.assert_eq(owner.cancel(), false)
				publication.current = function() return true end
				publication.cached = publication.current
				mutated = true
				return { ok = true, cleanup_ok = true }
			end), false)
			helpers.assert_true(mutated, "the emitter actually replaced its public view")
			helpers.assert_true(owner.is_settled())
			helpers.assert_eq(state.resets, 0)
		end)
	end)
end)

helpers.describe("selected reads survive an idle action transfer", function()
	for _, action in ipairs({ "edit", "shift-tone", "translate" }) do
		helpers.it("keeps the immutable read for a distinct authorized " .. action .. " action", function()
			fixture.with(function(state, owner)
				local token = state.read()
				state.allowed = false
				helpers.assert_true(owner.cancel(), "idle cancellation has no physical writer to retire")
				helpers.assert_eq(state.replace(token), false, "the original action lost its own authority")
				local committed
				helpers.assert_true(owner.replace(token, "ok", function() return true end, state.emit, function(value) committed = value end))
				state.deliver()
				helpers.assert_true(committed, "a new action may revalidate this unchanged native observation")
				helpers.assert_eq(state.emits, 1)
				helpers.assert_true(owner.is_settled())
			end)
		end)
	end
	helpers.it("terminal stop invalidates idle reads even for a new authorized action", function()
		fixture.with(function(state, owner)
			local token = state.read()
			helpers.assert_true(owner.stop())
			helpers.assert_eq(owner.replace(token, "ok", function() return true end, state.emit, function() end), false)
			helpers.assert_eq(state.emits, 0)
		end)
	end)
end)
