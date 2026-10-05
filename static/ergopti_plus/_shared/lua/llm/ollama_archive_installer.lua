--- _shared/lua/llm/ollama_archive_installer.lua

--- ==============================================================================
--- MODULE: Explicit Ollama Archive Installation Transaction (Scratch)
--- DESCRIPTION:
--- Coordinates Linux native file receipts with injected physically owned HTTP
--- and process capabilities. It never imports an alternative process policy.
--- No model installation, daemon startup, preference write or automatic consent
--- follows from installing the verified official runtime archive.
--- ==============================================================================

local M = {}
local owners = {}

local function successful(result)
	return type(result) == "table" and result.ok == true and result.exit_code == 0
end

local function valid_asset(asset)
	if type(asset) ~= "table" or type(asset.url) ~= "string" or type(asset.version) ~= "string"
		or not asset.version:match("^%d+%.%d+%.%d+$") or type(asset.name) ~= "string"
		or not asset.name:match("^ollama%-linux%-[a-z0-9]+%.tar%.zst$")
		or type(asset.sha256) ~= "string" or #asset.sha256 ~= 64 or not asset.sha256:match("^[0-9a-f]+$")
		or type(asset.bytes) ~= "number" or asset.bytes <= 0 or asset.bytes % 1 ~= 0 then return false end
	return asset.url == "https://github.com/ollama/ollama/releases/download/v" .. asset.version .. "/" .. asset.name
end

--- Starts one explicitly chosen archive transaction through strong native ports.
--- Process.start must return cancel/is_settled/on_settled; its callback supplies
--- { ok, exit_code, stdout }. HTTP.get_owned uses the existing Linux owned ABI.
--- Callbacks may arrive before retirement; the next step waits for settlement.
--- @param ports table { files, process, http }.
--- @param options table { asset, authorized, explicit_consent, timeout_ms, helper_timeout_ms }.
--- @param callback function Called only after complete physical/file cleanup.
--- @return table operation { started, result, cleanup_error, cancel, is_settled, on_settled }.
function M.start(ports, options, callback)
	local operation = { started = false }
	local settled, cancelled, terminal, dispatching, pumping = false, false, false, false, false
	local listeners, active, files, owner = {}, nil, nil, nil
	local step_index = 0
	local pump, finish, dispatch
	local source = type(options) == "table" and options.authorized or nil
	local asset = {}
	if type(options) == "table" and type(options.asset) == "table" then
		for _, field in ipairs({ "version", "name", "url", "bytes", "sha256" }) do asset[field] = rawget(options.asset, field) end
	end
	local timeout = type(options) == "table" and options.timeout_ms or nil
	local helper_timeout = type(options) == "table" and options.helper_timeout_ms or nil

	local function current()
		if cancelled or terminal or type(source) ~= "function" then return false end
		local ok, allowed = pcall(source)
		return ok and allowed == true and not cancelled and not terminal
	end

	local function notify(fn, ...)
		if type(fn) == "function" then pcall(fn, ...) end
	end

	local function retire()
		if settled or not terminal or dispatching or active then return end
		if files then
			local ok, clean = pcall(files.cleanup)
			if not ok or clean ~= true then operation.cleanup_error = "install_file_cleanup_refused" return end
		end
		settled = true
		operation.cleanup_error = nil
		if owner and owners[owner] == operation then owners[owner] = nil end
		operation.result.installed = files ~= nil and files.published == true
		local admit, allowed = pcall(source or function() return false end)
		if not cancelled and admit and allowed == true then notify(callback, operation.result) end
		local pending = listeners
		listeners = {}
		for _, listener in ipairs(pending) do notify(listener) end
	end

	finish = function(error_reason)
		if terminal then return end
		terminal = true
		operation.result = { ok = error_reason == nil, error = error_reason }
		if active and type(active.operation) == "table" and type(active.operation.cancel) == "function" then
			pcall(active.operation.cancel, active.operation)
		end
		retire()
	end

	function operation:is_settled() return settled end
	function operation:on_settled(listener)
		if type(listener) ~= "function" then return false end
		if settled then notify(listener) else listeners[#listeners + 1] = listener end
		return true
	end
	function operation:cancel()
		cancelled = true
		if not terminal then finish("cancelled") end
		if active and type(active.operation) == "table" and type(active.operation.cancel) == "function" then
			pcall(active.operation.cancel, active.operation)
		end
		if pump then pump() else retire() end
		return settled
	end

	if type(ports) ~= "table" or type(options) ~= "table" or type(callback) ~= "function"
		or type(source) ~= "function" or options.explicit_consent ~= true or not valid_asset(asset)
		or type(timeout) ~= "number" or timeout <= 0 or timeout % 1 ~= 0
		or type(helper_timeout) ~= "number" or helper_timeout <= 0
		or helper_timeout % 1 ~= 0 then finish("install_admission_invalid") return operation end
	files = ports.files
	if type(files) ~= "table" or type(files.directory) ~= "string" or type(ports.process) ~= "table"
		or type(ports.process.start) ~= "function" or type(ports.http) ~= "table"
		or type(ports.http.get_owned) ~= "function" then files = nil finish("install_port_unavailable") return operation end
	for _, name in ipairs({ "prepare", "admit_size", "hash_command", "admit_checksum", "extract_command",
		"admit_extraction", "publish_command", "admit_publication", "cleanup" }) do
		if type(files[name]) ~= "function" then files = nil finish("install_file_port_unavailable") return operation end
	end
	owner = files.directory
	if owners[owner] then files = nil finish("install_owner_busy") return operation end
	-- Reserve before the injected authorizer, which can synchronously reenter.
	owners[owner] = operation
	if not current() then finish("install_source_stale") return operation end
	operation.started = true
	local native_owner = "llm-ollama-install:" .. owner

	local function process(program, args, timeout, delivered)
		active.native_dispatch = true
		return ports.process.start(program, args, {
			owner = native_owner, authorized = current, timeout_ms = timeout, max_output_bytes = 65536,
		}, delivered)
	end

	local prerequisites = {
		{ "sha256sum", { "--help" }, { "--zero", "GNU coreutils" } },
		{ "tar", { "--version" }, { "GNU tar" } },
		{ "tar", { "--help" }, { "--zstd", "--no-same-owner", "--no-same-permissions" } },
		{ "mv", { "--help" }, { "--no-clobber", "--no-target-directory", "GNU coreutils" } },
		{ "zstd", { "--version" }, { "Zstandard CLI" } },
	}
	local steps = {}
	for _, prerequisite in ipairs(prerequisites) do
		local definition = prerequisite
		steps[#steps + 1] = {
			launch = function(delivered) return process(definition[1], definition[2], helper_timeout, delivered) end,
			admit = function(result)
				if not successful(result) or type(result.stdout) ~= "string" then return false, "install_prerequisite_unavailable" end
				for _, fragment in ipairs(definition[3]) do
					if not result.stdout:find(fragment, 1, true) then return false, "install_prerequisite_unsupported" end
				end
				return true
			end,
		}
	end
	steps[#steps + 1] = {
		launch = function(delivered)
			local paths, reason = files.prepare()
			if not paths then return nil, reason end
			if not current() then return nil, "install_source_stale" end
			active.native_dispatch = true
			return ports.http.get_owned(asset.url, {}, {
				owner = native_owner, output_path = paths.archive, follow_redirects = true, https_only = true,
				max_download_bytes = asset.bytes, timeout_ms = timeout,
			}, delivered)
		end,
		admit = function(result)
			if type(result) ~= "table" or result.ok ~= true or result.status ~= 200 then return false, "archive_download_failed" end
			return files.admit_size(asset)
		end,
	}
	steps[#steps + 1] = {
		launch = function(delivered)
			local program, args = files.hash_command()
			if not program then return nil, args end
			return process(program, args, timeout, delivered)
		end,
		admit = function(result) return files.admit_checksum(asset, result) end,
	}
	steps[#steps + 1] = {
		launch = function(delivered)
			local program, args = files.extract_command()
			if not program then return nil, args end
			return process(program, args, timeout, delivered)
		end,
		admit = files.admit_extraction,
	}
	steps[#steps + 1] = {
		launch = function(delivered)
			local program, args = files.publish_command()
			if not program then return nil, args end
			return process(program, args, helper_timeout, delivered)
		end,
		admit = files.admit_publication,
	}

	dispatch = function(step)
		if not current() then finish("install_source_stale") return end
		local receipt = { step = step, delivered = false }
		active = receipt
		dispatching = true
		local ok, capability, refusal = pcall(step.launch, function(result)
			if receipt.delivered then receipt.error = "install_duplicate_receipt" else
				receipt.delivered, receipt.result = true, result
			end
			if not dispatching then pump() end
		end)
		dispatching = false
		if not ok then
			-- An exception carries no acquisition/retirement receipt. Keep this debt.
			receipt.error = "install_dispatch_exception"
			operation.cleanup_error = "install_unknown_dispatch_debt"
			finish(receipt.error)
			return
		end
		if capability == nil and not receipt.native_dispatch then
			active = nil finish(refusal or "install_dispatch_refused") return
		end
		receipt.operation = capability
		if type(capability) ~= "table" or type(capability.cancel) ~= "function"
			or type(capability.is_settled) ~= "function" or type(capability.on_settled) ~= "function" then
			operation.cleanup_error = "install_malformed_capability_debt"
			finish("install_capability_malformed")
			return
		end
		local registered, accepted = pcall(capability.on_settled, capability, function() pump() end)
		if not registered or accepted ~= true then
			operation.cleanup_error = "install_settlement_listener_refused"
			finish("install_settlement_listener_refused")
		end
	end

	pump = function()
		if pumping or dispatching or settled then return end
		pumping = true
		while not settled do
			if active then
				local capability = active.operation
				if type(capability) ~= "table" or type(capability.is_settled) ~= "function" then break end
				local checked, retired = pcall(capability.is_settled, capability)
				if not checked or retired ~= true then break end
				local receipt = active
				active = nil
				if not terminal then
					if not current() then finish("install_source_stale")
					elseif receipt.error then finish(receipt.error)
					elseif capability.started ~= true then finish("install_dispatch_refused")
					elseif not receipt.delivered then finish("install_receipt_missing")
					else
						local admitted, accepted, reason = pcall(receipt.step.admit, receipt.result)
						if not admitted or accepted ~= true then finish(reason or "install_receipt_refused") end
					end
				end
			end
			if terminal then retire() break end
			if not current() then finish("install_source_stale") retire() break end
			step_index = step_index + 1
			local step = steps[step_index]
			if not step then finish(nil) retire() break end
			dispatch(step)
		end
		pumping = false
	end

	pump()
	return operation
end

return M
