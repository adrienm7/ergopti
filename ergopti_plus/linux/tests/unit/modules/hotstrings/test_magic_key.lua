--- tests/unit/modules/hotstrings/test_magic_key.lua

--- ==============================================================================
--- MODULE: The Magic Key Is the User's To Choose
--- DESCRIPTION:
--- Covers modules/hotstrings/magic_key.lua, which owns the character that fires a
--- dynamic hotstring.
---
--- WHY THIS MODULE EXISTS AT ALL:
--- Six call sites on this driver read `ManifestReader.default_for(…)` directly.
--- That is the SHIPPED DEFAULT, so the key could not be changed on Linux — while
--- Windows and macOS both offer an editor. The menu manifest recorded the gap
--- honestly, restricting the row to those two with a translated reason. A gap a
--- manifest declares closes by writing the feature; widening the declaration over
--- an absence would have put a row in the menu that does nothing when clicked.
---
--- WHAT THESE TESTS PIN, AND WHY EACH ONE IS A REAL FAILURE:
--- 1. The stored value wins over the default. If it did not, the setting would
---    appear to work — the dialog accepts the key, the menu redraws with it — and
---    the engine would go on listening for the old one. That is worse than no
---    setting: the user believes they configured something.
--- 2. Length is counted in CODEPOINTS. "★" is three bytes and one character, so a
---    byte-length check rejects the shipped default itself, and every other
---    non-ASCII key a user might reasonably pick.
--- 3. A character common in prose is refused. Accepting "e" arms a trigger on
---    ordinary words, and the symptom — text mangled seemingly at random — reads
---    as a bug in the expansion engine rather than as the setting they chose.
--- 4. A failed write is reported. A key that silently fails to persist comes back
---    at the next restart with no explanation.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Installs an in-memory canonical preference owner and returns it with a
--- restore function. The real owner writes config.toml; its own contract test
--- covers the file, so these cases pin what the magic key does with the answers.
--- @param opts table|nil { stored?: string, writable?: boolean }
--- @return table stub, function restore
local function stub_storage(opts)
	opts = opts or {}
	local previous = package.loaded["infra.hotstring_preferences"]
	local stub = { values = {}, writes = 0, deletes = 0, writable = opts.writable ~= false }
	if opts.stored ~= nil then stub.values["hotstrings.trigger_char"] = opts.stored end
	local function neutral(path) return require("infra.manifest_reader").default_for(path) end
	stub.get = function(path)
		local value = stub.values[path]
		if value == nil then return neutral(path) end
		return value
	end
	stub.is_explicit = function(path) return stub.values[path] ~= nil end
	stub.set = function(path, value)
		if not stub.writable then return false end
		-- Sparse, as the real owner: the neutral value removes the leaf.
		if value == neutral(path) then
			stub.deletes = stub.deletes + 1
			stub.values[path] = nil
		else
			stub.writes = stub.writes + 1
			stub.values[path] = value
		end
		return true
	end
	package.loaded["infra.hotstring_preferences"] = stub
	return stub, function() package.loaded["infra.hotstring_preferences"] = previous end
end


--- Installs a manifest-reader stub declaring `default` as the shipped key.
--- @param default string|nil
--- @return function restore
local function stub_manifest(default)
	local previous = package.loaded["infra.manifest_reader"]
	package.loaded["infra.manifest_reader"] = {
		default_for = function(path)
			if path == "hotstrings.trigger_char" then return default end
			return nil
		end,
	}
	return function() package.loaded["infra.manifest_reader"] = previous end
end


--- Loads the module fresh against the currently-installed stubs.
--- @return table
local function load_magic_key()
	return helpers.load_module("modules.hotstrings.magic_key")
end





-- ==================================================
-- ==================================================
-- ======= 1/ The stored value wins =================
-- ==================================================
-- ==================================================

helpers.describe("magic key: the user's choice outranks the shipped default", function()

	helpers.it("returns the manifest default when nothing was stored", function()
		local _, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		helpers.assert_eq("★", magic.get(), "an unconfigured driver must use what ships")
		helpers.assert_true(not magic.is_customised(), "and must not claim the user chose it")

		restore_manifest(); restore_storage()
	end)

	helpers.it("returns the stored value when there is one", function()
		local _, restore_storage = stub_storage({ stored = "§" })
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		helpers.assert_eq("§", magic.get(),
			"reading the default here is what made the setting inert on this driver")
		helpers.assert_true(magic.is_customised(), "and the menu needs to know it can offer a reset")

		restore_manifest(); restore_storage()
	end)

	helpers.it("reports no customisation when the stored value equals the default", function()
		local _, restore_storage = stub_storage({ stored = "★" })
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		helpers.assert_true(not magic.is_customised(),
			"offering to 'restore the default' when it is already the default is a dead row")

		restore_manifest(); restore_storage()
	end)

	helpers.it("does not revive an unsafe key persisted by an older version", function()
		local _, restore_storage = stub_storage({ stored = "e" })
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		helpers.assert_eq(magic.get(), "★",
			"an unsafe legacy value must fail closed to the validated shipped key")
		helpers.assert_eq(magic.is_customised(), false,
			"an ignored legacy value must not be advertised as active")

		restore_manifest(); restore_storage()
	end)

	helpers.it("warns once, never an ERROR, about that key and offers it (config-outdated-magic-key)", function()
		local _, restore_storage = stub_storage({ stored = "e" })
		local restore_manifest = stub_manifest("★")
		local Logger = require("logger.shim")
		local real_warn, real_error, warnings, errors = Logger.warn, Logger.error, {}, {}
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		require("config_outdated").reset_for_tests()
		local ok, err = pcall(function()
			local magic = load_magic_key()
			for _ = 1, 3 do helpers.assert_eq(magic.get(), "★") end
			helpers.assert_eq(errors, {}, "an outdated magic key is never an ERROR")
			helpers.assert_eq(#warnings, 1, "named once, not at every menu build")
			helpers.assert_contains(warnings[1], "hotstrings.trigger_char")
		end)
		Logger.warn, Logger.error = real_warn, real_error
		restore_manifest(); restore_storage()
		if not ok then error(err, 0) end
		local source = '[hotstrings]\ntrigger_char = "e"\n'
		local scan = require("config_unused_keys").find_in_source(source, require("ui.menu.unused_keys_cleanup").collect)
		helpers.assert_eq(#scan.keys, 1, "the cleanup offers the key the reader ignores")
		helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "hotstrings", "trigger_char" })
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 2/ Validation ============================
-- ==================================================
-- ==================================================

helpers.describe("magic key: what may be chosen", function()

	helpers.it("accepts a multi-byte character", function()
		local _, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		-- Three bytes, one character. A byte-length check would refuse the key this
		-- project actually ships.
		helpers.assert_true((magic.validate("★")),
			"the shipped default must itself pass validation")
		helpers.assert_true((magic.validate("§")), "and so must any other single non-ASCII key")

		restore_manifest(); restore_storage()
	end)

	helpers.it("refuses two characters", function()
		local _, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		local ok, reason = magic.validate("ab")
		helpers.assert_true(not ok, "a two-character trigger is not a key")
		helpers.assert_eq("dialog.magic_key.error_length", reason,
			"and the refusal must name the reason the dialog will show")

		-- Two multi-byte characters: six bytes, and a byte check would let this in
		-- while refusing the one-character "★" above.
		helpers.assert_true(not (magic.validate("★★")), "counted in codepoints, not bytes")

		restore_manifest(); restore_storage()
	end)

	helpers.it("refuses the empty string and non-strings", function()
		local _, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		helpers.assert_true(not (magic.validate("")), "an empty entry is not a cancel")
		helpers.assert_true(not (magic.validate(nil)), "and nil must not crash the handler")
		helpers.assert_true(not (magic.validate(42)), "nor must a non-string")

		restore_manifest(); restore_storage()
	end)

	helpers.it("refuses characters that occur in ordinary text", function()
		local _, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		for _, candidate in ipairs({ " ", ".", ",", "'", "-" }) do
			local ok, reason = magic.validate(candidate)
			helpers.assert_true(not ok,
				"a key that appears mid-sentence fires expansions on text the user is merely writing")
			helpers.assert_eq("dialog.magic_key.error_common", reason,
				"and the message has to explain that, or the refusal looks arbitrary")
		end

		restore_manifest(); restore_storage()
	end)

	helpers.it("rejects every ASCII letter and digit plus non-Latin word characters", function()
		local _, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		local ordinary = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
		for index = 1, #ordinary do
			helpers.assert_eq(magic.validate(ordinary:sub(index, index)), false,
				"ordinary ASCII codepoints must never become destructive triggers")
		end
		for _, candidate in ipairs({ "é", "я", "א", "中", "١" }) do
			helpers.assert_eq(magic.validate(candidate), false,
				"the policy must reject word codepoints outside English too: " .. candidate)
		end
		for _, candidate in ipairs({ "§", "★", "◆", "✓", "🔑" }) do
			helpers.assert_eq(magic.validate(candidate), true,
				"the shared symbol policy must keep safe choices usable: " .. candidate)
		end

		restore_manifest(); restore_storage()
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 3/ Writing ===============================
-- ==================================================
-- ==================================================

helpers.describe("magic key: setting and resetting", function()

	helpers.it("persists an accepted key and notifies the daemon", function()
		local storage, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		local announced = nil
		magic.init(function(value) announced = value end)

		helpers.assert_true((magic.set("§")), "a valid key must be accepted")
		helpers.assert_eq("§", storage.values["hotstrings.trigger_char"],
			"a key held only in memory is a key lost at the next restart")
		helpers.assert_eq("§", announced,
			"the dynamic rules bake the character into their triggers, so they must be told")

		restore_manifest(); restore_storage()
	end)

	helpers.it("writes nothing when the key is refused", function()
		local storage, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		local announced = nil
		magic.init(function(value) announced = value end)

		local ok = magic.set(".")
		helpers.assert_true(not ok, "a refused key must report the refusal")
		helpers.assert_eq(0, storage.writes, "and must not reach storage at all")
		helpers.assert_eq(nil, announced, "nor announce a change that did not happen")

		restore_manifest(); restore_storage()
	end)

	helpers.it("reports a storage failure instead of claiming success", function()
		local _, restore_storage = stub_storage({ writable = false })
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		local ok, reason = magic.set("§")
		helpers.assert_true(not ok,
			"a write that failed must not read as success — the key would silently revert")
		helpers.assert_eq("dialog.magic_key.error_persist", reason,
			"and the user has to be told why, not left to discover it after a restart")

		restore_manifest(); restore_storage()
	end)

	helpers.it("reset removes the override rather than storing the default", function()
		local storage, restore_storage = stub_storage({ stored = "§" })
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()

		magic.reset()
		helpers.assert_eq(1, storage.deletes,
			"deleting is what makes the key follow the shipped default if it ever changes")
		helpers.assert_eq("★", magic.get(), "and the effective key returns to the default")
		helpers.assert_true(not magic.is_customised(), "with no reset row left offering itself")

		restore_manifest(); restore_storage()
	end)

	helpers.it("a failed reset keeps the override and sends no change notification", function()
		local storage, restore_storage = stub_storage({ stored = "§", writable = false })
		local restore_manifest = stub_manifest("★")
		local magic = load_magic_key()
		local announced = nil
		magic.init(function(value) announced = value end)

		helpers.assert_eq(magic.reset(), false)
		helpers.assert_eq(storage.values["hotstrings.trigger_char"], "§")
		helpers.assert_eq(magic.get(), "§", "the active key must remain the durable override")
		helpers.assert_eq(announced, nil, "the daemon must not rebuild for a reset that failed")

		restore_manifest(); restore_storage()
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 4/ A manifest with no default ============
-- ==================================================
-- ==================================================

helpers.describe("magic key: a missing manifest default is said out loud", function()

	helpers.it("does not invent a fallback character", function()
		local _, restore_storage = stub_storage({})
		local restore_manifest = stub_manifest(nil)
		local magic = load_magic_key()

		-- The last time a reader on this driver answered with a hardcoded literal,
		-- it answered "\" while the engine listened for "★" — and the menu
		-- documented the wrong key in 21 languages. An empty string here is a build
		-- problem that shows itself; a literal is one that hides.
		helpers.assert_eq("", magic.default(),
			"a hardcoded fallback would paper over a broken manifest, in every locale")

		restore_manifest(); restore_storage()
	end)

end)

-- Uses the actual native builder closure and genuine shared factory; no provider stand-in.
local function with_magic_frame(language, stored, mode, body)
	local names = { "infra.manifest_menu", "ui.menu.menu_builder", "modules.hotstrings.magic_key", "infra.i18n", "infra.locale", "locale.core", "ui.text_prompt" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local storage, restore_storage, restore_manifest
	local root, frame, first_i18n, prompt_owner, prior_ask
	local effects = { prompts = 0, redraws = 0, frame_hooks = 0 }
	local ok, detail = xpcall(function()
		storage, restore_storage = stub_storage({ stored = stored })
		restore_manifest = stub_manifest("★")
		local json = require("json")
		local Paths = require("infra.paths")
		package.loaded["infra.i18n"], package.loaded["infra.locale"], package.loaded["locale.core"] = nil, nil, nil
		local native_locale = require("infra.locale")
		native_locale.set_locale(language)
		local native_i18n = require("infra.i18n")
		prompt_owner = require("ui.text_prompt")
		prior_ask = prompt_owner.ask
		prompt_owner.ask = function() effects.prompts = effects.prompts + 1; return "§" end
		local renderer = assert(require("menu.renderer").new({ platform = "linux", json_decode = json.decode,
			manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
			i18n = native_i18n, logger = { error = function() end, warn = function() end } }))
		root = renderer.get_root(); frame = root.hotstrings_magic_trigger_frame; first_i18n = frame and frame[1].i18n
		local template = renderer.template_rows
		renderer.template_rows = function(...)
			local rows = template(...)
			if select(1, ...) == "hotstrings_magic_trigger_frame" then
				if mode == "withdrawal" then root.hotstrings_magic_trigger_frame = nil end
				if mode == "drift" then frame[1].i18n = "menu.hotstrings.params" end
				if mode == "slots" then frame.foreign = true end
				if mode == "meta" then setmetatable(frame, { __len = function() effects.frame_hooks = effects.frame_hooks + 1; return 3 end }) end
			end
			return rows
		end
		package.loaded["infra.manifest_menu"] = renderer
		package.loaded["modules.hotstrings.magic_key"] = nil
		package.loaded["ui.menu.menu_builder"] = nil
		local native = require("ui.menu.menu_builder")
		local function upvalue(fn, wanted)
			for index = 1, math.huge do
				local name, value = debug.getupvalue(fn, index)
				if name == nil then break end
				if name == wanted then return value end
			end
		end
		local hotstrings = assert(upvalue(native.build, "_build_hotstrings"))
		local actual = assert(upvalue(hotstrings, "_manifest_hotstring_rows"))
		local captured
		local build = renderer.build
		renderer.build = function(section, category, dynamic, groups, context, providers)
			if section == "hotstrings_params_group" then
				captured = assert(providers.magic_key_config)()
				return build(section, category, dynamic, groups, context, providers)
			end
			return build(section, category, dynamic, groups, context, providers)
		end
		local config = { any_enabled = function() return false end, get_categories = function() return {} end, get_groups = function() return {} end }
		actual({ config = config, state = {}, paused = false, on_menu_changed = function() effects.redraws = effects.redraws + 1 end }, config)
		body(assert(captured), effects, storage)
	end, debug.traceback)
	if root then root.hotstrings_magic_trigger_frame = frame end
	if frame then frame[1].i18n = first_i18n; frame.foreign = nil; setmetatable(frame, nil) end
	if prompt_owner then prompt_owner.ask = prior_ask end
	if restore_manifest then restore_manifest() end
	if restore_storage then restore_storage() end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("Magic trigger declared native provider", function()
	for _, code in ipairs({ "en", "fr" }) do
		local language = code
		helpers.it("keeps native default order and current character in " .. language, function()
			with_magic_frame(language, nil, nil, function(rows, effects, storage)
				helpers.assert_eq(#rows, 1)
				helpers.assert_eq(rows[1].label, language == "en" and "Magic key : ★" or "Touche magique : ★")
				helpers.assert_eq(effects.prompts, 0); helpers.assert_eq(storage.writes, 0)
				rows[1].action()
				helpers.assert_eq(effects.prompts, 1); helpers.assert_eq(storage.writes, 1)
				helpers.assert_eq(effects.redraws, 1)
			end)
		end)
		helpers.it("keeps actual customised reset and native reset callback in " .. language, function()
			with_magic_frame(language, "§", nil, function(rows, effects, storage)
				helpers.assert_eq(#rows, 2)
				helpers.assert_eq(rows[1].label, language == "en" and "Magic key : §" or "Touche magique : §")
				helpers.assert_eq(rows[2].label, language == "en" and "    Restore the default key" or "    Rétablir la touche par défaut")
				rows[2].action()
				helpers.assert_eq(storage.deletes, 1); helpers.assert_eq(effects.redraws, 1)
				helpers.assert_eq(effects.prompts, 0)
			end)
		end)
	end
	for _, mode_name in ipairs({ "withdrawal", "drift", "slots", "meta" }) do
		local mode = mode_name
		helpers.it("withholds actual rows after late " .. mode .. " and all native effects", function()
			with_magic_frame("en", "§", mode, function(rows, effects, storage)
				helpers.assert_eq(#rows, 0)
				helpers.assert_eq(effects.frame_hooks, 0)
				helpers.assert_eq(effects.prompts, 0); helpers.assert_eq(effects.redraws, 0)
				helpers.assert_eq(storage.writes, 0); helpers.assert_eq(storage.deletes, 0)
			end)
		end)
	end
end)
