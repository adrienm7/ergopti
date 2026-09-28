--- tests/unit/infra/test_llm_platform_defaults.lua

--- Exercises hardware defaults through the real reader and preference writer.
local helpers = require("tests.helpers")
local Codec = require("toml_codec")

helpers.describe("LLM hardware defaults", function()
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
