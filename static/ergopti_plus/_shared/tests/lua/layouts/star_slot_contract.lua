--- _shared/tests/lua/layouts/star_slot_contract.lua

--- Replays the ★ key's physical-source and ordinary-slot decisions on both Lua
--- drivers. Windows replays the same corpus through _shared/shortcuts/data/star_slot.ahk.
--- @param helpers table Driver test helpers.
--- @param json table Shared JSON codec.
--- @param shared_root string Absolute shared source directory.
--- @param platform string "macos" or "linux".
return function(helpers, json, shared_root, platform)
	local Policy = require("shortcuts.engine.star_slot_core")
	local handle = assert(io.open(shared_root .. "/tests/corpus/shortcuts/star_slot_vectors.json", "rb"))
	local corpus = json.decode(handle:read("*a"))
	handle:close()
	local registry_handle = assert(io.open(shared_root .. "/layouts/data/keycodes/physical_keys.json", "rb"))
	local registry = json.decode(registry_handle:read("*a"))
	registry_handle:close()
	local function options(changes)
		local candidates = changes.candidates or {
			{ code = "KeyC", native_code = 8, identity = "physical:KeyC", text = "★", direct = true, dead = false },
		}
		local claims = {}
		if changes.claim then claims["physical:KeyC"] = { action = changes.claim, binding_id = "keyboard__custom" } end
		if changes.unrelated_claim then claims["physical:KeyA"] = { action = changes.unrelated_claim } end
		return {
			default_action = "open_hotstrings_editor",
			stored_action = changes.stored_action,
			is_action = function(id) return id == "open_hotstrings_editor" or id == "copy" end,
			platform = platform,
			source = { generation = 11, status = changes.status or "ready", candidates = candidates },
			known_codes = registry.keys,
			explicit_claims = claims,
			configuration_generation = 23,
			admission = { master = changes.master ~= false, paused = changes.paused == true, inhibited = changes.inhibited == true },
		}
	end
	helpers.describe("★ key slot shared policy", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(star-slot) " .. vector.id, function()
				local decision = Policy.resolve(options(vector.changes))
				helpers.assert_eq(decision.action, vector.expected.action)
				helpers.assert_eq(decision.active, vector.expected.active)
				helpers.assert_eq(decision.reason, vector.expected.reason)
				local expected_code = type(vector.expected.source_code) == "string" and vector.expected.source_code or nil
				helpers.assert_eq(decision.source and decision.source.code, expected_code)
				helpers.assert_eq(decision.path, Policy.slot(platform).path)
				helpers.assert_eq(decision.binding_id, Policy.slot(platform).binding_id)
			end)
		end
		helpers.it("(star-slot) snapshots native source records without mutable aliases", function()
			local opts = options({})
			local decision = Policy.resolve(opts)
			opts.source.candidates[1].native_code = 999
			opts.source.candidates[1].identity = "physical:wrong"
			helpers.assert_eq(decision.source.native_code, 8)
			helpers.assert_eq(decision.source.identity, "physical:KeyC")
		end)
		helpers.it("(star-slot) rejects stale source, configuration, action and live admission", function()
			local decision = Policy.resolve(options({}))
			local function state()
				return { source_generation = 11, configuration_generation = 23, action = "open_hotstrings_editor",
					master = true, paused = false, inhibited = false }
			end
			helpers.assert_true(Policy.can_deliver(decision, state()))
			for field, value in pairs({ source_generation = 12, configuration_generation = 24,
				action = "copy", master = false, paused = true, inhibited = true }) do
				local changed = state()
				changed[field] = value
				helpers.assert_eq(Policy.can_deliver(decision, changed), false, field)
			end
			helpers.assert_eq(Policy.can_deliver(Policy.resolve(options({ stored_action = "none" })), state()), false)
		end)
		helpers.it("(star-slot) names the slot of each driver by its role", function()
			helpers.assert_eq(Policy.slot("windows").id, "meta_star")
			helpers.assert_eq(Policy.slot("linux").id, "meta_star")
			helpers.assert_eq(Policy.slot("macos").id, "secondary_star")
			helpers.assert_eq(pcall(Policy.slot, "beos"), false)
		end)
		helpers.it("(star-slot) refuses fabricated physical codes and incomplete source evidence", function()
			local unknown = options({})
			unknown.source.candidates[1].code = "SC999"
			helpers.assert_eq(pcall(Policy.resolve, unknown), false)
			local missing = options({})
			missing.source.candidates[1].dead = nil
			helpers.assert_eq(pcall(Policy.resolve, missing), false)
			local invented = options({ stored_action = "invented_action" })
			helpers.assert_eq(pcall(Policy.resolve, invented), false)
		end)
	end)
end
