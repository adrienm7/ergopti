--- _shared/shortcuts/engine/workflows/editor_host.lua

--- ==============================================================================
--- MODULE: User Workflows Editor Host (Shared)
--- DESCRIPTION:
--- The macOS and Linux answer to the « Workflows personnalisés… » window
--- (_shared/ui/user_workflows, bridge hsWorkflows): its first data, a save
--- checked by the shared model, a test run whose steps are pushed back for the
--- highlight, Escape and Stop, the approval of an imported shell step, and the
--- export and import of a workflow file.
---
--- FEATURES & RATIONALE:
--- 1. Every write is checked again here: the page's own check is a courtesy,
---    the store refuses what the model refuses.
--- 2. An imported workflow is stamped origin = "import" here, whatever its
---    file says, so a file can never claim to be local (maintainer decision
---    pending of 2026-11-25).
--- 3. An approval is the shell digest of the workflow the user is looking at,
---    stored apart from workflows.json; an edit of a command asks again.
--- 4. The driver owns the window, its dialogs and the file I/O (ports).
--- ==============================================================================

local Json = require("core.text.engine.json")
local Logger = require("core.logger.engine.shim")
local Model = require("shortcuts.engine.workflows.model")
local Base64 = require("core.lifecycle.engine.compat.base64")

local M = {}

local LOG = "workflows.editor"

-- The page's own strings (workflows.editor.<name>); the step, field, value,
-- refusal and reason labels follow from the catalogue.
local EDITOR_KEYS = {
	"window_title",
	"heading",
	"subtitle",
	"toolbar",
	"new",
	"duplicate",
	"delete",
	"import",
	"export",
	"list_heading",
	"list_empty",
	"editor_heading",
	"name",
	"imported_shell",
	"approve_shell",
	"steps_heading",
	"reorder_hint",
	"images_heading",
	"add_image",
	"test_run",
	"stop",
	"close",
	"save",
	"move_up",
	"move_down",
	"remove_step",
	"moved",
	"add_step",
	"add",
	"optional",
	"none",
	"placeholder_hint",
	"image_alt",
	"remove_image",
	"invalid",
	"new_name",
	"copy_name",
	"confirm_delete",
	"deleted",
	"running",
	"running_step",
	"run_done",
	"run_failed",
	"saved",
	"imported",
}

--- Every locale key the page reads, from the catalogue and EDITOR_KEYS.
--- @param catalogue table Decoded steps.json.
--- @return table Array of keys.
function M.string_keys(catalogue)
	local keys, seen = {}, {}
	local function add(key)
		if not seen[key] then seen[key] = true; keys[#keys + 1] = key end
	end
	for _, name in ipairs(EDITOR_KEYS) do add("workflows.editor." .. name) end
	local function fields_of(fields)
		for name, spec in pairs(fields) do
			add("workflows.field." .. name)
			for _, value in ipairs(spec.values or {}) do add("workflows.value." .. value) end
		end
	end
	for kind, declared in pairs(catalogue.kinds) do
		add("workflows.step." .. kind)
		fields_of(declared.fields)
	end
	for name, fields in pairs(catalogue.targets) do add("workflows.value." .. name); fields_of(fields) end
	for name, declared in pairs(catalogue.conditions) do add("workflows.value." .. name); fields_of(declared.fields) end
	add("workflows.field.type")
	for _, reason in ipairs(catalogue.reasons) do add("workflows.refusal." .. reason) end
	for _, reason in ipairs(catalogue.run_reasons) do add("workflows.reason." .. reason) end
	table.sort(keys)
	return keys
end

--- The window's app id in apps.manifest.json and its bridge name.
M.APP_ID = "user_workflows"
M.BRIDGE = "hsWorkflows"

-- The closed reasons (steps.json reasons and run_reasons) this host answers.
local REASON = {
	step_failed = "step_failed", already_running = "already_running", bad_type = "bad_type",
	not_object = "not_object", bad_image = "bad_image", too_long = "too_long",
}

--- The file name an export proposes.
M.EXPORT_FILE_NAME = "workflows.json"

--- Builds one window's host.
--- @param ports table {
---   workflows = the driver's workflow module (Owner.driver_module),
---   push = function(fn_name, payload): calls window[fn_name](payload) in the page,
---   translate = function(key) -> string: the active locale,
---   action_ids = function() -> array of the parameterless action ids the « Ergopti action » step offers,
---   save_path = function(default_name) -> string|nil: a file the user picks to write,
---   open_path = function(kind) -> string|nil: a file the user picks to read,
---     kind "workflows" (a JSON export) or "png" (an image for a screen step),
---   read_file = function(path) -> string|nil, write_file = function(path, text) -> boolean,
---   close = function(): closes the window }
--- @return table host { on_message }
function M.new(ports)
	assert(type(ports) == "table" and type(ports.workflows) == "table" and type(ports.push) == "function",
		"a workflow editor host needs the workflow module and a push port")
	for _, name in ipairs({ "translate", "action_ids", "save_path", "open_path", "read_file", "write_file", "close" }) do
		assert(type(ports[name]) == "function", "a workflow editor host needs the port " .. name)
	end
	local host = {}
	local owner = ports.workflows.owner()
	local store = owner.store

	--- The approval state the page shows: id -> whether its current shell
	--- commands are approved.
	--- @param doc table
	--- @return table
	local function approved_map(doc)
		local map = {}
		for _, workflow in ipairs(doc.workflows or {}) do
			local digest = Model.shell_digest(workflow)
			map[workflow.id] = digest ~= nil and store.approval(workflow.id) == digest
		end
		return map
	end

	local function find(doc, id)
		for _, workflow in ipairs(doc and doc.workflows or {}) do
			if workflow.id == id then return workflow end
		end
		return nil
	end

	-- Each offered action with its catalogue label (sg_actions.<id>).
	local function action_choices()
		local choices = {}
		for index, id in ipairs(ports.action_ids()) do
			choices[index] = { id = id, label = ports.translate("sg_actions." .. id) }
		end
		return choices
	end

	local function strings(catalogue)
		local out = {}
		for _, key in ipairs(M.string_keys(catalogue)) do out[key] = ports.translate(key) end
		return out
	end

	local function ready()
		local doc, refusal = store.load()
		local runner_timeouts = require("shortcuts.engine.workflows.runner").registry_timeouts()
		if not doc then
			Logger.error(LOG, "workflows.json is invalid (%s at %s): the editor opens empty.", refusal.reason,
				tostring(refusal.path))
		end
		local catalogue = owner.catalogue()
		ports.push("initData", {
			strings = strings(catalogue), catalogue = catalogue, vocabulary = owner.context().vocabulary,
			timings = { wait_max_ms = runner_timeouts.wait_max_ms }, actions = action_choices(),
			doc = doc or { schema_version = catalogue.schema_version, workflows = Json.array({}) },
			approved = doc and approved_map(doc) or {},
		})
		if refusal then ports.push("onSaved", { ok = false, reason = refusal.reason, path = refusal.path }) end
	end

	local function save(doc)
		local saved, refusal = store.save(doc)
		if not saved then
			Logger.warn(LOG, "The editor's workflows were refused (%s at %s).", refusal.reason, tostring(refusal.path))
			return ports.push("onSaved", { ok = false, reason = refusal.reason, path = refusal.path })
		end
		Logger.info(LOG, "Saved %d workflow(s) from the editor.", #doc.workflows)
		ports.push("onSaved", { ok = true, approved = approved_map(doc) })
	end

	local function test_run(doc, id)
		local workflow = find(doc, id)
		if not workflow then return ports.push("onRunEnd", { op = "failed", reason = REASON.step_failed }) end
		local started, refusal = owner.test_run(workflow, {
			on_step = function(effect) ports.push("onRunStep", { path = effect.path }) end,
			on_end = function(outcome)
				ports.push("onRunEnd", { op = outcome.op, reason = outcome.reason, path = outcome.path, kind = outcome.kind })
			end,
		})
		if refusal then
			ports.push("onSaved", { ok = false, reason = refusal.reason, path = refusal.path })
			ports.push("onRunEnd", { op = "failed", reason = REASON.step_failed })
		elseif not started then
			ports.push("onRunEnd", { op = "failed", reason = REASON.already_running })
		end
	end

	local function approve(doc, id)
		local workflow = find(doc, id)
		local digest = workflow and Model.shell_digest(workflow)
		if not digest then return end
		store.approve(id, digest)
		Logger.info(LOG, "The user approved the shell commands of workflow %s.", id)
		ports.push("onSaved", { ok = true, approved = approved_map(doc) })
	end

	local function export(doc)
		local result = Model.validate_file(doc, owner.catalogue(), owner.context())
		if not result.ok then return ports.push("onSaved", { ok = false, reason = result.reason, path = result.path }) end
		local path = ports.save_path(M.EXPORT_FILE_NAME)
		if not path then return end
		if not ports.write_file(path, Json.encode(doc)) then
			Logger.error(LOG, "The workflow export could not be written.")
			return ports.push("onSaved", { ok = false, reason = REASON.bad_type, path = "/" })
		end
		Logger.info(LOG, "Exported %d workflow(s).", #doc.workflows)
	end

	local function import()
		local path = ports.open_path("workflows")
		if not path then return end
		local text = ports.read_file(path)
		local ok, doc = pcall(Json.decode_lossless, text or "")
		if not ok or doc == nil then return ports.push("onImported", { ok = false, reason = REASON.not_object, path = "/" }) end
		local result = Model.validate_file(doc, owner.catalogue(), owner.context())
		if not result.ok then return ports.push("onImported", { ok = false, reason = result.reason, path = result.path }) end
		for _, workflow in ipairs(doc.workflows) do workflow.origin = "import" end
		Logger.info(LOG, "Imported %d workflow(s); their shell steps wait for an approval.", #doc.workflows)
		ports.push("onImported", { ok = true, workflows = doc.workflows })
	end

	-- A PNG for a screen step, read by the host: WKWebView offers no file
	-- input without a UI delegate, so the page asks instead.
	local function pick_image()
		local path = ports.open_path("png")
		if not path then return end
		local bytes = ports.read_file(path)
		if type(bytes) ~= "string" or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
			Logger.warn(LOG, "The picked image is not a PNG file.")
			return ports.push("onImagePicked", { ok = false, reason = REASON.bad_image })
		end
		local encoded = Base64.encode(bytes)
		if #encoded > owner.catalogue().limits.image_base64_bytes then
			return ports.push("onImagePicked", { ok = false, reason = REASON.too_long })
		end
		local name = (path:match("([^/\\]+)$") or "image"):gsub("%.[Pp][Nn][Gg]$", "")
		ports.push("onImagePicked", { ok = true, name = name, data = encoded })
	end

	--- Handles one message of the page.
	--- @param message table Decoded with Json.decode_lossless.
	function host.on_message(message)
		if type(message) ~= "table" or type(message.action) ~= "string" then
			Logger.warn(LOG, "The workflow editor sent a message without an action.")
			return
		end
		local action = message.action
		if action == "ready" then return ready() end
		if action == "save" then return save(message.doc) end
		if action == "test_run" then return test_run(message.doc, message.id) end
		if action == "stop" then owner.abort_all(); return end
		if action == "approve_shell" then return approve(message.doc, message.id) end
		if action == "export" then return export(message.doc) end
		if action == "import" then return import() end
		if action == "pick_image" then return pick_image() end
		if action == "close" then owner.abort_all(); return ports.close() end
		Logger.warn(LOG, "The workflow editor sent an unknown action '%s'.", action)
	end

	return host
end

return M
