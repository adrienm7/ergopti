--- tests/unit/meta/test_menu_row_dialect.lua

--- ==============================================================================
--- MODULE: A Row In The Wrong Dialect Is Reported, Not Swallowed
--- DESCRIPTION:
--- Covers the shared renderer's handling of provider rows written with the
--- hs.menubar field names — `title`, `fn`, `menu` — instead of the provider ones
--- — `label`, `action`, `items`.
---
--- WHY THIS EXISTS:
--- Three menus lost rows to that single confusion in the days this project moved
--- onto the shared renderer, and every one of them was found by opening the menu
--- and noticing something missing:
---   1. the About submenu's version header and channel picker (`title`),
---   2. every macOS hotstring category's whole section list (`menu`),
---   3. every personal-extension file row, plus a crash while sorting rows on a
---      field the conversion had renamed out from under the comparator.
---
--- The renderer's behaviour was reasonable and the diagnosis was impossible: a
--- `title` is not a label, so the row was dropped with a warning that named no
--- field, and a `menu` was never read at all, so the row rendered with its whole
--- subtree gone and NOTHING was logged. This pins the two halves of the fix —
--- the drift is reported field by field, and the row still renders exactly as
--- before wherever the data is right.
---
--- WHY IT LIVES IN THE LINUX SUITE:
--- the renderer is `_shared/lua/menu/renderer.lua`, shared by macOS and Linux and
--- mirrored in windows/infra/manifest_menu.ahk. This suite is the one that loads
--- the shared module directly and runs on plain LuaJIT in CI.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a renderer bound to nothing but a log recorder.
---
--- `render_rows` reads neither the manifest nor i18n — it materialises data the
--- caller already holds — so the fixture supplies only what `new()` demands.
--- @return table R, table logs Renderer, and every line it logged.
local function make_renderer()
	local Renderer = helpers.load_module("menu.renderer")
	local logs = { warn = {}, error = {} }
	local logger = helpers.make_logger_stub()
	local function record(bucket)
		return function(_, fmt, ...)
			local ok, formatted = pcall(string.format, fmt, ...)
			bucket[#bucket + 1] = ok and formatted or tostring(fmt)
		end
	end
	logger.warn = record(logs.warn)
	logger.error = record(logs.error)

	local R = Renderer.new({
		platform      = "linux",
		manifest_path = function() return "/nonexistent/menu_manifest.json" end,
		json_decode   = require("json").decode,
		i18n          = { get = function(key) return key end, section = function(key) return key end },
		logger        = logger,
	})
	helpers.assert_true(R ~= nil, "the renderer must have been created")
	return R, logs
end

--- True when some logged line contains every fragment given.
--- @param lines table
--- @param ... string
--- @return boolean
local function logged(lines, ...)
	local needles = { ... }
	for _, line in ipairs(lines) do
		local all = true
		for _, needle in ipairs(needles) do
			if not line:find(needle, 1, true) then all = false; break end
		end
		if all then return true end
	end
	return false
end





-- ======================================================
-- ======================================================
-- ======= 1/ The subtree hung on the wrong field =======
-- ======================================================
-- ======================================================

helpers.describe("renderer: a provider row that hangs its subtree on `menu`", function()

	helpers.it("renders the row with nothing under it — the field is not read", function()
		local R = make_renderer()
		local rows = R.render_rows({
			{ label = "Autocorrection (42)", menu = {
				{ label = "Ouvrir le fichier", action = function() end },
			} },
		}, "hotstring_categories_standard")

		helpers.assert_eq(#rows, 1, "the row itself still renders")
		helpers.assert_eq(rows[1].title, "Autocorrection (42)", "and keeps its label")
		helpers.assert_true(rows[1].menu == nil,
			"`menu` is the hs.menubar field, not a provider field: the subtree written there is not read, "
			.. "which is how every macOS hotstring category lost its whole section list")
	end)

	helpers.it("says so, naming the row and the field", function()
		local R, logs = make_renderer()
		R.render_rows({
			{ label = "Autocorrection (42)", menu = { { label = "Ouvrir le fichier" } } },
		}, "hotstring_categories_standard")

		helpers.assert_true(logged(logs.error, "Autocorrection (42)", "menu", "items"),
			"the drift must name the row and both field names — the whole cost of this bug was that a row "
			.. "with a missing subtree logged absolutely nothing")
	end)

	helpers.it("stays quiet when the subtree is handed over correctly", function()
		local R, logs = make_renderer()
		local rows = R.render_rows({
			{ label = "Autocorrection (42)", items = {
				{ label = "Ouvrir le fichier", action = function() end },
			} },
		}, "hotstring_categories_standard")

		helpers.assert_eq(#rows, 1, "one row")
		helpers.assert_true(type(rows[1].menu) == "table" and #rows[1].menu == 1,
			"`items` is the provider field and the renderer materialises it")
		helpers.assert_eq(rows[1].menu[1].title, "Ouvrir le fichier", "down to the nested row's label")
		helpers.assert_true(#logs.error == 0, "correct data must not be reported as drift")
	end)
end)





-- =============================================
-- =============================================
-- ======= 2/ The label and the callback =======
-- =============================================
-- =============================================

helpers.describe("renderer: a provider row written with `title` or `fn`", function()

	helpers.it("names `title` when the row is dropped for having no label", function()
		local R, logs = make_renderer()
		local rows = R.render_rows({ { title = "Version 3.1.4", disabled = true } }, "about_updates")

		helpers.assert_eq(#rows, 0, "a row with no label is dropped, as before")
		helpers.assert_true(logged(logs.error, "Version 3.1.4", "title", "label"),
			"the warning used to say only « a row with no label », which named neither the row nor the "
			.. "field — that is what let the About version row vanish unnoticed")
	end)

	helpers.it("names `fn` on a row that renders but does nothing", function()
		local R, logs = make_renderer()
		local rows = R.render_rows({ { label = "Journal des modifications", fn = function() end } }, "about_updates")

		helpers.assert_eq(#rows, 1, "the row renders — it has a label")
		helpers.assert_true(rows[1].fn == nil, "but its callback was written on a field the renderer does not read")
		helpers.assert_true(logged(logs.error, "Journal des modifications", "fn", "action"),
			"a row that silently does nothing when clicked is worse than a missing one, so it is reported")
	end)
end)





-- ===========================================================
-- ===========================================================
-- ======= 3/ Nesting deep enough for a user's folders =======
-- ===========================================================
-- ===========================================================

helpers.describe("renderer: nesting is bounded by recursion safety, not by menu shape", function()

	helpers.it("renders four levels — the depth a single extension subfolder needs", function()
		local R, logs = make_renderer()
		-- The personal-extensions tree: the personal row, its contents, one folder
		-- the user created, and that folder's files. The cap used to be three, so
		-- this exact shape was truncated and the folder came out empty.
		local rows = R.render_rows({
			{ label = "Perso", items = {
				{ label = "Extensions", items = {
					{ label = "travail", items = {
						{ label = "clients (12)", action = function() end },
					} },
				} },
			} },
		}, "hotstring_personal")

		local level4 = rows[1] and rows[1].menu and rows[1].menu[1] and rows[1].menu[1].menu
			and rows[1].menu[1].menu[1] and rows[1].menu[1].menu[1].menu
		helpers.assert_true(type(level4) == "table" and level4[1] ~= nil,
			"a folder the USER created must not be truncated by a cap sized for a hand-written menu")
		helpers.assert_eq(level4[1].title, "clients (12)", "the deepest row keeps its label")
		helpers.assert_true(#logs.error == 0, "and nothing is reported as too deep")
	end)

	helpers.it("still refuses a structure that contains itself", function()
		local R, logs = make_renderer()
		local cyclic = { label = "boucle" }
		cyclic.items = { cyclic }

		R.render_rows({ cyclic }, "cyclic")
		helpers.assert_true(logged(logs.error, "nests deeper"),
			"the cap exists to stop a provider returning a table that contains itself — raising it must "
			.. "not remove the guard")
	end)
end)
