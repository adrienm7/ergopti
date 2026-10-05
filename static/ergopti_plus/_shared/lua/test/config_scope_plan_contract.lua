--- _shared/lua/test/config_scope_plan_contract.lua

--- Plans carry dynamic ownership and separate-file requirements explicitly.
return function(helpers)
	local Manifest = require("infra.manifest_reader")
	local Actions = require("_generated.action_catalogue").actions
	-- This port stands in for each host's existing parameter-key validator. The
	-- real generated catalogue supplies parameter capability; scopes never infer it.
	local function parameter_domain(path)
		local key = path:match("^action_parameters%.(.+)$")
		if not key then return nil end
		local domain, binding, action = key:match("^([a-z_]+)__(.-)__([a-z0-9_]+)$")
		if not domain or not binding:match("^[a-z0-9_]+$") or binding:find("__", 1, true)
			or binding:sub(1, 1) == "_" or binding:sub(-1) == "_" then return nil end
		local meta = Actions[action]
		return meta and type(meta.parameter) == "string" and meta.parameter ~= "" and domain or nil
	end
	local owners = { action_parameter_domain = parameter_domain }
	helpers.describe("scoped configuration planning", function()
		helpers.it("retains generated dynamic scalar types before a native runtime erases false versus zero", function()
			local found = {}
			for _, scope in pairs(Manifest.scopes()) do
				for _, definition in ipairs(scope.dynamic_defaults or {}) do
					local kind = type(definition.default)
					if kind == "table" then
						for index in pairs(definition.default) do
							helpers.assert_true(type(index) == "number" and index % 1 == 0
								and index >= 1 and index <= #definition.default, "array defaults must be dense")
						end
						kind = "array"
					end
					helpers.assert_eq(definition.type, kind == "number" and "integer" or kind)
					found[definition.type] = true
				end
			end
			helpers.assert_eq(found.boolean, true)
			helpers.assert_eq(found.integer, true)
		end)
		helpers.it("removes only validated parameter domains for both clear and recommendation restore", function()
			local paths = { "action_parameters.gesture__tap_4__open_url", "action_parameters.keyboard__ctrl_k__open_url",
				"action_parameters.script__reload__open_url", "action_parameters.tap_key__digit_1__open_url",
				"action_parameters.tap_hold__caps_lock__open_url" }
			for _, selected in ipairs({ { "gestures", 1 }, { "shortcuts", 3 }, { "tap_holds", 1 }, { "hotstrings", 0 } }) do
				local inventory = Manifest.scope_inventory(selected[1], { actions = function() return paths end }, owners)
				helpers.assert_eq(#inventory, selected[2])
				for _, mode in ipairs({ "clear", "recommended" }) do
					local plan = Manifest.scope_plan(selected[1], mode, paths, owners)
					local actual = {}
					for _, row in ipairs(plan.operations) do
						if row.section == "action_parameters" then
							helpers.assert_eq(row.delete, true)
							helpers.assert_eq(row.value, nil)
							actual[#actual + 1] = row.section .. "." .. row.key
						end
					end
					table.sort(actual)
					helpers.assert_eq(actual, inventory)
				end
			end
		end)
		helpers.it("requires exact host ownership and refuses malformed or non-parameter actions", function()
			for _, path in ipairs({ "action_parameters.gesture__tap_4__none", "action_parameters.gesture__tap_4__made_up",
				"action_parameters.gesture__tap__4__open_url", "action_parameters.gesture__tap_4__open_url.extra",
				"action_parameters.foreign__tap_4__open_url", "other.gesture__tap_4__open_url" }) do
				helpers.assert_eq(pcall(Manifest.scope_plan, "gestures", "clear", { path }, owners), false, path)
				helpers.assert_eq(pcall(Manifest.scope_inventory, "gestures", { actions = function() return { path } end }, owners), false, path)
			end
			local path = "action_parameters.gesture__tap_4__open_url"
			helpers.assert_eq(pcall(Manifest.scope_plan, "gestures", "clear", { path }), false)
			helpers.assert_eq(pcall(Manifest.scope_plan, "gestures", "clear", { path }, {
				action_parameter_domain = function() error("owner unavailable") end,
			}), false)
		end)
		helpers.it("collects exact runtime-owned leaves once without claiming static or unknown siblings", function()
			local calls = 0
			helpers.assert_not_nil(Manifest.find_entry_by_path("gestures.enabled"))
			local owned = Manifest.scope_inventory("hotstrings", {
				language = function()
					calls = calls + 1
					return { "hotstrings.groups.french_probe", "hotstrings.modules.french_probe.accents",
						"gestures.enabled" }
				end,
				extension = function()
					calls = calls + 1
					return { "hotstrings.modules.ext:ergopti:rolls.custom", "hotstrings.groups.french_probe",
						"shortcuts.personal.other_scope" }
				end,
			})
			helpers.assert_eq(calls, 2)
			helpers.assert_eq(owned, { "hotstrings.groups.french_probe",
				"hotstrings.modules.ext:ergopti:rolls.custom", "hotstrings.modules.french_probe.accents" })
			local plan = Manifest.scope_plan("hotstrings", "clear", owned)
			local indexed = {}
			for _, row in ipairs(plan.operations) do
				local segments = assert(require("toml_codec.key_path").parse(row.section))
				indexed[table.concat(segments, ".") .. "." .. row.key] = row
			end
			for _, path in ipairs(owned) do helpers.assert_eq(indexed[path].delete, true) end
			helpers.assert_eq(indexed["hotstrings.modules.ext:ergopti:rolls.custom"].section,
				'hotstrings.modules."ext:ergopti:rolls"', "the colon identity stays one valid TOML section segment")
			helpers.assert_eq(indexed["hotstrings.modules.ext:ergopti:rolls.unknown"], nil)
			helpers.assert_eq(indexed["shortcuts.personal.other_scope"], nil)
		end)
		helpers.it("refuses incomplete inventory instead of returning a partial successful plan", function()
			helpers.assert_type(Manifest.scope_inventory, "function")
			for _, paths in ipairs({ { "hotstrings.modules.group.section.expert" }, { "future.setting" },
				{ [1] = "hotstrings.groups.valid", [3] = "hotstrings.groups.hole" },
				{ named = "hotstrings.groups.valid" }, { "hotstrings.groups..invalid" } }) do
				local ok = pcall(Manifest.scope_inventory, "hotstrings", { runtime = function() return paths end })
				helpers.assert_eq(ok, false)
			end
			helpers.assert_eq(pcall(Manifest.scope_inventory, "hotstrings", {
				first = function() return { "hotstrings.groups.valid" } end,
				second = function() error("runtime inventory unavailable") end,
			}), false)
			helpers.assert_eq(pcall(Manifest.scope_inventory, "hotstrings", { invalid = false }), false)
		end)
		-- « Tout effacer » of the Tap-Holds menu, then of the Gestures menu,
		-- switched the feature off, and the next key or gesture the user set did
		-- nothing until the switch was found again.
		for _, case in ipairs({
			{ slug = "tap-hold-clear-keeps-switch", scope = "tap_holds",
				switches = { ["tap_holds.enabled"] = true, ["category_enabled.tap_holds"] = true } },
			{ slug = "gestures-clear-keeps-switch", scope = "gestures", switches = { ["gestures.enabled"] = true } },
		}) do
			helpers.it("(" .. case.slug .. ") a clear leaves the " .. case.scope .. " switch as it is", function()
				local declared = false
				for path in pairs(case.switches) do declared = declared or Manifest.find_entry_by_path(path) ~= nil end
				helpers.assert_true(declared, "this driver's switch is a manifest entry")
				for _, scope in ipairs({ case.scope, "global" }) do
					local restored = false
					for _, row in ipairs(Manifest.scope_plan(scope, "clear", {}).operations) do
						helpers.assert_nil(case.switches[row.section .. "." .. row.key], scope .. " clear rewrites the switch")
					end
					for _, row in ipairs(Manifest.scope_plan(scope, "recommended", {}).operations) do
						restored = restored or case.switches[row.section .. "." .. row.key] == true
					end
					helpers.assert_true(restored, scope .. " restore still switches the feature on")
				end
			end)
		end
		helpers.it("routes separate-file presets for restore and clear without inventing config rows", function()
			for _, mode in ipairs({ "recommended", "clear" }) do
				local plan = Manifest.scope_plan("global", mode, {})
				helpers.assert_eq(plan.scope, "global")
				helpers.assert_eq(plan.mode, mode)
				helpers.assert_eq(plan.presets, { { scope = "tap_holds", preset = "tap_hold", mode = mode } })
				helpers.assert_true(#plan.operations > 100)
				plan.presets[1].preset = "mutated"
				helpers.assert_eq(Manifest.scope_plan("global", mode).presets[1].preset, "tap_hold")
				helpers.assert_eq(#Manifest.scope_plan("gestures", mode).presets, 0)
			end
		end)
	end)
end
