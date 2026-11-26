--- tests/unit/modules/shortcuts/text_actions/fifo/test_borrowed_clipboard_output_types.lua
--- TextSender and keymap output never snapshot a clipboard another family
--- borrows: they type the text instead, as Windows' SendInstant does (MCP-002).
local helpers = require("tests.helpers")

local STUBS = {
	"platform.input.text_sender", "clipboard.adapters.clipboard", "platform.input.synthetic_input",
	"core.events.timer_scheduler", "diagnostics.adapters.event_provenance", "core.fs.adapters.storage",
	"core.fs.adapters.json_codec", "core.logger.engine.logger", "core.fs.engine.paths", "core.timing.engine.timings",
	"clipboard.borrowers", "hotstrings.engine.expander.utils",
}

local LONG_TEXT = string.rep("borrowed clipboard output ", 12)

--- Runs body with a recording native pasteboard and the real synthetic broker.
--- @param body function Receives the board record and the loaded fixture.
local function with_board(body)
	helpers.with_stub_scope(STUBS, function()
		local f = require("tests.support.synthetic_input_fixture").make({ deliver_trigger = false })
		local original = { ["public.utf8-plain-text"] = "USER CLIPBOARD", ["public.html"] = "<b>original</b>" }
		local board = { contents = original, reads = 0, writes = 0, count = 0 }
		f.hs_overrides.pasteboard = {
			changeCount = function() return board.count end,
			allContentTypes = function() return { {} } end,
			readAllData = function() board.reads = board.reads + 1; return board.contents end,
			setContents = function(text)
				board.writes = board.writes + 1
				board.count = board.count + 1
				board.contents = { ["public.utf8-plain-text"] = text }
				return true
			end,
			writeAllData = function(value)
				board.writes = board.writes + 1
				board.count = board.count + 1
				board.contents = value
				return true
			end,
			clearContents = function() board.count = board.count + 1; board.contents = {} end,
		}
		local synthetic = f.load()
		board.original, board.typed = original, {}
		local emit_key_strokes = synthetic.emit_key_strokes
		synthetic.emit_key_strokes = function(text, ...)
			board.typed[#board.typed + 1] = text
			return emit_key_strokes(text, ...)
		end
		body(board, f, synthetic)
	end)
end

--- Registers another family that holds a borrowed clipboard.
local function borrow_elsewhere()
	require("clipboard.borrowers").register("other_family", function() return true end)
end

helpers.describe("Borrowed clipboard output is typed (clipboard-borrowed-output-types)", function()
	helpers.it("(clipboard-borrowed-output-types) TextSender types instead of snapshotting a borrow", function()
		with_board(function(board)
			borrow_elsewhere()
			local sender = require("platform.input.text_sender")
			helpers.assert_true(sender.send(LONG_TEXT, { mode = "clipboard" }), "the output is still delivered")
			helpers.assert_eq(board.reads, 0, "the borrowed payload is never snapshotted")
			helpers.assert_eq(board.writes, 0, "the borrowed payload is never replaced")
			helpers.assert_true(board.contents == board.original, "the borrowing family keeps its clipboard")
			helpers.assert_eq(board.typed[1], LONG_TEXT, "the text is typed as keystrokes")
		end)
	end)

	helpers.it("(clipboard-borrowed-output-types) TextSender still pastes when nobody borrows", function()
		with_board(function(board)
			local sender = require("platform.input.text_sender")
			helpers.assert_true(sender.send(LONG_TEXT, { mode = "clipboard" }))
			helpers.assert_eq(board.reads > 0, true, "the user's clipboard is snapshotted")
			helpers.assert_eq(board.writes > 0, true, "the payload is published for Cmd+V")
			helpers.assert_eq(#board.typed, 0, "nothing is typed")
		end)
	end)

	helpers.it("(clipboard-borrowed-output-types) keymap output types instead of snapshotting a borrow", function()
		with_board(function(board)
			borrow_elsewhere()
			local utils = require("hotstrings.engine.expander.utils")
			helpers.assert_true(utils.should_paste(LONG_TEXT), "this output would normally be pasted")
			local count, echo, logical = utils.emit_text(LONG_TEXT)
			helpers.assert_true(count > 0, "the output is still delivered")
			helpers.assert_eq(echo, LONG_TEXT, "typed output reports its keystrokes")
			helpers.assert_eq(logical, LONG_TEXT)
			helpers.assert_eq(board.reads, 0, "the borrowed payload is never snapshotted")
			helpers.assert_eq(board.writes, 0, "the borrowed payload is never replaced")
			helpers.assert_eq(board.typed[1], LONG_TEXT, "the text is typed as keystrokes")
		end)
	end)
end)
