--- _shared/lua/test/layout_composer_contract.lua

--- Exercises a driver's composer operations (docs/layout-composer.md) with the
--- shared composer corpus: what the page may save, the record entry, the
--- stored declaration, the sources sent to the page, the removal, and the
--- messages of the layout manager bridge. The native installation, transport
--- and input-source ports stay controlled by the driver's manager fixture.
return function(helpers, Json, ports)
	local corpus_dir = helpers.driver_root() .. "/../_shared/tests/corpus/layouts/composer/"
	local function corpus(name)
		local handle = assert(io.open(corpus_dir .. name, "rb"))
		local text = handle:read("*a")
		handle:close()
		return text
	end
	local KEYLAYOUT = corpus("composed.keylayout")
	local DECLARATION = corpus("composition.json")
	local FAKE_DIGEST = string.rep("ab", 32)
	local DECLARATION_PATH = ports.config_dir .. "layout_composer/composition.json"

	local function replace_once(text, old, new)
		local first, last = text:find(old, 1, true)
		assert(first, "target not found: " .. old)
		return text:sub(1, first - 1) .. new .. text:sub(last + 1)
	end

	--- A fresh manager whose digest answers for the corpus layout.
	local function fresh(options)
		local registry, deps, state = ports.manager(options or { files = ports.files() })
		deps.config_dir = ports.config_dir
		local digest = deps.transport.sha256
		deps.transport.sha256 = function(text, callback)
			if text == KEYLAYOUT then callback(FAKE_DIGEST, nil) return end
			return digest(text, callback)
		end
		if ports.prepare then ports.prepare(deps, state) end
		return registry, deps, state
	end

	local function saved(registry, deps, payload)
		local result = { calls = 0 }
		registry.composer_save(payload, function(ok, code, detail, used)
			result.calls = result.calls + 1
			result.ok, result.code, result.detail, result.used = ok, code, detail, used
		end, deps)
		helpers.assert_eq(result.calls, 1, "a save settles exactly once")
		return result
	end

	helpers.describe("layout composer (" .. ports.name .. "): saving", function()
		helpers.it("refuses what the compiled layout does not say (layout-composer)", function()
			local registry, deps, state = fresh()
			local refused = {
				["a renamed layout"] = { declaration = DECLARATION, keylayout = replace_once(KEYLAYOUT, "Composer Corpus", "Other") },
				["not a composer product"] = {
					declaration = DECLARATION,
					keylayout = replace_once(KEYLAYOUT, 'mapSet="composed"', 'mapSet="layout"'),
				},
				["a non-text layout"] = { declaration = DECLARATION, keylayout = 5 },
				["bad json"] = { declaration = "{ nope", keylayout = KEYLAYOUT },
				["unknown schema"] = {
					declaration = replace_once(DECLARATION, '"schema_version": 1', '"schema_version": 9'),
					keylayout = KEYLAYOUT,
				},
				["unknown convention"] = {
					declaration = replace_once(DECLARATION, '"iso"', '"jis"'),
					keylayout = KEYLAYOUT,
				},
				["an oversized layout"] = {
					declaration = DECLARATION,
					keylayout = KEYLAYOUT .. string.rep(" ", deps.settings.max_file_bytes),
				},
			}
			for label, payload in pairs(refused) do
				local result = saved(registry, deps, payload)
				helpers.assert_true(not result.ok, label .. " must be refused")
				helpers.assert_eq(result.code, "invalid", label)
			end
			helpers.assert_nil(state.files[DECLARATION_PATH], "nothing is stored")
			helpers.assert_nil(state.files[ports.local_dir .. "installed.json"], "nothing is recorded")
		end)

		helpers.it("stores the declaration and installs a recorded composed layout (layout-composer)", function()
			local registry, deps, state = fresh()
			local result = saved(registry, deps, { declaration = DECLARATION, keylayout = KEYLAYOUT, use = false })
			helpers.assert_true(result.ok, "the save must succeed: " .. tostring(result.detail))
			helpers.assert_eq(result.used, false)
			helpers.assert_eq(state.files[DECLARATION_PATH], DECLARATION, "the declaration is stored as sent")
			helpers.assert_eq(state.files[ports.installed_copy], KEYLAYOUT, "the layout is installed unchanged")
			local entry = Json.decode(state.files[ports.local_dir .. "installed.json"]).layouts.composed
			helpers.assert_eq(entry.sha256, FAKE_DIGEST)
			helpers.assert_eq(entry.size, #KEYLAYOUT)
			helpers.assert_eq(entry.keycode_convention, "iso")
			helpers.assert_eq(entry.name, "Composer Corpus")
			helpers.assert_eq(ports.selections(state), 0, "saving alone selects nothing")

			local used = saved(registry, deps, { declaration = DECLARATION, keylayout = KEYLAYOUT, use = true })
			helpers.assert_true(used.ok, "the second save must succeed: " .. tostring(used.detail))
			helpers.assert_eq(used.used, true)
			helpers.assert_eq(ports.selections(state), 1, "use selects the composed layout")
		end)
	end)

	helpers.describe("layout composer (" .. ports.name .. "): opening and removing", function()
		helpers.it("sends the verified sources and the stored composition (layout-composer)", function()
			local registry, deps = fresh()
			local data
			registry.composer_open(function(payload) data = payload end, deps)
			helpers.assert_true(data ~= nil, "the page gets its data")
			helpers.assert_eq(data.platform, ports.platform)
			helpers.assert_eq(data.shortcuts, ports.shortcuts)
			helpers.assert_eq(data.declaration, nil, "no composition yet")
			local by_id = {}
			for _, source in ipairs(data.sources) do by_id[source.id] = source end
			helpers.assert_true(by_id.ergol ~= nil and by_id.ergopti ~= nil, "the shipped layouts are sources")
			helpers.assert_eq(by_id.composed, nil, "the composition is not its own source")
			helpers.assert_eq(by_id.ergol.convention, "ansi")
			helpers.assert_eq(by_id.ergol.text, ports.registry_text("ergol/ergol.keylayout"))
			saved(registry, deps, { declaration = DECLARATION, keylayout = KEYLAYOUT, use = false })
			registry.composer_open(function(payload) data = payload end, deps)
			helpers.assert_eq(data.declaration, DECLARATION)
			helpers.assert_eq(data.active, false)
		end)

		helpers.it("leaves a layout out of the sources when its checksum is wrong (layout-composer)", function()
			local registry, deps = fresh()
			local digest = deps.transport.sha256
			deps.transport.sha256 = function(text, callback)
				if text == ports.registry_text("ergol/ergol.keylayout") then callback(string.rep("0", 64), nil) return end
				return digest(text, callback)
			end
			local data
			registry.composer_open(function(payload) data = payload end, deps)
			local ids = {}
			for _, source in ipairs(data.sources) do ids[source.id] = true end
			helpers.assert_true(not ids.ergol and ids.ergopti, "only the damaged layout is left out")
		end)

		helpers.it("removes the installed layout and its declaration (layout-composer)", function()
			local registry, deps, state = fresh()
			saved(registry, deps, { declaration = DECLARATION, keylayout = KEYLAYOUT, use = false })
			local result = { calls = 0 }
			registry.composer_remove(function(ok, code, detail)
				result.calls, result.ok, result.code, result.detail = result.calls + 1, ok, code, detail
			end, deps)
			helpers.assert_eq(result.calls, 1)
			helpers.assert_true(result.ok, "the removal must succeed: " .. tostring(result.detail))
			helpers.assert_nil(state.files[DECLARATION_PATH])
			helpers.assert_nil(state.files[ports.installed_copy])
			helpers.assert_eq(Json.decode(state.files[ports.local_dir .. "installed.json"]).layouts.composed, nil)
		end)
	end)

	helpers.describe("layout composer (" .. ports.name .. "): the manager bridge", function()
		helpers.it("routes the three composer messages and pushes their results (layout-composer)", function()
			local ManagerBridge = require("layouts.manager_bridge")
			local registry, deps = fresh()
			local pushed = {}
			local wrapper = {
				snapshot = function() return registry.snapshot(deps) end,
				refresh = function(done) done() end,
				composer_open = function(done) return registry.composer_open(done, deps) end,
				composer_save = function(payload, done) return registry.composer_save(payload, done, deps) end,
				composer_remove = function(done) return registry.composer_remove(done, deps) end,
			}
			local controller = ManagerBridge.new({
				registry = wrapper,
				push = function(name, payload) pushed[#pushed + 1] = { name = name, payload = payload } end,
				strings = function() return {} end,
				open_url = function() end,
				close = function() end,
				log = function() end,
			})
			helpers.assert_true(controller.on_message({ action = "composer_open" }))
			helpers.assert_eq(pushed[#pushed].name, "composerData")
			helpers.assert_true(not controller.on_message({ action = "composer_save", declaration = 5 }), "a save needs text")
			helpers.assert_true(controller.on_message({ action = "composer_save", declaration = DECLARATION,
				keylayout = KEYLAYOUT, use = false }))
			local result
			for _, item in ipairs(pushed) do if item.name == "composerResult" then result = item.payload end end
			helpers.assert_true(result and result.ok, "the save result reaches the page")
			helpers.assert_eq(result.action, "composer_save")
			helpers.assert_true(controller.on_message({ action = "composer_remove" }))
			helpers.assert_eq(pushed[#pushed - 1].name, "composerResult")
			helpers.assert_eq(pushed[#pushed - 1].payload.action, "composer_remove")
			local plain = { snapshot = wrapper.snapshot, refresh = wrapper.refresh }
			local limited = ManagerBridge.new({ registry = plain, push = function() end, strings = function() return {} end,
				open_url = function() end, close = function() end, log = function() end })
			helpers.assert_true(not limited.on_message({ action = "composer_open" }), "a registry without a composer refuses")
		end)
	end)
end
