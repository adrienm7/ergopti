--- _shared/shortcuts/engine/workflows/store.lua

--- ==============================================================================
--- MODULE: User Workflow Store (Shared)
--- DESCRIPTION:
--- Reads and writes the user's workflows (workflows.json) and the shell
--- approvals (workflow_approvals.json) in the Ergopti config folder, for the
--- macOS and Linux drivers. Every file read is checked by the shared model;
--- every write is checked before it reaches the disk.
---
--- FEATURES & RATIONALE:
--- 1. Fail fast, never a silent default: an absent file is an empty list, an
---    unreadable or invalid one is an error the caller shows (the reason and
---    the JSON Pointer of the model), so a typo never makes workflows vanish.
--- 2. Approvals live in their own file: an export of workflows.json never
---    carries one, and only the runner (after a yes) or the editor (after an
---    explicit approval) writes one.
--- 3. The driver owns the I/O (an atomic write, its config folder); this
---    module owns the rules.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Model = require("shortcuts.engine.workflows.model")

local M = {}

--- The file names in the config folder.
M.WORKFLOWS_FILE = "workflows.json"
M.APPROVALS_FILE = "workflow_approvals.json"

--- The only approvals schema version this store reads and writes.
M.APPROVALS_VERSION = 1

local DIGEST_HEX_LENGTH = 64

-- The model's refusals a file read can end in before the model runs.
local REFUSAL = { too_long = "too_long", not_object = "not_object" }

--- Whether a decoded approvals document is well formed.
--- @param doc any
--- @return boolean
local function valid_approvals(doc)
	if type(doc) ~= "table" or Json.is_array(doc) or Json.is_null(doc) then return false end
	for key in pairs(doc) do
		if key ~= "schema_version" and key ~= "approvals" then return false end
	end
	if doc.schema_version ~= M.APPROVALS_VERSION or type(doc.approvals) ~= "table" or Json.is_array(doc.approvals) then
		return false
	end
	for id, digest in pairs(doc.approvals) do
		if type(id) ~= "string" or not id:match("^[A-Za-z0-9_%-]+$") or #id > 64 or type(digest) ~= "string"
			or #digest ~= DIGEST_HEX_LENGTH or not digest:match("^%x+$") then
			return false
		end
	end
	return true
end

--- Builds one driver's store.
--- @param ports table {
---   path = function(name) -> string: the absolute path of a file of the config folder,
---   read = function(path) -> string|nil: nil when the file does not exist; raises on any other failure,
---   write = function(path, text): writes atomically; raises on failure,
---   catalogue = decoded steps.json,
---   context = { vocabulary = decoded send_keys.json, timings = { wait_max_ms } } }
--- @return table store
function M.new(ports)
	assert(type(ports) == "table", "a workflow store needs its ports")
	for _, name in ipairs({ "path", "read", "write" }) do
		assert(type(ports[name]) == "function", "a workflow store needs the port " .. name)
	end
	assert(type(ports.catalogue) == "table" and type(ports.context) == "table",
		"a workflow store needs the catalogue and the check context")
	local store = {}

	--- The decoded, valid workflows document.
	--- @return table|nil doc { schema_version, workflows }
	--- @return table|nil refusal { reason, path } when the file is unreadable or invalid.
	function store.load()
		local text = ports.read(ports.path(M.WORKFLOWS_FILE))
		if text == nil then return { schema_version = ports.catalogue.schema_version, workflows = Json.array({}) } end
		if #text > ports.catalogue.limits.file_bytes then return nil, { reason = REFUSAL.too_long, path = "" } end
		local ok, doc = pcall(Json.decode_lossless, text)
		if not ok or doc == nil then return nil, { reason = REFUSAL.not_object, path = "" } end
		local result = Model.validate_file(doc, ports.catalogue, ports.context)
		if not result.ok then return nil, { reason = result.reason, path = result.path } end
		return doc
	end

	--- One workflow by id.
	--- @param id string
	--- @return table|nil workflow
	--- @return table|nil refusal The load refusal, when the file is invalid.
	function store.find(id)
		local doc, refusal = store.load()
		if not doc then return nil, refusal end
		for _, workflow in ipairs(doc.workflows) do
			if workflow.id == id then return workflow end
		end
		return nil
	end

	--- The choices a binding editor offers: { value = id, label = name }, in file order.
	--- @return table|nil choices
	--- @return table|nil refusal
	function store.choices()
		local doc, refusal = store.load()
		if not doc then return nil, refusal end
		local choices = {}
		for index, workflow in ipairs(doc.workflows) do choices[index] = { value = workflow.id, label = workflow.name } end
		return choices
	end

	--- Writes a whole workflows document after checking it.
	--- @param doc table Decoded with Json.decode_lossless (the editor's save).
	--- @return boolean saved
	--- @return table|nil refusal { reason, path }
	function store.save(doc)
		local result = Model.validate_file(doc, ports.catalogue, ports.context)
		if not result.ok then return false, { reason = result.reason, path = result.path } end
		ports.write(ports.path(M.WORKFLOWS_FILE), Json.encode(doc))
		return true
	end

	local function load_approvals()
		local text = ports.read(ports.path(M.APPROVALS_FILE))
		if text == nil then return { schema_version = M.APPROVALS_VERSION, approvals = {} } end
		local ok, doc = pcall(Json.decode_lossless, text)
		if not ok or not valid_approvals(doc) then
			error("workflows.store: " .. M.APPROVALS_FILE .. " is not a valid approvals file")
		end
		return doc
	end

	--- The digest the user approved for a workflow, or nil.
	--- @param id string
	--- @return string|nil
	function store.approval(id)
		return load_approvals().approvals[id]
	end

	--- Records an approval of a workflow's shell digest.
	--- @param id string
	--- @param digest string 64 lowercase hex characters (model.shell_digest).
	function store.approve(id, digest)
		assert(type(digest) == "string" and #digest == DIGEST_HEX_LENGTH and digest:match("^%x+$"),
			"a workflow approval needs a shell digest")
		local doc = load_approvals()
		doc.approvals[id] = digest
		ports.write(ports.path(M.APPROVALS_FILE), Json.encode(doc))
	end

	return store
end

return M
