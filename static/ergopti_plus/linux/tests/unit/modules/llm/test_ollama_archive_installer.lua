--- tests/unit/modules/llm/test_ollama_archive_installer.lua

--- ==============================================================================
--- MODULE: Owned Ollama Installation Regression Cases
--- DESCRIPTION:
--- Registers independent controlled receipts through the normal Linux helpers.
--- Native archive, HTTP, process and installation acceptance are separate gates.
--- ==============================================================================

local helpers = require("tests.helpers")
local function expect(value, message) assert(value, message) end
local function test(name, body) helpers.it(name .. " (ollama-install)", body) end
local Installer = helpers.load_module("llm.ollama_archive_installer")
local sequence = {
	{ program = "sha256sum", stdout = "GNU coreutils --zero" },
	{ program = "tar", stdout = "tar (GNU tar) 1.35" },
	{ program = "tar", stdout = "--zstd --no-same-owner --no-same-permissions" },
	{ program = "mv", stdout = "GNU coreutils --no-clobber --no-target-directory" },
	{ program = "zstd", stdout = "Zstandard CLI" },
	{ program = "HTTP", status = 200 },
	{ program = "sha256sum", stdout = "independent receipt interpreted by exact file owner" },
	{ program = "tar", stdout = "" },
	{ program = "mv", stdout = "" },
}
local serial = 0
local function fixture()
	serial = serial + 1
	local f = { current = true, calls = {}, completions = {}, cleanup_count = 0, prepare_count = 0, cleanup_ok = true }
	local files = { directory = "/fixture/transaction-" .. serial .. "/ollama", published = false }
	f.files = files
	function files.prepare() f.prepare_count = f.prepare_count + 1 return { archive = "/private/archive", stage = "/private/stage" } end
	function files.cleanup() f.cleanup_count = f.cleanup_count + 1 return f.cleanup_ok end
	function files.admit_size(asset) f.last_size_asset = asset return f.bad_size ~= true, "archive_size_mismatch" end
	function files.hash_command() return "sha256sum", { "--zero", "--", "/private/archive" } end
	function files.admit_checksum(asset) f.last_checksum_asset = asset return f.bad_checksum ~= true, "archive_checksum_mismatch" end
	function files.extract_command() return "tar", { "--zstd", "--extract" } end
	function files.admit_extraction() return true end
	function files.publish_command() return "mv", { "--no-clobber", "--no-target-directory" } end
	function files.admit_publication()
		if f.foreign_target then return false, "install_publication_not_owned" end
		files.published = true
		return true
	end
	local function launch(program, args, options, callback)
		local call = { program = program, args = args, options = options, callback = callback, retired = false, listeners = {}, cancelled = 0 }
		f.calls[#f.calls + 1] = call
		local op = { started = true }
		call.operation = op
		function op:is_settled() return call.retired end
		function op:cancel() call.cancelled = call.cancelled + 1 return false end
		function op:on_settled(fn) call.listeners[#call.listeners + 1] = fn if call.retired then fn() end return true end
		function call.deliver(result)
			local expected = sequence[#f.calls]
			call.callback(result or { ok = true, exit_code = 0, stdout = expected.stdout, status = expected.status })
		end
		function call.retire()
			call.retired = true
			for _, fn in ipairs(call.listeners) do fn() end
		end
		return op
	end
	f.ports = {
		files = files,
		process = { start = launch },
		http = { get_owned = function(url, headers, options, callback) return launch("HTTP", { url }, options, callback) end },
	}
	f.options = {
		explicit_consent = true, authorized = function() return f.current end,
		timeout_ms = 120000, helper_timeout_ms = 10000,
		asset = {
			version = "0.24.0", name = "ollama-linux-amd64.tar.zst", bytes = 1198635318,
			sha256 = "15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb",
			url = "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst",
		},
	}
	function f.start(options)
		return Installer.start(f.ports, options or f.options, function(result) f.completions[#f.completions + 1] = result end)
	end
	function f.through(index)
		for expected = #f.calls, index do
			local call = f.calls[expected]
			expect(call and call.program == sequence[expected].program, "independent expected step " .. expected)
			call.deliver()
			expect(#f.calls == expected, "callback alone must not admit successor")
			call.retire()
		end
	end
	return f
end

test("explicit consent prevents automatic installation", function()
	local f = fixture()
	f.options.explicit_consent = false
	local op = f.start()
	expect(op.started == false and op:is_settled(), "refusal physically empty")
	expect(#f.calls == 0 and f.prepare_count == 0, "no download/process/files writes")
end)

test("ordered receipts wait for every native retirement", function()
	local f = fixture()
	local op = f.start()
	f.through(9)
	expect(#f.calls == 9 and op:is_settled(), "all nine exact operations complete")
	expect(#f.completions == 1 and f.completions[1].ok and f.completions[1].installed, "runtime only complete result")
	expect(f.cleanup_count == 1 and f.prepare_count == 1, "owned file cleanup once")
	local http = f.calls[6].options
	expect(http.https_only and http.follow_redirects and http.output_path == "/private/archive", "owned TLS archive path")
	expect(http.max_download_bytes == 1198635318, "authoritative bound unchanged")
	expect(type(http.owner) == "string" and http.owner == "llm-ollama-install:" .. f.files.directory, "existing HTTP ABI never falls back to default owner")
	expect(f.calls[1].options.owner == http.owner and f.calls[9].options.owner == http.owner, "all native ports share the exact named transaction owner")
end)

test("authorizer cannot mutate admitted official asset scalars", function()
	local f = fixture()
	local changed
	f.options.authorized = function()
		if not changed then
			changed = true
			f.options.asset.url = "https://example.org/foreign.tar.zst"
			f.options.asset.bytes = 1
			f.options.asset.sha256 = string.rep("b", 64)
		end
		return true
	end
	local op = f.start() f.through(9)
	expect(op:is_settled() and op.result.ok, "original admitted asset survives authorizer mutation")
	expect(f.calls[6].args[1] == "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst", "original authoritative URL frozen")
	expect(f.calls[6].options.max_download_bytes == 1198635318 and f.last_size_asset.bytes == 1198635318, "pinned byte bound frozen")
	expect(f.last_checksum_asset.sha256 == "15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb", "pinned authoritative digest frozen")
end)

test("caller cannot replace asset while preflight awaits retirement", function()
	local f = fixture()
	local op = f.start()
	f.options.asset = { url = "https://example.org/foreign", bytes = 1, sha256 = string.rep("b", 64) }
	f.options.timeout_ms, f.options.helper_timeout_ms = 1, 1
	f.through(9)
	expect(op:is_settled() and op.result.ok, "frozen constructor admission preserved")
	expect(f.calls[6].options.max_download_bytes == 1198635318 and f.calls[6].options.timeout_ms == 120000, "archive limits frozen")
	expect(f.calls[9].options.timeout_ms == 10000, "helper deadline frozen")
end)

test("same target cannot acquire live predecessor", function()
	local f = fixture()
	local first = f.start()
	local second = f.start()
	expect(second.started == false and second:is_settled(), "successor refuses")
	expect(#f.calls == 1 and not first:is_settled() and f.cleanup_count == 0, "live predecessor preserved")
	first:cancel() f.calls[1].retire()
end)

test("authorizer reentry cannot overwrite reservation", function()
	local f = fixture()
	local inner, once
	f.options.authorized = function()
		if not once then once = true inner = f.start() end
		return true
	end
	local outer = f.start()
	expect(inner and inner.started == false and inner:is_settled(), "nested acquisition refuses reserved owner")
	expect(#f.calls == 1 and outer.started, "one physical dispatch")
	outer:cancel() f.calls[1].retire()
end)

test("cancelled download holds files and successor until physical close", function()
	local f = fixture()
	local op = f.start()
	f.through(5)
	expect(#f.calls == 6, "download reached")
	op:cancel()
	expect(not op:is_settled() and f.cleanup_count == 0, "cancel acceptance cannot remove live archive")
	expect(f.start().started == false, "same target still reserved")
	f.calls[6].retire()
	expect(op:is_settled() and f.cleanup_count == 1 and #f.calls == 6, "no checksum successor")
	expect(#f.completions == 1 and not f.completions[1].ok, "only separate refused contender result")
end)

test("cancellation after publication preserves verified installation", function()
	local f = fixture()
	local op = f.start()
	f.through(8)
	f.files.published = true -- Native inode transfer occurs before mv retirement.
	op:cancel()
	expect(not op:is_settled(), "publication helper retained")
	f.calls[9].retire()
	expect(op:is_settled() and op.result.installed and op.result.error == "cancelled", "honest kept installation")
	expect(#f.completions == 0, "no activation publication after cancellation")
end)

test("stale source suppresses archive callback and successors", function()
	local f = fixture()
	local op = f.start()
	f.through(5)
	f.current = false
	f.calls[6].deliver() f.calls[6].retire()
	expect(op:is_settled() and op.result.error == "install_source_stale", "exact stale source refused")
	expect(#f.calls == 6 and #f.completions == 0, "no hash or activation")
end)

test("unsupported native prerequisite cannot download", function()
	local f = fixture()
	local op = f.start()
	f.calls[1].deliver({ ok = true, exit_code = 0, stdout = "foreign checksum utility" })
	f.calls[1].retire()
	expect(op:is_settled() and op.result.error == "install_prerequisite_unsupported", "GNU semantics required")
	expect(f.prepare_count == 0 and #f.calls == 1, "no staging or archive")
end)

test("checksum mismatch cannot extract", function()
	local f = fixture()
	f.bad_checksum = true
	local op = f.start()
	f.through(7)
	expect(op:is_settled() and op.result.error == "archive_checksum_mismatch", "digest refused")
	expect(#f.calls == 7 and not f.files.published, "no extraction or publication")
end)

test("successful no-clobber skip cannot claim installation", function()
	local f = fixture()
	f.foreign_target = true
	local op = f.start()
	f.through(9)
	expect(op:is_settled() and not op.result.ok and not op.result.installed, "foreign target preserved and refusal reported")
	expect(op.result.error == "install_publication_not_owned", "exact identity receipt required")
end)

test("refused file cleanup retains owner and supports explicit retry", function()
	local f = fixture()
	f.cleanup_ok = false
	local op = f.start()
	f.through(9)
	expect(not op:is_settled() and op.cleanup_error == "install_file_cleanup_refused", "owned cleanup debt retained")
	expect(f.start().started == false, "successor blocked")
	f.cleanup_ok = true
	op:cancel()
	expect(op:is_settled() and op.result.installed, "later actual file receipt retires owner")
end)

test("physically settled operation without result is refused", function()
	local f = fixture()
	local op = f.start()
	f.calls[1].retire()
	expect(op:is_settled() and op.result.error == "install_receipt_missing", "no invented process success")
	expect(#f.calls == 1, "no successor")
end)

test("duplicate completion cannot qualify native receipt", function()
	local f = fixture()
	local op = f.start()
	f.calls[1].deliver() f.calls[1].deliver() f.calls[1].retire()
	expect(op:is_settled() and op.result.error == "install_duplicate_receipt", "exact single delivery required")
end)

test("foreign download provenance rejected before dispatch", function()
	local f = fixture()
	f.options.asset.url = "https://example.org/ollama-linux-amd64.tar.zst"
	local op = f.start()
	expect(op:is_settled() and not op.started and #f.calls == 0, "official pinned source required")
end)

test("throwing native dispatch retains unknown acquisition debt", function()
	local f = fixture()
	f.ports.process.start = function() error("unknown native acquisition") end
	local op = f.start()
	expect(not op:is_settled() and op.cleanup_error == "install_unknown_dispatch_debt", "exception never proves retirement")
	expect(f.start().started == false, "successor cannot borrow unknown cleanup")
end)

test("malformed native capability retains acquisition debt", function()
	local f = fixture()
	f.ports.process.start = function() return 42 end
	local op = f.start()
	expect(not op:is_settled() and op.result.error == "install_capability_malformed", "malformed native owner refused")
	expect(op.cleanup_error == "install_malformed_capability_debt", "no fabricated empty owner")
end)

test("missing native capability cannot fabricate empty acquisition", function()
	local f = fixture()
	f.ports.process.start = function() return nil end
	local op = f.start()
	expect(not op:is_settled() and op.result.error == "install_capability_malformed", "missing native ownership is not refusal proof")
	expect(op.cleanup_error == "install_malformed_capability_debt", "unknown native debt retained")
end)

test("refused native spawn cannot qualify delivered success", function()
	local f = fixture()
	local op = f.start()
	f.calls[1].operation.started = false
	f.calls[1].deliver() f.calls[1].retire()
	expect(op:is_settled() and op.result.error == "install_dispatch_refused" and #f.calls == 1, "physical spawn admission required")
end)

test("throwing source refuses before any native allocation", function()
	local f = fixture()
	f.options.authorized = function() error("source read refused") end
	local op = f.start()
	expect(op:is_settled() and not op.started and #f.calls == 0 and f.prepare_count == 0, "fail closed source")
end)
