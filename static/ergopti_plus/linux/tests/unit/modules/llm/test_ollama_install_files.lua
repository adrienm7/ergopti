--- tests/unit/modules/llm/test_ollama_install_files.lua

--- ==============================================================================
--- MODULE: Owned Ollama Installation Regression Cases
--- DESCRIPTION:
--- Registers independent controlled receipts through the normal Linux helpers.
--- Native archive, HTTP, process and installation acceptance are separate gates.
--- ==============================================================================

local helpers = require("tests.helpers")
local function expect(value, message) assert(value, message) end
local function test(name, body) helpers.it(name .. " (ollama-install)", body) end
local Files = helpers.load_module_with_dependency("modules.llm.ollama_install_files", "luv", false)
local function fixture()
	local f = { nodes = {}, next_inode = 1, descriptors = {}, unlinked = {}, next_directory = 0 }
	local function node(path, kind, uid, mode, size)
		local value = { type = kind, uid = uid or 1000, mode = mode or 448, size = size or 0, dev = 7, ino = f.next_inode }
		f.next_inode = f.next_inode + 1 f.nodes[path] = value return value
	end
	f.node = node
	node("/", "directory", 0, 493)
	node("/fixture", "directory", 1000, 448)
	local fs = {}
	f.backend = fs
	function fs.getuid() return 1000 end
	function fs.fs_lstat(path)
		local value = f.nodes[path]
		if not value then return nil, "missing", "ENOENT" end
		local copy = {} for key, item in pairs(value) do copy[key] = item end return copy
	end
	function fs.fs_access(path) return f.nodes[path] and true or nil end
	function fs.fs_mkdir(path, mode) if f.nodes[path] then return nil, "exists", "EEXIST" end node(path, "directory", 1000, mode) return true end
	function fs.fs_mkdtemp(template)
		f.next_directory = f.next_directory + 1
		local path = template:gsub("XXXXXX$", "unique" .. f.next_directory)
		node(path, "directory") return path
	end
	function fs.fs_open(path, flags, mode)
		expect(flags == "wx", "independent exclusive file creation")
		if f.nodes[path] then return nil, "exists", "EEXIST" end
		node(path, "file", 1000, mode)
		local fd = 30 + f.next_inode f.descriptors[fd] = true return fd
	end
	function fs.fs_close(fd) if f.close_refused then return nil, "refused", "EIO" end expect(f.descriptors[fd], "exact live descriptor") f.descriptors[fd] = nil return true end
	function fs.fs_chmod(path, mode) if f.chmod_refused then return nil, "refused", "EPERM" end f.nodes[path].mode = mode return true end
	function fs.fs_scandir(path)
		local names = {}
		for entry, value in pairs(f.nodes) do
			if entry:sub(1, #path + 1) == path .. "/" then
				local child = entry:sub(#path + 2)
				if not child:find("/", 1, true) then names[#names + 1] = { child, value.type } end
			end
		end
		table.sort(names, function(a, b) return a[1] < b[1] end)
		return { entries = names, next = 0 }
	end
	function fs.fs_scandir_next(iterator)
		if f.scandir_refused then return nil, "refused", "EIO" end
		iterator.next = iterator.next + 1
		local entry = iterator.entries[iterator.next]
		if entry then return entry[1], entry[2] end
	end
	function fs.fs_unlink(path) f.unlinked[#f.unlinked + 1] = path f.nodes[path] = nil return true end
	function fs.fs_rmdir(path)
		for entry in pairs(f.nodes) do if entry:sub(1, #path + 1) == path .. "/" then return nil, "not empty", "ENOTEMPTY" end end
		f.nodes[path] = nil return true
	end
	f.owner = assert(Files.new("/fixture/app/ollama", fs))
	f.asset = { bytes = 3, sha256 = string.rep("a", 64) }
	function f.prepare()
		f.paths = assert(f.owner.prepare()) f.nodes[f.paths.archive].size = 3 return f.paths
	end
	function f.verify()
		local accepted, reason = f.owner.admit_checksum(f.asset, {
			ok = true, exit_code = 0, stdout = string.rep("a", 64) .. "  " .. f.paths.archive .. "\0",
		})
		expect(accepted, reason)
	end
	function f.extract()
		node(f.paths.stage .. "/bin", "directory") node(f.paths.stage .. "/bin/ollama", "file", 1000, 420, 6)
		node(f.paths.stage .. "/lib", "directory") node(f.paths.stage .. "/lib/ollama", "directory")
		node(f.paths.stage .. "/lib/ollama/runtime.so", "file", 1000, 420, 9)
		expect(f.owner.admit_extraction({ ok = true, exit_code = 0 }), "complete tree admitted")
	end
	function f.transfer()
		local moved = {}
		for path, value in pairs(f.nodes) do
			if path == f.paths.stage or path:sub(1, #f.paths.stage + 1) == f.paths.stage .. "/" then
				moved[f.owner.directory .. path:sub(#f.paths.stage + 1)] = value f.nodes[path] = nil
			end
		end
		for path, value in pairs(moved) do f.nodes[path] = value end
	end
	return f
end

test("private staging exclusive archive and owner modes", function()
	local f = fixture() f.prepare()
	expect(f.nodes[f.paths.stage].mode == 448 and f.nodes[f.paths.archive].mode == 384, "0700 stage and0600 archive")
	expect(next(f.descriptors) == nil and f.owner.cleanup(), "actual close receipt and empty cleanup")
end)

test("foreign managed target preserved", function()
	local f = fixture() f.node(f.owner.directory, "directory", 2000)
	local paths, reason = f.owner.prepare()
	expect(paths == nil and reason == "install_target_not_absent", "existing target refused")
	expect(f.nodes[f.owner.directory].uid == 2000 and f.owner.cleanup(), "foreign tree untouched")
end)

test("symlink parent refused", function()
	local f = fixture() f.node("/fixture/app", "link")
	local paths, reason = f.owner.prepare()
	expect(paths == nil and reason == "install_parent_not_directory", "link cannot own private stage")
end)

test("shared writable parent refused", function()
	local f = fixture() f.node("/fixture/app", "directory", 1000, 511)
	local paths, reason = f.owner.prepare()
	expect(paths == nil and reason == "install_parent_writable_by_others", "0777 parent unsafe")
end)

test("foreign parent identity refused", function()
	local f = fixture() f.node("/fixture/app", "directory", 2000)
	local paths, reason = f.owner.prepare()
	expect(paths == nil and reason == "install_parent_not_owned", "actual UID ownership required")
end)

test("archive size is exact and pinned", function()
	local f = fixture() f.prepare() f.nodes[f.paths.archive].size = 4
	local ok, reason = f.owner.admit_size(f.asset)
	expect(not ok and reason == "archive_size_mismatch", "extra byte refused")
	expect(f.owner.extract_command() == nil and f.owner.cleanup(), "unverified archive cannot extract")
end)

test("same named replacement is not downloaded archive", function()
	local f = fixture() f.prepare() f.node(f.paths.archive, "file", 1000, 384, 3)
	local ok, reason = f.owner.admit_size(f.asset)
	expect(not ok and reason == "archive_identity_changed", "captured inode required")
	expect(f.owner.cleanup(), "private replacement stays within owned workspace cleanup")
end)

test("post-hash replacement cannot become extraction input", function()
	local f = fixture() f.prepare() f.verify() f.node(f.paths.archive, "file", 1000, 384, 3)
	local program, reason = f.owner.extract_command()
	expect(program == nil and reason == "archive_identity_changed", "post-checksum exact reserved inode required")
	expect(f.owner.cleanup(), "private workspace cleanup remains owned")
end)

test("post-hash size mutation cannot become extraction input", function()
	local f = fixture() f.prepare() f.verify() f.nodes[f.paths.archive].size = 4
	local program, reason = f.owner.extract_command()
	expect(program == nil and reason == "archive_size_mismatch", "admitted byte size retained")
	expect(f.owner.cleanup(), "mutated private archive cleaned")
end)

test("correct digest exact NUL receipt required", function()
	local f = fixture() f.prepare()
	local ok, reason = f.owner.admit_checksum(f.asset, { ok = true, exit_code = 0, stdout = string.rep("a", 64) .. "  " .. f.paths.archive .. "\n" })
	expect(not ok and reason == "archive_checksum_mismatch", "newline transcript cannot pass complete NUL receipt")
	f.verify() expect(f.owner.extract_command() == "tar", "verified archive alone admits extraction") f.owner.cleanup()
end)

test("wrong authoritative checksum cannot extract", function()
	local f = fixture() f.prepare()
	local ok, reason = f.owner.admit_checksum(f.asset, { ok = true, exit_code = 0, stdout = string.rep("b", 64) .. "  " .. f.paths.archive .. "\0" })
	expect(not ok and reason == "archive_checksum_mismatch" and f.owner.extract_command() == nil, "digest fails closed") f.owner.cleanup()
end)

test("failed checksum process cannot admit matching text", function()
	local f = fixture() f.prepare()
	local ok = f.owner.admit_checksum(f.asset, { ok = false, exit_code = 1, stdout = string.rep("a", 64) .. "  " .. f.paths.archive .. "\0" })
	expect(not ok and f.owner.extract_command() == nil, "exit receipt required") f.owner.cleanup()
end)

test("incomplete runtime library tree cannot publish", function()
	local f = fixture() f.prepare() f.verify()
	f.node(f.paths.stage .. "/bin", "directory")
	f.node(f.paths.stage .. "/bin/ollama", "file")
	local ok, reason = f.owner.admit_extraction({ ok = true, exit_code = 0 })
	expect(not ok and reason == "archive_runtime_tree_incomplete" and f.owner.publish_command() == nil, "whole tree required") f.owner.cleanup()
end)

test("intermediate bin symlink cannot redirect executable chmod", function()
	local f = fixture() f.prepare() f.verify()
	f.node(f.paths.stage .. "/bin", "link") f.node(f.paths.stage .. "/lib", "directory")
	f.node(f.paths.stage .. "/bin/ollama", "file", 1000, 384, 6)
	f.node(f.paths.stage .. "/lib/ollama", "directory")
	local ok, reason = f.owner.admit_extraction({ ok = true, exit_code = 0 })
	expect(not ok and reason == "archive_runtime_tree_incomplete", "intermediate bin link refused before descendants")
	expect(f.nodes[f.paths.stage .. "/bin/ollama"].mode == 384, "outside executable mode unchanged")
end)

test("intermediate lib symlink cannot admit runtime tree", function()
	local f = fixture() f.prepare() f.verify()
	f.node(f.paths.stage .. "/bin", "directory") f.node(f.paths.stage .. "/lib", "link")
	f.node(f.paths.stage .. "/bin/ollama", "file", 1000, 384, 6)
	f.node(f.paths.stage .. "/lib/ollama", "directory")
	local ok, reason = f.owner.admit_extraction({ ok = true, exit_code = 0 })
	expect(not ok and reason == "archive_runtime_tree_incomplete", "intermediate lib link refused")
	expect(f.nodes[f.paths.stage .. "/bin/ollama"].mode == 384, "refused library tree cannot chmod binary")
end)

test("exact atomic transfer proves installed directory", function()
	local f = fixture() f.prepare() f.verify() f.extract()
	local program, args = f.owner.publish_command()
	expect(program == "mv" and args[1] == "--no-clobber" and args[2] == "--no-target-directory", "GNU no overwrite flags")
	f.transfer()
	expect(f.owner.admit_publication({ ok = true, exit_code = 0 }) and f.owner.published, "same inode transfer accepted")
	expect(f.owner.cleanup() and f.nodes[f.owner.directory .. "/lib/ollama/runtime.so"], "published whole tree kept")
end)

test("mv zero exit with skipped foreign target is refused", function()
	local f = fixture() f.prepare() f.verify() f.extract() f.node(f.owner.directory, "directory", 2000)
	local ok, reason = f.owner.admit_publication({ ok = true, exit_code = 0 })
	expect(not ok and reason == "install_publication_not_owned", "mv-n skip is not success")
	expect(f.owner.cleanup() and f.nodes[f.owner.directory].uid == 2000, "foreign target preserved")
end)

test("late cancellation observes already published native identity", function()
	local f = fixture() f.prepare() f.verify() f.extract() f.transfer()
	expect(f.owner.cleanup() and f.owner.published and f.nodes[f.owner.directory], "cleanup observes transfer without callback")
end)

test("replaced staging identity blocks unsafe deletion", function()
	local f = fixture() f.prepare() f.node(f.paths.stage, "directory", 2000)
	expect(not f.owner.cleanup() and f.nodes[f.paths.stage].uid == 2000, "foreign same-name stage untouched")
end)

test("cleanup symlink is unlinked without traversal", function()
	local f = fixture() f.prepare() f.node(f.paths.stage .. "/outside-link", "link")
	f.node("/outside", "directory", 2000) f.node("/outside/private", "file", 2000)
	expect(f.owner.cleanup() and f.nodes["/outside/private"], "outside symlink target untouched")
end)

test("native scanner refusal remains honest cleanup debt", function()
	local f = fixture() f.prepare() f.scandir_refused = true
	expect(not f.owner.cleanup(), "failed iterator never means empty tree")
	f.scandir_refused = false expect(f.owner.cleanup(), "successful actual retry cleans owned stage")
end)

test("native descriptor close refusal cannot be forgotten", function()
	local f = fixture() f.close_refused = true
	local paths, reason = f.owner.prepare()
	expect(paths == nil and reason == "install_archive_close_refused" and next(f.descriptors), "exact open descriptor remains owned")
	expect(not f.owner.cleanup(), "failed close prevents settled files")
	f.close_refused = false expect(f.owner.cleanup() and next(f.descriptors) == nil, "later native close acknowledged")
end)
