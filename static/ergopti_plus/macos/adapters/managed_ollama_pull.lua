--- adapters/managed_ollama_pull.lua

--- ==============================================================================
--- MODULE: Managed Ollama Pull Adapter
--- DESCRIPTION:
--- Receives private source-bound daemon retirement before releasing a model
--- pull task. Child exit alone never releases daemon operation ownership.
--- ==============================================================================

local M = {}
local task_receipts = setmetatable({}, { __mode = "k" })
local FileSystem = require("adapters.file_system")
local FsDir = require("infra.fs_dir")
local Json = require("json")
local Receipt = require("core.llm.managed_ollama_pull_receipt")
local Logger = require("infra.logger")
local hs = hs
local LOG = "adapters.managed_ollama_pull"

local function fixed_failure()
	Logger.error(LOG, "Managed model pull source or receipt operation refused.")
end

local function identity(path)
	local ok, attributes, classification = pcall(FileSystem.classify_no_follow, path)
	if not ok or classification ~= "ok" or type(attributes) ~= "table" or attributes.mode ~= "file"
		or type(attributes.dev) ~= "number" or type(attributes.ino) ~= "number" then return nil end
	return attributes
end

local function matches(path, expected)
	local actual = identity(path)
	return actual ~= nil and expected ~= nil and actual.dev == expected.dev and actual.ino == expected.ino
end

--- The separately source-qualified runtime path; external daemons stay unsupported.
--- @param executable string Selected runtime pathname.
--- @return boolean managed Runtime can enter the authenticated native admission path.
function M.handles(executable)
	local home = os.getenv("HOME")
	return type(home) == "string" and home:sub(1, 1) == "/"
		and executable == home:gsub("/+$", "") .. "/Library/Application Support/Ergopti/ollama-native-http/ollama"
end

--- Prepares one private request and receipt without starting a model pull.
--- The caller must pass its actual native interpreter; no Rosetta or download fallback.
--- @param model string Requested registry model.
--- @param port number Configured local daemon port.
--- @param python_bin string Resolved native interpreter pathname.
--- @return table|nil handle Private receipt and input owner.
--- @return boolean prepared Exact input ready for dispatch.
function M.prepare(model, port, python_bin)
	if type(model) ~= "string" or model == "" or not model:match("^[%w%._:/%-]+$")
		or type(port) ~= "number" or port % 1 ~= 0 or port < 1024 or port > 65535
		or type(python_bin) ~= "string" or python_bin:sub(1, 1) ~= "/" or python_bin:find("\0", 1, true) then return nil, false end
	local source = debug.getinfo(1, "S").source
	local driver = source:sub(2):match("^(.*)/adapters/managed_ollama_pull%.lua$")
	if not driver then return nil, false end
	local policy = driver .. "/modules/llm/network-retry.sh"
	local script = driver .. "/modules/llm/managed_ollama_pull.py"
	if not FileSystem.exists(policy) or not FileSystem.exists(script) then return nil, false end
	local policy_path = driver .. "/../_shared/modules/network/proxy_policy.json"
	local read_ok, bytes, read_status = pcall(FileSystem.read_with_status, policy_path, fixed_failure)
	if not read_ok or read_status ~= "ok" then return nil, false end
	local parsed, proxy_policy = pcall(Json.decode, bytes)
	local maximum_bytes = parsed and type(proxy_policy) == "table" and proxy_policy.max_proxy_bytes or nil
	if type(maximum_bytes) ~= "number" or maximum_bytes <= 0 or maximum_bytes % 1 ~= 0 then return nil, false end
	local policy_ok, policy_bytes, policy_status = pcall(FileSystem.read_with_status, policy, fixed_failure)
	if not policy_ok or policy_status ~= "ok" or type(policy_bytes) ~= "string" then return nil, false end
	local function number(name)
		local selected = nil
		for line in (policy_bytes .. "\n"):gmatch("([^\n]*)\n") do
			local value = line:match("^" .. name .. "=([1-9]%d*)$")
			if value then
				if selected then return nil end
				selected = tonumber(value)
			end
		end
		if type(selected) ~= "number" or selected < 1 or selected > 9007199254740991 or selected % 1 ~= 0 then return nil end
		return selected
	end
	local admission, idle, retirement = number("CURL_CONNECT_TIMEOUT_SEC"), number("CURL_STALL_SEC"), number("CURL_MAX_TIME_SEC")
	if not admission or not idle or not retirement then return nil, false end
	-- Invoke the native interpreter directly. No shell startup file can run
	-- before source admission; inherited explicit relay/trust variables survive.
	local arguments = { "-I", script, "--admission-timeout", string.format("%.0f", admission),
		"--idle-timeout", string.format("%.0f", idle), "--retirement-timeout", string.format("%.0f", retirement),
		"--maximum-bytes", string.format("%.0f", maximum_bytes) }
	local generated, nonce = pcall(function() return hs.host.uuid() end)
	if not generated or type(nonce) ~= "string" or #nonce ~= 36 or not nonce:match("^[%w%-]+$") then return nil, false end
	local allocated, path = pcall(FileSystem.create_secure_temp_file)
	if not allocated or type(path) ~= "string" then return nil, false end
	local observed = identity(path)
	local attempted, retired, cleaned, expected, cleanup_retry = false, false, false, "", nil
	local cleanup_receipt, cleanup_removed = nil, false
	local handle = { executable = python_bin, arguments = arguments }
	local bound_task = nil
	local function exact_absence()
		local ok, value, status = pcall(FileSystem.classify_no_follow, path)
		return ok and value == nil and status == "absent"
	end
	local function cleanup()
		if cleaned then return true end
		if cleanup_retry ~= nil then
			local ok, settled, _, removed_by_owner = pcall(cleanup_retry)
			if not ok or settled ~= true then return false end
			cleanup_removed = removed_by_owner == true
				or (type(cleanup_receipt) == "table" and cleanup_receipt.removed == true)
			cleanup_retry = nil
			if cleanup_removed then
				if not exact_absence() then return false end
				cleaned = true
				return true
			end
			-- A release-only receipt can settle without unlinking. Revalidate
			-- the original inode and bytes before retrying that exact removal.
		end
		if cleanup_removed then
			if not exact_absence() then return false end
			cleaned = true
			return true
		end
		if not matches(path, observed) then return false end
		local ok, removed, _, receipt, retry = pcall(FileSystem.remove_if_unchanged,
			path, { status = "ok", content = expected }, fixed_failure,
			function() return matches(path, observed) end)
		-- The filesystem's literal true includes its own post-unlink absence
		-- check and closed native lock. Retain that established port contract.
		if ok and removed == true then cleaned = true; return true end
		if ok and type(receipt) == "table" then
			cleanup_receipt = receipt
			cleanup_removed = receipt.removed == true
		end
		if ok and type(retry) == "function" then cleanup_retry = retry end
		return false
	end
	function handle.rollback()
		if attempted then return false end
		return cleanup()
	end
	function handle.bind_input(task)
		if attempted or cleaned or bound_task ~= nil or task == nil
			or task_receipts[task] ~= nil or type(handle.input) ~= "string" then return false end
		-- Bind before crossing setInput: a reentrant or refused assignment keeps
		-- the same cleanup capability until pre-dispatch rollback settles it.
		bound_task, task_receipts[task] = task, handle
		local ok, assigned = pcall(function() return task:setInput(handle.input) end)
		return ok and assigned == task
	end
	function handle.mark_start_attempted()
		if attempted or cleaned then return false end
		attempted = true
		return true
	end
	function handle.settle(callback_status)
		if cleaned then return true end
		if not attempted then return false end
		if not retired then
			if not matches(path, observed) then return false end
			local current = identity(path)
			if type(current) ~= "table" or type(current.size) ~= "number"
				or current.size > Receipt.maximum_bytes then return false end
			local read_ok, raw, status = pcall(FileSystem.read_with_status, path, fixed_failure)
			if not read_ok or status ~= "ok" or not matches(path, observed)
				or Receipt.retired(raw, Json.decode, nonce, callback_status) ~= true then return false end
			expected, retired = raw, true
		end
		return cleanup()
	end
	if not observed or observed.size ~= 0 then return handle, false end
	local encoded, input = pcall(Json.encode, {
		version = 1, model = model, port = port, nonce = nonce, receipt_path = path,
	})
	if not encoded or type(input) ~= "string" or #input > 65535 then return handle, false end
	handle.input = input .. "\n"
	return handle, true
end

--- Marks the exact bound native dispatch; opaque tasks retain their old lifecycle.
--- @param task userdata|table Exact native task identity.
--- @return boolean admitted Native dispatch can be attempted once.
function M.mark_start_attempted(task)
	local handle = task_receipts[task]
	return handle == nil or handle.mark_start_attempted() == true
end

--- Rolls back only a bound receipt whose native dispatch was never attempted.
--- @param task userdata|table Exact native task identity.
--- @return boolean settled Private preparation is physically cleaned.
function M.rollback(task)
	local handle = task_receipts[task]
	if handle == nil then return true end
	if handle.rollback() ~= true then return false end
	task_receipts[task] = nil
	return true
end

--- Receives both callback closure and authenticated daemon retirement.
--- @param task userdata|table Exact native task identity.
--- @param callback_status number Actual completion status for the same task.
--- @return boolean settled Private proof authorizes the exact slot release.
function M.retire(task, callback_status)
	local handle = task_receipts[task]
	if handle == nil then return true end
	if handle.settle(callback_status) ~= true then return false end
	task_receipts[task] = nil
	return true
end

-- The explicit successor is dormant. Existing preparation and default CLI
-- selection keep their original protocol and ownership unchanged.
local cleanup_receipts = setmetatable({}, { __mode = "k" })
local owned_handles = setmetatable({}, { __mode = "k" })

local function decimal_identity(value, positive)
	if type(value) ~= "number" or value % 1 ~= 0 or value < (positive and 1 or 0)
		or value > 9007199254740991 then return nil end
	return string.format("%.0f", value)
end

local function private_identity(path)
	local value = identity(path)
	if not value or not decimal_identity(value.dev, false) or not decimal_identity(value.ino, true)
		or not decimal_identity(value.uid, false) or value.nlink ~= 1 or value.permissions ~= "rw-------"
		or type(value.size) ~= "number" or value.size < 0 or value.size % 1 ~= 0 then return nil end
	return value
end

local function private_matches(path, expected)
	local value = private_identity(path)
	return value ~= nil and expected ~= nil and value.dev == expected.dev and value.ino == expected.ino
		and value.uid == expected.uid
end

local function reserved_file(path)
	return { path = path, observed = private_identity(path), removed = false }
end

local function read_reserved(file)
	if file.removed or not private_matches(file.path, file.observed) then return nil end
	local current = private_identity(file.path)
	if not current or current.size > Receipt.maximum_bytes then return nil end
	local ok, raw, status = pcall(FileSystem.read_with_status, file.path, fixed_failure)
	if not ok or status ~= "ok" or type(raw) ~= "string" or #raw ~= current.size
		or not private_matches(file.path, file.observed) then return nil end
	return raw
end

local function reserved_absent(file)
	local ok, value, classification = pcall(FileSystem.classify_no_follow, file.path)
	return ok and value == nil and classification == "absent"
end

local function remove_reserved(file, raw)
	if file.removed and file.retry == nil then return reserved_absent(file) end
	if file.retry ~= nil then
		local ok, closed, _, physically_removed = pcall(file.retry)
		if not ok or closed ~= true then return false end
		local original_removed = physically_removed == true
			or (type(file.removal_receipt) == "table" and file.removal_receipt.removed == true)
		file.retry = nil
		if original_removed then file.removed = true; return reserved_absent(file) end
		-- Releasing a lock whose unlink never ran is not physical retirement.
		return false
	end
	if type(raw) ~= "string" or not private_matches(file.path, file.observed) then return false end
	local ok, removed, _, receipt, retry = pcall(FileSystem.remove_if_unchanged,
		file.path, { status = "ok", content = raw }, fixed_failure,
		function()
			return private_matches(file.path, file.observed)
				and (file.admission == nil or file.admission() == true)
		end)
	if ok and removed == true then file.removed = true; return true end
	if ok and type(receipt) == "table" then
		file.removal_receipt = receipt
		if receipt.removed == true then file.removed = true end
	end
	if ok and type(retry) == "function" then file.retry = retry end
	return false
end

local function directory_matches(directory)
	local ok, value, classification = pcall(FileSystem.classify_no_follow, directory.path)
	return ok and classification == "ok" and type(value) == "table" and value.mode == "directory" and value.permissions == "rwx------"
		and value.uid == directory.uid and decimal_identity(value.dev, false) == directory.device
		and decimal_identity(value.ino, true) == directory.inode
end

local function material_census(owner)
	if owner.directory_removed then return true end
	if not directory_matches(owner.directory) then return false end
	local allowed, count = {}, 0
	for _, name in ipairs({ "authority", "window" }) do
		if owner[name].removed ~= true then allowed[name .. ".json"] = true; count = count + 1 end
	end
	-- The canonical private iterator retains and closes its native state. A
	-- missing directory or a third entry cannot become an empty authoritative census.
	local ok, listing = pcall(FsDir.collect_private, owner.directory.path, math.max(1, count))
	if not ok or type(listing) ~= "table" or listing.truncated ~= false then return false end
	for _, name in ipairs(listing.names) do
		if allowed[name] ~= true then return false end
		allowed[name] = nil
	end
	return next(allowed) == nil and directory_matches(owner.directory)
end

local function capture_material(anchor, uid)
	local Crypto = require("adapters.crypto")
	local owner = { directory = { path = anchor.directory.path, device = anchor.directory.device,
		inode = anchor.directory.inode, uid = uid }, directory_removed = false }
	for _, name in ipairs({ "authority", "window" }) do
		local ref = anchor[name]
		local file = reserved_file(ref.path)
		if not file.observed or file.observed.uid ~= uid or file.observed.size > 16384
			or decimal_identity(file.observed.dev, false) ~= ref.device
			or decimal_identity(file.observed.ino, true) ~= ref.inode then return nil end
		owner[name] = file
	end
	if not material_census(owner) then return nil end
	for _, name in ipairs({ "authority", "window" }) do
		local file, ref = owner[name], anchor[name]
		local ok, raw, status = pcall(FileSystem.read_with_status, file.path, fixed_failure)
		if not ok or status ~= "ok" or type(raw) ~= "string" or #raw ~= file.observed.size
			or #raw > 16384 or not private_matches(file.path, file.observed)
			or not directory_matches(owner.directory) then return nil end
		local hashed, digest = pcall(Crypto.sha256_bytes, raw, fixed_failure)
		if not hashed or digest ~= ref.sha256 or not private_matches(file.path, file.observed)
			or not directory_matches(owner.directory) then return nil end
		file.raw = raw
	end
	if not material_census(owner) then return nil end
	return owner
end

local function material_directory_absent(owner)
	local ok, value, classification = pcall(FileSystem.classify_no_follow, owner.directory.path)
	return ok and value == nil and classification == "absent"
end

local function close_material(owner)
	if owner.directory_removed then return material_directory_absent(owner) end
	if not directory_matches(owner.directory) then return false end
	-- A conditional unlink can retain its own adjacent lock directory. Resume
	-- that exact capability before requiring the remaining filename census.
	for _, name in ipairs({ "authority", "window" }) do
		local file = owner[name]
		if file.retry ~= nil and remove_reserved(file, file.raw) ~= true then return false end
	end
	if not material_census(owner) then return false end
	for _, name in ipairs({ "authority", "window" }) do
		local file = owner[name]
		if file.removed ~= true then
			if not directory_matches(owner.directory) or not material_census(owner) then return false end
			file.admission = function() return directory_matches(owner.directory) end
			if remove_reserved(file, file.raw) ~= true then return false end
			if not material_census(owner) then return false end
		end
	end
	if not directory_matches(owner.directory) or not material_census(owner)
		or not hs.fs or type(hs.fs.rmdir) ~= "function" then return false end
	local ok, removed = pcall(hs.fs.rmdir, owner.directory.path)
	if not ok or removed ~= true then return false end
	owner.directory_removed = true
	return material_directory_absent(owner)
end

--- Prepares a dormant source-bound pull with one token-free handoff anchor.
--- @param model string Requested registry model.
--- @param port number Configured local daemon port.
--- @param python_bin string Resolved native interpreter pathname.
--- @return table|nil handle Exact task-bound request and anchor owner.
--- @return boolean prepared Version-two input is ready for explicit dispatch.
function M.prepare_owned(model, port, python_bin)
	local base, ready = M.prepare(model, port, python_bin)
	if not base or ready ~= true then return base, false end
	local decoded, input = pcall(Json.decode, base.input)
	if not decoded or type(input) ~= "table" then return base, false end
	local allocated, path = pcall(FileSystem.create_secure_temp_file)
	if not allocated or type(path) ~= "string" then return base, false end
	local anchor, original = reserved_file(path), reserved_file(input.receipt_path)
	local attempted, bound = false, nil
	local handle = { executable = base.executable, arguments = base.arguments }
	local context = { anchor = anchor, original = original, nonce = input.nonce, base = base,
		python = python_bin, arguments = base.arguments, cleanup_task = nil, cleanup_nonces = {} }
	function handle.bind_input(task)
		if bound ~= nil or attempted or type(handle.input) ~= "string" then return false end
		local ok, assigned = pcall(base.bind_input, task)
		if task_receipts[task] == base then
			bound = task
			task_receipts[task], owned_handles[task] = handle, context
		end
		return ok and assigned == true
	end
	function handle.mark_start_attempted()
		if attempted then return false end
		attempted = true
		return base.mark_start_attempted() == true
	end
	function handle.rollback()
		if attempted then return false end
		if remove_reserved(original, "") ~= true then return false end
		return remove_reserved(anchor, "")
	end
	function handle.settle(callback_status)
		if not attempted or context.cleanup_task ~= nil then return false end
		if callback_status == 78 then context.original_callback_status = 78 end
		if context.original_retired_status ~= nil and context.original_retired_status ~= callback_status then return false end
		if context.original_retired_raw == nil then
			local raw = read_reserved(original)
			if Receipt.retired(raw, Json.decode, context.nonce, callback_status) ~= true then return false end
			context.original_retired_raw, context.original_retired_status = raw, callback_status
		end
		if context.anchor_raw == nil then
			local raw = read_reserved(anchor)
			if type(raw) ~= "string" then return false end
			local proof = Json.decode(context.original_retired_raw)
			if raw == "" then
				if proof.operation ~= "" then return false end
				-- Only the original Python owner can retire an unsealed directory
				-- before publishing its pre-submission retired receipt.
			else
				local CleanupReceipt = require("core.llm.managed_ollama_cleanup_receipt")
				local parsed = CleanupReceipt.anchor(raw, Json.decode, context.nonce, proof.operation, anchor.path)
				if not parsed then return false end
				local material = capture_material(parsed, anchor.observed.uid)
				if not material then return false end
				context.material = material
			end
			context.anchor_raw = raw
		end
		if context.material ~= nil and close_material(context.material) ~= true then return false end
		if remove_reserved(original, context.original_retired_raw) ~= true then return false end
		return remove_reserved(anchor, context.anchor_raw)
	end
	if not anchor.observed or anchor.observed.size ~= 0 or not original.observed or original.observed.size ~= 0 then
		return handle, false
	end
	input.version = 2
	input.anchor = { path = path, device = decimal_identity(anchor.observed.dev, false),
		inode = decimal_identity(anchor.observed.ino, true) }
	local encoded, raw = pcall(Json.encode, input)
	if not encoded or type(raw) ~= "string" or #raw > 65535 then return handle, false end
	handle.input, base.input = raw .. "\n", raw .. "\n"
	return handle, true
end

--- Prepares one explicit GET-only cleanup for an exact occupied managed task.
--- @param original_task userdata|table Original source-bound pull task.
--- @return table|nil handle Independent cleanup request and receipt owner.
--- @return boolean prepared Exact fresh worker can be dispatched once.
function M.prepare_cleanup(original_task)
	local context = owned_handles[original_task]
	if not context or context.original_callback_status ~= 78
		or task_receipts[original_task] == nil or context.cleanup_task ~= nil then return nil, false end
	local CleanupReceipt = require("core.llm.managed_ollama_cleanup_receipt")
	local Crypto = require("adapters.crypto")
	local original_raw, anchor_raw = read_reserved(context.original), read_reserved(context.anchor)
	local proof = CleanupReceipt.original_pending(original_raw, Json.decode, context.nonce)
	if not proof then return nil, false end
	local anchor = CleanupReceipt.anchor(anchor_raw, Json.decode, context.nonce, proof.operation, context.anchor.path)
	if not anchor then return nil, false end
	local hashed, digest = pcall(Crypto.sha256_bytes, anchor_raw, fixed_failure)
	if not hashed or type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$")
		or read_reserved(context.anchor) ~= anchor_raw or read_reserved(context.original) ~= original_raw then return nil, false end
	if context.anchor_raw ~= nil and context.anchor_raw ~= anchor_raw then return nil, false end
	if context.original_raw ~= nil and context.original_raw ~= original_raw then return nil, false end
	context.anchor_raw, context.original_raw = anchor_raw, original_raw
	local generated, nonce = pcall(function() return hs.host.uuid() end)
	if not generated or type(nonce) ~= "string" or #nonce ~= 36 or not nonce:match("^[A-Za-z0-9%-]+$")
		or nonce == context.nonce or context.cleanup_nonces[nonce] then return nil, false end
	context.cleanup_nonces[nonce] = true
	local allocated, path = pcall(FileSystem.create_secure_temp_file)
	if not allocated or type(path) ~= "string" then return nil, false end
	local receipt = reserved_file(path)
	local attempted, bound, state, callback, acknowledgement, material = false, nil, nil, nil, nil, nil
	local script = context.arguments[2]:gsub("/managed_ollama_pull%.py$", "/managed_ollama_cleanup.py")
	local handle = { executable = context.python,
		arguments = { "-I", script, "--mode", "explicit-cleanup", "--timeout", context.arguments[8] } }
	local expected = { nonce = nonce, original_nonce = context.nonce, operation = proof.operation,
		authority_sha256 = anchor.authority.sha256, window_sha256 = anchor.window.sha256 }
	function handle.bind_input(task)
		if bound ~= nil or attempted or task == nil or cleanup_receipts[task] ~= nil
			or context.cleanup_task ~= nil or type(handle.input) ~= "string" then return false end
		bound, context.cleanup_task, cleanup_receipts[task] = task, task, handle
		local ok, assigned = pcall(function() return task:setInput(handle.input) end)
		return ok and assigned == task
	end
	function handle.mark_start_attempted()
		if attempted or receipt.removed then return false end
		attempted = true
		return true
	end
	function handle.rollback()
		if attempted then return false end
		if remove_reserved(receipt, "") ~= true then return false end
		if bound ~= nil then cleanup_receipts[bound] = nil end
		if context.cleanup_task == bound then context.cleanup_task = nil end
		return true
	end
	function handle.settle(callback_status)
		if not attempted or (callback ~= nil and callback ~= callback_status) then return false, false end
		if state == nil then
			local raw = read_reserved(receipt)
			state = CleanupReceipt.receive(raw, Json.decode, expected, callback_status)
			if state == nil then return false, false end
			callback, receipt.raw, acknowledgement = callback_status, raw, raw
		end
		if state == "retired" then
			if material == nil then
				material = capture_material(anchor, context.anchor.observed.uid)
				if material == nil then return false, false end
			end
			if acknowledgement ~= receipt.raw or close_material(material) ~= true then return false, false end
		end
		if remove_reserved(receipt, receipt.raw) ~= true then return false, false end
		if state == "retired" then
			if read_reserved(context.original) ~= context.original_raw and not context.original.removed then return false, false end
			if read_reserved(context.anchor) ~= context.anchor_raw and not context.anchor.removed then return false, false end
			if remove_reserved(context.original, context.original_raw) ~= true
				or remove_reserved(context.anchor, context.anchor_raw) ~= true then return false, false end
			task_receipts[original_task], owned_handles[original_task] = nil, nil
		end
		if bound ~= nil then cleanup_receipts[bound] = nil end
		if context.cleanup_task == bound then context.cleanup_task = nil end
		return state == "retired", true
	end
	if not receipt.observed or receipt.observed.size ~= 0 or script == context.arguments[2]
		or not FileSystem.exists(script) then return handle, false end
	local encoded, raw = pcall(Json.encode, {
		version = 1, nonce = nonce, original_nonce = context.nonce, original_worker_status = 78,
		operation = proof.operation, anchor = { path = context.anchor.path,
			device = decimal_identity(context.anchor.observed.dev, false), inode = decimal_identity(context.anchor.observed.ino, true),
			sha256 = digest }, receipt_path = path,
	})
	if not encoded or type(raw) ~= "string" or #raw > 65535 then return handle, false end
	handle.input = raw .. "\n"
	return handle, true
end

--- Joins only the cleanup worker bound to the same original task.
--- @param original_task userdata|table Exact original pending worker.
--- @param cleanup_task userdata|table Exact fresh cleanup worker.
--- @param callback_status number Actual fresh native completion status.
--- @return boolean retired Fresh ACK and physical files permit original release.
--- @return boolean closed Cleanup receipt is physically retired.
function M.finish_cleanup(original_task, cleanup_task, callback_status)
	local context, handle = owned_handles[original_task], cleanup_receipts[cleanup_task]
	if not context or context.cleanup_task ~= cleanup_task or not handle then return false, false end
	return handle.settle(callback_status)
end

return M
