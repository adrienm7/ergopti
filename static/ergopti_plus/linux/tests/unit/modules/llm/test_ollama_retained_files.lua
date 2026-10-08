--- static/ergopti_plus/linux/tests/unit/modules/llm/test_ollama_retained_files.lua
--- Independent original file-port model, copied without altering original corpus.
local helpers = require("tests.helpers")
local original_files = package.loaded["modules.llm.ollama_install_files"]
local function expect(value, message) assert(value, message) end
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

helpers.describe("Retained installation stage native receipts", function()
 helpers.it("prepares only original owned stage without archive descriptor or pathname", function()
  local f = fixture(); f.paths = assert(f.owner.prepare_retained())
  assert(f.paths.archive == nil and next(f.descriptors) == nil and f.next_directory == 1)
  assert(f.owner.retained_stage(function() return true end) == f.paths.stage)
  assert(f.owner.cleanup())
 end)
 helpers.it("reentrant source admission cannot substitute stage after first identity probe", function()
  local f = fixture(); f.paths = assert(f.owner.prepare_retained()); local probes = 0
  local stage = f.owner.retained_stage(function()
   probes = probes + 1; if probes == 2 then f.node(f.paths.stage, "directory") end; return true
  end)
  assert(stage == nil and probes == 2 and f.owner.cleanup() == false)
 end)
 helpers.it("substituted stage identity refuses reader destination before extraction", function()
  local f = fixture(); f.paths = assert(f.owner.prepare_retained())
  f.node(f.paths.stage, "directory")
  assert(f.owner.retained_stage(function() return true end) == nil)
  assert(f.owner.cleanup() == false, "foreign replacement is never removed")
 end)
 helpers.it("retained physical extraction still requires complete native runtime tree", function()
  local f = fixture(); f.paths = assert(f.owner.prepare_retained())
  assert(f.owner.admit_retained_extraction({ ok = true, exit_code = 0 }, function() return true end) == false)
  f.node(f.paths.stage .. "/bin", "directory"); f.node(f.paths.stage .. "/bin/ollama", "file", 1000, 420, 6)
  f.node(f.paths.stage .. "/lib", "directory"); f.node(f.paths.stage .. "/lib/ollama", "directory")
  assert(f.owner.admit_retained_extraction({ ok = true, exit_code = 1 }, function() return true end) == false)
  assert(f.owner.admit_retained_extraction({ ok = true, exit_code = 0 }, function() return true end))
  f.transfer(); assert(f.owner.admit_publication({ ok = true, exit_code = 0 }))
  assert(f.owner.cleanup() and f.owner.published)
 end)
 helpers.it("withdrawn branded reader admission cannot enable publication", function()
  local f = fixture(); f.paths = assert(f.owner.prepare_retained())
  assert(f.owner.retained_stage(function() return false end) == nil)
  assert(f.owner.admit_retained_extraction({ ok = true, exit_code = 0 }, function() return false end) == false)
  assert(f.owner.publish_command() == nil and f.owner.cleanup())
 end)
end)
package.loaded["modules.llm.ollama_install_files"] = original_files
