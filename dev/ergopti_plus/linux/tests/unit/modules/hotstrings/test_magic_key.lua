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


--- Installs a storage stub and returns it with a restore function.
--- @param opts table|nil { stored?: string, writable?: boolean }
--- @return table stub, function restore
local function stub_storage(opts)
	opts = opts or {}
	local previous = package.loaded["adapters.storage"]
	local stub = { values = {}, writes = 0, deletes = 0, writable = opts.writable ~= false }
	if opts.stored ~= nil then stub.values["hotstrings.trigger_char"] = opts.stored end
	stub.get = function(key, default_value)
		local value = stub.values[key]
		if value == nil then return default_value end
		return value
	end
	stub.set = function(key, value)
		stub.writes = stub.writes + 1
		if not stub.writable then return false end
		stub.values[key] = value
		return true
	end
	stub.delete = function(key)
		stub.deletes = stub.deletes + 1
		if not stub.writable then return false end
		stub.values[key] = nil
		return true
	end
	package.loaded["adapters.storage"] = stub
	return stub, function() package.loaded["adapters.storage"] = previous end
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
