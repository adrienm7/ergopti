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
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/config_scope/plan_vectors.json"), "rb"))
	local corpus = assert(require("json").decode(file:read("*a")))
	file:close()
	assert(#corpus.stored_paths == 5 and #corpus.inventories == 4 and #corpus.refusals == 6
		and #corpus.declaration_plans == 2 and #corpus.declaration_refusals == 3 and #corpus.declaration_cycles == 1
		and #corpus.inventory_collections == 1 and #corpus.inventory_refusals == 5,
		"plan_vectors.json must hold the vectors the contract replays")
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
			local paths = corpus.stored_paths
			for _, selected in ipairs(corpus.inventories) do
				local inventory = Manifest.scope_inventory(selected.scope, { actions = function() return paths end }, owners)
				helpers.assert_eq(#inventory, selected.inventory_count)
				for _, mode in ipairs({ "clear", "recommended" }) do
					local plan = Manifest.scope_plan(selected.scope, mode, paths, owners)
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
			for _, refusal in ipairs(corpus.refusals) do
				local path = refusal.path
				helpers.assert_eq(pcall(Manifest.scope_plan, "gestures", "clear", { path }, owners), false, path)
				helpers.assert_eq(pcall(Manifest.scope_inventory, "gestures", { actions = function() return { path } end }, owners), false, path)
			end
			local path = "action_parameters.gesture__tap_4__open_url"
			helpers.assert_eq(pcall(Manifest.scope_plan, "gestures", "clear", { path }), false)
			helpers.assert_eq(pcall(Manifest.scope_plan, "gestures", "clear", { path }, {
				action_parameter_domain = function() error("owner unavailable") end,
			}), false)
		end)
		--- Providers of a vector as the functions scope_inventory calls.
		local function providers_of(vector)
			local providers, calls = {}, { count = 0 }
			for _, provider in ipairs(vector.providers) do
				if provider.raises then
					providers[provider.name] = function() error("runtime inventory unavailable") end
				elseif provider.not_a_function then
					providers[provider.name] = false
				else
					providers[provider.name] = function() calls.count = calls.count + 1; return provider.paths end
				end
			end
			return providers, calls
		end
		for _, vector in ipairs(corpus.inventory_collections) do
			helpers.it("(config-scope-plan) " .. vector.id, function()
				helpers.assert_not_nil(Manifest.find_entry_by_path("gestures.enabled"))
				local providers, calls = providers_of(vector)
				local owned = Manifest.scope_inventory(vector.scope, providers)
				helpers.assert_eq(calls.count, vector.expect.calls)
				helpers.assert_eq(owned, vector.expect.owned)
				local plan = Manifest.scope_plan(vector.scope, "clear", owned)
				local indexed = {}
				for _, row in ipairs(plan.operations) do
					local segments = assert(require("toml_codec.key_path").parse(row.section))
					indexed[table.concat(segments, ".") .. "." .. row.key] = row
				end
				if vector.expect.clear_deletes_every_owned_path then
					for _, path in ipairs(owned) do helpers.assert_eq(indexed[path].delete, true) end
				end
				for path, section in pairs(vector.expect.section_of) do helpers.assert_eq(indexed[path].section, section) end
				for _, path in ipairs(vector.expect.no_row_for) do helpers.assert_eq(indexed[path], nil) end
			end)
		end
		for _, vector in ipairs(corpus.inventory_refusals) do
			helpers.it("(config-scope-plan) refuses incomplete inventory: " .. vector.id, function()
				local providers = providers_of(vector)
				helpers.assert_eq(pcall(Manifest.scope_inventory, vector.scope, providers), false)
			end)
		end
		helpers.it("refuses a sparse or named path list instead of returning a partial successful plan", function()
			helpers.assert_type(Manifest.scope_inventory, "function")
			for _, paths in ipairs({ { [1] = "hotstrings.groups.valid", [3] = "hotstrings.groups.hole" },
				{ named = "hotstrings.groups.valid" } }) do
				helpers.assert_eq(pcall(Manifest.scope_inventory, "hotstrings", { runtime = function() return paths end }), false)
			end
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
		-- Direct scope owners participate once alongside included native owners.
		helpers.it("plans global's declared rows without acquiring included presets or settings", function()
			local declarations = Manifest.scopes().global
			local expected = {}
			for _, entry in ipairs(Manifest.features()) do
				for _, prefix in ipairs(declarations.prefixes or {}) do
					if entry.path == prefix or entry.path:sub(1, #prefix + 1) == prefix .. "." then
						expected[entry.path] = true
					end
				end
			end
			for _, mode in ipairs({ "recommended", "clear" }) do
				local plan = Manifest.direct_scope_plan("global", mode, {})
				helpers.assert_eq(plan.scope, "global")
				helpers.assert_eq(plan.mode, mode)
				helpers.assert_eq(plan.presets, {})
				helpers.assert_eq(plan.operations, Manifest.direct_scope_operations("global", mode, {}))
				local actual = {}
				for _, operation in ipairs(plan.operations) do
					local path = operation.section .. "." .. operation.key
					helpers.assert_eq(expected[path], true, "included row escaped direct scope: " .. path)
					actual[path] = true
				end
				helpers.assert_eq(actual, expected)
				helpers.assert_eq(#Manifest.scope_plan("global", mode, {}).presets, 1)
			end
		end)
		if Manifest.resolves_platform_defaults == true then
			helpers.it("does not resolve an included native backend for direct planning", function()
				local name = "modules.llm.backend_detector"
				local previous, calls = package.loaded[name], 0
				package.loaded[name] = { auto_default = function() calls = calls + 1; return "llama_cpp" end }
				local ok, err = pcall(function()
					local reader = assert(loadfile(helpers.driver_root() .. "infra/manifest_reader.lua"))()
					reader.direct_scope_plan("global", "clear")
					reader.direct_scope_operations("global", "recommended")
					helpers.assert_eq(calls, 0, "direct script planning invoked the included AI owner")
					reader.scope_plan("global", "clear")
					helpers.assert_eq(calls, 1, "recursive planning must still resolve the included backend")
				end)
				package.loaded[name] = previous
				if not ok then error(err) end
			end)
		end
		for _, vector in ipairs(corpus.declaration_plans) do
			helpers.it("(config-scope-plan) " .. vector.id, function()
				local contract = require("config_defaults").new(vector.declaration)
				local plan = contract.direct_scope_plan(vector.scope, vector.mode, vector.paths, owners)
				helpers.assert_eq(plan.presets, vector.expect.direct_presets)
				local rows = {}
				for _, operation in ipairs(plan.operations) do rows[operation.section .. "." .. operation.key] = operation end
				for _, path in ipairs(vector.expect.absent) do helpers.assert_eq(rows[path], nil, path) end
				for _, path in ipairs(vector.expect.deleted) do helpers.assert_eq(rows[path].delete, true, path) end
				for _, path in ipairs(vector.expect.restored_not_deleted or {}) do
					helpers.assert_eq(rows[path].delete, nil, path)
				end
				for path, value in pairs(vector.expect.set or {}) do helpers.assert_eq(rows[path].value, value, path) end
				helpers.assert_eq(#contract.scope_plan(vector.scope, vector.mode, vector.paths, owners).presets,
					vector.expect.scope_preset_count)
			end)
		end
		for _, vector in ipairs(corpus.declaration_refusals) do
			helpers.it("(config-scope-plan) refuses a direct plan: " .. vector.id, function()
				local contract = require("config_defaults").new(vector.declaration)
				helpers.assert_eq(pcall(contract.direct_scope_plan, vector.scope, vector.mode, vector.paths,
					vector.with_owners and owners or nil), false)
			end)
		end
		helpers.it("hands out a detached plan on every call", function()
			local vector = corpus.declaration_plans[1]
			local contract = require("config_defaults").new(vector.declaration)
			local plan = contract.direct_scope_plan(vector.scope, vector.mode, vector.paths, owners)
			plan.presets[1].preset = "foreign"
			helpers.assert_eq(contract.direct_scope_plan(vector.scope, vector.mode, vector.paths, owners).presets[1].preset, "own_file")
		end)
		for _, vector in ipairs(corpus.declaration_cycles) do
			helpers.it("(config-scope-plan) " .. vector.id, function()
				local contract = require("config_defaults").new(vector.declaration)
				helpers.assert_eq(#contract.direct_scope_plan(vector.scope, vector.mode).operations, vector.expect.direct_operations)
				helpers.assert_eq(pcall(contract.scope_plan, vector.scope, vector.mode), not vector.expect.full_plan_refused)
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
