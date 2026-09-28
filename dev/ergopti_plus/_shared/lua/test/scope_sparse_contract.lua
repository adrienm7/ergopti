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
			for _, operation in pairs(rows("global", "clear", { "shortcuts.personal.sparse_probe" })) do
				helpers.assert_eq(operation.delete, true)
				helpers.assert_eq(operation.value, nil)
			end
		end)
	end)
end
