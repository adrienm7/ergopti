--- modules/llm/api_token_store.lua

--- ==============================================================================
--- MODULE: API Token Store (Linux Secret Service)
--- DESCRIPTION:
--- Keeps the remote-API keys in the desktop secret service (GNOME Keyring,
--- KWallet and KeePassXC all serve org.freedesktop.secrets) through libsecret's
--- secret-tool: the Linux counterpart of the macOS Keychain and of Windows
--- DPAPI. api_keys.json then holds a "secret-service:<entry id>#<revision>"
--- reference in place of each key.
---
--- FEATURES & RATIONALE:
--- 1. No plaintext fallback, as on macOS and Windows: when no secret service
---    answers, store() refuses with the reason and the caller refuses the save.
--- 2. The key reaches secret-tool on its standard input, never in its
---    arguments: any local user can read every process's command line.
--- 3. Each call runs through ui/modal.lua: a locked keyring asks for its
---    password in a desktop prompt, which needs the keyboard the daemon grabs.
--- 4. secret-tool exits 1 both for an absent item and for a failed service;
---    a failure usually writes a message. A dismissed unlock prompt and a clear
---    on a locked keyring exit 1 silently too (measured on gnome-keyring), so a
---    silent 1 is confirmed with `search`, which never prompts and still lists
---    a locked item: listed means locked, not absent, and not cleared.
--- 5. Items carry two attributes, the application name of
---    _shared/core/text/data/identifiers.json and "<entry id>#<revision>", so `secret-tool
---    search application ErgoptiPlus` lists every key this driver stored. Each
---    store is a new revision: a changed key never overwrites the one the file
---    still names until the file is published.
--- 6. The background calls (store_async, clear_async, probe_lock_async) never
---    block the event loop: each runs as an owned child process group with a
---    deadline, killed when it passes, and needs no keyboard hand-over since
---    the loop keeps delivering keys meanwhile. The key reaches secret-tool's
---    standard input through a shell builtin from the child's own environment,
---    readable only by its owner (/proc/<pid>/environ is mode 0400), never
---    through an argument. probe_lock_async reads the default collection's
---    Locked property over D-Bus, which never prompts, so a background retry
---    does not open an unlock prompt behind the user's back.
--- ==============================================================================

local M = {}

local Logger      = require("core.logger.engine.shim")
local ShellRunner = require("adapters.shell_runner")
local Identifiers = require("core.text.engine.identifiers")

local LOG = "modules.llm.api_token_store"

M.REFERENCE_PREFIX = "secret-service:"

local TOOL = "secret-tool"
-- The stand-in tool a test installed, or nil.
local _tool_override = nil
local APPLICATION_ATTRIBUTE = "application"
local KEY_ATTRIBUTE = "api_key"
-- secret-tool's stdin reader has an 8192-byte buffer and may exit successfully
-- after storing only that prefix. Never publish a reference to truncated data.
local SECRET_TOOL_INPUT_BYTES = 8192

-- The backend a test installed, or nil for secret-tool.
local _backend = nil
-- Random revisions also survive process restarts inside the same second.
local REVISION_BYTES = 16

local function revision()
	local loaded, uv = pcall(require, "luv")
	if not loaded or type(uv) ~= "table" or type(uv.random) ~= "function" then return nil end
	local called, bytes = pcall(uv.random, REVISION_BYTES)
	if not called or type(bytes) ~= "string" or #bytes ~= REVISION_BYTES then return nil end
	return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end




-- =========================================
-- =========================================
-- ======= 1/ secret-tool ==================
-- =========================================
-- =========================================

--- Reads a whole file and removes it.
--- @param path string
--- @param remove_owned function Cleanup bound to the created file.
--- @return string|nil text Nil when the result cannot be read safely.
local function take_file(path, remove_owned)
	local text, status = require("core.text.engine.toml_codec.writer").read_classified(path)
	local called, removed = pcall(remove_owned)
	if status ~= "ok" or not called or removed ~= true then return nil end
	return text
end

--- Runs secret-tool once, with stdin or stdout piped, its stderr and exit
--- status captured in private temporary files.
--- @param args table secret-tool arguments, each quoted here.
--- @param input string|nil Bytes for its standard input (store), or nil to read stdout.
--- @return number|nil status The exit status, nil when it could not run.
--- @return string output Its standard output, byte for byte.
--- @return string stderr What it wrote on its standard error.
local function run_tool(args, input)
	local words = { ShellRunner.quote(_tool_override or TOOL) }
	for _, arg in ipairs(args) do words[#words + 1] = ShellRunner.quote(arg) end
	local uv = require("luv")
	local dir = uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-secret-tool-XXXXXX")
	if not dir then return nil, "", "secret-tool result directory unavailable" end
	local err_path, status_path = dir .. "/stderr", dir .. "/status"
	local function reserve(path)
		local opened, fh, _, _, remove = pcall(require("infra.regular_file_writer").open, path, "wx")
		if not opened or not fh then return nil end
		local closed, ack = pcall(fh.close, fh)
		if not closed or ack ~= true or type(remove) ~= "function" then
			if type(remove) == "function" then pcall(remove) end
			return nil
		end
		return remove
	end
	local remove_err, remove_status = reserve(err_path), reserve(status_path)
	if not remove_err or not remove_status then
		if remove_err then pcall(remove_err) end
		if remove_status then pcall(remove_status) end
		uv.fs_rmdir(dir)
		return nil, "", "secret-tool result files are unavailable"
	end
	local command = table.concat(words, " ")
		.. (input and " >/dev/null" or "")
		.. " 2>" .. ShellRunner.quote(err_path)
		.. "; printf '%s' $? >" .. ShellRunner.quote(status_path)
	local output = ""
	local started, pipe = pcall(io.popen, command, input and "w" or "r")
	if not started or not pipe then
		pcall(remove_err)
		pcall(remove_status)
		uv.fs_rmdir(dir)
		return nil, "", "the shell could not be started"
	end
	local exchanged, value
	if input then exchanged, value = pcall(pipe.write, pipe, input)
	else exchanged, value = pcall(pipe.read, pipe, "*a"); output = type(value) == "string" and value or "" end
	local closed, close_ack = pcall(pipe.close, pipe)
	local status_text, stderr = take_file(status_path, remove_status), take_file(err_path, remove_err)
	local removed_dir = uv.fs_rmdir(dir)
	local received = input and (value == true or value == pipe) or (not input and type(value) == "string")
	if not exchanged or not received or not closed or close_ack ~= true
		or status_text == nil or stderr == nil or removed_dir ~= true then
		return nil, "", "secret-tool result files are unavailable"
	end
	return tonumber(status_text), output, stderr
end

--- The reason a failed call gives, its stderr on one line.
--- @param stderr string
--- @param status number|nil
--- @return string
local function failure_reason(stderr, status)
	local message = stderr:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
	if message == "" then message = "exit status " .. tostring(status) end
	return message
end

--- The secret-tool backend, run with the keyboard handed to the desktop.
local SECRET_TOOL = {}

--- Why secret-tool cannot be used, or nil when it can be tried.
--- @return string|nil
function SECRET_TOOL.unavailable()
	if not ShellRunner.has_command(_tool_override or TOOL, true) then
		return "secret-tool is not installed (package libsecret-tools or libsecret)"
	end
	return nil
end

--- @param name string The item's "<entry id>#<revision>".
--- @param token string
--- @return boolean ok, string|nil reason
function SECRET_TOOL.store(name, token)
	if #token > SECRET_TOOL_INPUT_BYTES then return false, "API key exceeds secret-tool input capacity" end
	local status, _, stderr = run_tool({
		"store", "--label=" .. Identifiers.app.name .. " API key " .. name,
		APPLICATION_ATTRIBUTE, Identifiers.app.name, KEY_ATTRIBUTE, name,
	}, token)
	if status == 0 then return true end
	return false, failure_reason(stderr, status)
end

--- Whether the service still lists the item, without asking to unlock it.
--- @param name string
--- @return boolean|nil listed, string|nil reason
local function listed(name)
	local status, output, stderr = run_tool({
		"search", APPLICATION_ATTRIBUTE, Identifiers.app.name, KEY_ATTRIBUTE, name,
	})
	if status ~= 0 then return nil, failure_reason(stderr, status) end
	return output:find("^%[/") ~= nil or output:find("\n%[/") ~= nil
end

local LOCKED = "the keyring is locked, or its unlock prompt was dismissed"

--- @param name string
--- @return string|nil token, string|nil reason ("absent" when no item matches)
function SECRET_TOOL.lookup(name)
	local status, output, stderr = run_tool({
		"lookup", APPLICATION_ATTRIBUTE, Identifiers.app.name, KEY_ATTRIBUTE, name,
	})
	if status == 0 and output ~= "" then return output end
	if status == 1 and stderr == "" then
		local present, reason = listed(name)
		if present == nil then return nil, reason end
		return nil, present and LOCKED or "absent"
	end
	return nil, failure_reason(stderr, status)
end

--- @param name string
--- @return boolean ok, string|nil reason
function SECRET_TOOL.clear(name)
	local status, _, stderr = run_tool({
		"clear", APPLICATION_ATTRIBUTE, Identifiers.app.name, KEY_ATTRIBUTE, name,
	})
	if status == 0 then return true end
	if status == 1 and stderr == "" then
		-- Nothing matched, or a locked keyring refused silently: only a search
		-- that no longer lists the item makes this the success asked for.
		local present, reason = listed(name)
		if present == nil then return false, reason end
		if present then return false, LOCKED .. "; the key stays in the secret service" end
		return true
	end
	return false, failure_reason(stderr, status)
end

--- The backend in use.
--- @return table
local function backend()
	return _backend or SECRET_TOOL
end

--- Runs fn with the keyboard handed to the desktop when the real tool runs:
--- only a desktop prompt needs it, never a test's backend or stand-in tool.
--- @param fn function
--- @return any
local function with_keyboard(fn)
	if _backend or _tool_override then return fn() end
	return require("ui.modal").run(fn)
end




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Whether a stored token field is a secret-service reference.
--- @param stored any
--- @return boolean
function M.is_reference(stored)
	return type(stored) == "string" and #stored > #M.REFERENCE_PREFIX
		and stored:sub(1, #M.REFERENCE_PREFIX) == M.REFERENCE_PREFIX
end

--- The item name a reference holds.
--- @param reference string
--- @return string
local function name_of(reference)
	return reference:sub(#M.REFERENCE_PREFIX + 1)
end

--- Stores a key under a new revision and returns the reference the file holds
--- instead. The key is never returned as a failure fallback.
--- @param entry_id string
--- @param token string A non-empty key.
--- @return string|nil reference, string|nil reason
function M.store(entry_id, token)
	if type(entry_id) ~= "string" or entry_id == "" or type(token) ~= "string" or token == "" then
		return nil, "an entry id and a key are required"
	end
	local unavailable = backend().unavailable()
	if unavailable then
		Logger.error(LOG, "API key of '%s' not stored: %s.", entry_id, unavailable)
		return nil, unavailable
	end
	local suffix = revision()
	if not suffix then return nil, "secure random revision unavailable" end
	local name = entry_id .. "#" .. suffix
	local called, ok, reason = pcall(with_keyboard, function() return backend().store(name, token) end)
	if not called then ok, reason = false, tostring(ok) end
	if ok ~= true then
		Logger.error(LOG, "API key of '%s' not stored in the secret service: %s.", entry_id, tostring(reason))
		return nil, tostring(reason)
	end
	Logger.info(LOG, "API key stored in the secret service as '%s'.", name)
	return M.REFERENCE_PREFIX .. name
end

--- Reads the keys several references name, in one keyboard hand-over.
--- @param references table List of references.
--- @return table tokens Reference to key, for those read.
--- @return table reasons Reference to the reason, for the others.
function M.lookup_many(references)
	local tokens, reasons = {}, {}
	if #references == 0 then return tokens, reasons end
	local unavailable = backend().unavailable()
	if unavailable then
		for _, reference in ipairs(references) do reasons[reference] = unavailable end
		Logger.error(LOG, "%d API key(s) not read: %s.", #references, unavailable)
		return tokens, reasons
	end
	local called, failure = pcall(with_keyboard, function()
		for _, reference in ipairs(references) do
			local token, reason = backend().lookup(name_of(reference))
			if type(token) == "string" and token ~= "" then tokens[reference] = token
			else reasons[reference] = tostring(reason or "no key") end
		end
	end)
	for _, reference in ipairs(references) do
		if not called and not tokens[reference] then reasons[reference] = tostring(failure) end
		if reasons[reference] then
			Logger.error(LOG, "API key '%s' not read from the secret service: %s.",
				name_of(reference), reasons[reference])
		end
	end
	return tokens, reasons
end

--- Deletes the key a reference names. An absent key counts as deleted.
--- @param reference string
--- @return boolean ok, string|nil reason
function M.clear(reference)
	if not M.is_reference(reference) then return false, "a secret-service reference is required" end
	local name = name_of(reference)
	local unavailable = backend().unavailable()
	if unavailable then
		Logger.error(LOG, "API key '%s' not deleted: %s.", name, unavailable)
		return false, unavailable
	end
	local called, ok, reason = pcall(with_keyboard, function() return backend().clear(name) end)
	if not called then ok, reason = false, tostring(ok) end
	if ok ~= true then
		Logger.error(LOG, "API key '%s' not deleted from the secret service: %s.", name, tostring(reason))
		return false, tostring(reason)
	end
	Logger.info(LOG, "API key '%s' deleted from the secret service.", name)
	return true
end





-- =========================================
-- =========================================
-- ======= 3/ Background Calls =============
-- =========================================
-- =========================================

local SECRET_INPUT_VARIABLE = "ERGOPTI_SECRET_TOOL_INPUT"
-- `$0` is the tool and `$@` its arguments: the key never enters the argv.
local FEED_SCRIPT = 'printf \'%s\' "$' .. SECRET_INPUT_VARIABLE .. '" | "$0" "$@"'
local _async_sequence = 0
-- The asynchronous process starter a test installed, or nil.
local _start_override = nil
-- The D-Bus query tool a test installed, or nil for gdbus.
local _probe_tool_override = nil

--- The daemon's environment as "NAME=value" rows, without the key variable.
--- @return table|nil rows
local function environment_rows()
	local loaded, uv = pcall(require, "luv")
	if not loaded or type(uv) ~= "table" or type(uv.os_environ) ~= "function" then return nil end
	local called, values = pcall(uv.os_environ)
	if not called or type(values) ~= "table" then return nil end
	local rows = {}
	for key, value in pairs(values) do
		if type(key) == "string" and type(value) == "string" and not key:find("=", 1, true)
			and not key:find("\0", 1, true) and not value:find("\0", 1, true) and key ~= SECRET_INPUT_VARIABLE then
			rows[#rows + 1] = key .. "=" .. value
		end
	end
	table.sort(rows)
	return rows
end

--- Runs one program as an owned child with a deadline and calls back once.
--- @param program string
--- @param args table
--- @param env table|nil "NAME=value" rows, nil to inherit.
--- @param timeout_ms number
--- @param callback function Receives (status|nil, stdout, stderr, reason|nil).
--- @return table|nil operation Its cancel() kills the child's process group.
local function run_async(program, args, env, timeout_ms, callback)
	_async_sequence = _async_sequence + 1
	local start = _start_override or require("adapters.owned_process").start
	local called, operation = pcall(start, program, args, {
		owner = "api_token_store:" .. _async_sequence, timeout_ms = timeout_ms, env = env,
	}, function(result)
		if type(result) ~= "table" then callback(nil, "", "", "no process result") return end
		local reason = result.error
		if reason == require("diagnostics.engine.adapter_errors").PROCESS_EXITED_UNSUCCESSFULLY then reason = nil end
		callback(reason == nil and result.exit_code or nil, result.stdout or "", result.stderr or "", reason)
	end)
	if not called or type(operation) ~= "table" then
		callback(nil, "", "", "the process could not start: " .. tostring(operation))
		return nil
	end
	-- A refused start settles through the same callback.
	return operation
end

--- Stores a key without blocking the event loop, under a new revision.
--- A store that passes its deadline is killed and refused; the reference is
--- only ever returned for a store secret-tool acknowledged.
--- @param entry_id string
--- @param token string A non-empty key.
--- @param timeout_ms number Deadline of the store.
--- @param callback function Receives (reference|nil, reason|nil).
--- @return table|nil operation The running child, for cancel().
function M.store_async(entry_id, token, timeout_ms, callback)
	assert(type(callback) == "function", "store_async(): a callback is required")
	if type(entry_id) ~= "string" or entry_id == "" or type(token) ~= "string" or token == "" then
		callback(nil, "an entry id and a key are required")
		return
	end
	if #token > SECRET_TOOL_INPUT_BYTES then callback(nil, "API key exceeds secret-tool input capacity") return end
	local unavailable = backend().unavailable()
	if unavailable then callback(nil, unavailable) return end
	local suffix = revision()
	if not suffix then callback(nil, "secure random revision unavailable") return end
	local name = entry_id .. "#" .. suffix
	if _backend then
		-- A test backend answers at once, as the fake service holds no prompt.
		local ok, reason = _backend.store(name, token)
		if ok == true then callback(M.REFERENCE_PREFIX .. name) else callback(nil, tostring(reason)) end
		return
	end
	local env = environment_rows()
	if not env then callback(nil, "the process environment is unreadable") return end
	env[#env + 1] = SECRET_INPUT_VARIABLE .. "=" .. token
	return run_async("sh", {
		"-c", FEED_SCRIPT, _tool_override or TOOL, "store",
		"--label=" .. Identifiers.app.name .. " API key " .. name,
		APPLICATION_ATTRIBUTE, Identifiers.app.name, KEY_ATTRIBUTE, name,
	}, env, timeout_ms, function(status, _, stderr, reason)
		if status == 0 then
			Logger.info(LOG, "API key stored in the secret service as '%s'.", name)
			callback(M.REFERENCE_PREFIX .. name)
			return
		end
		callback(nil, reason or failure_reason(stderr, status))
	end)
end

--- Deletes the key a reference names without blocking the event loop.
--- @param reference string
--- @param timeout_ms number
--- @param callback function Receives (ok, reason|nil).
--- @return table|nil operation The running child, for cancel().
function M.clear_async(reference, timeout_ms, callback)
	assert(type(callback) == "function", "clear_async(): a callback is required")
	if not M.is_reference(reference) then callback(false, "a secret-service reference is required") return end
	local name = name_of(reference)
	local unavailable = backend().unavailable()
	if unavailable then callback(false, unavailable) return end
	if _backend then
		local ok, reason = _backend.clear(name)
		callback(ok == true, ok == true and nil or tostring(reason))
		return
	end
	return run_async(_tool_override or TOOL, {
		"clear", APPLICATION_ATTRIBUTE, Identifiers.app.name, KEY_ATTRIBUTE, name,
	}, nil, timeout_ms, function(status, _, stderr, reason)
		if status == 0 then
			Logger.info(LOG, "API key '%s' deleted from the secret service.", name)
			callback(true)
			return
		end
		callback(false, reason or failure_reason(stderr, status))
	end)
end

--- Reads whether the default collection is locked, without ever prompting.
--- "unknown" when D-Bus cannot say (no gdbus, no service, no default
--- collection yet): a store may then be tried under its own deadline.
--- @param timeout_ms number
--- @param callback function Receives ("locked"|"unlocked"|"unknown", reason|nil).
--- @return table|nil operation The running child, for cancel().
function M.probe_lock_async(timeout_ms, callback)
	assert(type(callback) == "function", "probe_lock_async(): a callback is required")
	if _backend then
		local locked = type(_backend.locked) == "function" and _backend.locked() or nil
		callback(locked == true and "locked" or locked == false and "unlocked" or "unknown")
		return
	end
	local tool = _probe_tool_override or "gdbus"
	if not ShellRunner.has_command(tool, true) then callback("unknown", "gdbus is not installed") return end
	return run_async(tool, {
		"call", "--session", "--dest", "org.freedesktop.secrets",
		"--object-path", "/org/freedesktop/secrets/aliases/default",
		"--method", "org.freedesktop.DBus.Properties.Get", "org.freedesktop.Secret.Collection", "Locked",
	}, nil, timeout_ms, function(status, output, stderr, reason)
		if status == 0 and output:find("<true>", 1, true) then callback("locked") return end
		if status == 0 and output:find("<false>", 1, true) then callback("unlocked") return end
		callback("unknown", reason or failure_reason(stderr, status))
	end)
end

--- Replaces the asynchronous process starter (tests). nil restores it.
--- @param start function|nil OwnedProcess.start's signature.
function M._set_async_start_for_test(start)
	_start_override = start
end

--- Runs a stand-in for gdbus (tests). nil restores gdbus.
--- @param path string|nil An executable path.
function M._set_probe_tool_for_test(path)
	_probe_tool_override = path
end

--- Replaces the backend (tests): { unavailable(), store(name, token),
--- lookup(name), clear(name), locked()? } with secret-tool's results. nil restores it.
--- @param fake table|nil
function M._set_backend_for_test(fake)
	_backend = fake
end

--- Runs a stand-in for secret-tool (tests). nil restores secret-tool.
--- @param path string|nil An executable path.
function M._set_tool_for_test(path)
	_tool_override = path
end

return M
