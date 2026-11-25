--- _shared/tests/lua/workflows/workflow_editor_host_contract.lua

--- ==============================================================================
--- MODULE: User Workflows Editor Host Contract
--- DESCRIPTION:
--- Drives the shared host of the « Workflows personnalisés… » window over the
--- owner contract's in-memory config folder on the macOS and Linux runtimes:
--- its first data and strings, a save the model accepts or refuses, a test
--- run's step and end pushes, an import stamped « import » whatever its file
--- says, the approval of its shell steps, an export without approvals, a
--- picked PNG and the close.
---
--- ROOT CAUSE ENCODED:
--- The workflow window had no host: nothing saved, ran, imported or exported a
--- workflow, and an import could have claimed to be local.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Model = require("shortcuts.engine.workflows.model")
local OwnerContract = require("tests.lua.workflows.workflow_owner_contract")

local M = {}

--- @param shared_path function
--- @param relative string
--- @return table
local function load_json(shared_path, relative)
	local file = assert(io.open(shared_path(relative), "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return assert(Json.decode(text), relative)
end

--- Registers the host checks.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
function M.register(helpers, shared_path)
	local catalogue = load_json(shared_path, Model.CATALOGUE_PATH)
	local vocabulary = load_json(shared_path, "shortcuts/data/actions/send_keys.json")
	local harness, file_of = OwnerContract.harness, OwnerContract.file_of

	helpers.describe("workflows: editor host", function()
		helpers.it("workflows: the editor host saves, test-runs, approves, imports and exports", function()
			local EditorHost = require("shortcuts.engine.workflows.editor_host")
			local owner, world = harness(catalogue, vocabulary, {})
			local pushed, closed = {}, false
			local picked = { save = "/out/export.json", open = "/in/import.json" }
			world.files["/in/import.json"] = file_of({ { kind = "shell", command = "rm -rf ~" } })
			local host = EditorHost.new({
				workflows = { owner = function() return owner end },
				push = function(name, payload) pushed[#pushed + 1] = { name = name, payload = payload } end,
				translate = function(key) return "<" .. key .. ">" end,
				action_ids = function() return { "select_all" } end,
				save_path = function() return picked.save end,
				open_path = function(kind) return kind == "png" and "/in/shot.png" or picked.open end,
				read_file = function(path) return world.files[path] end,
				write_file = function(path, text) world.files[path] = text; return true end,
				close = function() closed = true end,
			})
			host.on_message({ action = "ready" })
			helpers.assert_eq(pushed[1].name, "initData")
			helpers.assert_eq(pushed[1].payload.catalogue.schema_version, 1)
			helpers.assert_eq(pushed[1].payload.actions[1].id, "select_all")
			helpers.assert_eq(pushed[1].payload.actions[1].label, "<sg_actions.select_all>")
			helpers.assert_eq(pushed[1].payload.strings["workflows.step.shell"], "<workflows.step.shell>")
			helpers.assert_eq(pushed[1].payload.strings["workflows.editor.save"], "<workflows.editor.save>")
			local doc = Json.decode_lossless(file_of({ { kind = "notify", text = "hi" } }))
			host.on_message({ action = "save", doc = doc })
			helpers.assert_eq(pushed[2].payload.ok, true)
			helpers.assert_true(world.files["/cfg/workflows.json"] ~= nil, "the save reached the store")
			local bad = Json.decode_lossless('{"schema_version":1,"workflows":[{"id":"a","name":"","origin":"local","steps":[]}]}')
			host.on_message({ action = "save", doc = bad })
			helpers.assert_eq(pushed[3].payload.reason, "bad_text")
			host.on_message({ action = "test_run", doc = doc, id = "wf_1" })
			local names = {}
			for _, entry in ipairs(pushed) do names[#names + 1] = entry.name end
			helpers.assert_true(table.concat(names, ","):find("onRunStep,onRunEnd", 1, true) ~= nil, table.concat(names, ","))
			host.on_message({ action = "import" })
			local imported = pushed[#pushed]
			helpers.assert_eq(imported.name, "onImported")
			helpers.assert_eq(imported.payload.workflows[1].origin, "import", "an import is stamped by the host")
			local import_doc = Json.decode_lossless(file_of({ { kind = "shell", command = "rm -rf ~" } }, "import"))
			host.on_message({ action = "approve_shell", doc = import_doc, id = "wf_1" })
			helpers.assert_eq(pushed[#pushed].payload.approved.wf_1, true)
			host.on_message({ action = "export", doc = doc })
			helpers.assert_true(world.files["/out/export.json"] ~= nil, "the export was written")
			helpers.assert_true(not world.files["/out/export.json"]:find("approv", 1, true), "an export carries no approval")
			world.files["/in/shot.png"] = "\137PNG\r\n\26\n\0\0\0\13IHDR"
			host.on_message({ action = "pick_image" })
			helpers.assert_eq(pushed[#pushed].name, "onImagePicked")
			helpers.assert_eq(pushed[#pushed].payload.name, "shot")
			helpers.assert_eq(pushed[#pushed].payload.data:sub(1, 11), "iVBORw0KGgo")
			world.files["/in/shot.png"] = "GIF89a"
			host.on_message({ action = "pick_image" })
			helpers.assert_eq(pushed[#pushed].payload.reason, "bad_image")
			host.on_message({ action = "close" })
			helpers.assert_eq(closed, true)
		end)

	end)
end

return M
