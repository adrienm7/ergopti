--- tests/unit/modules/llm/test_ollama_install_resolver.lua

--- ==============================================================================
--- MODULE: Owned Ollama Installation Regression Cases
--- DESCRIPTION:
--- Registers independent controlled receipts through the normal Linux helpers.
--- Native archive, HTTP, process and installation acceptance are separate gates.
--- ==============================================================================

local helpers = require("tests.helpers")
local function expect(value, message) assert(value, message) end
local function test(name, body) helpers.it(name .. " (ollama-install)", body) end
local Policy = helpers.load_module("llm.ollama_install_policy")
local Resolver = helpers.load_module_with_dependency("modules.llm.ollama_install_resolver", "luv", false)
local Json, AppDirs = require("json"), require("app_dirs")
local source = assert(io.open(assert(require("infra.paths").shared("modules/llm/ollama_release.json")), "rb"))
local release_text = assert(source:read("*a")); assert(source:close())
local function release() return assert(Json.decode_lossless(release_text)) end
local catalogue = release()
local function fixture()
	local f = { nodes = {}, created = {}, uid = 1000, machine = "x86_64", next_inode = 1 }
	function f.node(path, uid, mode, kind)
		local value = { uid = uid, mode = mode, type = kind or "directory", dev = 7, ino = f.next_inode }
		f.next_inode = f.next_inode + 1 f.nodes[path] = value return value
	end
	f.node("/", 0, 493) f.node("/home", 0, 493) f.node("/home/test", 1000, 448)
	local native = {}
	function native.getuid() return f.uid end
	function native.os_uname() return { machine = f.machine } end
	function native.fs_lstat(path)
		local value = f.nodes[path]
		if not value then return nil, "not found", "ENOENT" end
		local copy = {} for key, item in pairs(value) do copy[key] = item end return copy
	end
	function native.fs_access() return f.access_refused ~= true end
	function native.fs_mkdir(path, mode)
		if f.mkdir_refused then return nil, "refused", "EACCES" end
		expect(not f.nodes[path], "exclusive missing-directory admission")
		f.node(path, 1000, mode) f.created[#f.created + 1] = path return true
	end
	f.options = { native = native, catalogue = release(), app_dirs = AppDirs, environment = { HOME = "/home/test" } }
	function f.new() return Resolver.new(f.options) end
	return f
end

test("canonical Linux asset comes from packaged catalogue", function()
	local asset = assert(Policy.asset(release(), "linux", "x86_64"))
	expect(asset.version == "0.24.0" and asset.key == "linux-amd64", "frozen authoritative version and architecture")
	expect(asset.bytes == 1198635318 and asset.sha256 == "15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb", "independent pinned byte/hash receipts")
end)

test("version asset and complete digest form immutable directory name", function()
	local asset = assert(Policy.asset(release(), "linux", "x86_64"))
	local plan = assert(Policy.posix_plan({ HOME = "/home/test" }, AppDirs, asset))
	expect(plan.directory == "/home/test/.local/share/ergopti_plus/runtimes/ollama/0.24.0-linux-amd64-15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb/ollama", "independent complete immutable name")
	expect(plan.executable == plan.directory .. "/bin/ollama" and plan.libraries == plan.directory .. "/lib/ollama", "whole archive layout")
end)

test("unsupported architecture never guesses a binary", function()
	local asset, reason = Policy.asset(release(), "linux", "riscv64")
	expect(asset == nil and reason == "ollama_architecture_unavailable", "unsupported platform is explicit")
end)

test("no HOME cannot borrow TMPDIR or guessed home", function()
	local directory, reason = Policy.data_root({ TMPDIR = "/tmp" })
	expect(directory == nil and reason == "user_home_unavailable", "temporary paths are not installation homes")
end)

test("relative XDG root cannot silently switch to HOME", function()
	local directory, reason = Policy.data_root({ XDG_DATA_HOME = "relative", HOME = "/home/test" })
	expect(directory == nil and reason == "xdg_data_home_invalid", "explicit unusable root refused")
end)

test("traversal repeated separator and NUL are refused", function()
	for _, path in ipairs({ "/home/test/../other", "/home/./test", "//home/test", "/home//test", "/home/test\0outside" }) do
		expect(Policy.canonical_posix_path(path) == nil, "ambiguous path cannot normalize into permission")
	end
	expect(Policy.canonical_posix_path("/home/test/") == "/home/test", "trailing slash alone is lexical normalization")
end)

test("release snapshot does not follow original catalogue mutation", function()
	local catalogue = release()
	local asset = assert(Policy.asset(catalogue, "linux", "x86_64"))
	catalogue.version = "99.0.0" catalogue.assets["linux-amd64"].sha256 = string.rep("b", 64)
	expect(asset.version == "0.24.0" and asset.sha256 == "15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb", "admitted canonical scalars frozen")
end)

test("construction is read-only and plan getters cannot rewrite owner", function()
	local f = fixture()
	local resolver = assert(f.new())
	local first = resolver.plan() first.directory = "/outside" first.asset.sha256 = string.rep("b", 64)
	expect(resolver.plan().directory ~= "/outside" and resolver.plan().asset.sha256 ~= first.asset.sha256, "sealed owner projections")
	expect(#f.created == 0 and resolver.current(), "menu resolution creates nothing")
end)

test("explicit consent creates only captured private missing parents", function()
	local f = fixture() local resolver = assert(f.new())
	expect(resolver.prepare({ explicit_consent = true, authorized = function() return true end }), "native parent receipts admitted")
	expect(#f.created > 0 and f.nodes[resolver.plan().parent].uid == 1000, "actual user owns install parent")
	for _, path in ipairs(f.created) do expect(f.nodes[path].mode == 448, "every new parent mode0700") end
	expect(f.nodes[resolver.plan().directory] == nil, "final no-clobber target stays absent for file owner")
end)

test("missing consent never creates a directory", function()
	local f = fixture() local resolver = assert(f.new())
	local ok, reason = resolver.prepare({ authorized = function() return true end })
	expect(not ok and reason == "install_consent_unavailable" and #f.created == 0, "no implicit preparation")
end)

test("intermediate ancestor symlink is refused before writes", function()
	local f = fixture() f.node("/home", 0, 493, "link")
	local resolver, reason = f.new()
	expect(resolver == nil and reason == "install_ancestor_not_directory" and #f.created == 0, "root-to-parent link checks")
end)

test("foreign nonroot ancestor cannot own user install", function()
	local f = fixture() f.nodes["/home"].uid = 2000
	local resolver, reason = f.new()
	expect(resolver == nil and reason == "install_ancestor_foreign_owner", "other user can replace their descendant entries")
end)

test("overflow namespace UID is never asserted to be root", function()
	local f = fixture() f.nodes["/"].uid = 65534
	local resolver, reason = f.new()
	expect(resolver == nil and reason == "install_ancestor_foreign_owner", "unknown unmapped ownership refuses honestly")
end)

test("group or other writable ancestor cannot borrow private child", function()
	for _, mode in ipairs({ 509, 495 }) do
		local f = fixture() f.nodes["/home"].mode = mode
		local resolver, reason = f.new()
		expect(resolver == nil and reason == "install_ancestor_writable_by_others", "mutable ancestor refused")
	end
end)

test("actual native UID ignores environment identity hints", function()
	local f = fixture() f.options.environment.USER = "root" f.options.environment.UID = 0
	local resolver = assert(f.new()) expect(resolver.plan().uid == 1000, "getuid is authority")
	f.uid = 2000 expect(not resolver.current(), "later native privilege identity change refused")
end)

test("same named ancestor inode replacement withdraws admission", function()
	local f = fixture() local resolver = assert(f.new()) f.node("/home/test", 1000, 448)
	expect(not resolver.current(), "exact native inode retained")
	expect(not resolver.prepare({ explicit_consent = true, authorized = function() return true end }) and #f.created == 0, "source stale before any write")
end)

test("new foreign prefix after capture cannot be adopted by retry", function()
	local f = fixture() local resolver = assert(f.new()) f.node("/home/test/.local", 1000, 448)
	expect(not resolver.current(), "captured absence cannot become third-party ownership")
	expect(not resolver.prepare({ explicit_consent = true, authorized = function() return true end }) and #f.created == 0, "fresh owner required")
end)

test("authorizer reentry cannot concurrently prepare same resolver", function()
	local f = fixture() local resolver = assert(f.new()) local nested, once
	local admission
	admission = { explicit_consent = true, authorized = function()
		if not once then once = true nested = resolver.prepare(admission) end return true
	end }
	expect(resolver.prepare(admission) and nested == false, "one native parent writer")
end)

test("source cancellation after first creation blocks all successors", function()
	local f = fixture() local resolver = assert(f.new())
	local ok = resolver.prepare({ explicit_consent = true, authorized = function() return #f.created == 0 end })
	expect(not ok and #f.created == 1, "currentness checked before each mkdir and final publication")
	expect(f.nodes[f.created[1]].uid == 1000, "only exact newly owned durable parent remains")
end)

test("native write-access refusal cannot masquerade as owner readiness", function()
	local f = fixture() f.access_refused = true
	local resolver, reason = f.new()
	expect(resolver == nil and reason == "install_writable_anchor_unavailable" and #f.created == 0, "real effective access receipt required")
end)
