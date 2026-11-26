--- tests/unit/core/fs/adapters/storage/test_clipboard_save_type_count.lua

--- ==============================================================================
--- MODULE: Regression — clipboard.save() logs the real UTI type count
--- DESCRIPTION:
--- Audit finding F-I3. hs.pasteboard.readAllData() returns a UTI-STRING-keyed hash
--- table, so the diagnostic `#(result or {})` was always 0 — "0 type(s)" even with
--- several types present. Fix: count with pairs(). Cosmetic, but a truthful triage log.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("clipboard.save counts UTI types via pairs(), not #", function()
	helpers.it("logs the real type count for a hash-keyed pasteboard", function()
		local logged
		package.loaded["core.logger.engine.logger"] = {
			debug   = function(_l, fmt, ...) logged = string.format(fmt, ...) end,
			error   = function() end, info = function() end, warn = function() end,
			trace   = function() end, done = function() end, start = function() end, success = function() end,
		}

		local Clipboard = helpers.load_with_stubs("clipboard.adapters.clipboard", {
			pasteboard = {
				allContentTypes = function() return { {} } end,
			changeCount = function() return 0 end,
				readAllData  = function() return { ["public.utf8-plain-text"] = "x", ["public.html"] = "<b>" } end,
				writeAllData = function() return true end,
			},
		})
		Clipboard.save()

		helpers.assert_true(logged ~= nil and logged:find("2 type(s)", 1, true) ~= nil,
			"save() must report 2 type(s) for a 2-UTI hash table, got: " .. tostring(logged))

		package.loaded["core.logger.engine.logger"]         = nil
		package.loaded["clipboard.adapters.clipboard"] = nil
	end)
end)
