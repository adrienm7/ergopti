--- tests/unit/ui/menu/menu_llm/test_ollama_migration_requirement_admission.lua
--- Drives the unchanged requirement mutators and same original child identities.
local helpers = require("tests.helpers")
local function with_registry(callback)
	helpers.with_fresh_modules({ "ui.menu.menu_llm.requirement_operation_registry" }, function()
		callback(require("ui.menu.menu_llm.requirement_operation_registry"))
	end)
end

helpers.describe("Read-only joined model migration admission", function()
	helpers.it("(ollama-migration-operation) logical terminal alone cannot release a retained original child", function()
		with_registry(function(Registry)
			local registry = Registry.new({ backend = "Ollama", require_owned = true })
			local capability = assert(registry.create_owner("migration receiving"))
			local operation = assert(registry.begin(capability))
			local child, attempts = {}, 0
			helpers.assert_true(operation.lifecycle.adopt(child, function() attempts = attempts + 1; return false end))
			helpers.assert_eq(Registry.backend_idle("Ollama"), false)
			helpers.assert_true(operation.finish(nil, "fixture logical completion"))
			helpers.assert_eq(Registry.backend_idle("Ollama"), false)
			helpers.assert_eq(attempts, 0)
			helpers.assert_true(operation.lifecycle.settle(child))
			helpers.assert_true(Registry.backend_idle("Ollama"))
		end)
	end)

	helpers.it("(ollama-migration-pause-debt) original failed pause retains debt through registry GC", function()
		with_registry(function(Registry)
			local registry = Registry.new({ backend = "Ollama", require_owned = true })
			local capability = assert(registry.create_owner("migration pause receiving"))
			local operation = assert(registry.begin(capability))
			local child, attempts = {}, 0
			helpers.assert_true(operation.lifecycle.adopt(child, function() attempts = attempts + 1; return false end))
			helpers.assert_eq(registry.pause(capability), false)
			registry, capability = nil, nil
			collectgarbage("collect")
			helpers.assert_eq(Registry.backend_idle("Ollama"), false)
			helpers.assert_eq(attempts, 1, "read-only query cannot signal the exact child again")
			helpers.assert_true(operation.lifecycle.settle(child))
			helpers.assert_true(Registry.backend_idle("Ollama"))
		end)
	end)
end)
