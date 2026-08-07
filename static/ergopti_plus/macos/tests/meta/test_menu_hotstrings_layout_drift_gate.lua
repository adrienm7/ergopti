--- tests/meta/test_menu_hotstrings_layout_drift_gate.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings/Layout Drift Gate (macOS) — F41b
--- DESCRIPTION:
--- UPDATED 2026-08-07: the hotstrings half of this gate's premise is gone.
--- ui/menu/builder.lua renders hotstrings_menu through ManifestMenu.build now —
--- the two bulk commands, the params group, the four section headers and the
--- five category lists all come from the declaration — so that menu can no
--- longer drift from it by construction. The pinned signature below stays,
--- because it is what the OTHER two drivers render and a change to it is still
--- a change to three menus at once, and case 3 now asserts that this driver
--- keeps reading it.
---
--- layout_menu is the half that remains: menu_keyboard_layout.lua renders the
--- manifest's own rows but still hand-builds the install/update block and the
--- pause/resume pickers around them.
---
--- A full manifest-driven migration of hotstrings/layout is a larger, riskier
--- refactor deferred to a follow-up (AUDIT_AHK_2026-07-01.md, F41b — this
--- gate is the interim mitigation the audit calls out explicitly). Until that
--- migration lands, this test pins the manifest's current hs-filtered shape
--- for both keys. Any edit to hotstrings_menu/layout_menu in
--- menu_manifest.json now fails this test, forcing a human to consciously
--- check whether ui/menu/menu_hotstrings.lua, ui/menu/builder.lua, or
--- ui/menu/menu_keyboard_layout.lua still need updating — turning a
--- previously silent desync into a loud one.
---
--- NOTE: layout_menu's pinned shape does NOT imply macOS renders those entries
--- FROM THE MANIFEST. It does not read layout_menu at all — menu_keyboard_layout
--- builds the whole submenu imperatively, and this gate pins the manifest's shape
--- so the two cannot drift further apart while that is true.
---
--- CORRECTED 2026-08-04: this note used to say the on/off toggle,
--- layout_features_base/altgr and the hotstrings.magic_key.replace feature path
--- "have no macOS counterpart yet". The replace row does have one, and has for
--- some time — menu_keyboard_layout.lua builds it with its own checked and
--- disabled state. A stale note in a drift gate is worse than no note: it is the
--- paragraph the next person scopes the migration from, and it under-reports what
--- macOS already draws by hand.
---
--- The AHK half reads both keys generically via MenuRenderer_Build in
--- infra/manifest_menu.ahk (see ui/menu/menu_hotstrings.ahk,
--- ui/menu/menu_layout.ahk) — no equivalent drift gate is needed there.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Canonical hs-filtered signatures for hotstrings_menu, in manifest order.
-- Signature = "<type>:<id>" for entries with a stable id, "<type>:<category|i18n|path>"
-- for the few entries that key off a different field (toggle/section_header/feature),
-- or "---" for separators.
-- The five category blocks became `list` on 2026-08-06: their rows are
-- materialised by the renderer from provider data instead of each driver
-- appending them. macOS builds this menu by hand in ui/menu/builder.lua and does
-- not read the manifest for it, so what this list pins here is the SHARED
-- description the other two drivers render — which is exactly what makes it
-- worth pinning from this side.
local CANONICAL_HOTSTRINGS_MENU = {
	"toggle:Hotstrings",
	"group:hotstrings_params",
	-- One `dynamic:hotstring_bulk_actions` row until 2026-08-06, which expanded
	-- to TWO rows inside each driver — so the manifest described neither, and
	-- macOS had no handler for the id at all and rendered nothing. Two `command`
	-- rows now: the renderer builds them, and what this list pins is what the
	-- user sees rather than a slot whose contents only the drivers knew.
	"command:hotstrings_enable_all",
	"command:hotstrings_disable_all",
	"---",
	"section_header:menu.hotstrings.header_common",
	"list:hotstring_categories_standard",
	"list:hotstring_categories_dynamic",
	"---",
	"section_header:menu.hotstrings.header_ergopti",
	"list:hotstring_categories_ergopti",
	"---",
	"section_header:menu.hotstrings.personal_header",
	"list:hotstring_personal",
	"---",
	"section_header:menu.extensions.header",
	-- The extensions row. A first pass on 2026-08-04 removed it from this list on
	-- the manifest's word that it "scans a Windows extensions directory" and that
	-- neither Lua driver ships one. Both halves were false: the directory is
	-- static/ergopti_plus/extensions, part of this repository and shipped to all
	-- three drivers, and macOS has scanned it all along — hotstring_counter.lua
	-- walks ext_root for manifest.toml + hotstrings/*.toml and builder.lua renders
	-- the section under this very header. The row was restricted out of a menu that
	-- was already drawing it. Linux gained the same scan through
	-- _shared/lua/hotstrings/extensions.lua; the manifest now says all three.
	"list:hotstring_extensions",
}

-- Canonical hs-filtered signatures for layout_menu, in manifest order.
-- ahk-only entries (accented_letters group, ahk.layout.ctrl_magic_save feature)
-- are dropped by the hs platform filter, same as the real manifest reader.
--
-- UPDATED 2026-08-04, 7 -> 5, and this gate is what caught it — which is the
-- behaviour it exists for. `layout_features_base` and `layout_features_altgr`
-- were restricted to platforms = ["ahk"], because every one of the five
-- features.layout.* entries they enumerate is itself ["ahk"]: on this driver the
-- two rows listed an empty set, and the manifest was promising a row macOS could
-- never draw. Nothing changed in the hand-built menu, because it never
-- implemented either id — they are two of the twenty rows the handler-bijection
-- ratchet counts for hs.
-- The two separators that framed them stay: this gate pins the MANIFEST's
-- signature, and the renderer is what collapses a separator with nothing between
-- it and the next one.
local CANONICAL_LAYOUT_MENU = {
	"toggle:Layout",
	-- The two blocks macOS alone has, declared 2026-08-07. It installs a .bundle
	-- keyboard layout through the OS's input-source mechanism and draws a
	-- menubar icon; neither concept exists on the other two drivers. Ten rows
	-- were built by hand here and described nowhere until now.
	"list:layout_bundle",
	"---",
	"list:layout_logo",
	"---",
	"---",
	-- `list`, not `dynamic`, since 2026-08-07. This driver has always supplied
	-- active_layout_rows() as a LIST PROVIDER, and the manifest said `dynamic`,
	-- so the renderer looked for a dynamic handler, found none, warned once and
	-- skipped the row — the layout list did not render at all.
	"list:active_layouts",
	"---",
	"feature:hotstrings.magic_key.replace",
}

--- Reads and decodes the shared menu_manifest.json.
--- @return table Decoded manifest.
local function read_manifest()
	local fh = io.open(helpers.shared("modules/menu/menu_manifest.json"), "r")
	helpers.assert_true(fh ~= nil, "Cannot open menu_manifest.json")
	local raw = fh:read("*a")
	fh:close()
	local data = hs.json.decode(raw)
	helpers.assert_true(type(data) == "table", "menu_manifest.json must decode to a table")
	return data
end

--- Builds a signature string identifying a manifest entry regardless of which
--- field it keys off (id, category, i18n, or path).
--- @param entry table A menu_manifest.json array entry.
--- @return string Signature, e.g. "dynamic:hotstring_bulk_actions" or "---".
local function entry_signature(entry)
	local t = entry.type
	if t == "---" then return "---" end
	if type(entry.id) == "string" then return t .. ":" .. entry.id end
	if t == "toggle" and type(entry.category) == "string" then return t .. ":" .. entry.category end
	if t == "section_header" and type(entry.i18n) == "string" then return t .. ":" .. entry.i18n end
	if t == "feature" and type(entry.path) == "string" then return t .. ":" .. entry.path end
	return tostring(t)
end

--- Filters a manifest menu array down to entries relevant to the "hs" platform.
--- Entries with no `platforms` field apply to every platform.
--- @param menu_array table Raw array from menu_manifest.json.
--- @return table signatures Ordered list of entry_signature() results.
local function hs_filtered_signatures(menu_array)
	local sigs = {}
	for _, entry in ipairs(menu_array) do
		if type(entry) == "table" then
			local include = true
			if type(entry.platforms) == "table" then
				include = false
				for _, p in ipairs(entry.platforms) do
					if p == "hs" then include = true; break end
				end
			end
			if include then table.insert(sigs, entry_signature(entry)) end
		end
	end
	return sigs
end

--- Asserts an ordered list of signatures matches a pinned canonical list.
--- @param actual table Signatures extracted from the manifest.
--- @param expected table Pinned CANONICAL_* list.
--- @param label string Menu key name, for error messages.
local function assert_signatures_match(actual, expected, label)
	helpers.assert_eq(#actual, #expected,
		label .. " has " .. #actual .. " hs-relevant entrie(s), expected " .. #expected ..
		" — menu_manifest.json's " .. label .. " drifted; update the CANONICAL list above " ..
		"AND check whether the macOS hand-built menu needs the same change (F41b)")
	for i, expected_sig in ipairs(expected) do
		helpers.assert_eq(actual[i], expected_sig,
			label .. "[" .. i .. "] = '" .. tostring(actual[i]) .. "', expected '" .. expected_sig ..
			"' — menu_manifest.json's " .. label .. " drifted; update the CANONICAL list above " ..
			"AND check whether the macOS hand-built menu needs the same change (F41b)")
	end
end

helpers.describe("menu drift gate (macOS): hotstrings_menu/layout_menu manifest shape is pinned (F41b)", function()

	helpers.it("hotstrings_menu hs-filtered signatures match the pinned canonical order", function()
		local data = read_manifest()
		helpers.assert_true(type(data.hotstrings_menu) == "table", "menu_manifest.json must have a hotstrings_menu array")
		local actual = hs_filtered_signatures(data.hotstrings_menu)
		assert_signatures_match(actual, CANONICAL_HOTSTRINGS_MENU, "hotstrings_menu")
	end)

	helpers.it("layout_menu hs-filtered signatures match the pinned canonical order", function()
		local data = read_manifest()
		helpers.assert_true(type(data.layout_menu) == "table", "menu_manifest.json must have a layout_menu array")
		local actual = hs_filtered_signatures(data.layout_menu)
		assert_signatures_match(actual, CANONICAL_LAYOUT_MENU, "layout_menu")
	end)

	helpers.it("the hotstrings submenu is built from the manifest, not assembled here", function()
		local src = helpers.read_driver_source("local function collect_groups")  -- ui/menu/builder.lua
		helpers.assert_true(src:find('ManifestMenu%.build%("hotstrings_menu"') ~= nil,
			"builder.lua must render hotstrings_menu through the shared renderer — this gate " ..
			"existed because it did not, and a menu that stops reading its declaration can " ..
			"disagree with it in silence")
		for _, id in ipairs({
			"hotstring_categories_standard",
			"hotstring_categories_ergopti",
			"hotstring_personal",
			"hotstring_extensions",
		}) do
			helpers.assert_true(src:find('%["' .. id .. '"%]') ~= nil,
				"builder.lua must answer the declared row '" .. id .. "' with a provider")
		end
	end)
end)
