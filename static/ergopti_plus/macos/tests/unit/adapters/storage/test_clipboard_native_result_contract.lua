--- tests/unit/adapters/storage/test_clipboard_native_result_contract.lua

--- ==============================================================================
--- MODULE: Clipboard adapter native-result contract
--- DESCRIPTION:
--- Hammerspoon clipboard writers return booleans. A successful pcall containing
--- false or nil is an operational refusal, not a committed write/restore.
--- `clearContents()` is the exception: it has no result and succeeds on non-throw.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_clipboard(pasteboard)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("adapters.clipboard", { pasteboard = pasteboard })
end


helpers.describe("clipboard adapter: native boolean results are authoritative", function()
	helpers.it("refuses an unavailable generation at either snapshot boundary", function()
		for _, fail_on in ipairs({ 1, 2 }) do
			local calls, reads = 0, 0
			local clipboard = load_clipboard({
				changeCount = function() calls = calls + 1; if calls == fail_on then return nil end; return 0 end,
				allContentTypes = function() return { { "public.utf8-plain-text" } } end,
				readAllData = function() reads = reads + 1; return { ["public.utf8-plain-text"] = "text" } end,
			})
			local snapshot, ok = clipboard.save()
			helpers.assert_eq(snapshot, nil)
			helpers.assert_eq(ok, false)
			helpers.assert_eq(reads, fail_on == 1 and 0 or 1)
		end
	end)

	helpers.it("rejects a snapshot if a second item appears during capture", function()
		local count = 10
		local clipboard = load_clipboard({
			changeCount = function() return count end,
			allContentTypes = function() return { { "public.utf8-plain-text" } } end,
			readAllData = function()
				count = 11 -- another app replaced the board with two items
				return { ["public.utf8-plain-text"] = "same text" }
			end,
		})
		local snapshot, ok = clipboard.save()
		helpers.assert_eq(snapshot, nil)
		helpers.assert_eq(ok, false)
	end)

	helpers.it("preserves an advertised empty raw representation", function()
		local clipboard = load_clipboard({
			changeCount = function() return 1 end,
			allContentTypes = function() return { { "public.utf8-plain-text" } } end,
			readAllData = function() return { ["public.utf8-plain-text"] = "" } end,
		})
		local snapshot, ok = clipboard.save()
		helpers.assert_eq(ok, true)
		helpers.assert_eq(snapshot["public.utf8-plain-text"], "")
	end)

	helpers.it("refuses a single item whose advertised data could not be read", function()
		local clipboard = load_clipboard({
			changeCount = function() return 1 end,
			allContentTypes = function() return { { "public.utf8-plain-text", "public.png" } } end,
			readAllData = function() return { ["public.utf8-plain-text"] = "visible" } end,
		})
		local snapshot, ok = clipboard.save()
		helpers.assert_eq(snapshot, nil)
		helpers.assert_eq(ok, false)
	end)

	helpers.it("refuses snapshots when item enumeration is unavailable", function()
		local reads = 0
		local clipboard = load_clipboard({
			getContents = function() return "plain text" end,
			readAllData = function() reads = reads + 1; return { text = "first" } end,
		})
		local snapshot, ok = clipboard.save()
		helpers.assert_eq(snapshot, nil)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(reads, 0)
		helpers.assert_eq(clipboard.read(), "plain text")
	end)

	helpers.it("refuses snapshots when item enumeration fails", function()
		local clipboard = load_clipboard({
			changeCount = function() return 1 end,
			allContentTypes = function() error("pasteboard unavailable") end,
			readAllData = function() error("must not read") end,
		})
		local snapshot, ok = clipboard.save()
		helpers.assert_eq(snapshot, nil)
		helpers.assert_eq(ok, false)
	end)

	helpers.it("refuses a multi-item pasteboard that readAllData cannot preserve", function()
		local reads = 0
		local clipboard = load_clipboard({
			changeCount = function() return 1 end,
			allContentTypes = function() return { { "public.file-url" }, { "public.file-url" } } end,
			readAllData = function() reads = reads + 1; return { ["public.file-url"] = "first" } end,
		})
		local snapshot, ok = clipboard.save()
		helpers.assert_eq(snapshot, nil)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(reads, 0)
	end)

	helpers.it("distinguishes empty text from an empty pasteboard", function()
		local text = ""
		local clipboard = load_clipboard({ getContents = function() return text end })
		helpers.assert_eq(clipboard.read(), "")
		text = nil
		helpers.assert_eq(clipboard.read(), nil)
	end)

	for _, refusal in ipairs({ false, "nil" }) do
		helpers.it("write returns false when setContents returns " .. tostring(refusal), function()
			local clipboard = load_clipboard({
				setContents = function()
					if refusal == "nil" then return nil end
					return refusal
				end,
			})
			helpers.assert_eq(clipboard.write("payload"), false,
				"pcall success must not turn a refused native write into success")
		end)

		helpers.it("restore returns false when writeAllData returns " .. tostring(refusal), function()
			local clipboard = load_clipboard({
				writeAllData = function()
					if refusal == "nil" then return nil end
					return refusal
				end,
			})
			helpers.assert_eq(clipboard.restore({ ["public.utf8-plain-text"] = "original" }), false,
				"pcall success must not release clipboard ownership after restore refusal")
		end)
	end

	helpers.it("restore nil accepts clearContents' documented void result", function()
		local cleared = 0
		local clipboard = load_clipboard({
			clearContents = function() cleared = cleared + 1 end,
		})
		helpers.assert_eq(clipboard.restore(nil), true)
		helpers.assert_eq(cleared, 1)
	end)
end)
