--- _shared/diagnostics/engine/healthcheck/report_page.lua

--- ==============================================================================
--- MODULE: Diagnostics Report Page
--- DESCRIPTION:
--- The approved diagnostics report as one self-contained HTML page, for a host
--- that cannot open its diagnostics window: the report is written to a file in
--- the logs' diagnostics folder and opened in the default browser, so the
--- diagnostics never depend on the window component they may be diagnosing
--- (maintainer, 2026-11-25).
---
--- FEATURES & RATIONALE:
--- 1. Self-Contained: no script, no asset and no network, so any browser shows
---    it whatever the machine lacks; the browser's light and dark defaults
---    apply, the page has no colour of its own.
--- 2. Approved Text Only: the page carries the shared report
---    (diagnostics/engine/healthcheck/share.lua document), the text the
---    clipboard and the saved Markdown already carry; this module only
---    escapes it.
--- 3. One Delivery: writing, opening and announcing the page is the same
---    sequence on macOS and Linux, so it lives here; each driver passes its
---    snapshot, its translations and its side effects.
--- ==============================================================================

local M = {}

local Share = require("diagnostics.engine.healthcheck.share")

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }

--- Escapes text for an HTML element or attribute.
--- @param text string
--- @return string
local function escape_html(text)
	return (text:gsub("[&<>\"']", ESCAPES))
end

--- The report as one self-contained page.
--- @param title string The page title (the diagnostics window's name).
--- @param lead string The sentence that says why this is a file.
--- @param text string The approved report.
--- @param locale string The page language.
--- @return string html
function M.render_html(title, lead, text, locale)
	assert(type(title) == "string" and type(lead) == "string" and type(text) == "string"
		and type(locale) == "string", "the diagnostics report page needs a title, a lead, a text and a locale")
	return table.concat({
		"<!doctype html>",
		'<html lang="' .. escape_html(locale) .. '">',
		'<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
		"<title>" .. escape_html(title) .. "</title>",
		"<style>:root{color-scheme:light dark}"
			.. "body{font:15px/1.5 system-ui,sans-serif;margin:2em auto;max-width:60em;padding:0 1em}"
			.. "pre{white-space:pre-wrap;word-break:break-word;border:1px solid;padding:1em;border-radius:6px}</style>",
		"</head><body>",
		"<h1>" .. escape_html(title) .. "</h1>",
		"<p>" .. escape_html(lead) .. "</p>",
		"<pre>" .. escape_html(text) .. "</pre>",
		"</body></html>",
		"",
	}, "\n")
end

--- The ports deliver needs, by type.
local DELIVERY_PORTS = {
	logger = "table", log = "string", title = "string", lead = "string", locale = "string",
	collect = "function", translate = "function", save = "function", open = "function", notify = "function",
}

--- Delivers the diagnostics report when no window can show it: the approved
--- report of a fresh snapshot is written as a page in the logs' diagnostics
--- folder, opened in the default browser, and a notice names the file.
--- @param spec table
---   logger table The driver's logger (start, success, warn, error).
---   log string The log tag.
---   title string The page title, the diagnostics window's name.
---   lead string The sentence that says why this is a file.
---   locale string The page language.
---   collect function(): table, table A complete local snapshot and the
---     diagnostics documents (schema, share policy).
---   translate function(key): string The driver's translation lookup.
---   save function(dir, name, html): string|nil, string|nil The written path,
---     or nil and why.
---   open function(path, done, current): table|nil, string|nil The opening
---     request, or nil and why; done receives the opener's receipt.
---   notify function(path): boolean Names the file to the user.
--- @return boolean delivered Whether the file was written and its opening asked.
function M.deliver(spec)
	assert(type(spec) == "table", "the windowless diagnostics report needs its ports")
	for name, kind in pairs(DELIVERY_PORTS) do
		assert(type(spec[name]) == kind, "the windowless diagnostics report needs its '" .. name .. "' port")
	end
	local logger, log = spec.logger, spec.log
	logger.start(log, "Writing the diagnostics report to a file: no window can show it…")
	local ok, path = xpcall(function()
		local snapshot, documents = spec.collect()
		assert(type(snapshot) == "table" and type(snapshot.sections) == "table"
			and type(snapshot.sections.paths) == "table", "the diagnostics snapshot has no paths section")
		local dir = snapshot.sections.paths.diagnostics_dir
		if type(dir) ~= "string" or dir == "" then error("the diagnostics folder is unknown") end
		local document = Share.document(snapshot, documents.schema, spec.translate(documents.schema.share_policy.notice_key))
		local suffix = documents.schema.report.name_suffix
		assert(document.name:sub(-#suffix) == suffix, "the report name does not end with the schema's suffix")
		local html = M.render_html(spec.title, spec.lead, document.text, spec.locale)
		local written, detail = spec.save(dir, document.name:sub(1, -#suffix - 1) .. ".html", html)
		if not written then error("the report could not be saved: " .. tostring(detail)) end
		return written
	end, debug.traceback)
	if not ok then
		logger.error(log, "The diagnostics report could not be written to a file: %s", tostring(path))
		return false
	end
	logger.success(log, "Diagnostics report written to %s.", path)
	local asked, request, refusal = pcall(spec.open, path, function(receipt)
		if type(receipt) ~= "table" or receipt.ok ~= true then
			logger.warn(log, "The browser did not open the diagnostics report (status=%s, reason=%s).",
				tostring(type(receipt) == "table" and receipt.code), tostring(type(receipt) == "table" and receipt.error))
		end
	end, function() return true end)
	if not asked or type(request) ~= "table" then
		logger.warn(log, "The browser could not be asked to open the diagnostics report: %s.",
			tostring(asked and refusal or request))
	end
	local sent, delivered = pcall(spec.notify, path)
	if not sent or delivered ~= true then
		logger.warn(log, "The diagnostics file notice was not delivered: %s.", tostring(delivered))
	end
	return true
end

return M
