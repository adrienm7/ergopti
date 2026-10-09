--- tests/unit/ui/menu/menu_llm/test_reattached_download_progress.lua

--- ==============================================================================
--- MODULE: Regression — a reattached download reports overall progress, not a
---         per-file percentage
--- DESCRIPTION:
--- `reattach_download` picks a download back up after a reload. It was written as
--- a stripped-down copy of `process_stream` and dropped the two things that make
--- the number mean anything.
---
--- First, `_bytes_done`, `_bytes_total` and `_current_pct` were declared INSIDE the
--- per-chunk handler, so every chunk reset them: nothing ever accumulated and
--- `_bytes_total` stayed 0 for the life of the download, which is why the window
--- showed no total and no ETA.
---
--- Second, the percentage was scraped out of the tool's own output with
--- `out:match("(%d+)%%")`. That number is the progress of the file currently being
--- fetched, not of the download — so a model with eight shards showed the bar
--- climbing to 99% and snapping back to 0, eight times over.
---
--- ROOT CAUSE ENCODED:
--- State that must persist across chunks, declared per chunk. The assertions are on
--- the SCOPE of those variables and on where the percentage comes from, because the
--- handler is a deeply nested closure inside a mixin installer and driving it end
--- to end would mean reconstructing the whole download session.
---
--- PROVENANCE: source invariant, stated as such.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by the reattach entry point rather than by a path.
local ANCHOR = "process_stream_reattached"




-- ==================================================================
-- ==================================================================
-- ======= 1/ Byte accounting survives across chunks ================
-- ==================================================================
-- ==================================================================

--- Returns the comment-stripped source of the download mixin.
--- @return string
local function mixin_code()
	local src = helpers.read_driver_source(ANCHOR)
	helpers.assert_true(src ~= nil and src ~= "",
		"the MLX download mixin must be locatable by '" .. ANCHOR .. "'; an empty corpus "
		.. "would make every assertion below vacuous")
	return (src:gsub("%-%-[^\n]*", ""))
end


helpers.describe("reattached download: byte totals persist across chunks", function()

	helpers.it("does not re-declare the byte counters inside the chunk handler", function()
		local code = mixin_code()
		local at = code:find("local function " .. ANCHOR, 1, true)
		helpers.assert_true(at ~= nil, "the reattached chunk handler must exist")

		-- The handler's own body. A `local _bytes_done` here means the accumulator is
		-- reset on every chunk, so it can never accumulate.
		local body = code:sub(at, at + 1200)
		helpers.assert_true(body:find("local _bytes_done", 1, true) == nil,
			"declaring the byte counters inside the per-chunk handler resets them on every "
			.. "chunk, so nothing accumulates and _bytes_total stays 0 for the whole "
			.. "download — which is why the window showed neither a total nor an ETA")
	end)

	helpers.it("declares them as upvalues of the reattach function", function()
		local code = mixin_code()
		local fn_at = code:find("reattach_download", 1, true)
		local handler_at = code:find("local function " .. ANCHOR, 1, true)
		helpers.assert_true(fn_at ~= nil and handler_at ~= nil and fn_at < handler_at,
			"the reattach entry point must precede its chunk handler")

		-- Without this case the assertion above would pass against a change that
		-- simply deleted the counters.
		local before_handler = code:sub(fn_at, handler_at)
		helpers.assert_true(before_handler:find("local _bytes_done", 1, true) ~= nil,
			"the counters must be declared ABOVE the handler so it closes over them — a "
			.. "local below the closure would bind the nil global instead")
	end)

	helpers.it("seeds the total from the model preset", function()
		local code = mixin_code()
		local fn_at = code:find("reattach_download", 1, true)
		local handler_at = code:find("local function " .. ANCHOR, 1, true)
		local window = code:sub(fn_at, handler_at)

		-- The launcher path seeds its total from hardware_requirements.mlx.download_gb.
		-- Without the same seed the reattached path has no denominator at all.
		helpers.assert_true(window:find("download_gb", 1, true) ~= nil,
			"the reattached path needs the same estimated total the launcher uses, or "
			.. "there is nothing to compute a percentage or an ETA against")
	end)

	helpers.it("derives the percentage from bytes, not from the tool's own output", function()
		local code = mixin_code()
		local at = code:find("local function " .. ANCHOR, 1, true)
		local body = code:sub(at, at + 1400)

		helpers.assert_true(body:find("_bytes_done / _bytes_total", 1, true) ~= nil,
			"the percentage must be computed from the accumulated bytes over the estimated "
			.. "total, exactly as the launcher path does")
		helpers.assert_true(body:find('out:match("(%d+)%%")', 1, true) == nil,
			"that number is the progress of the file currently being fetched, not of the "
			.. "download. A model with eight shards showed the bar climb to 99% and snap "
			.. "back to 0, eight times over")
	end)

end)
