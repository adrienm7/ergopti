--- platform/system/vision/tesseract_ocr.lua

--- ==============================================================================
--- MODULE: Tesseract OCR (Linux)
--- DESCRIPTION:
--- Recognises the text of a screen vision image, or of an image file, with the
--- tesseract command, and returns the words with their boxes
--- (docs/design/screen-vision.md). Tesseract is an optional dependency: when it
--- is missing, availability() says so with a reason and the callers grey their
--- text options; image matching never needs it.
---
--- FEATURES & RATIONALE:
--- 1. Asynchronous: the child runs under libuv (ShellRunner.run_async) with a
---    deadline from the timings registry, so the keyboard loop never waits on
---    a recognition.
--- 2. The raw gray capture is read as it is: tesseract 5 inverts light text on
---    a dark theme by itself, and an inversion or an upscale done here made it
---    miss whole lines in the probes of 2026-11-25.
--- 3. Two layouts: "sparse" (--psm 11) finds scattered words such as a button
---    caption anywhere in a window; "block" (--psm 3) keeps the reading order
---    of a region the user selected for Ctrl+O.
--- 4. Private files: the capture is written under $XDG_RUNTIME_DIR (0700) when
---    the session has one and removed when the child settles, whatever the
---    outcome; its text never reaches a log.
--- 5. Languages: the interface language and English, as far as tesseract has
---    them (_shared/shortcuts/data/ocr_languages.json), else every installed
---    language but the "osd" script detector.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ShellRunner = require("core.process.adapters.shell_runner")
local Timings = require("core.timing.engine.timings")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local Utils = require("core.text.engine.utils_core")

local LOG = "platform.system.vision.tesseract_ocr"

-- Tesseract page segmentation modes, by the layout names of the service.
local PAGE_SEGMENTATION = { sparse = "11", block = "3" }

-- The TSV level of a word row, and the column count of a row.
local TSV_WORD_LEVEL = 5
local TSV_COLUMNS = 12

local _installed = nil
local _file_counter = 0




-- =========================================
-- =========================================
-- ======= 1/ Parsing ======================
-- =========================================
-- =========================================

--- Parses tesseract's TSV output into words.
--- @param text string The TSV, header row first.
--- @return table words { text, x, y, width, height, confidence (0 to 1), line }
---   in image pixels, in reading order; a line id groups the words of one line.
function M.parse_tsv(text)
	assert(type(text) == "string", "the TSV output is a string")
	local words = {}
	local first = true
	for row in text:gmatch("[^\n]+") do
		if first then
			first = false
		else
			local cells = {}
			for cell in (row .. "\t"):gmatch("([^\t]*)\t") do cells[#cells + 1] = cell end
			if #cells >= TSV_COLUMNS and tonumber(cells[1]) == TSV_WORD_LEVEL then
				local word = Utils.trim(cells[TSV_COLUMNS])
				local confidence = tonumber(cells[11]) or -1
				if word ~= "" and confidence >= 0 then
					words[#words + 1] = {
						text = word,
						x = tonumber(cells[7]), y = tonumber(cells[8]),
						width = tonumber(cells[9]), height = tonumber(cells[10]),
						confidence = confidence / 100,
						line = table.concat({ cells[3], cells[4], cells[5] }, "."),
					}
				end
			end
		end
	end
	return words
end

--- Parses `tesseract --list-langs` into language names, osd left out.
--- @param text string
--- @return table names
function M.parse_languages(text)
	local names, first = {}, true
	for line in text:gmatch("[^\n]+") do
		if first then first = false
		else
			local name = (line:gsub("%s+", ""))
			if name ~= "" and name ~= "osd" then names[#names + 1] = name end
		end
	end
	return names
end

--- The tesseract languages to ask for.
--- @param locale string Interface locale ("fr").
--- @param installed table Installed language names.
--- @return string|nil spec "fra+eng"; nil when nothing is installed.
function M.languages_for(locale, installed)
	assert(type(installed) == "table", "the installed languages are a list")
	if #installed == 0 then return nil end
	local have = {}
	for _, name in ipairs(installed) do have[name] = true end
	local table_ = M.language_table()
	local wanted, seen = {}, {}
	for _, code in ipairs({ locale, table_.fallback }) do
		local entry = table_.languages[code]
		if entry and have[entry.tesseract] and not seen[entry.tesseract] then
			wanted[#wanted + 1] = entry.tesseract
			seen[entry.tesseract] = true
		end
	end
	if #wanted == 0 then return table.concat(installed, "+") end
	return table.concat(wanted, "+")
end

--- The shared OCR language table.
--- @return table { fallback, languages }
function M.language_table()
	local handle = assert(io.open(Paths.shared("shortcuts/data/ocr_languages.json"), "rb"))
	local text = handle:read("*a")
	handle:close()
	return assert(Json.decode(text), "ocr_languages.json is not valid JSON")
end




-- =========================================
-- =========================================
-- ======= 2/ Files ========================
-- =========================================
-- =========================================

--- A private path for one capture.
--- @return string path
local function private_path()
	_file_counter = _file_counter + 1
	local runtime = os.getenv("XDG_RUNTIME_DIR")
	if runtime and runtime ~= "" then
		return string.format("%s/ergopti-ocr-%d-%d.pgm", runtime, os.time(), _file_counter)
	end
	return os.tmpname()
end

--- Writes a gray image as a binary PGM, which tesseract reads directly.
--- @param image table The screen vision image.
--- @param path string
--- @return boolean ok, string|nil reason
function M.write_pgm(image, path)
	local handle, open_error = io.open(path, "wb")
	if not handle then return false, open_error end
	handle:write(string.format("P5\n%d %d\n255\n", image.width, image.height))
	local chunk, pixels = {}, image.pixels
	local row_bytes = image.width
	for row = 0, image.height - 1 do
		for col = 1, row_bytes do chunk[col] = string.char(pixels[row * row_bytes + col]) end
		handle:write(table.concat(chunk, "", 1, row_bytes))
	end
	handle:close()
	return true
end




-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Whether tesseract can run.
--- @return boolean ok, string|nil reason "ocr_engine_missing"
function M.available()
	if not ShellRunner.has_command("tesseract", true) then return false, "ocr_engine_missing" end
	return true
end

--- Reads the installed languages once, asynchronously.
--- @param callback function (names|nil, reason)
function M.load_languages(callback)
	if _installed then callback(_installed); return end
	local handle, reason = ShellRunner.run_async("tesseract", { "--list-langs" },
		{ timeout_ms = Timings.ms("screen_vision", "ocr_timeout_ms") }, function(result)
			if not result.ok then
				Logger.warn(LOG, "tesseract --list-langs failed: %s.", tostring(result.error))
				callback(nil, "ocr_engine_missing")
				return
			end
			_installed = M.parse_languages(result.stdout or "")
			Logger.info(LOG, "Tesseract languages read: %d installed.", #_installed)
			callback(_installed)
		end)
	if not handle then callback(nil, reason) end
end

--- Recognises the text of an image file.
--- @param path string
--- @param options table { layout = "sparse"|"block", locale = string }
--- @param callback function (words|nil, reason)
--- @param on_settled function|nil Runs once the child has settled, whatever the outcome.
function M.recognize_file(path, options, callback, on_settled)
	local psm = PAGE_SEGMENTATION[options.layout]
	assert(psm, "the OCR layout is sparse or block")
	M.load_languages(function(installed, reason)
		if not installed then
			if on_settled then on_settled() end
			callback(nil, reason)
			return
		end
		local languages = M.languages_for(options.locale, installed)
		if not languages then
			if on_settled then on_settled() end
			callback(nil, "ocr_language_missing")
			return
		end
		Logger.start(LOG, "Recognising text (%s layout, %s).", options.layout, languages)
		local handle, refusal = ShellRunner.run_async("tesseract",
			{ path, "stdout", "-l", languages, "--psm", psm, "tsv" },
			{ timeout_ms = Timings.ms("screen_vision", "ocr_timeout_ms"),
				max_output_bytes = Timings.count("limits", "ocr_output_bytes") }, function(result)
				if on_settled then on_settled() end
				if not result.ok then
					Logger.error(LOG, "Text recognition failed: %s.", tostring(result.error))
					callback(nil, result.timed_out and "ocr_timeout" or "ocr_failed")
					return
				end
				local words = M.parse_tsv(result.stdout or "")
				Logger.success(LOG, "Text recognised: %d word(s).", #words)
				callback(words)
			end)
		if not handle then
			if on_settled then on_settled() end
			Logger.error(LOG, "Text recognition refused: %s.", tostring(refusal))
			callback(nil, "ocr_failed")
		end
	end)
end

--- Recognises the text of a screen vision image.
--- @param image table
--- @param options table As recognize_file.
--- @param callback function (words|nil, reason)
function M.recognize(image, options, callback)
	local path = private_path()
	local written, write_error = M.write_pgm(image, path)
	if not written then
		os.remove(path)
		Logger.error(LOG, "The capture could not be written for OCR: %s.", tostring(write_error))
		callback(nil, "ocr_failed")
		return
	end
	M.recognize_file(path, options, callback, function() os.remove(path) end)
end

return M
