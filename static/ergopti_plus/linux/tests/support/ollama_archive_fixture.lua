--- tests/support/ollama_archive_fixture.lua

-- Independent fixture copied from the frozen archive qualification; expectations unchanged.
local Installer = require("llm.ollama_archive_installer")
local function expect(value, message) assert(value, message) end
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

return fixture
