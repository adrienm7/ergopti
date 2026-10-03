--- _shared/lua/test/magic_editor_contract.lua

--- Replays independent physical-source and ordinary-slot decisions on both Lua
--- drivers. Native acquisition tests additionally replay this corpus on Windows.
--- @param helpers table Driver test helpers.
--- @param json table Shared JSON codec.
--- @param shared_root string Absolute shared source directory.
return function(helpers, json, shared_root)
	local Policy = require("shortcuts.magic_editor")
	local handle = assert(io.open(shared_root .. "/tests/corpus/shortcuts/magic_editor_vectors.json", "rb"))
	local corpus = json.decode(handle:read("*a"))
	handle:close()
	local registry_handle = assert(io.open(shared_root .. "/data/keycodes/physical_keys.json", "rb"))
	local registry = json.decode(registry_handle:read("*a"))
	registry_handle:close()
	local function options(changes)
		local candidates = changes.candidates or {
			{ code = "Semicolon", native_code = 41, identity = "physical:Semicolon", text = ";", direct = true, dead = false },
		}
		local claims = {}
		if changes.claim then claims["physical:Semicolon"] = { action = changes.claim, binding_id = "keyboard__custom" } end
		if changes.unrelated_claim then claims["physical:KeyA"] = { action = changes.unrelated_claim } end
		return {
			default_action = "open_hotstrings_editor",
			stored_action = changes.stored_action,
			is_action = function(id) return id == "open_hotstrings_editor" or id == "copy" end,
			trigger = changes.trigger or ";",
			source = { generation = 11, status = changes.status or "ready", candidates = candidates },
			known_codes = registry.keys,
			explicit_claims = claims,
			configuration_generation = 23,
			admission = { master = changes.master ~= false, paused = changes.paused == true, inhibited = changes.inhibited == true },
		}
	end
	helpers.describe("physical magic editor shared policy", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(magic-editor) " .. vector.id, function()
				local decision = Policy.resolve(options(vector.changes))
				helpers.assert_eq(decision.action, vector.expected.action)
				helpers.assert_eq(decision.active, vector.expected.active)
				helpers.assert_eq(decision.reason, vector.expected.reason)
				local expected_code = type(vector.expected.source_code) == "string" and vector.expected.source_code or nil
				helpers.assert_eq(decision.source and decision.source.code, expected_code)
				helpers.assert_eq(decision.path, Policy.PATH)
				helpers.assert_eq(decision.binding_id, Policy.BINDING_ID)
			end)
		end
		helpers.it("(magic-editor) snapshots native source records without mutable aliases", function()
			local opts = options({})
			local decision = Policy.resolve(opts)
			opts.source.candidates[1].native_code = 999
			opts.source.candidates[1].identity = "physical:wrong"
			helpers.assert_eq(decision.source.native_code, 41)
			helpers.assert_eq(decision.source.identity, "physical:Semicolon")
		end)
		helpers.it("(magic-editor) rejects stale source, configuration, action and live admission", function()
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
		helpers.it("(magic-editor) refuses fabricated physical codes and incomplete source evidence", function()
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
