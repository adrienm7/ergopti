--- _shared/lua/test/pause_switch_policy_contract.lua

--- ==============================================================================
--- MODULE: Pause Switch Policy Contract
--- DESCRIPTION:
--- Replays the shared pause/resume/quit layout vectors against the shared
--- policy and checks the driver's manifest declares the three settings with the
--- types the policy reads, so macOS and Linux hold the rule the AHK twin holds.
--- The native switch and the picker remain adapter-owned.
--- ==============================================================================

local M = {}
local Policy = require("layout.pause_switch_policy")
local Json = require("json")

--- Registers the target and event vectors.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string Canonical shared corpus path.
function M.run(helpers, corpus_path)
	local file = assert(io.open(corpus_path, "rb"))
	local content = file:read("*a")
	assert(file:close())
	local corpus = Json.decode(content)

	helpers.describe("Shared pause switch layout policy", function()
		helpers.it("accepts a layout id or no change and refuses other stored values", function()
			helpers.assert_eq(#corpus.targets, 6, "complete target vectors")
			for _, row in ipairs(corpus.targets) do
				helpers.assert_eq(Policy.valid_target(row.value), row.valid, row.id)
				helpers.assert_eq(Policy.target_id(row.value), row.target, row.id .. " id")
			end
		end)

		helpers.it("switches only when enabled, to the event's non-empty target", function()
			helpers.assert_eq(#corpus.vectors, 14, "complete event vectors")
			for _, row in ipairs(corpus.vectors) do
				helpers.assert_eq(Policy.target(row.settings, row.event), row.target, row.id)
			end
		end)

		helpers.it("refuses an unknown event and settings that are not a table", function()
			for _, event in ipairs(corpus.invalid_events) do
				helpers.assert_eq(pcall(Policy.target, { enabled = true, on_pause = "x" }, event), false,
					"unknown event " .. event)
			end
			for _, event in ipairs(corpus.events) do
				helpers.assert_eq(pcall(Policy.target, nil, event), false, "no settings for " .. event)
			end
		end)
	end)
end

--- Registers the declaration check against a driver's generated manifest.
--- @param helpers table Driver assertions and case registration.
--- @param manifest table Driver manifest reader exposing find_entry_by_path.
function M.run_manifest(helpers, manifest)
	helpers.describe("Pause switch settings declaration", function()
		helpers.it("reads settings the manifest declares as a boolean switch and two text targets", function()
			local switch = manifest.find_entry_by_path(Policy.PATHS.enabled)
			helpers.assert_eq(type(switch), "table", "the switch is declared")
			helpers.assert_eq(switch.type, "boolean", "the switch is a boolean")
			helpers.assert_eq(switch.default, false, "switching is off by default")
			for _, role in ipairs({ "on_pause", "on_resume" }) do
				local entry = manifest.find_entry_by_path(Policy.PATHS[role])
				helpers.assert_eq(type(entry), "table", role .. " is declared")
				-- The targets hold layout ids: a boolean type refused every chosen layout.
				helpers.assert_eq(entry.type, "string", role .. " holds a layout id")
				helpers.assert_eq(entry.default, "", role .. " defaults to no change")
				helpers.assert_eq(Policy.valid_target(entry.default), true, role .. " default is valid")
			end
		end)
	end)
end

return M
