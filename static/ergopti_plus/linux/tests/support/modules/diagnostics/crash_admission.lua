--- tests/support/modules/diagnostics/crash_admission.lua

-- Metadata fixtures own virtual file handles, not a running Logger core. Admit
-- their explicit privacy port with the real canonical policy and redactor before
-- they replace io.open. Real Sink admission is covered by test_crash_privacy.
local M = {}

function M.with_admission(body, identity)
	local Sink = require("infra.logger_sink")
	local previous = Sink.capture_redactor
	local root = require("infra.paths").shared_root()
	local file = assert(io.open(root .. "/modules/diagnostics/redaction.json", "rb"))
	local content = file:read("*a"); assert(file:close())
	local rules = require("json").decode(content)
	identity = identity or { home = require("infra.config_paths").account_home(), user = os.getenv("USER") or os.getenv("LOGNAME") }
	local context = { home = identity.home, user = identity.user, case_insensitive = false }
	assert(type(context.home) == "string" and type(context.user) == "string")
	local apply = require("diagnostics.redact").apply
	local active = true
	local function redact(text) assert(active); return apply(text, rules, context) end
	local capture
	capture = function()
		return redact, function() return active and Sink.capture_redactor == capture end
	end
	Sink.capture_redactor = capture
	local ok, err = xpcall(function() return body(redact) end, debug.traceback)
	active = false; Sink.capture_redactor = previous
	if not ok then error(err, 0) end
	return err
end

--- Models the canonical writer receipts for metadata-only virtual dump consumers.
--- Native acquisition, privacy and refusal controls remain in test_crash_privacy.
function M.with_output(body)
	local Writer = require("infra.regular_file_writer")
	local previous_open, previous_execute, previous_popen = Writer.open, os.execute, io.popen
	local parts = {}
	Writer.open = function(_, mode)
		assert(mode == "wx", "metadata output must retain exclusive report acquisition")
		local closed = false
		local file = {}
		function file:write(text)
			if closed then return nil end
			parts[#parts + 1] = text
			return self
		end
		function file:close()
			if closed then return false end
			closed = true
			return true
		end
		return file, nil, nil, nil, function(expected)
			return closed and table.concat(parts) == expected
		end
	end
	os.execute = function() return true end
	io.popen = function() return nil end
	local ok, result = xpcall(function()
		return M.with_admission(function(redact) return body(redact, parts) end)
	end, debug.traceback)
	Writer.open, os.execute, io.popen = previous_open, previous_execute, previous_popen
	if not ok then error(result, 0) end
	return result
end

return M
