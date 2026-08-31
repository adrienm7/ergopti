--- tests/unit/modules/llm/test_llm_settings.lua

--- ==============================================================================
--- MODULE: Two Constants That Were Pretending To Be Settings
--- DESCRIPTION:
--- The temperature and the context length: what they default to, what survives
--- a restart, and what is refused.
---
--- WHAT WAS WRONG:
--- The manifest has declared both as features for as long as it has existed.
--- This driver read them from the shared canonical defaults and had no way to
--- change either, so `llm.generation` could not honestly be declared for Linux —
--- and declaring a capability with no control is what ADR-008 removed a
--- notifier for.
---
--- WHY AN OUT-OF-RANGE STORED VALUE IS REFUSED AND NOT CLIPPED:
--- It can only come from a hand-edited config or an older schema. Clipping
--- would silently apply a setting the user never chose while the menu showed
--- the clipped value as if they had — the failure is invisible from both sides.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

local _displaced = { storage = nil, module = nil, held = false }

--- Loads the settings over a fake storage.
--- @param initial table|nil
--- @param writes_fail boolean|nil
--- @return table settings, table storage
local function load_over_storage(initial, writes_fail)
	if not _displaced.held then
		_displaced.storage = package.loaded["adapters.storage"]
		_displaced.module = package.loaded["modules.llm.settings"]
		_displaced.held = true
	end
	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	package.loaded["adapters.storage"] = storage
	package.loaded["modules.llm.settings"] = nil
	local settings = require("modules.llm.settings")
	settings._reset()
	return settings, storage
end

--- Puts back exactly what was there.
local function drop_storage()
	package.loaded["adapters.storage"] = _displaced.storage
	package.loaded["modules.llm.settings"] = _displaced.module
end




-- =================================================================
-- =================================================================
-- ======= 1/ The shipped answer ===================================
-- =================================================================
-- =================================================================

helpers.describe("llm settings: where the default comes from", function()

	helpers.it("takes both from the shared manifest", function()
		local settings = load_over_storage()
		local Manifest = helpers.load_module("infra.manifest_reader")
		local temperature = settings.get("temperature")
		local context = settings.get("context_length")
		drop_storage()

		helpers.assert_eq(temperature, Manifest.default_for("llm.generation.temperature"),
			"a driver that writes its own default is not configurable, it is "
				.. "coincidentally similar")
		helpers.assert_eq(context, Manifest.default_for("llm.generation.context_length"))
	end)

	helpers.it("stores nothing while both are at their shipped values", function()
		local settings, storage = load_over_storage()
		settings.get("temperature")
		settings.get("context_length")
		local written = 0
		for _, key in ipairs(storage.keys()) do
			if key:find("^llm%.generation%.") then written = written + 1 end
		end
		drop_storage()
		helpers.assert_eq(written, 0,
			"persisting the default would freeze today's default for anyone who had "
				.. "already run the driver")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ A change, and what survives ==========================
-- =================================================================
-- =================================================================

helpers.describe("llm settings: changing them", function()

	helpers.it("stores a value the user chose", function()
		local settings, storage = load_over_storage()
		helpers.assert_true(settings.set("temperature", 0.8))
		local stored = storage.get("llm.generation.temperature")
		drop_storage()
		helpers.assert_eq(stored, 0.8,
			"a setting that is not persisted is a control that forgets what the "
				.. "user told it at every restart")
	end)

	helpers.it("reads a stored value back", function()
		local settings = load_over_storage({ ["llm.generation.temperature"] = 0.5 })
		local value = settings.get("temperature")
		drop_storage()
		helpers.assert_eq(value, 0.5)
	end)

	helpers.it("clears the entry when it returns to the shipped value", function()
		local settings, storage = load_over_storage()
		local shipped = settings.get("temperature")
		settings.set("temperature", 0.8)
		settings.set("temperature", shipped)
		local has = storage.has("llm.generation.temperature")
		drop_storage()
		helpers.assert_true(not has,
			"back to the default means back to no entry, so the shipped answer "
				.. "stays live rather than being pinned at the moment they touched it")
	end)

	helpers.it("keeps the durable value active when a write or delete fails", function()
		local settings, storage = load_over_storage({ ["llm.generation.temperature"] = 0.5 }, true)
		helpers.assert_eq(settings.get("temperature"), 0.5)
		helpers.assert_eq(settings.set("temperature", 0.8), false)
		helpers.assert_eq(settings.get("temperature"), 0.5,
			"a failed write must not publish a session-only value")
		local default = helpers.load_module("infra.manifest_reader")
			.default_for("llm.generation.temperature")
		helpers.assert_eq(settings.set("temperature", default), false)
		helpers.assert_eq(settings.get("temperature"), 0.5,
			"a failed delete must not publish the shipped default")
		helpers.assert_eq(storage.get("llm.generation.temperature"), 0.5)
		drop_storage()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ What is refused ======================================
-- =================================================================
-- =================================================================

helpers.describe("llm settings: the bounds", function()

	helpers.it("refuses a value outside the declared range", function()
		local settings, storage = load_over_storage()
		local bounds = settings.bounds("temperature")
		helpers.assert_not_nil(bounds, "the range must be declared")
		local accepted = settings.set("temperature", bounds.max + 10)
		local written = #storage.keys()
		drop_storage()
		helpers.assert_true(not accepted,
			"a temperature ten above the maximum is not a user asking for more "
				.. "creativity, it is a caller with a bug, and accepting it hides that "
				.. "for ever")
		helpers.assert_eq(written, 0)
	end)

	helpers.it("ignores a stored value outside the range rather than clipping it", function()
		local settings = load_over_storage({ ["llm.generation.temperature"] = 99 })
		local value = settings.get("temperature")
		local shipped = settings.bounds("temperature")
		drop_storage()
		helpers.assert_true(value <= shipped.max,
			"clipping would silently apply a setting the user never chose while the "
				.. "menu showed the clipped value as if they had — invisible from both "
				.. "sides")
	end)

	helpers.it("offers only presets inside the range", function()
		local settings = load_over_storage()
		local checked = 0
		for _, name in ipairs({ "temperature", "context_length" }) do
			local bounds = settings.bounds(name)
			for _, value in ipairs(settings.presets(name)) do
				checked = checked + 1
				helpers.assert_true(value >= bounds.min and value <= bounds.max,
					name .. " offers " .. tostring(value) .. ", which its own set() would "
						.. "refuse — a menu row that cannot be applied")
			end
		end
		drop_storage()
		helpers.assert_true(checked > 0,
			"no presets were checked — the menu would have nothing to offer")
	end)

end)
