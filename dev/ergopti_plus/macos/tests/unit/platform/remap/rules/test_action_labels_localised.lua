--- tests/unit/platform/remap/rules/test_action_labels_localised.lua

--- ==============================================================================
--- MODULE: Remap Action Label Localisation Tests
--- DESCRIPTION:
--- Eighteen of `platform/remap/data/actions.json`'s entries are ALSO rows of the
--- one action registry (`_shared/shortcuts/data/actions/actions.toml`), and those
--- eighteen already carry an `sg_actions.<id>` label in all twenty-one locales.
--- The French string in the JSON was a second declaration of the same label, so
--- the remap picker showed French to every user while the gesture picker — which
--- lists the same action — showed their own language.
---
--- COVERAGE:
--- 1. An action whose key RESOLVES takes the translated label, in both the long
---    and short forms the menu reads.
--- 2. An action whose key does not resolve keeps its French label rather than
---    being blanked — the fifty-five with no registry row must stay usable.
--- 3. The unresolved-key sentinel is honoured: `i18n.get` answers with the KEY
---    when it cannot resolve, and writing that through would put
---    "sg_actions.cmd_tab" in the menu.
--- 4. The two groups both still exist in the shipped locale catalogue, read from
---    the file — otherwise a merge that emptied one would leave its case passing
---    over nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local json    = require("core.text.engine.json")




-- ==============================================
-- ==============================================
-- ======= 1/ Harness ===========================
-- ==============================================
-- ==============================================

-- An id that IS a row of the shared registry, and one that is not.
local KEYED_ID = "copy"
local UNKEYED_ID = "cmd_tab"

-- What the injected i18n answers for the keyed id. Deliberately not French, so a
-- label that came from the JSON instead cannot pass by coincidence.
local TRANSLATED = "COPY-FROM-REGISTRY"

local ACTIONS_JSON = helpers.driver_root() .. "/platform/remap/data/actions.json"

--- Loads the config module with an i18n whose resolution the test controls.
--- The module captures the i18n TABLE at require time, so replacing the table's
--- `get` afterwards reaches the code under test — injecting a whole new module
--- would not, because the upvalue still points at the original table.
--- @return table config
local function fresh()
	local config = helpers.load_with_stubs("platform.remap.config")
	local i18n = require("core.i18n.engine.i18n")
	i18n.get = function(key)
		if key == "sg_actions." .. KEYED_ID then return TRANSLATED end
		-- Everything else answers with the key, which is what the real module does
		-- when a key has no entry — and is the sentinel the code must recognise.
		return key
	end
	-- The catalogue answers which keys exist without decoding a fallback locale.
	i18n.has = function(key) return key == "sg_actions." .. KEYED_ID end
	return config
end

--- Finds one action by id in a loaded catalogue.
--- @param actions table
--- @param id string
--- @return table|nil
local function find(actions, id)
	for _, a in ipairs(actions or {}) do
		if a.id == id then return a end
	end
	return nil
end




-- ==============================================
-- ==============================================
-- ======= 2/ Both Groups Exist =================
-- ==============================================
-- ==============================================

helpers.describe("remap action labels: the two groups", function()
	helpers.it("the shipped catalogue really has a keyed id and an unkeyed one", function()
		-- Read from the locale file rather than through i18n, because the harness
		-- stubs i18n and would make this assert its own stub. If a merge gives
		-- every remap action a key, the second half fails and this file's third
		-- case has to be retired deliberately.
		local fh = io.open(helpers.shared("core/i18n/data/locales/fr.json"), "r")
		assert(fh, "the French catalogue must be readable")
		local locale = json.decode(fh:read("*a"))
		fh:close()

		helpers.assert_eq(type(locale["sg_actions." .. KEYED_ID]), "string",
			"'" .. KEYED_ID .. "' must have a catalogue entry — it is the case for the keyed group")
		helpers.assert_nil(locale["sg_actions." .. UNKEYED_ID],
			"'" .. UNKEYED_ID .. "' must NOT have one — it is the case for the group awaiting the merge, " ..
			"and if it gained a key this file is guarding an empty set")
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 3/ Localisation ======================
-- ==============================================
-- ==============================================

helpers.describe("remap action labels: localisation", function()
	helpers.it("an action whose key resolves takes the translated label", function()
		local config = fresh()
		local actions = config.load_available_actions(ACTIONS_JSON)
		helpers.assert_eq(type(actions), "table", "the catalogue must load")

		local found = find(actions, KEYED_ID)
		helpers.assert_true(found ~= nil, "'" .. KEYED_ID .. "' must be in the catalogue")
		helpers.assert_eq(found.label, TRANSLATED,
			"the long label must come from the registry, not from the JSON's French string")
		helpers.assert_eq(found.short_label, TRANSLATED,
			"and so must the short one — the menu reads short_label first, so localising only the long " ..
			"form would leave the picker in French")
	end)

	helpers.it("an action whose key does not resolve keeps its own label", function()
		local config = fresh()
		local actions = config.load_available_actions(ACTIONS_JSON)

		local found = find(actions, UNKEYED_ID)
		helpers.assert_true(found ~= nil, "'" .. UNKEYED_ID .. "' must be in the catalogue")
		helpers.assert_eq(type(found.label), "string", "it must still carry a label")
		helpers.assert_true(#found.label > 0, "which must not be empty — the row would be unreadable")
		helpers.assert_true(found.label:find("sg_actions.", 1, true) == nil,
			"and must not be the unresolved key: i18n.get answers with the KEY when it cannot resolve, " ..
			"so writing it through would put 'sg_actions." .. UNKEYED_ID .. "' in the menu")
	end)

	helpers.it("an unresolved key is asked of the catalogue, never translated", function()
		-- i18n.get decodes en.json on the active locale's first miss: these
		-- probes made every boot decode it, although every shipped catalogue
		-- carries the same keys, so the miss was certain.
		local config = fresh()
		local i18n = require("core.i18n.engine.i18n")
		local translate = i18n.get
		local probed = {}
		i18n.get = function(key)
			if key:find("^sg_actions%.") then probed[#probed + 1] = key end
			return translate(key)
		end
		helpers.assert_eq(type(config.load_available_actions(ACTIONS_JSON)), "table", "the catalogue must load")
		for _, key in ipairs(probed) do
			helpers.assert_eq(key, "sg_actions." .. KEYED_ID, "only a key the catalogue has is translated")
		end
		helpers.assert_true(#probed >= 1, "the keyed action is still translated")
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 4/ Headings And Key Actions ==========
-- ==============================================
-- ==============================================

helpers.describe("remap action labels: picker headings and key actions", function()
	helpers.it("every heading comes from remap.category.*, in every locale", function()
		-- The headings read « Modificateurs », « Touches » or « Keyboard shortcuts »
		-- whatever the user's language: the catalogue held the French text.
		local config = fresh()
		local i18n = require("core.i18n.engine.i18n")
		i18n.get = function(key) return key:find("^remap%.category%.") and "<" .. key .. ">" or key end
		local actions = config.load_available_actions(ACTIONS_JSON)
		helpers.assert_eq(type(actions), "table", "the catalogue must load")
		local fh = assert(io.open(helpers.shared("core/i18n/data/locales/en.json"), "r"))
		local english = json.decode(fh:read("*a"))
		fh:close()
		local seen = 0
		for _, action in ipairs(actions) do
			local key = action.category:match("^<(remap%.category%.[a-z_]+)>$")
			helpers.assert_true(key ~= nil, "'" .. action.id .. "' heading must be a locale key: " .. action.category)
			helpers.assert_eq(type(english[key]), "string", key .. " must exist in the locale catalogue")
			seen = seen + 1
		end
		helpers.assert_true(seen > 600, "the shared modifier chords must be named too, " .. seen .. " seen")
	end)

	helpers.it("AltGr is named from the key name table", function()
		local config = fresh()
		local i18n = require("core.i18n.engine.i18n")
		i18n.get = function(key) return key == "key_name.right_option" and "RIGHT-OPTION" or key end
		local altgr = find(config.load_available_actions(ACTIONS_JSON), "altgr")
		helpers.assert_true(altgr ~= nil, "'altgr' must be in the catalogue")
		-- The right Option key has no glyph of its own in the table.
		helpers.assert_eq(altgr.label, "RIGHT-OPTION", "the long label is the key's name")
		helpers.assert_eq(altgr.short_label, "RIGHT-OPTION", "and so is the short one")
	end)
end)
