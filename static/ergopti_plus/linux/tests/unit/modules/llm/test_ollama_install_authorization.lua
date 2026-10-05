--- tests/unit/modules/llm/test_ollama_install_authorization.lua

--- ==============================================================================
--- MODULE: Owned Ollama Installation Regression Cases
--- DESCRIPTION:
--- Registers independent controlled receipts through the normal Linux helpers.
--- Native archive, HTTP, process and installation acceptance are separate gates.
--- ==============================================================================

local helpers = require("tests.helpers")
local function expect(value, message) assert(value, message) end
local function test(name, body) helpers.it(name .. " (ollama-install)", body) end
local Resolver = helpers.load_module_with_dependency("modules.llm.ollama_install_resolver", "luv", false)
local Json, AppDirs = require("json"), require("app_dirs")
local source = assert(io.open(assert(require("infra.paths").shared("modules/llm/ollama_release.json")), "rb"))
local release_text = assert(source:read("*a")); assert(source:close())
local function release() return assert(Json.decode_lossless(release_text)) end
local catalogue = release()
local function fixture()
	local f = { nodes = {}, created = {}, inode = 1 }
	local function node(path, uid, mode)
		f.nodes[path] = { type = "directory", uid = uid, mode = mode, dev = 7, ino = f.inode }; f.inode = f.inode + 1
	end
	node("/", 0, 493); node("/home", 0, 493); node("/home/test", 1000, 448)
	local native = { getuid = function() return 1000 end, os_uname = function() return { machine = "x86_64" } end }
	function native.fs_lstat(path)
		local value = f.nodes[path]; if not value then return nil, "missing", "ENOENT" end
		local copy = {}; for key, item in pairs(value) do copy[key] = item end; return copy
	end
	function native.fs_access() return true end
	function native.fs_mkdir(path, mode)
		assert(f.nodes[path] == nil, "owned preparation cannot overwrite existing directory")
		node(path, 1000, mode); f.created[#f.created + 1] = path
		if f.after_mkdir then f.after_mkdir() end
		return true
	end
	f.resolver = assert(Resolver.new({ native = native, catalogue = catalogue, app_dirs = AppDirs, environment = { HOME = "/home/test" } }))
	return f
end
test("predicate replacement cannot borrow original consent for later mkdir", function()
	local f = fixture(); local original_calls, replacement_calls = 0, 0; local allowed = true; local admission
	admission = { explicit_consent = true, authorized = function()
		original_calls = original_calls + 1
		admission.authorized = function() replacement_calls = replacement_calls + 1; return true end
		return allowed
	end }
	f.after_mkdir = function() allowed = false end
	local accepted, reason = f.resolver.prepare(admission)
	assert(accepted == false and reason == "install_source_or_parent_stale", "revoked ORIGINAL predicate must refuse preparation")
	assert(#f.created == 1 and original_calls > 1 and replacement_calls == 0, "exact one admitted mkdir; replacement receives no authority")
end)
test("table replacement cannot revoke a still-current captured predicate", function()
	local f = fixture(); local replacement_calls = 0; local admission
	admission = { explicit_consent = true, authorized = function()
		admission.authorized = function() replacement_calls = replacement_calls + 1; return false end
		return true
	end }
	assert(f.resolver.prepare(admission) == true, "exact original predicate remains current")
	assert(#f.created > 1 and replacement_calls == 0 and f.resolver.current(), "captured predicate owns full prepared ancestry")
end)
test("reentrant prepare cannot acquire a second admission", function()
	local f = fixture(); local nested_ok, nested_reason; local entered = false
	assert(f.resolver.prepare({ explicit_consent = true, authorized = function()
		if not entered then entered = true; nested_ok, nested_reason = f.resolver.prepare({ explicit_consent = true, authorized = function() return true end }) end
		return true
	end }))
	assert(nested_ok == false and nested_reason == "install_resolver_already_prepared", "reentrant source cannot borrow preparation")
end)
