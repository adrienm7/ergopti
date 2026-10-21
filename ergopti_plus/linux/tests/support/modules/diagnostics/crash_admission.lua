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

return M
