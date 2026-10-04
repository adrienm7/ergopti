--- modules/llm/mlx_bootstrap_diagnosis.lua

--- ==============================================================================
--- MODULE: MLX Bootstrap Diagnosis
--- DESCRIPTION:
--- Keeps the last lines an MLX runtime installation or import probe printed,
--- and names in plain words why it failed: access refused on a named path, a
--- Mac or a Python that MLX does not support, the developer tools macOS asks
--- for, a Gatekeeper refusal, a full disk, packages that do not import, or the
--- network. Only a typed native receipt identifies a network cause; unstructured
--- download stderr remains unknown. Non-network runtime repair diagnoses keep
--- their existing evidence and wording.
---
--- FEATURES & RATIONALE:
--- 1. The output is kept while it streams: a task's completion receives only
---    what its streaming callback did not already take, so a tail computed from
---    the completion alone was empty and every failure read "cause inconnue".
--- 2. The specific cause wins over the last line: the installer's retry loop
---    and its closing message both blame the network, so the line that names
---    the real cause is searched for in the whole retained tail.
--- 3. Pure: no native call, so the dependency checker, the import probe of the
---    models manager and the tests share one classifier and one wording.
--- 4. Generic curl failures, origin HTTP refusals and DNS/timeout text cannot
---    prove certificate, proxy, firewall or offline causes. The native owner
---    may supply a shared typed receipt; otherwise retry names the unknown
---    failure and retains its diagnostic tail without an invented cause.
--- ==============================================================================

local M = {}

-- Resolved per call: the locale owner is a stateful singleton that tests and
-- reloads replace, and a captured copy would keep speaking the old one.
local function i18n() return require("infra.i18n") end

-- Lines kept per tail. The installer retries uv six times and each attempt
-- prints its own verbose lines, so the cause line of the last attempt can sit
-- well above the closing messages.
local DEFAULT_MAX_LINES = 80

-- Longest line kept; a longer one keeps its head, where uv and Python name the
-- failing path.
local MAX_LINE_CHARS = 400

-- Longest detail quoted to the user.
local MAX_DETAIL_CHARS = 240

-- Cause kinds, from the most specific to the least. The first kind with a
-- matching line wins, so a permission error followed by the retry loop's
-- network messages is reported as the permission error it is.
M.KINDS = {
	"foreign_path", "developer_tools", "unsupported", "gatekeeper",
	"permission", "disk_full", "import_failed", "python",
}

-- The network classes, as _shared/modules/network/managed_network.json names
-- them for every driver; their sentence is the contract's message_key.
M.NETWORK_KINDS = { certificate = true, proxy = true, host_blocked = true, offline = true, network_unknown = true }

-- Case-insensitive plain substrings proving each kind.
local SIGNATURES = {
	-- ensure-mlx-deps.sh refused to delete a folder it does not own
	foreign_path = { "refusing to remove" },
	developer_tools = {
		"no developer tools were found", "command line developer tools",
		"invalid active developer path", "xcrun: error",
	},
	unsupported = {
		"wheel for the current platform", "only has wheels for",
		"bad cpu type in executable", "incompatible architecture",
		"mach-o file, but is an incompatible",
	},
	gatekeeper = {
		"library load disallowed by system policy", "not valid for use in process",
		"code signature", "com.apple.quarantine", "gatekeeper",
	},
	permission = {
		"permission denied", "operation not permitted", "os error 13",
		"os error 1)", "errno 13", "errno 1]", "eacces", "eperm",
		"read-only file system", "os error 30",
	},
	disk_full = { "no space left on device", "os error 28", "disk quota exceeded" },
	import_failed = {
		"modulenotfounderror", "importerror", "no module named",
		"packages do not import",
	},
	python = {
		"externally-managed-environment", "externally managed",
		"no interpreter found", "bad interpreter", "library not loaded",
		"symbol not found",
	},
}

-- Activity hints select the unknown download wording; they never establish a cause.
local NETWORK_ACTIVITY = {
	"curl:", "http ", "http/", "invalid peer certificate", "certificate verify failed",
	"unknownissuer", "proxy authentication", "failed to download", "failed to fetch",
	"error sending request", "could not resolve", "could not connect", "connection refused",
	"connection reset", "network is unreachable", "no route to host", "tcp connect error",
	"timed out", "request failed after", "dns error",
}

-- Retained diagnostic helper; a text hint no longer admits a host_blocked cause.
local DOWNLOAD_FAILURES = {
	"error sending request", "failed to download", "request failed after", "tcp connect error",
	"client error (connect)", "urlopen error", "failed to fetch", "curl: (7)",
}
-- What macOS says when a filter denies a process network access.
local CONNECTION_REFUSALS = { "operation not permitted", "os error 1)", "errno 1]" }

-- Kinds the repair (remove Ergopti's venv, reinstall it) can fix.
local REPAIRABLE = {
	developer_tools = true, gatekeeper = true, permission = true,
	disk_full = true, import_failed = true, python = true,
	certificate = true, proxy = true, host_blocked = true, offline = true, network_unknown = true,
	exit = true, venv_not_native = true,
}

-- Message key per kind.
local CAUSE_KEYS = {
	developer_tools = "mlx.cause_developer_tools",
	gatekeeper      = "mlx.cause_gatekeeper",
	disk_full       = "mlx.cause_disk_full",
	import_failed   = "mlx.cause_import",
	python          = "mlx.cause_python",
	certificate     = "network.failure.certificate",
	proxy           = "network.failure.proxy",
	host_blocked    = "network.failure.host_blocked",
	offline         = "network.failure.offline",
	network_unknown = "network.failure.unknown",
	-- Named before the installer starts (adapters/python_interpreter.lua): its
	-- fix is a native Python, which ui/python_runtime_offer.lua installs.
	no_native_python = "mlx.cause_no_native_python",
}





-- ==================================
-- ==================================
-- ======= 1/ Output Tail ===========
-- ==================================
-- ==================================

--- Normalizes one raw line: terminal colors and carriage-return progress go.
--- @param line string Raw line.
--- @return string clean Trimmed printable line, possibly empty.
local function clean_line(line)
	-- A pseudo-terminal lets uv color its output and redraw progress with CR.
	line = line:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("\27%][^\7]*\7", "")
	line = line:match("([^\r]*)\r*$") or line
	line = line:gsub("^%s+", ""):gsub("%s+$", "")
	if #line > MAX_LINE_CHARS then line = line:sub(1, MAX_LINE_CHARS) .. "…" end
	return line
end

--- Creates a bounded tail of the meaningful lines of a subprocess.
--- @param opts table|nil { max_lines = integer, markers = { [line] = true } }
--- @return table tail { push(chunk, stream), lines() }
function M.new_tail(opts)
	opts = type(opts) == "table" and opts or {}
	local max_lines = tonumber(opts.max_lines) or DEFAULT_MAX_LINES
	local markers = type(opts.markers) == "table" and opts.markers or {}
	local kept = {}
	local partial = {}

	local function keep(raw)
		local line = clean_line(raw)
		if line == "" or markers[line] then return end
		kept[#kept + 1] = line
		if #kept > max_lines then table.remove(kept, 1) end
	end

	local tail = {}

	--- Adds a chunk; a line split across chunks is joined before it is kept.
	--- @param chunk any Raw chunk; non-strings are ignored.
	--- @param stream string|nil Stream name, so two streams never splice lines.
	function tail.push(chunk, stream)
		if type(chunk) ~= "string" or chunk == "" then return end
		local key = stream or "out"
		local text = (partial[key] or "") .. chunk
		local start = 1
		while true do
			local stop = text:find("\n", start, true)
			if not stop then break end
			keep(text:sub(start, stop - 1))
			start = stop + 1
		end
		partial[key] = text:sub(start)
	end

	--- Returns the kept lines, oldest first, unfinished lines included.
	--- @return table lines Dense copy.
	function tail.lines()
		local copy = {}
		for index, line in ipairs(kept) do copy[index] = line end
		for _, key in ipairs({ "out", "stdout", "stderr" }) do
			local rest = partial[key] and clean_line(partial[key]) or ""
			if rest ~= "" and not markers[rest] then copy[#copy + 1] = rest end
		end
		return copy
	end

	return tail
end





-- ==================================
-- ==================================
-- ======= 2/ Classification ========
-- ==================================
-- ==================================

--- Extracts the path a failing line names.
--- @param line string Clean line.
--- @return string|nil path Absolute path, or nil.
local function path_in(line)
	local patterns = {
		"`(/[^`]+)`",
		"'(/[^']+)'",
		"\"(/[^\"]+)\"",
		"dlopen%((/[^,%)]+)",
		"(/[^:,%)]+):%s*[Pp]ermission denied",
		"(/[^:,%)]+):%s*[Oo]peration not permitted",
		"(/[^:,%)]+):%s*[Rr]ead%-only file system",
	}
	for _, pattern in ipairs(patterns) do
		local path = line:match(pattern)
		if path then return (path:gsub("%s+$", "")) end
	end
	return nil
end

--- Reports whether a line carries one of the signatures of a kind.
--- @param line string Clean line.
--- @param kind string Cause kind.
--- @return boolean matched
local function line_matches(line, kind)
	local lower = line:lower()
	for _, signature in ipairs(SIGNATURES[kind]) do
		if lower:find(signature, 1, true) then return true end
	end
	return false
end

--- Finds a connection the system refused: a download failed, and a line says
--- "Operation not permitted" without naming a file, the words macOS gives a
--- process a company filter or firewall denies network access.
--- @param lines table Clean lines, oldest first.
--- @return string|nil line The refusal, nil when none.
function M.refused_connection(lines)
	local downloading = false
	for _, line in ipairs(lines) do
		local lower = type(line) == "string" and line:lower() or ""
		for _, signature in ipairs(DOWNLOAD_FAILURES) do
			if lower:find(signature, 1, true) then downloading = true end
		end
	end
	if not downloading then return nil end
	for index = #lines, 1, -1 do
		local line = lines[index]
		local lower = type(line) == "string" and line:lower() or ""
		for _, signature in ipairs(CONNECTION_REFUSALS) do
			if lower:find(signature, 1, true) and path_in(line) == nil then return line end
		end
	end
	return nil
end

--- Names the cause of a failed installation or import probe.
--- @param lines table Clean lines, oldest first (see new_tail().lines()).
--- @param exit_code any Exit code of the subprocess.
--- @param context table|nil Platform context and optional network_receipt/network_contract from the native owner.
--- @return table cause { kind, line, path, exit_code, machine, repairable }
function M.classify(lines, exit_code, context)
	lines = type(lines) == "table" and lines or {}
	context = type(context) == "table" and context or {}
	local code = tonumber(exit_code)
	if context.network_receipt ~= nil then
		assert(type(context.network_contract) == "table" and type(context.network_contract.classify) == "function",
			"MLX typed failure needs the initialized shared network contract")
		local report = context.network_contract.classify(context.network_receipt, {})
		local kind = report.cause == "unknown" and "network_unknown" or report.cause
		if kind == "disk" then kind = "disk_full" end
		return { kind = kind, exit_code = code, repairable = true, network_report = report }
	end
	local network_line = nil
	for index = #lines, 1, -1 do
		local line = lines[index]
		if type(line) == "string" then
			for _, hint in ipairs(NETWORK_ACTIVITY) do
				if line:lower():find(hint, 1, true) then network_line = network_line or line end
			end
		end
	end
	for _, kind in ipairs(M.KINDS) do
		for index = #lines, 1, -1 do
			local line = lines[index]
			if type(line) == "string" and line_matches(line, kind)
				and not (kind == "permission" and network_line ~= nil and path_in(line) == nil) then
				-- A supported Mac with no wheel for "the current platform" was
				-- handed a foreign interpreter: the Python is at fault, not the Mac.
				local resolved = kind
				if kind == "unsupported" and context.platform_supported == true then
					resolved = "python"
				end
				return {
					kind = resolved,
					line = line,
					path = path_in(line),
					exit_code = code,
					machine = context.machine,
					repairable = REPAIRABLE[resolved] == true,
				}
			end
		end
	end
	if network_line then
		return { kind = "network_unknown", line = network_line, exit_code = code, repairable = true }
	end
	local last = nil
	for index = #lines, 1, -1 do
		if type(lines[index]) == "string" and lines[index] ~= "" then
			last = lines[index]
			break
		end
	end
	return { kind = "exit", line = last, exit_code = code, repairable = true }
end

--- Describes an unsupported Mac from its probes.
--- @param arch string|nil "arm64", "x86_64" or nil when unknown.
--- @param macos_major integer|nil macOS major version, nil when unknown.
--- @return string machine Localized description, e.g. "Intel processor, macOS 13".
function M.describe_machine(arch, macos_major)
	local parts = {}
	if arch == "x86_64" then
		parts[#parts + 1] = i18n().get("mlx.machine_intel")
	elseif arch == "arm64" then
		parts[#parts + 1] = i18n().get("mlx.machine_apple_silicon")
	end
	if tonumber(macos_major) then parts[#parts + 1] = "macOS " .. tostring(macos_major) end
	return table.concat(parts, ", ")
end





-- ==================================
-- ==================================
-- ======= 3/ Wording ===============
-- ==================================
-- ==================================

--- Shortens a detail line for display.
--- @param line string
--- @return string
local function short(line)
	if #line <= MAX_DETAIL_CHARS then return line end
	return line:sub(1, MAX_DETAIL_CHARS) .. "…"
end

--- The one sentence naming the cause.
--- @param cause table Cause from classify().
--- @return string sentence
function M.cause_sentence(cause)
	local kind = type(cause) == "table" and cause.kind or "exit"
	if type(cause) == "table" and type(cause.network_report) == "table" then
		return i18n().get(cause.network_report.message_key)
	end
	if kind == "permission" then
		if cause.path then return i18n().format("mlx.cause_permission", cause.path) end
		return i18n().get("mlx.cause_permission_generic")
	end
	if kind == "unsupported" then
		return i18n().format("mlx.cause_unsupported", cause.machine or "?")
	end
	if kind == "foreign_path" then
		return i18n().format("mlx.cause_foreign_path", tostring(cause.path))
	end
	if kind == "venv_not_native" then
		-- Named from the interpreter's header (mlx_deps_checker); never started.
		return i18n().format("mlx.cause_venv_not_native", tostring(cause.archs or "?"))
	end
	if kind == "developer_tools" then
		return i18n().format("mlx.cause_developer_tools", i18n().get("mlx.repair_button"))
	end
	local key = CAUSE_KEYS[kind]
	if key then return i18n().get(key) end
	return i18n().format("mlx.cause_exit", tostring(cause and cause.exit_code or "?"))
end

--- The proof quoted under the cause, or nil when the sentence says it all.
--- @param cause table Cause from classify().
--- @return string|nil detail
local function detail_of(cause)
	-- An unsupported Mac and a foreign folder are fully named by their sentence;
	-- their proof is a developer-facing line.
	if type(cause) == "table" and type(cause.line) == "string" and cause.line ~= ""
		and cause.kind ~= "unsupported" and cause.kind ~= "foreign_path" then
		return i18n().format("mlx.repair_detail", short(cause.line))
	end
	return nil
end

--- One line for the progress window: the cause, then its proof.
--- @param cause table Cause from classify().
--- @return string summary
function M.summary(cause)
	local sentence = M.cause_sentence(cause)
	local detail = detail_of(cause)
	if detail then return sentence .. " " .. detail end
	return sentence
end

--- The full explanation for the repair dialog: cause, proof, and what the
--- button does, or which backends work on an unsupported Mac.
--- @param cause table Cause from classify().
--- @param opts table|nil { venv = string|nil, log_path = string|nil }
--- @return string message Paragraphs separated by blank lines.
function M.describe(cause, opts)
	opts = type(opts) == "table" and opts or {}
	local paragraphs = { M.cause_sentence(cause) }
	local detail = detail_of(cause)
	if detail then paragraphs[1] = paragraphs[1] .. "\n" .. detail end
	if type(cause) == "table" and cause.kind == "unsupported" then
		paragraphs[#paragraphs + 1] = i18n().get("mlx.cause_unsupported_alternatives")
	elseif type(cause) == "table" and cause.repairable and type(opts.venv) == "string"
		-- A network failure's offer carries a retry, not the repair this names.
		and not M.NETWORK_KINDS[cause.kind] and type(cause.network_report) ~= "table" then
		paragraphs[#paragraphs + 1] = i18n().format("mlx.repair_action", opts.venv,
			i18n().get("mlx.repair_button"))
	end
	if type(opts.log_path) == "string" and opts.log_path ~= "" then
		paragraphs[#paragraphs + 1] = i18n().format("mlx.repair_log", opts.log_path)
	end
	return table.concat(paragraphs, "\n\n")
end

return M
