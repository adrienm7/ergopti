--- tests/unit/ui/test_asset_inlining_is_loud.lua

--- ==============================================================================
--- MODULE: An Asset That Cannot Be Read Says So
--- DESCRIPTION:
--- What the HTML inliner does when a `<script src>` or `<link rel=stylesheet>`
--- names a file it cannot open.
---
--- THE DEFECT THIS PINS:
--- It replaced the tag with an empty string. The page then loaded LOOKING
--- correct and did nothing: every function the script defined was undefined, so
--- every push the host made was discarded by the page's own `if (window.x)`
--- guard, and no log line anywhere said the script was absent. Five CI cycles
--- and seven eliminated hypotheses went into a defect of exactly that shape,
--- and the reason it took five is that silence is indistinguishable from a page
--- that received its data and ignored it.
---
--- Stripping the cache-busting query fixed ONE reason the read can miss. A
--- typo, a moved file, a permission refusal and a bad assets_dir all still land
--- in the same branch — which is why the fix that matters is the diagnostic,
--- not the query.
---
--- WHAT IS STILL RIGHT ABOUT RETURNING EMPTY:
--- The tag is dropped rather than left in place. Leaving `<script src="…">` in
--- an inlined page points the webview at a path it cannot resolve either, so
--- the outcome is the same and the page also emits a network error nobody
--- reads. The page failing is not in question; being told is.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Captures every ERROR the inliner logs while building one page.
--- @param dir string Assets directory handed to the builder.
--- @param name string HTML file name.
--- @return string html, table errors
local function build(dir, name)
	local host = helpers.load_module("ui.webkit_host")
	local logger = require("logger.shim")
	local original = logger.error
	local errors = {}
	logger.error = function(_tag, fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		errors[#errors + 1] = ok and line or tostring(fmt)
	end

	local ok_build, html = pcall(host.build_injected_html, dir, name)
	logger.error = original
	return ok_build and html or "", errors
end

--- Writes a throwaway page and returns its directory and file name.
--- @param body string The HTML to write.
--- @return string dir, string name
local function fixture(body)
	local dir = (os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp")
		:gsub("\\", "/"):gsub("/$", "")
	local name = "ergopti_inline_probe.html"
	local fh = assert(io.open(dir .. "/" .. name, "w"))
	fh:write(body)
	fh:close()
	return dir, name
end




-- =================================================================
-- =================================================================
-- ======= 1/ A missing asset is reported ==========================
-- =================================================================
-- =================================================================

helpers.describe("asset inlining: a read that misses is loud", function()

	helpers.it("names the script it could not read", function()
		local dir, name = fixture(
			"<html><head></head><body><script src=\"absent_script.js\"></script></body></html>")
		local html, errors = build(dir, name)
		os.remove(dir .. "/" .. name)

		helpers.assert_true(#errors > 0,
			"a page whose script is missing loaded silently before this, and the "
				.. "only symptom was every host push being discarded by the page's "
				.. "own guard — which reads exactly like a page that got its data")

		local said = table.concat(errors, "\n")
		helpers.assert_contains(said, "absent_script.js",
			"the message must name the file, or the reader has to guess which of "
				.. "the page's scripts vanished")
		helpers.assert_true(not html:find("absent_script.js", 1, true),
			"and the tag is still dropped: leaving it points the webview at a path "
				.. "it cannot resolve either, so the page fails the same way and "
				.. "emits a network error nobody reads")
	end)

	helpers.it("names the stylesheet it could not read", function()
		local dir, name = fixture(
			"<html><head><link rel=\"stylesheet\" href=\"absent_style.css\" /></head><body></body></html>")
		local _, errors = build(dir, name)
		os.remove(dir .. "/" .. name)

		helpers.assert_contains(table.concat(errors, "\n"), "absent_style.css",
			"an unstyled page is a milder failure than a scriptless one, and just "
				.. "as invisible without a line saying why")
	end)

	helpers.it("says nothing when every asset resolves", function()
		local dir, name = fixture("<html><head></head><body><p>rien</p></body></html>")
		local _, errors = build(dir, name)
		os.remove(dir .. "/" .. name)

		helpers.assert_eq(#errors, 0,
			"a diagnostic that fires on a healthy page is a diagnostic nobody reads "
				.. "on a broken one")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The cache-busting query =============================
-- =================================================================
-- =================================================================

helpers.describe("asset inlining: a versioned reference", function()

	helpers.it("opens the file, not the file plus its query", function()
		local dir, name = fixture(
			"<html><head></head><body><script src=\"probe_asset.js?v=3\"></script></body></html>")
		local asset = assert(io.open(dir .. "/probe_asset.js", "w"))
		asset:write("window.probeMarker = 1;\n")
		asset:close()

		local html, errors = build(dir, name)
		os.remove(dir .. "/" .. name)
		os.remove(dir .. "/probe_asset.js")

		helpers.assert_eq(#errors, 0,
			"`script.js?v=3` is an ordinary thing for a page author to write — it "
				.. "means something to a browser fetching over HTTP — and it is not "
				.. "part of the filename")
		helpers.assert_contains(html, "window.probeMarker",
			"the script's CONTENT must be in the page; a tag that survives is a "
				.. "reference the inlined page can no longer resolve")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Author spellings are not semantics ===================
-- =================================================================
-- =================================================================

helpers.describe("asset inlining: every spelling of the same tag (tag-spellings)", function()

	--- Writes a probe asset and returns its remover.
	local function probe_asset(dir, filename, content)
		local asset = assert(io.open(dir .. "/" .. filename, "w"))
		asset:write(content)
		asset:close()
		return function() os.remove(dir .. "/" .. filename) end
	end

	helpers.it("tag-spellings: an href-first stylesheet link is inlined", function()
		local dir, name = fixture(
			"<html><head><link href=\"probe.css\" rel=\"stylesheet\" /></head><body></body></html>")
		local unwrite = probe_asset(dir, "probe.css", ".probe{color:red;}\n")
		local html, errors = build(dir, name)
		os.remove(dir .. "/" .. name)
		unwrite()

		helpers.assert_eq(#errors, 0, "the file exists, so there is nothing to report")
		helpers.assert_contains(html, ".probe{color:red;}",
			"attribute ORDER must not decide whether the CSS reaches the page")
		helpers.assert_true(html:find("probe.css", 1, true) == nil,
			"and the tag must not survive: the inlined page cannot resolve it")
	end)

	helpers.it("tag-spellings: a non-self-closed stylesheet link is inlined", function()
		local dir, name = fixture(
			"<html><head><link rel=\"stylesheet\" href=\"probe.css\"></head><body></body></html>")
		local unwrite = probe_asset(dir, "probe.css", ".probe{color:red;}\n")
		local html, errors = build(dir, name)
		os.remove(dir .. "/" .. name)
		unwrite()

		helpers.assert_eq(#errors, 0, "the file exists, so there is nothing to report")
		helpers.assert_contains(html, ".probe{color:red;}",
			"the self-closing slash must not decide whether the CSS reaches the page")
	end)

	helpers.it("tag-spellings: a single-quoted script is inlined", function()
		local dir, name = fixture(
			"<html><head></head><body><script src='probe_asset.js'></script></body></html>")
		local unwrite = probe_asset(dir, "probe_asset.js", "window.probeMarker = 1;\n")
		local html, errors = build(dir, name)
		os.remove(dir .. "/" .. name)
		unwrite()

		helpers.assert_eq(#errors, 0, "the file exists, so there is nothing to report")
		helpers.assert_contains(html, "window.probeMarker",
			"the quote STYLE must not decide whether the script reaches the page")
	end)

	helpers.it("tag-spellings: a non-stylesheet link is left alone, silently", function()
		local dir, name = fixture(
			"<html><head><link rel=\"icon\" href=\"favicon.ico\" /></head><body></body></html>")
		local html, errors = build(dir, name)
		os.remove(dir .. "/" .. name)

		helpers.assert_eq(#errors, 0,
			"an icon link is not this inliner's business — failing the page over "
				.. "it would be the noise this file exists to prevent")
		helpers.assert_contains(html, "favicon.ico",
			"and the tag must survive untouched for the webview to resolve")
	end)

	helpers.it("tag-spellings: an inline script without src is left alone", function()
		local dir, name = fixture(
			"<html><head></head><body><script>window.inlineMarker = 2;</script></body></html>")
		local html, errors = build(dir, name)
		os.remove(dir .. "/" .. name)

		helpers.assert_eq(#errors, 0, "there is no asset to resolve, so nothing to report")
		helpers.assert_contains(html, "window.inlineMarker",
			"an inline script must pass through byte for byte")
	end)

end)
