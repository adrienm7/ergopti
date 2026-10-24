--- tests/unit/modules/llm/ollama/test_model_delete.lua

--- ==============================================================================
--- MODULE: Linux Ollama Model Delete Tests
--- DESCRIPTION:
--- Proves the removal sends one owned DELETE /api/delete naming the model,
--- publishes its outcome once after the transport settled, refuses a second
--- removal and stays silent for a caller whose admission was revoked.
--- ==============================================================================

local helpers = require("tests.helpers")

local held = {}

local function replace(name, value)
	held[name] = package.loaded[name] or false
	package.loaded[name] = value
end

local function restore()
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
	package.loaded["modules.llm.model_delete"] = nil
end

--- Loads the module over a scripted owned DELETE port.
--- @return table Delete, table transport
local function load_fixture()
	local transport = { deletes = {} }
	package.loaded["infra.llm_bridge"] = nil
	replace("adapters.http_client", {
		delete_owned = function(url, headers, body, options, callback)
			local operation = { started = true, closed = false, cancelled = false, listeners = {} }
			function operation:is_settled() return self.closed end
			function operation:on_settled(listener)
				if self.closed then listener() else self.listeners[#self.listeners + 1] = listener end
				return true
			end
			function operation:settle()
				self.closed = true
				for _, listener in ipairs(self.listeners) do listener() end
			end
			function operation:cancel()
				self.cancelled = true
				if not transport.hold_cancel then self:settle() end
				return self.closed
			end
			if options.authorized() ~= true then
				operation.started, operation.closed = false, true
				return operation
			end
			transport.deletes[#transport.deletes + 1] = { url = url, headers = headers, body = body,
				options = options, callback = callback, operation = operation }
			return operation
		end,
	})
	package.loaded["modules.llm.model_delete"] = nil
	return require("modules.llm.model_delete"), transport
end

--- Runs one scenario and always restores the replaced modules.
--- @param scenario function Receives (Delete, transport).
local function run(scenario)
	local Delete, transport = load_fixture()
	local ok, err = xpcall(function() scenario(Delete, transport) end, debug.traceback)
	restore()
	if not ok then error(err, 0) end
end

helpers.describe("Ollama model delete: owned removal", function()
	helpers.it("linux-model-delete: sends one DELETE /api/delete naming the model and publishes success after settlement", function()
		run(function(Delete, transport)
			local outcomes = {}
			helpers.assert_true(Delete.start("http://127.0.0.1:11434", "qwen:2b",
				function(...) outcomes[#outcomes + 1] = { ... } end))
			helpers.assert_eq(#transport.deletes, 1)
			local sent = transport.deletes[1]
			helpers.assert_eq(sent.url, "http://127.0.0.1:11434/api/delete")
			helpers.assert_eq(require("json").decode(sent.body), { name = "qwen:2b" })
			helpers.assert_eq(sent.headers["Content-Type"], "application/json")
			helpers.assert_eq(sent.options.owner, "ollama_model_delete")
			helpers.assert_true(sent.options.timeout_ms > 0)
			sent.callback({ ok = true, status = 200, body = "" })
			helpers.assert_eq(#outcomes, 0, "a result is published only once the transport settled")
			helpers.assert_true(Delete.is_active())
			sent.operation:settle()
			helpers.assert_eq(outcomes, { { true, "qwen:2b" } })
			helpers.assert_eq(Delete.is_active(), false)
		end)
	end)

	helpers.it("linux-model-delete: names the error Ollama answered when the model was not removed", function()
		run(function(Delete, transport)
			local outcomes = {}
			helpers.assert_true(Delete.start("http://127.0.0.1:11434", "qwen:2b",
				function(...) outcomes[#outcomes + 1] = { ... } end))
			transport.deletes[1].operation:settle()
			helpers.assert_eq(#outcomes, 0, "settlement alone waits for the result")
			transport.deletes[1].callback({ ok = false, status = 404, body = '{"error":"model \'qwen:2b\' not found"}' })
			helpers.assert_eq(outcomes, { { false, "qwen:2b", "model 'qwen:2b' not found" } })
		end)
	end)

	helpers.it("linux-model-delete: refuses a second removal while one runs and an unusable tag before any request", function()
		run(function(Delete, transport)
			helpers.assert_true(Delete.start("http://127.0.0.1:11434", "qwen:2b", function() end))
			helpers.assert_eq(Delete.start("http://127.0.0.1:11434", "other:1b", function() end), false)
			helpers.assert_eq(#transport.deletes, 1)
			transport.deletes[1].callback({ ok = true, status = 200, body = "" })
			transport.deletes[1].operation:settle()
			helpers.assert_eq(Delete.start("http://127.0.0.1:11434", "bad tag;rm", function() end), false)
			helpers.assert_eq(Delete.start("not an origin", "qwen:2b", function() end), false)
			helpers.assert_eq(#transport.deletes, 1)
		end)
	end)

	helpers.it("linux-model-delete: never sends or answers for a caller whose admission was revoked", function()
		run(function(Delete, transport)
			local outcomes = 0
			helpers.assert_eq(Delete.start("http://127.0.0.1:11434", "qwen:2b",
				function() outcomes = outcomes + 1 end, function() return false end), false)
			helpers.assert_eq(#transport.deletes, 0, "a stale menu click sends no DELETE")
			local current = true
			helpers.assert_true(Delete.start("http://127.0.0.1:11434", "qwen:2b",
				function() outcomes = outcomes + 1 end, function() return current end))
			current = false
			transport.deletes[1].callback({ ok = true, status = 200, body = "" })
			transport.deletes[1].operation:settle()
			helpers.assert_eq(outcomes, 0, "a revoked caller is never answered")
			helpers.assert_eq(Delete.is_active(), false)
		end)
	end)

	helpers.it("linux-model-delete: cancel waits for the physical settlement and publishes nothing", function()
		run(function(Delete, transport)
			local outcomes = 0
			transport.hold_cancel = true
			helpers.assert_true(Delete.start("http://127.0.0.1:11434", "qwen:2b", function() outcomes = outcomes + 1 end))
			helpers.assert_eq(Delete.cancel(), false, "a cancelled transport still owns its process")
			helpers.assert_true(transport.deletes[1].operation.cancelled)
			helpers.assert_true(Delete.is_active())
			transport.deletes[1].callback({ ok = true, status = 200, body = "" })
			transport.deletes[1].operation:settle()
			helpers.assert_eq(outcomes, 0)
			helpers.assert_eq(Delete.is_active(), false)
			helpers.assert_true(Delete.cancel())
		end)
	end)
end)
