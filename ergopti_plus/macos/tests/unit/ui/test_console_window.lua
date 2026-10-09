--- tests/unit/ui/test_console_window.lua

--- ==============================================================================
--- MODULE: Native Debug Console Placement Tests
--- DESCRIPTION:
--- Opening the console must defer native placement, target the console itself,
--- and preserve an existing large window rather than shrinking the user's view.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the console owner against a stateful native window and deferred queue.
--- @param run function Receives the owner and observable native state.
local function with_console(run)
	helpers.with_fresh_modules({ "ui.console_window", "infra.deferred_work", "infra.logger", "infra.paths" }, function()
		local state = {
			frame = { x = 10, y = 20, w = 300, h = 200 },
			screen = { x = 100, y = 50, w = 1000, h = 800 },
			moves = 0, opens = 0, errors = 0, reads = 0, queue = {},
		}
		package.loaded["infra.deferred_work"] = { after = function(delay, callback)
			helpers.assert_eq(delay, 0)
			if state.refuse_timer then return false end
			state.queue[#state.queue + 1] = callback
			return true
		end }
		local logger = helpers.make_logger_stub()
		logger.error = function() state.errors = state.errors + 1 end
		package.loaded["infra.logger"] = logger
		local window = {
			frame = function() return state.frame end,
			setFrame = function(self, frame)
				if state.refuse_move then return nil end
				state.moves = state.moves + 1
				state.frame = frame
				return self
			end,
		}
		local owner = helpers.load_with_stubs("ui.console_window", {
			openConsole = function(front)
				helpers.assert_eq(front, true)
				if state.refuse_open then error("native opening failed") end
				state.opens = state.opens + 1
			end,
			console = { hswindow = function() if not state.missing_window then return window end end },
			screen = { mainScreen = function()
				if not state.missing_screen then return { frame = function() return state.screen end } end
			end },
		})
		-- The native fixture supplies its own path adapter while loading the owner.
		-- Wrap that exact captured table so the read counter observes production.
		local paths = package.loaded["infra.paths"]
		local shared = paths.shared
		paths.shared = function(relative)
			state.reads = state.reads + 1
			if state.missing_manifest then error("manifest unavailable") end
			return shared(relative)
		end
		run(owner, state)
	end)
end

helpers.describe("Native console placement", function()
	helpers.it("opens in front and enlarges only on the next run-loop turn", function()
		with_console(function(owner, state)
			helpers.assert_eq(owner.open(), true)
			helpers.assert_eq(state.opens, 1)
			helpers.assert_eq(state.moves, 0)
			helpers.assert_eq(state.reads, 0, "the originating action must not read the geometry manifest")
			helpers.assert_eq(#state.queue, 1)
			state.queue[1]()
			helpers.assert_eq(state.reads, 1)
			helpers.assert_eq(state.moves, 1)
			helpers.assert_eq(state.frame.w, 700)
			helpers.assert_eq(state.frame.h, 600)
			helpers.assert_eq(state.frame.x, 250)
			helpers.assert_eq(state.frame.y, 150)
		end)
	end)

	for _, refusal in ipairs({ "missing_manifest", "refuse_move" }) do
		helpers.it("reports " .. refusal .. " from the deferred callback", function()
			with_console(function(owner, state)
				state[refusal] = true
				helpers.assert_eq(owner.open(), true)
				state.queue[1]()
				helpers.assert_eq(state.moves, 0)
				helpers.assert_eq(state.errors, 1)
			end)
		end)
	end

	helpers.it("does not schedule placement after an opening error", function()
		with_console(function(owner, state)
			state.refuse_open = true
			helpers.assert_eq(owner.open(), false)
			helpers.assert_eq(#state.queue, 0)
			helpers.assert_eq(state.reads, 0)
			helpers.assert_eq(state.errors, 1)
		end)
	end)

	helpers.it("keeps the position and size of an already large console", function()
		with_console(function(owner, state)
			state.frame = { x = 12, y = 34, w = 900, h = 700 }
			owner.open()
			state.queue[1]()
			helpers.assert_eq(state.moves, 0)
			helpers.assert_eq(state.frame.x, 12)
		end)
	end)

	helpers.it("grows a short dimension without shrinking the other", function()
		with_console(function(owner, state)
			state.frame.w = 900
			owner.open()
			state.queue[1]()
			helpers.assert_eq(state.frame.w, 900)
			helpers.assert_eq(state.frame.h, 600)
			helpers.assert_eq(state.frame.x, 150)
		end)
	end)

	for _, missing in ipairs({ "missing_window", "missing_screen" }) do
		helpers.it("reports " .. missing .. " without touching another window", function()
			with_console(function(owner, state)
				state[missing] = true
				owner.open()
				state.queue[1]()
				helpers.assert_eq(state.moves, 0)
				helpers.assert_eq(state.errors, 1)
			end)
		end)
	end

	helpers.it("reports a refused deferred placement", function()
		with_console(function(owner, state)
			state.refuse_timer = true
			helpers.assert_eq(owner.open(), false)
			helpers.assert_eq(#state.queue, 0)
			helpers.assert_eq(state.errors, 1)
		end)
	end)
end)
