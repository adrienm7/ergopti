--- _shared/lua/test/scope_sparse_contract.lua

--- Real generated manifests must restore recommendations without storing absence.
return function(helpers)
	local manifest = require("_generated.features_manifest")
	local defaults = require("config_defaults").new(manifest)
	local function rows(scope, mode, owned)
		local indexed = {}
		for _, operation in ipairs(defaults.scope_operations(scope, mode, owned)) do
			indexed[operation.section .. "." .. operation.key] = operation
		end
		return indexed
	end
	helpers.describe("sparse recommended scope operations", function()
		for _, feature in ipairs({ false, true }) do
			helpers.it("deletes neutral " .. (feature and "feature leaves" or "scalar settings") .. " on restore", function()
				local indexed = rows("global", "recommended")
				local neutral, nonneutral = 0, 0
				for _, entry in ipairs(manifest.features) do
					if (entry.type == "feature") == feature then
						local recommendations = feature and entry.recommended or { [false] = entry.recommended }
						for key, value in pairs(recommendations) do
							local path = key and entry.path .. "." .. key or entry.path
							local operation = indexed[path]
							local baseline = defaults.default_for(path)
							if operation and type(value) ~= "table" then
								if value == baseline then
									neutral = neutral + 1
									helpers.assert_eq(operation.delete, true, path)
									helpers.assert_eq(operation.value, nil, path)
								else
									nonneutral = nonneutral + 1
									helpers.assert_eq(operation.delete, nil, path)
									helpers.assert_eq(operation.value, value, path)
								end
							end
						end
					end
				end
				helpers.assert_true(neutral > 0, "exercise real neutral recommendations")
				helpers.assert_true(nonneutral > 0, "retain explicit non-neutral recommendations")
			end)
		end
		helpers.it("keeps runtime-owned dynamic recommendations sparse and scoped", function()
			local owned = { "shortcuts.personal.sparse_probe", "hotstrings.personal.sparse_probe.enabled",
				"hotstrings.personal.sparse_probe.time_activation_seconds", "hotstrings.groups.sparse_probe" }
			local indexed = rows("global", "recommended", owned)
			for i = 1, 3 do
				helpers.assert_eq(indexed[owned[i]].delete, true, owned[i])
				helpers.assert_eq(indexed[owned[i]].value, nil, owned[i])
			end
			helpers.assert_eq(indexed[owned[4]].value, true)
			helpers.assert_eq(indexed[owned[4]].delete, nil)
			helpers.assert_eq(indexed["hotstrings.groups.unowned_probe"], nil)
			local layout = rows("keyboard_layout", "recommended", owned)
			for _, path in ipairs(owned) do helpers.assert_eq(layout[path], nil, path) end
		end)
		helpers.it("retains consent exclusions and explicit deletion during clear", function()
			local indexed = rows("global", "recommended")
			for _, path in ipairs({ "llm.enabled", "metrics.enabled", "metrics.metrics_enabled", "hotstrings.preview_ai_enabled" }) do
				helpers.assert_eq(indexed[path], nil, path)
			end
			-- An entry active by default (the script chords) is the one exception:
			-- its clear writes the declared off value, checked below.
			local cleared = {}
			for _, entry in ipairs(manifest.features) do
				if entry.cleared ~= nil then cleared[entry.path] = entry.cleared end
			end
			for path, operation in pairs(rows("global", "clear", { "shortcuts.personal.sparse_probe" })) do
				if cleared[path] ~= nil then
					helpers.assert_eq(operation.delete, nil, path)
					helpers.assert_eq(operation.value, cleared[path], path)
				else
					helpers.assert_eq(operation.delete, true, path)
					helpers.assert_eq(operation.value, nil, path)
				end
			end
		end)
		-- script-chords-three-os-2026-09-30: an entry active by default restores
		-- its preset when its key is deleted, so a clear that deleted it (the
		-- Shortcuts clear, the global clear) switched the chords back on.
		helpers.it("writes the off value of an entry active by default during clear", function()
			local demo = require("config_defaults").new({
				features = {
					{ path = "demo.chords.slot", type = "action", default = "script_reload",
						recommended = "script_reload", cleared = "none" },
					{ path = "demo.chords.switch", type = "boolean", default = true, recommended = true },
					{ path = "demo.other", type = "action", default = "none", recommended = "script_quit" },
				},
				scopes = { demo = { prefixes = { "demo" }, restore_exclude = {} } },
			})
			local indexed = {}
			for _, operation in ipairs(demo.scope_operations("demo", "clear")) do
				indexed[operation.section .. "." .. operation.key] = operation
			end
			helpers.assert_eq(indexed["demo.chords.slot"].value, "none")
			helpers.assert_eq(indexed["demo.chords.slot"].delete, nil)
			helpers.assert_eq(indexed["demo.chords.switch"].delete, true)
			helpers.assert_eq(indexed["demo.other"].delete, true)
			indexed = {}
			for _, operation in ipairs(demo.scope_operations("demo", "recommended")) do
				indexed[operation.section .. "." .. operation.key] = operation
			end
			helpers.assert_eq(indexed["demo.chords.slot"].delete, true)
			helpers.assert_eq(indexed["demo.other"].value, "script_quit")
		end)
		helpers.it("writes every declared off value in the scopes that own it", function()
			for _, entry in ipairs(manifest.features) do
				if entry.cleared ~= nil then
					for _, scope in ipairs({ "shortcuts", "global" }) do
						local operation = rows(scope, "clear")[entry.path]
						helpers.assert_not_nil(operation, scope .. " " .. entry.path)
						helpers.assert_eq(operation.value, entry.cleared, scope .. " " .. entry.path)
					end
				end
			end
		end)
	end)
end
