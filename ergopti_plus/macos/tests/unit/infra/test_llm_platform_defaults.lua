--- tests/unit/infra/test_llm_platform_defaults.lua

--- Exercises hardware defaults through the real reader and preference writer.
local helpers = require("tests.helpers")
local Codec = require("toml_codec")

helpers.describe("LLM hardware defaults", function()
	helpers.it("does not probe hardware for metadata or unrelated configuration values", function()
		package.loaded["modules.llm.backend_detector"], package.loaded["infra.manifest_reader"] = nil, nil
		local probes = 0
		local manifest = helpers.load_with_stubs("infra.manifest_reader", { execute = function()
			probes = probes + 1; return "arm64"
		end })
		manifest.coverage_gaps()
		manifest.version()
		manifest.scopes()
		manifest.has_default("llm.models.selected")
		manifest.default_for("metrics.enabled")
		manifest.recommended_for("gestures.enabled")
		manifest.sparse_operation("metrics.enabled", false)
		manifest.scope_plan("metrics", "clear")
		helpers.assert_eq(probes, 0)
		manifest.default_for("llm.models.selected")
		helpers.assert_true(probes > 0)
		local count = probes
		manifest.scope_plan("llm", "recommended")
		manifest.document_defaults()
		helpers.assert_eq(probes, count, "one resolved owner is reused by every projection")
	end)
	helpers.it("resolves each backend value projection through the existing hardware owner", function()
		local saved = package.loaded["modules.llm.backend_detector"]
		local projections = {
			function(m) m.default_for("llm.models.selected") end,
			function(m) m.recommended_for("llm.models.selected") end,
			function(m) m.sparse_operation("llm.models.selected", "ollama") end,
			function(m) m.scope_operations("llm", "recommended") end,
			function(m) m.scope_plan("global", "clear") end,
			function(m) m.document_defaults() end,
			function(m) m.features() end,
			function(m) m.find_entry_by_path("llm.models.selected") end,
		}
		local ok, err = pcall(function()
			for index, project in ipairs(projections) do
				local calls = 0
				package.loaded["modules.llm.backend_detector"] = { auto_default = function()
					calls = calls + 1; return "ollama"
				end }
				package.loaded["infra.manifest_reader"] = nil
				local manifest = require("infra.manifest_reader")
				helpers.assert_eq(calls, 0)
				project(manifest)
				helpers.assert_eq(calls, 1, "projection " .. index)
				helpers.assert_eq(manifest.default_for("llm.models.selected"), "ollama")
				helpers.assert_eq(calls, 1)
			end
		end)
		package.loaded["modules.llm.backend_detector"] = saved
		package.loaded["infra.manifest_reader"] = nil
		if not ok then error(err, 0) end
	end)
	for _, case in ipairs({ { "x86_64", "ollama", "14.5" }, { "arm64", "mlx", "14.5" }, { "arm64", "ollama", "12.0" } }) do
		helpers.it("keeps bootstrap, scoped deletion and sparse persistence coherent on " .. case[1] .. "/" .. case[3], function()
			package.loaded["modules.llm.backend_detector"] = nil
			package.loaded["infra.manifest_reader"] = nil
			local prefs = helpers.load_with_stubs("infra.preferences", { execute = function(command) if command:find("sw_vers", 1, true) then return case[3] end; return case[1] end })
			local manifest = require("infra.manifest_reader")
			local menu = require("ui.menu.menu_llm")
			helpers.assert_eq(menu.DEFAULT_STATE.llm_backend, case[2])
			helpers.assert_eq(manifest.default_for("llm.models.selected"), case[2])
			helpers.assert_eq(manifest.recommended_for("llm.models.selected"), case[2])
			helpers.assert_eq(manifest.sparse_operation("llm.models.selected", case[2]).delete, true)
			for _, mode in ipairs({ "clear", "recommended" }) do
				local found = false
				for _, row in ipairs(manifest.scope_operations("llm", mode)) do
					if row.section == "llm.models" and row.key == "selected" then
						found = true
						helpers.assert_eq(row.delete, true)
					end
				end
				helpers.assert_eq(found, true)
			end
			local content = '[llm.models]\nselected = "api:old"\nfuture = 7\n'
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return content, "ok" end,
				write_if_unchanged = function(_, value, expected)
					if expected.content ~= content then return false end
					content = value; return true
				end,
			}
			prefs = helpers.load_with_stubs("infra.preferences", { execute = function(command) if command:find("sw_vers", 1, true) then return case[3] end; return case[1] end })
			local state = prefs.load("config")
			state.llm_backend = case[2]
			helpers.assert_eq(prefs.save("config", state, {}, {}), true)
			local disk = Codec.decode(content)
			helpers.assert_nil(disk.llm.models.selected)
			helpers.assert_eq(disk.llm.models.future, 7)
		end)
	end
end)
