--- tests/unit/platform/input/synthetic_input/test_transient_markers.lua

--- ==============================================================================
--- MODULE: Transient Pasteboard Markers
--- DESCRIPTION:
--- Clipboard managers (Maccy, Raycast, Alfred, Paste) leave out of their history
--- an item that carries the nspasteboard.org transient or concealed type. The
--- payloads the driver pastes and then restores (TextSend, hotstring
--- expansions, text actions) carry both, added to the same item without a
--- second change, so the ownership checks that compare change counts hold.
--- ==============================================================================

local helpers = require("tests.helpers")

local TEXT_UTI = "public.utf8-plain-text"

--- Runs body with the named pasteboard functions restored afterwards: the stub
--- table is shared by the whole run, and __reset() clears data only.
local function with_pasteboard(names, body)
	local pasteboard = require("tests.stubs.hs").pasteboard
	local saved = {}
	for _, name in ipairs(names) do saved[name] = pasteboard[name] end
	local ok, err = pcall(body)
	for _, name in ipairs(names) do pasteboard[name] = saved[name] end
	if not ok then error(err, 0) end
end

local function load_adapter()
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	local warnings = {}
	local logger = helpers.make_logger_stub()
	logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
	package.loaded["core.logger.engine.logger"] = logger
	package.loaded["clipboard.adapters.clipboard"] = nil
	return require("clipboard.adapters.clipboard"), hs_stub.pasteboard, warnings
end

helpers.describe("clipboard adapter: transient payload markers", function()
	helpers.it("publishes the text and both markers in one change", function()
		helpers.with_stub_scope({ "core.logger.engine.logger", "clipboard.adapters.clipboard" }, function()
			local Clipboard, pasteboard, warnings = load_adapter()
			local before = pasteboard.changeCount()
			helpers.assert_true((Clipboard.write_transient("expansion ✓")))
			helpers.assert_eq(pasteboard.changeCount(), before + 1, "the markers must not count as a second change")
			helpers.assert_eq(pasteboard.readAllData(), {
				[TEXT_UTI] = "expansion ✓",
				["org.nspasteboard.TransientType"] = "",
				["org.nspasteboard.ConcealedType"] = "",
			})
			helpers.assert_eq(#warnings, 0)
		end)
	end)

	helpers.it("adds no marker to a payload that was not written", function()
		helpers.with_stub_scope({ "core.logger.engine.logger", "clipboard.adapters.clipboard" }, function()
		with_pasteboard({ "setContents", "writeDataForUTI" }, function()
			local Clipboard, pasteboard = load_adapter()
			assert(pasteboard.writeAllData({ ["public.rtf"] = "{\\rtf1 user}" }))
			pasteboard.setContents = function() return false end
			local marks = 0
			pasteboard.writeDataForUTI = function() marks = marks + 1; return true end
			helpers.assert_eq((Clipboard.write_transient("lost")), false)
			helpers.assert_eq(marks, 0, "a user's copy must never be marked transient")
		end)
		end)
	end)

	helpers.it("keeps the paste when the pasteboard refuses a marker, and says so", function()
		helpers.with_stub_scope({ "core.logger.engine.logger", "clipboard.adapters.clipboard" }, function()
		with_pasteboard({ "writeDataForUTI" }, function()
			local Clipboard, pasteboard, warnings = load_adapter()
			pasteboard.writeDataForUTI = function() return false end
			helpers.assert_true((Clipboard.write_transient("payload")))
			helpers.assert_eq(pasteboard.getContents(), "payload")
			helpers.assert_eq(#warnings, 1)
			helpers.assert_true(warnings[1]:find("org.nspasteboard.TransientType", 1, true) ~= nil)
		end)
		end)
	end)

	helpers.it("uses the add form, which keeps the other types of the item", function()
		helpers.with_stub_scope({ "core.logger.engine.logger", "clipboard.adapters.clipboard" }, function()
		with_pasteboard({ "writeDataForUTI" }, function()
			local Clipboard, pasteboard = load_adapter()
			local calls = {}
			pasteboard.writeDataForUTI = function(...) calls[#calls + 1] = table.pack(...); return true end
			helpers.assert_true(Clipboard.mark_transient())
			helpers.assert_eq(#calls, 2)
			for _, call in ipairs(calls) do
				helpers.assert_eq(call.n, 3)
				helpers.assert_eq(call[2], "")
				helpers.assert_eq(call[3], true, "without add=true the payload itself would be cleared")
			end
		end)
		end)
	end)
end)

helpers.describe("transient payload writers: every paste-then-restore payload is marked", function()
	helpers.it("routes TextSend, hotstring and text-action payloads through the markers", function()
		local sender = assert(helpers.read_driver_source("Clipboard.write_transient(text, receipt)"),
			"TextSend must publish its payload through write_transient")
		helpers.assert_true(sender:find("Clipboard.write(text, receipt)", 1, true) == nil,
			"TextSend must not keep an unmarked write")
		local expander = assert(helpers.read_driver_source("pcall(hs.pasteboard.setContents, value)"))
		helpers.assert_true(expander:find(
			"pcall%(hs%.pasteboard%.setContents, value%)\n%s*%-%-[^\n]*\n%s*%-%-[^\n]*\n%s*if ok_write and write_result == true then Clipboard%.mark_transient%(%) end") ~= nil,
			"the hotstring payload must be marked right after its write")
		local text = assert(helpers.read_driver_source("local function set_transient_contents(text)"))
		helpers.assert_true(text:find("mutate_owned_clipboard(owner, pasteboard.setContents,", 1, true) == nil,
			"text actions must not publish an unmarked payload")
		local _, uses = text:gsub("mutate_owned_clipboard%(owner, set_transient_contents,", "")
		helpers.assert_eq(uses, 3, "the transform, plain paste and wrap payloads are marked")
	end)
end)
