--- tests/unit/ui/menu/menu_llm/test_models_manager_requirement_capabilities.lua

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger",
	"ui.menu.menu_llm.requirement_operation_registry",
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
		package.loaded["ui.menu.menu_llm.requirement_operation_registry"] = nil
		local backend_name = "mlx"
		local records = { mlx = {}, ollama = {} }
		local function manager_for(name)
			local record = records[name]
			local manager = {}
			record.registry = require("ui.menu.menu_llm.requirement_operation_registry").new({ backend = name, require_owned = true })
			function manager.create_requirement_owner(label)
				local capability = record.registry.create_owner(label)
				capability.backend, capability.label = name, label
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

helpers.describe("ModelsManager exact original settlement observations (issue94)", function()
	helpers.it("waits for both original backends and never consumes native custody" .. " (issue94)", function()
		with_fixture(function(f)
			local public = f.manager.create_requirement_owner("startup")
			local operations, children = {}, {}
			for _, backend in ipairs({ "mlx", "ollama" }) do
				local record = f.records[backend]
				operations[backend] = assert(record.registry.begin(record.created[1]))
				children[backend] = {}
				assert(operations[backend].lifecycle.adopt(children[backend], function() return false end))
				assert(operations[backend].finish())
			end
			local called = 0
			local lease, committed = f.manager.when_requirements_settled(public, function() called = called + 1 end)
			helpers.assert_true(committed)
			helpers.assert_eq(called, 0)
			helpers.assert_true(operations.mlx.lifecycle.settle(children.mlx))
			helpers.assert_eq(called, 0)
			helpers.assert_true(operations.ollama.lifecycle.settle(children.ollama))
			helpers.assert_eq(called, 1)
			helpers.assert_true(lease.cancel())
			helpers.assert_eq(called, 1)
		end)
	end)

	helpers.it("cancels both snapshots and refuses foreign authority" .. " (issue94)", function()
		with_fixture(function(f)
			local public = f.manager.create_requirement_owner("startup")
			local record = f.records.mlx
			local operation = assert(record.registry.begin(record.created[1]))
			local child = {}
			assert(operation.lifecycle.adopt(child, function() return false end))
			assert(operation.finish())
			local called = 0
			local lease, committed = f.manager.when_requirements_settled(public, function() called = called + 1 end)
			helpers.assert_true(committed)
			helpers.assert_true(lease.cancel())
			helpers.assert_true(operation.lifecycle.settle(child))
			helpers.assert_eq(called, 0)
			local refused, admitted = f.manager.when_requirements_settled({}, function() called = called + 1 end)
			helpers.assert_eq(refused, nil)
			helpers.assert_eq(admitted, false)
		end)
	end)
end)

helpers.describe("ModelsManager settlement admission boundaries (issue94)", function()
	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("cancels an admitted first snapshot when the second registration " .. mode .. " (issue94)", function()
			with_fixture(function(f)
				local public = f.manager.create_requirement_owner("startup")
				local record = f.records.mlx
				local operation = assert(record.registry.begin(record.created[1]))
				local child = {}
				assert(operation.lifecycle.adopt(child, function() return false end))
				assert(operation.finish())
				local Registry = require("ui.menu.menu_llm.requirement_operation_registry")
				local observe = Registry.when_owner_settled
				Registry.when_owner_settled = function(capability, callback)
					if capability == f.records.ollama.created[1] then
						if mode == "throw" then error("second registration failed") end
						return nil, false
					end
					return observe(capability, callback)
				end
				local calls = 0
				local lease, committed = f.manager.when_requirements_settled(public, function() calls = calls + 1 end)
				helpers.assert_eq(lease, nil)
				helpers.assert_eq(committed, false)
				helpers.assert_true(operation.lifecycle.settle(child))
				helpers.assert_eq(calls, 0)
			end)
		end)
	end

	helpers.it("isolates a throwing public observer without changing terminal authority" .. " (issue94)", function()
		with_fixture(function(f)
			local public = f.manager.create_requirement_owner("startup")
			local lease, committed = f.manager.when_requirements_settled(public, function()
				error("public settlement exception")
			end)
			helpers.assert_true(committed)
			helpers.assert_true(lease.cancel())
			local calls = 0
			local next_lease, next_committed = f.manager.when_requirements_settled(public, function()
				calls = calls + 1
				helpers.assert_true(f.manager.pause_requirements(public))
			end)
			helpers.assert_true(next_committed)
			helpers.assert_eq(calls, 1)
			helpers.assert_true(next_lease.cancel())
		end)
	end)
end)

helpers.describe("RequirementRegistry passive exact snapshots (issue94)", function()
	local function with_registry(callback)
		helpers.with_fresh_modules({ "infra.logger", "ui.menu.menu_llm.requirement_operation_registry" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local Registry = require("ui.menu.menu_llm.requirement_operation_registry")
			callback(Registry.new({ backend = "mlx", require_owned = true }), Registry)
		end)
	end

	helpers.it("requires logical terminal and every exact child before notifying" .. " (issue94)", function()
		with_registry(function(registry)
			local capability = registry.create_owner("startup")
			local operation = assert(registry.begin(capability))
			local first, second = {}, {}
			assert(operation.lifecycle.adopt(first, function() return false end))
			assert(operation.lifecycle.adopt(second, function() return false end))
			local calls = 0
			local lease, committed = registry.when_settled(capability, function() calls = calls + 1 end)
			helpers.assert_true(committed)
			helpers.assert_true(operation.lifecycle.settle(first))
			helpers.assert_eq(calls, 0)
			helpers.assert_true(operation.finish())
			helpers.assert_eq(calls, 0)
			helpers.assert_true(operation.lifecycle.settle(second))
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(operation.lifecycle.settle(second), false)
			helpers.assert_true(lease.cancel())
			helpers.assert_eq(calls, 1)
		end)
	end)

	helpers.it("unregisters without cancelling descendants or borrowing a successor" .. " (issue94)", function()
		with_registry(function(registry)
			local capability = registry.create_owner("startup")
			local original = assert(registry.begin(capability))
			local child, pauses = {}, 0
			assert(original.lifecycle.adopt(child, function() pauses = pauses + 1; return false end))
			local calls = 0
			local cancelled = assert(registry.when_settled(capability, function() error("cancelled observer") end))
			helpers.assert_true(cancelled.cancel())
			helpers.assert_true(cancelled.cancel())
			local successor = assert(registry.begin(capability))
			assert(registry.when_settled(capability, function() calls = calls + 1 end))
			helpers.assert_true(original.finish())
			helpers.assert_true(original.lifecycle.settle(child))
			helpers.assert_eq(calls, 0, "the captured sibling must also retire")
			helpers.assert_true(successor.finish())
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(pauses, 0, "observation cannot cancel native work")
		end)
	end)

	helpers.it("never waits on a future same-capability operation (issue94)", function()
		with_registry(function(registry, Registry)
			local capability = registry.create_owner("startup")
			local original = assert(registry.begin(capability))
			local child = {}
			assert(original.lifecycle.adopt(child, function() return false end))
			local calls = 0
			assert(registry.when_settled(capability, function() calls = calls + 1 end))
			local successor = assert(registry.begin(capability))
			helpers.assert_true(original.finish())
			helpers.assert_true(original.lifecycle.settle(child))
			helpers.assert_eq(calls, 1, "only the original snapshot may authorize its cleanup handoff")
			helpers.assert_eq(Registry.backend_idle("mlx"), false)
			helpers.assert_true(successor.finish())
			helpers.assert_eq(calls, 1)
			helpers.assert_true(Registry.backend_idle("mlx"))
		end)
	end)

	helpers.it("isolates throwing observers and permits exact reentrant settlement" .. " (issue94)", function()
		with_registry(function(registry)
			local capability = registry.create_owner("startup")
			local original = assert(registry.begin(capability))
			local child = {}
			assert(original.lifecycle.adopt(child, function() return false end))
			assert(original.finish())
			local calls = 0
			assert(registry.when_settled(capability, function() error("observer exception") end))
			assert(registry.when_settled(capability, function()
				calls = calls + 1
				helpers.assert_eq(original.lifecycle.settle(child), false)
				local successor = assert(registry.begin(capability))
				helpers.assert_true(successor.finish())
			end))
			helpers.assert_true(original.lifecycle.settle(child))
			helpers.assert_eq(calls, 1)
		end)
	end)

	helpers.it("refuses foreign capabilities and notifies an idle original inline once" .. " (issue94)", function()
		with_registry(function(registry, Registry)
			local calls = 0
			local foreign, accepted = Registry.when_owner_settled({}, function() calls = calls + 1 end)
			helpers.assert_eq(foreign, nil)
			helpers.assert_eq(accepted, false)
			local capability = registry.create_owner("startup")
			local lease, committed = Registry.when_owner_settled(capability, function() calls = calls + 1 end)
			helpers.assert_true(committed)
			helpers.assert_eq(calls, 1)
			helpers.assert_true(lease.cancel())
			local successor = assert(registry.begin(capability))
			helpers.assert_true(successor.finish())
			helpers.assert_eq(calls, 1)
		end)
	end)
end)
