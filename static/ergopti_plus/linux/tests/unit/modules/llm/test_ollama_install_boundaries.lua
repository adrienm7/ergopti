--- tests/unit/modules/llm/test_ollama_install_boundaries.lua

--- ==============================================================================
--- MODULE: Owned Ollama Installation Regression Cases
--- DESCRIPTION:
--- Registers independent controlled receipts through the normal Linux helpers.
--- Native archive, HTTP, process and installation acceptance are separate gates.
--- ==============================================================================

local helpers = require("tests.helpers")
local function expect(value, message) assert(value, message) end
local function test(key, name, body) helpers.it(name .. " (ollama-install-boundary)", body) end
helpers.load_module("llm.ollama_archive_installer")
local Phase = helpers.load_module("llm.ollama_install_phase")
local Admission = helpers.load_module("modules.llm.ollama_install_admission")
local Resolver = helpers.load_module_with_dependency("modules.llm.ollama_install_resolver", "luv", false)
local fixture = helpers.load_module("tests.support.ollama_archive_fixture")
local Json, AppDirs = require("json"), require("app_dirs")
local source = assert(io.open(assert(require("infra.paths").shared("modules/llm/ollama_release.json")), "rb"))
local release_text = assert(source:read("*a")); assert(source:close())
local function release() return assert(Json.decode_lossless(release_text)) end
local catalogue = release()
local function phase()
	local f = fixture(); f.remaining, f.ancestry = 1000, true
	f.files.current = function() return f.ancestry end
	f.options.budget = { remaining_ms = function() return f.remaining end, current = function() return true end,
		on_cancel = function() return true end }
	function f.start() return Phase.start(f.ports, f.options, function(result) f.completions[#f.completions + 1] = result end) end
	return f
end
local function native_files(directory)
	local files = { directory = directory, cleanup = function() return true end }
	for _, name in ipairs({ "prepare", "admit_size", "hash_command", "admit_checksum", "extract_command", "admit_extraction", "publish_command", "admit_publication" }) do
		files[name] = function() return true end
	end
	return files
end
test("ancestor-first", "changed native ancestry prevents even prerequisite helper dispatch", function()
	local f = phase(); f.ancestry = false; local op = f.start()
	assert(op:is_settled() and not op.started and #f.calls == 0, "unavailable ancestry cannot launch helper")
end)
test("ancestor-later", "source callback ancestor substitution prevents successor dispatch", function()
	local f = phase(); local op = f.start()
	local first = f.calls[1]; first.deliver(); f.options.budget.current = function() return true end
	f.ancestry = false; first.retire()
	assert(op:is_settled() and #f.calls == 1, "no successor after native command/retirement ancestor drift")
end)
test("exported-admission", "exported native admission cannot borrow changed ancestry", function()
	local f = phase(); local op = f.start(); f.ancestry = false
	assert(f.calls[1].options.authorized() == false, "native helper admission requires exact current paths")
	op:cancel(); f.calls[1].retire()
end)
test("budget-after-source", "source callback budget exhaustion prevents initial helper dispatch", function()
	-- Cross initial owner, pump and step admission; exhaust at final native dispatch admission.
	local f = phase(); local calls = 0
	f.options.authorized = function() calls = calls + 1; if calls >= 4 then f.remaining = 0 end; return true end
	local op = f.start()
	assert(op:is_settled() and #f.calls == 0, "remainder must be fresh after the final source callback")
end)
test("budget-after-path", "native file admission cannot consume the budget then admit stale timeout", function()
	local f = phase(); f.files.current = function() f.remaining = 0; return true end
	local op = f.start(); assert(op:is_settled() and #f.calls == 0, "final path callback exhausted master budget")
end)
test("factory-mismatch", "native file owner must bind the captured immutable target", function()
	local resolver = { plan = function() return { directory = "/original/ollama" } end, current = function() return true end, prepare = function() return true end }
	local files = native_files("/different/ollama")
	local owner, reason = Admission.new(resolver, { new = function() return files end }, function() return true end, true)
	assert(owner == nil and reason == "install_file_owner_mismatch", "foreign factory receipt cannot own plan")
end)
test("factory-plan-alias", "factory cannot rewrite the captured plan into another target", function()
	local plan = { directory = "/original/ollama" }
	local resolver = { plan = function() return plan end, current = function() return true end, prepare = function() return true end }
	local files = native_files("/different/ollama")
	local owner, reason = Admission.new(resolver, { new = function(directory)
		assert(directory == "/original/ollama"); plan.directory = "/different/ollama"; return files
	end }, function() return true end, true)
	assert(owner == nil and reason == "install_file_owner_mismatch", "returned plan alias cannot change constructor ownership")
end)
test("resolver-private-current", "public current replacement cannot replace private ancestry admission", function()
	local nodes, created = {}, {}
	local function node(path, uid, mode, ino) nodes[path] = { type = "directory", uid = uid, mode = mode, dev = 7, ino = ino } end
	node("/", 0, 493, 1); node("/home", 0, 493, 2); node("/home/test", 1000, 448, 3)
	local native = { getuid = function() return 1000 end, os_uname = function() return { machine = "x86_64" } end,
		fs_access = function() return true end }
	function native.fs_lstat(path) if nodes[path] then return nodes[path] end return nil, "missing", "ENOENT" end
	function native.fs_mkdir(path, mode) created[#created + 1] = path; node(path, 1000, mode, 100 + #created); return true end
	local resolver = assert(Resolver.new({ native = native, catalogue = catalogue, app_dirs = AppDirs, environment = { HOME = "/home/test" } }))
	local altered = false
	local accepted, reason = resolver.prepare({ explicit_consent = true, authorized = function()
		if not altered then altered = true; node("/home/test", 1000, 448, 99); resolver.current = function() return true end end
		return true
	end })
	assert(accepted == false and reason == "install_source_or_parent_stale" and #created == 0, "private native checker must reject substituted ancestor")
end)
