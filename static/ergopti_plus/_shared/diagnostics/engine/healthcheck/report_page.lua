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
--- 2. Approved Text Only: the caller passes the shared report
---    (diagnostics/engine/healthcheck/share.lua document), the text the
---    clipboard and the saved Markdown already carry; this module only
---    escapes it.
--- ==============================================================================

local M = {}

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

return M
