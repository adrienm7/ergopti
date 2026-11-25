--- _shared/shortcuts/engine/ocr_capture.lua

--- ==============================================================================
--- MODULE: OCR Capture to Clipboard — Shared Lua Implementation
--- DESCRIPTION:
--- The « Capture → texte » action (sg_actions.ocr_screenshot, Ctrl+O on the
--- three OS): the user selects a screen region, the screen vision service
--- reads it, and the text goes to the clipboard with a notification. The
--- drivers own the region selection, the OCR engine and the clipboard; this
--- module owns the order of the steps, the text assembly and every outcome, so
--- the three drivers behave the same. The Windows driver runs a twin pinned by
--- the same corpus.
---
--- FEATURES & RATIONALE:
--- 1. Line breaks are kept: the words of one OCR line are joined by a space
---    and the lines by a line feed, in the order the engine read them.
--- 2. Nothing recognised leaves the clipboard unchanged and says so: an empty
---    paste after a failed read would destroy what the user had copied.
--- 3. Escape cancels quietly: a cancelled selection is logged and nothing is
---    shown, since the user asked for it.
--- 4. The recognised text is never logged, only its size: a capture can show
---    a password manager or a private message.
--- 5. The capture file is removed whatever the outcome.
---
--- Pinned by _shared/tests/corpus/keep_awake/ocr_capture_vectors.json.
--- ==============================================================================

local M = {}

-- Every outcome of one run; a driver logs exactly one of them.
M.OUTCOMES = {
	copied = "copied",
	nothing_recognised = "nothing_recognised",
	cancelled = "cancelled",
	failed = "failed",
}

-- The notification of each outcome that shows one, with its level.
M.NOTICES = {
	copied = { key = "ocr_capture.copied", level = "info" },
	nothing_recognised = { key = "ocr_capture.nothing_recognised", level = "warning" },
	failed = { key = "ocr_capture.failed", level = "error" },
}

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The clipboard text of OCR words: one line per OCR line, in reading order.
--- @param words table { { text, line } } as the screen vision service returns them.
--- @return string|nil text nil when no word has a visible character.
--- @return integer lines The number of lines kept.
function M.text(words)
	assert(type(words) == "table", "the OCR words are a list")
	local order, by_line = {}, {}
	for _, word in ipairs(words) do
		local text = type(word.text) == "string" and trim(word.text) or ""
		if text ~= "" then
			local line = tostring(word.line or "")
			if not by_line[line] then
				by_line[line] = {}
				order[#order + 1] = line
			end
			local parts = by_line[line]
			parts[#parts + 1] = text
		end
	end
	if #order == 0 then return nil, 0 end
	local lines = {}
	for index, line in ipairs(order) do lines[index] = table.concat(by_line[line], " ") end
	return table.concat(lines, "\n"), #lines
end

--- Runs one capture: select, recognise, copy, notify.
--- @param ports table {
---   select(callback(path|nil, reason)) — reason "cancelled" when the user pressed Escape;
---   recognize(path, callback(words|nil, reason));
---   set_clipboard(text) -> boolean;
---   notify(key, level, lines) — lines is the copied line count, nil otherwise;
---   remove(path);
---   log(level, message, ...) }
--- @param done function|nil (outcome, reason) once the run ended.
function M.run(ports, done)
	for _, name in ipairs({ "select", "recognize", "set_clipboard", "notify", "remove", "log" }) do
		assert(type(ports[name]) == "function", "the OCR capture needs the port " .. name)
	end
	local function finish(outcome, reason, arg)
		local notice = M.NOTICES[outcome]
		if notice then ports.notify(notice.key, notice.level, arg) end
		if outcome == M.OUTCOMES.failed then
			ports.log("warn", "OCR capture failed: reason=%s.", tostring(reason))
		elseif outcome == M.OUTCOMES.cancelled then
			ports.log("info", "OCR capture cancelled.")
		end
		if done then done(outcome, reason) end
	end
	ports.select(function(path, reason)
		if not path then
			if reason == "cancelled" then return finish(M.OUTCOMES.cancelled, reason) end
			return finish(M.OUTCOMES.failed, reason or "capture_empty")
		end
		ports.recognize(path, function(words, ocr_reason)
			ports.remove(path)
			if not words then
				return finish(M.OUTCOMES.failed, ocr_reason or "ocr_failed")
			end
			local text, lines = M.text(words)
			if not text then
				ports.log("info", "OCR capture recognised nothing; the clipboard is unchanged.")
				return finish(M.OUTCOMES.nothing_recognised)
			end
			if not ports.set_clipboard(text) then
				return finish(M.OUTCOMES.failed, "clipboard_write_failed")
			end
			ports.log("info", "OCR capture copied %d line(s), %d character(s).", lines, #text)
			finish(M.OUTCOMES.copied, nil, lines)
		end)
	end)
end

return M
