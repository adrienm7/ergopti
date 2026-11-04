--- tests/unit/infra/scope/test_keyboard_layout_scope.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Scope (Linux)
--- DESCRIPTION:
--- The layout category of the global restore on Linux changes config.toml's
--- layout rows, then has the layout manager load the layout carrying them. Pins
--- the transaction (rows restored or cleared, foreign content kept, exact
--- inverse, refused publication leaves the file alone, a refused revert stays
--- owed) and the participant: it settles only when the session answers, a load
--- the session refuses reverts the rows, an inert choice is acknowledged with its
--- reason, and a reload refused during a rollback stays owed until retried.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

local SOURCE = '[layout]\ndirect_access_digits = "digits"\nnumber_row_reorder_edges = true\nunknown = "keep"\n[other]\nopaque = [1, 2]\n'

local function with_scope(body)
	Sandbox.with_config(SOURCE, function(path)
		local names = { "infra.config_paths", "infra.keyboard_layout_scope", "infra.number_row_preferences" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local controls = {}
		local backup = path .. ".scope-backup"
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional publication") end,
				write_if_unchanged = function(target, content, expected)
					if controls.refuse == target then return false, "injected refusal" end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			local Scope = require("infra.keyboard_layout_scope")
			local owner = Scope.new({ path = path, backup_path = backup, files = files })
			body(owner, controls, path, backup, Scope)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		os.remove(backup)
		if not ok then error(err, 0) end
	end)
end

--- A number-row live owner whose session answers when the test says so.
--- @param options table|nil { unavailable = reason }
--- @return table live
--- @return table state { loads, answer(ok, code) }
local function fake_live(options)
	options = options or {}
	local Preferences = require("infra.number_row_preferences")
	local state = { loads = {} }
	local live = {
		stored = function() return Preferences.settings() end,
		available = function()
			if options.unavailable then return false, options.unavailable end
			return true, nil
		end,
		apply_stored = function(on_done)
			state.loads[#state.loads + 1] = Preferences.settings()
			state.answer = function(ok, code)
				state.answer = nil
				if ok then return on_done(true, nil, nil, nil, { order = "native" }) end
				return on_done(false, "live_apply_failed", "not loaded", code, nil)
			end
			return true
		end,
	}
	return live, state
end

helpers.describe("Linux keyboard layout scope", function()
	helpers.it("restores the recommended layout rows and keeps foreign content", function()
		with_scope(function(owner, _, path)
			helpers.assert_eq(owner.apply("recommended"), true)
			local document = Codec.decode(Sandbox.read_bytes(path))
			-- Linux recommends the declared defaults, which the file leaves implicit.
			helpers.assert_eq(document.layout.direct_access_digits, nil)
			helpers.assert_eq(document.layout.number_row_reorder_edges, nil)
			helpers.assert_eq(document.layout.unknown, "keep")
			helpers.assert_eq(document.other.opaque, { 1, 2 })
		end)
	end)

	helpers.it("clears the layout rows and keeps foreign content", function()
		with_scope(function(owner, _, path)
			helpers.assert_eq(owner.apply("clear"), true)
			local document = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(document.layout.direct_access_digits, nil)
			helpers.assert_eq(document.layout.number_row_reorder_edges, nil)
			helpers.assert_eq(document.layout.unknown, "keep")
		end)
	end)

	helpers.it("puts the exact bytes back on revert and leaves no debt", function()
		with_scope(function(owner, _, path)
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(owner.apply("recommended"), true)
			helpers.assert_eq(owner.revert(), true)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	helpers.it("preserves a preexisting backup and refuses before changing the file", function()
		with_scope(function(owner, _, path, backup)
			local before = Sandbox.read_bytes(path)
			Sandbox.write_bytes(backup, "reserved backup")
			helpers.assert_eq(owner.apply("recommended"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(Sandbox.read_bytes(backup), "reserved backup")
		end)
	end)

	helpers.it("refuses a paused request and an unknown mode before any request", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq((Scope.apply("recommended", function() return true end)), false)
			helpers.assert_eq((Scope.apply("bogus", function() return false end)), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
		end)
	end)

	helpers.it("composes through the participant and reverts when a later category refuses", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local live, state = fake_live()
			local participant = Scope.participant(function() return false end, { live = live })
			local settled
			participant.apply("recommended", function(ok) settled = ok end)
			state.answer(true)
			helpers.assert_eq(settled, true)
			helpers.assert_true(Sandbox.read_bytes(path) ~= before)
			local reverted
			participant.revert(function(ok) reverted = ok end)
			state.answer(true)
			helpers.assert_eq(reverted, true)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(state.loads[2], { order = "digits", edges = true }, "the session goes back to the old rows")
			helpers.assert_eq(participant.pending(), false)
		end)
	end)

	helpers.it("settles only once the session holds the layout carrying the new rows (layout-scope-ack)", function()
		with_scope(function(_, _, _, _, Scope)
			local live, state = fake_live()
			local participant = Scope.participant(function() return false end, { live = live })
			local settled
			participant.apply("clear", function(ok, detail) settled = { ok, detail } end)
			helpers.assert_nil(settled, "the rows are written but the session has not answered")
			helpers.assert_eq(state.loads[1], { order = "native", edges = false }, "the session is asked for the new rows")
			helpers.assert_eq(participant.pending(), true, "an unanswered load is pending")
			state.answer(true)
			helpers.assert_eq(settled, { true, nil })
			helpers.assert_eq(participant.pending(), false)
			helpers.assert_true(participant.release() ~= false, "a settled request releases its inverse")
		end)
	end)

	helpers.it("reverts the rows when the session refuses the layout (layout-scope-ack)", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local live, state = fake_live()
			local participant = Scope.participant(function() return false end, { live = live })
			local settled
			participant.apply("recommended", function(ok, detail) settled = { ok, detail } end)
			state.answer(false, "stale_keymap")
			helpers.assert_eq(settled[1], false)
			helpers.assert_true(tostring(settled[2]):find("stale_keymap", 1, true) ~= nil, tostring(settled[2]))
			helpers.assert_eq(Sandbox.read_bytes(path), before, "the file does not claim rows the keyboard lacks")
			helpers.assert_eq(participant.pending(), false)
		end)
	end)

	helpers.it("acknowledges a choice this session cannot load with its reason (layout-scope-ack)", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local live, state = fake_live({ unavailable = "session_unsupported" })
			local participant = Scope.participant(function() return false end, { live = live })
			local settled
			participant.apply("recommended", function(ok, detail) settled = { ok, detail } end)
			helpers.assert_eq(settled, { true, "session_unsupported" })
			helpers.assert_eq(#state.loads, 0, "nothing is loaded")
			helpers.assert_true(Sandbox.read_bytes(path) ~= before, "the choice is stored")
		end)
	end)

	helpers.it("asks nothing of the session when the rows do not change (layout-scope-ack)", function()
		with_scope(function(owner, _, _, _, Scope)
			helpers.assert_eq(owner.apply("recommended"), true)
			owner.release()
			local live, state = fake_live()
			local participant = Scope.participant(function() return false end, { live = live })
			local settled
			participant.apply("recommended", function(ok, detail) settled = { ok, detail } end)
			helpers.assert_eq(settled, { true, "rows_unchanged" })
			helpers.assert_eq(#state.loads, 0)
		end)
	end)

	helpers.it("keeps a reload the session refused during a rollback owed until retried (layout-scope-ack)", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local live, state = fake_live()
			local participant = Scope.participant(function() return false end, { live = live })
			participant.apply("recommended", function() end)
			state.answer(true)
			local reverted
			participant.revert(function(ok) reverted = ok end)
			state.answer(false, "not_loaded")
			helpers.assert_eq(reverted, false)
			helpers.assert_eq(Sandbox.read_bytes(path), before, "the rows are back")
			helpers.assert_eq(participant.pending(), true, "the session still holds the new rows")
			helpers.assert_eq(participant.release(), false, "an owed reload is never forgotten")
			local retried
			participant.retry_restore(function(ok) retried = ok end)
			state.answer(true)
			helpers.assert_eq(retried, true)
			helpers.assert_eq(state.loads[3], { order = "digits", edges = true })
			helpers.assert_eq(participant.pending(), false)
		end)
	end)

	helpers.it("composes with the global scope and settles it only after the session answers (layout-scope-ack)", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local saved = package.loaded["infra.global_scope"]
			package.loaded["infra.global_scope"] = nil
			local ok, err = pcall(function()
				local GlobalScope = require("infra.global_scope")
				local live, state = fake_live()
				local refusing = { pending = function() return false end, release = function() end,
					retry_restore = function(done) return done(true) end,
					revert = function(done) return done(true) end,
					apply = function(_, done) return done(false, "llm refused") end }
				local settled
				helpers.assert_eq(GlobalScope.apply("recommended", {
					keyboard_layout = Scope.participant(function() return false end, { live = live }), llm = refusing,
				}, function(committed, report) settled = { committed, report } end), true)
				helpers.assert_nil(settled, "the composition waits for the session")
				local again
				GlobalScope.apply("clear", {}, function(committed, report) again = { committed, report } end)
				helpers.assert_eq({ again[1], again[2].point, again[2].kind }, { false, "acquire", "pending" })
				helpers.assert_eq(GlobalScope.pending(), true, "Quit sees the global writer")
				state.answer(true)
				helpers.assert_nil(settled, "the later refusal reverts the layout, which the session must answer")
				state.answer(true)
				helpers.assert_eq(settled[1], false)
				helpers.assert_eq({ settled[2].failed, settled[2].reverted }, { "llm", true })
				helpers.assert_eq(Sandbox.read_bytes(path), before)
				helpers.assert_eq(GlobalScope.pending(), false)
			end)
			package.loaded["infra.global_scope"] = saved
			if not ok then error(err, 0) end
		end)
	end)
end)
