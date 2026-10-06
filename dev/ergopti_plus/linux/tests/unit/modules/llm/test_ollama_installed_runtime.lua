--- tests/unit/modules/llm/test_ollama_installed_runtime.lua

--- ==============================================================================
--- MODULE: Managed Runtime Logical Descriptor Regression Cases
--- DESCRIPTION:
--- Exercises complete native inventory drift without claiming an immutable FD
--- or process lease. Actual package execution remains a separate native gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local Runtime = helpers.load_module_with_dependency("modules.llm.ollama_installed_runtime", "luv", false)
local function test(name, body) helpers.it(name .. " (managed-ollama-runtime)", body) end
local function fixture()
	local f = { nodes = {}, inode = 1, uid = 1000, ancestry = true, reads = 0 }
	local directory = "/managed/ollama"
	f.plan = { directory = directory, executable = directory .. "/bin/ollama", libraries = directory .. "/lib/ollama", uid = 1000 }
	function f.node(path, kind, uid, mode, size)
		local value = { type = kind or "directory", uid = uid or 1000, mode = mode or 448, size = size or 0, dev = 7, ino = f.inode,
			mtime = { sec = 10, nsec = f.inode }, ctime = { sec = 20, nsec = f.inode } }
		f.inode = f.inode + 1; f.nodes[path] = value; return value
	end
	for _, path in ipairs({ directory, directory .. "/bin", directory .. "/lib", f.plan.libraries }) do f.node(path) end
	f.binary = f.node(f.plan.executable, "file", nil, 493, 9)
	f.library = f.node(f.plan.libraries .. "/libfixture.so", "file", nil, 420, 7)
	local fs = { getuid = function() return f.uid end, fs_access = function() return f.executable ~= false end }
	function fs.fs_lstat(path)
		f.reads = f.reads + 1
		if f.stat_refused then return nil, "permission denied", "EACCES" end
		local value = f.nodes[path]
		if not value then return nil, "missing", "ENOENT" end
		local copy = {}; for key, item in pairs(value) do
			if type(item) == "table" then copy[key] = { sec = item.sec, nsec = item.nsec } else copy[key] = item end
		end
		return copy
	end
	function fs.fs_scandir(path)
		local names = {}
		for candidate, value in pairs(f.nodes) do
			local relative = candidate:sub(#path + 2)
			if candidate:sub(1, #path + 1) == path .. "/" and not relative:find("/", 1, true) then
				names[#names + 1] = { name = relative, kind = value.type }
			end
		end
		table.sort(names, function(a, b) return a.name < b.name end)
		return { names = names, index = 0 }
	end
	function fs.fs_scandir_next(iterator)
		iterator.index = iterator.index + 1; local row = iterator.names[iterator.index]
		if row then return row.name, row.kind end
	end
	function fs.fs_readlink(path) return f.nodes[path].target end
	function fs.fs_realpath(path) return f.nodes[path].resolved end
	f.resolver = { plan = function() return f.plan end, current = function() return f.ancestry end }
	function f.capture() return Runtime.capture(f.resolver, fs) end
	return f
end
test("managed capture is read-only and returns only logical descriptor ownership", function()
	local f = fixture(); local result = f.capture()
	assert(result.status == "installed" and result.runtime.current() and result.runtime.executable() == f.plan.executable)
	assert(f.reads > 0 and not result.runtime.is_settled(), "descriptor acquired no native process/FD but remains logically held")
	assert(result.runtime.release() and result.runtime.is_settled())
end)
test("absent exact managed target is missing", function()
	local f = fixture(); f.nodes[f.plan.directory] = nil
	assert(f.capture().status == "missing")
end)
test("unreadable target cannot masquerade as missing installation", function()
	local f = fixture(); f.stat_refused = true; local result = f.capture()
	assert(result.status == "unavailable" and result.reason == "installed_runtime_stat_refused")
end)
test("foreign target cannot borrow a user-local descriptor", function()
	local f = fixture(); f.nodes[f.plan.directory].uid = 2000
	assert(f.capture().status == "unavailable")
end)
test("symlinked bin cannot redirect executable admission", function()
	local f = fixture(); f.nodes[f.plan.directory .. "/bin"].type = "link"
	assert(f.capture().status == "unavailable")
end)
test("binary X admission is required", function()
	local f = fixture(); f.executable = false; local result = f.capture()
	assert(result.status == "unavailable" and result.reason == "installed_runtime_binary_not_executable")
end)
test("same-inode same-length executable mtime edit invalidates captured runtime", function()
	local f = fixture(); local runtime = assert(f.capture().runtime)
	f.binary.mtime.nsec = f.binary.mtime.nsec + 1
	assert(runtime.current() == false and runtime.executable() == nil)
end)
test("same-inode same-length library ctime edit invalidates full inventory", function()
	local f = fixture(); local runtime = assert(f.capture().runtime)
	f.library.ctime.nsec = f.library.ctime.nsec + 1
	assert(runtime.current() == false, "directory inode and binary are unchanged; library receipt alone must withdraw admission")
end)
test("added library entry cannot borrow unchanged directory timestamps", function()
	local f = fixture(); local runtime = assert(f.capture().runtime)
	f.node(f.plan.libraries .. "/new.so", "file", nil, 420, 7)
	assert(runtime.current() == false, "inventory adds independent entry despite fixture's unchanged parent metadata")
end)
test("removed library entry withdraws admission", function()
	local f = fixture(); local runtime = assert(f.capture().runtime)
	f.nodes[f.plan.libraries .. "/libfixture.so"] = nil
	assert(runtime.current() == false)
end)
test("empty library directory is not a complete runtime", function()
	local f = fixture(); f.nodes[f.plan.libraries .. "/libfixture.so"] = nil; local result = f.capture()
	assert(result.status == "unavailable" and result.reason == "installed_runtime_libraries_empty")
end)
test("native UID change invalidates a logical descriptor", function()
	local f = fixture(); local runtime = assert(f.capture().runtime); f.uid = 2000
	assert(runtime.current() == false)
end)
test("native ancestry substitution invalidates descriptor before byte use", function()
	local f = fixture(); local runtime = assert(f.capture().runtime); f.ancestry = false
	assert(runtime.current() == false and runtime.executable() == nil)
end)
test("library link remains confined to the actual captured library tree", function()
	local f = fixture(); local path = f.plan.libraries .. "/alias.so"
	local link = f.node(path, "link", nil, 511, 13); link.target, link.resolved = "libfixture.so", f.plan.libraries .. "/libfixture.so"
	local runtime = assert(f.capture().runtime); assert(runtime.current())
	link.resolved = "/outside/user.so"
	assert(runtime.current() == false, "same named link cannot borrow outside bytes")
end)
test("logical release has immediate acknowledgement and suppresses future reads", function()
	local f = fixture(); local runtime = assert(f.capture().runtime); local acknowledged = 0
	runtime.on_settled(function() acknowledged = acknowledged + 1 end)
	local reads = f.reads
	assert(runtime.cancel() and runtime.is_settled() and acknowledged == 1)
	assert(runtime.current() == false and runtime.executable() == nil and f.reads == reads)
	assert(runtime.release() and acknowledged == 1, "logical release is idempotent; no physical retirement claim")
end)
