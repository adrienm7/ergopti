--- tests/unit/ui/menu/menu_llm/test_models_manager_requirement_capabilities.lua

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger",
	"infra.dialog_util",
	"infra.i18n",
	"infra.paths",
	"modules.llm",
	"ui.menu.menu_llm.models_manager_mlx",
	"ui.menu.menu_llm.models_manager_ollama",
	"ui.menu.menu_llm.models_manager",
}

local function with_fixture(callback)
	local saved_hs = _G.hs
	local saved_open = io.open
	local saved_modules = {}
	for _, name in ipairs(MODULES) do saved_modules[name] = package.loaded[name] end
	local outcome = table.pack(xpcall(function()
		local backend_name = "mlx"
		local records = { mlx = {}, ollama = {} }
		local function manager_for(name)
			local record = records[name]
			local manager = {}
			function manager.create_requirement_owner(label)
				local capability = { backend = name, label = label }
				record.created = record.created or {}
				record.created[#record.created + 1] = capability
				return capability
			end
			function manager.check_requirements(_, _, _, opts)
				record.last_requirement_owner = opts and opts.requirement_owner
				return true
			end
			function manager.pause_requirements(capability)
				record.pause_calls = (record.pause_calls or 0) + 1
				record.last_paused = capability
				if record.pause_mode == "throw" then error(name .. " pause") end
				if record.pause_mode == "false" then return false, true end
				if record.pause_mode == "nil" then return nil, true end
				return true, record.had == true
			end
			manager.get_installed_models = function() return {} end
			manager.delete_model = function() return true end
			manager.get_mlx_repo = function(value) return value end
			if name == "mlx" then
				manager.reattach_download = function(session, opts)
					record.reattach_session = session
					record.reattach_opts = opts
					return true
				end
				manager.has_reattached_download = function()
					record.probe_calls = (record.probe_calls or 0) + 1
					return true
				end
				manager.pause_reattached_download = function()
					record.reattach_pause_calls =
						(record.reattach_pause_calls or 0) + 1
					return true
				end
				manager.resume_reattached_download = function(opts)
					record.reattach_resume_opts = opts
					return true
				end
			end
			return manager
		end

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.paths"] = {
			shared_llm_path = function() return "/fixture/models.json" end,
		}
		package.loaded["modules.llm"] = {
			get_backend = function() return backend_name end,
		}
		package.loaded["ui.menu.menu_llm.models_manager_mlx"] = {
			new = function() return manager_for("mlx") end,
		}
		package.loaded["ui.menu.menu_llm.models_manager_ollama"] = {
			new = function() return manager_for("ollama") end,
		}
		_G.hs = {
			json = { decode = function() return {{ families = {} }} end },
			execute = function() return "" end,
			timer = { doAfter = function() return true end },
		}
		io.open = function()
			return {
				read = function() return "fixture" end,
				close = function() return true end,
			}
		end

		local manager = require("ui.menu.menu_llm.models_manager").new({})
		callback({
			manager = manager,
			records = records,
			set_backend = function(value) backend_name = value end,
		})
	end, debug.traceback))
	_G.hs = saved_hs
	io.open = saved_open
	for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("ModelsManager backend-agnostic requirement capabilities", function()
	helpers.it("maps one public owner to distinct backend-local capabilities", function()
		with_fixture(function(fixture)
			local capability = fixture.manager.create_requirement_owner("startup")
			helpers.assert_true(type(capability) == "table")
			helpers.assert_eq(fixture.records.mlx.created[1].label, "startup:mlx")
			helpers.assert_eq(fixture.records.ollama.created[1].label, "startup:ollama")

			helpers.assert_true(fixture.manager.check_requirements("model", nil, nil, {
				requirement_owner = capability,
			}))
			helpers.assert_eq(fixture.records.mlx.last_requirement_owner,
				fixture.records.mlx.created[1])
			fixture.set_backend("ollama")
			helpers.assert_true(fixture.manager.check_requirements("model", nil, nil, {
				requirement_owner = capability,
			}))
			helpers.assert_eq(fixture.records.ollama.last_requirement_owner,
				fixture.records.ollama.created[1])
		end)
	end)

	helpers.it("joins both backends even when the first pause raises", function()
		with_fixture(function(fixture)
			local capability = fixture.manager.create_requirement_owner("model")
			fixture.records.mlx.pause_mode = "throw"
			fixture.records.ollama.had = true
			local settled, had = fixture.manager.pause_requirements(capability)
			helpers.assert_eq(settled, false)
			helpers.assert_true(had)
			helpers.assert_eq(fixture.records.mlx.pause_calls, 1)
			helpers.assert_eq(fixture.records.ollama.pause_calls, 1)
			helpers.assert_eq(fixture.records.mlx.last_paused,
				fixture.records.mlx.created[1])
			helpers.assert_eq(fixture.records.ollama.last_paused,
				fixture.records.ollama.created[1])
		end)
	end)

	helpers.it("fails closed for foreign public capabilities", function()
		with_fixture(function(fixture)
			local settled, had = fixture.manager.pause_requirements({})
			helpers.assert_eq(settled, false)
			helpers.assert_eq(had, false)
			helpers.assert_eq(fixture.records.mlx.pause_calls, nil)
			helpers.assert_eq(fixture.records.ollama.pause_calls, nil)
		end)
	end)

	helpers.it("forwards the exact MLX reattachment lifecycle through the facade", function()
		with_fixture(function(fixture)
			local session = { pid = 42 }
			local opts = { generation = 7 }
			helpers.assert_true(fixture.manager.reattach_download(session, opts))
			helpers.assert_eq(fixture.records.mlx.reattach_session, session)
			helpers.assert_eq(fixture.records.mlx.reattach_opts, opts)
			helpers.assert_true(fixture.manager.has_reattached_download())
			helpers.assert_eq(fixture.records.mlx.probe_calls, 1)
			helpers.assert_true(fixture.manager.pause_reattached_download())
			helpers.assert_eq(fixture.records.mlx.reattach_pause_calls, 1)
			helpers.assert_true(fixture.manager.resume_reattached_download(opts))
			helpers.assert_eq(fixture.records.mlx.reattach_resume_opts, opts)
			helpers.assert_eq(fixture.records.ollama.reattach_session, nil,
				"MLX session ownership must never route through the active backend")
		end)
	end)
end)
