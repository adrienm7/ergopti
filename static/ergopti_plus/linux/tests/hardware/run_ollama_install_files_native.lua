--- tests/hardware/run_ollama_install_files_native.lua

--- ==============================================================================
--- MODULE: Native Owned Ollama Archive Installation Receipts
--- DESCRIPTION:
--- Runs the independent tiny archive against real GNU helpers, native files and
--- exact physical process ownership. This proves neither official runtime bytes,
--- HTTPS transport, an owned server, a model nor application UI behavior.
--- The Python fixture builder supplies its independent byte/digest receipts and
--- the shared child subreaper must physically retire every adopted descendant.
--- ==============================================================================

local driver, shared, native_driver, native_shared, root, fixture_archive, fixture_bytes, fixture_digest = ...
assert(driver and shared and native_driver and native_shared and root and fixture_archive and tonumber(fixture_bytes) and fixture_digest)
package.path = native_driver .. "/?.lua;" .. native_shared .. "/?.lua;"
	.. driver .. "/?.lua;" .. shared .. "/?.lua;" .. package.path
local uv = require("luv")
local Files = require("modules.llm.ollama_install_files")
local Process = require("adapters.owned_process")
local Installer = require("llm.ollama_archive_installer")
local passed = 0
local process_serial = 0
local function expect(value, message) assert(value, message) end
local function test(name, body)
	local ok, reason = pcall(body)
	if not ok then io.stderr:write("FAIL ", name, ": ", tostring(reason), "\n") error(reason) end
	passed = passed + 1 io.write("PASS ", name, "\n")
end
local function process(program, args)
	local result
	process_serial = process_serial + 1
	local op = Process.start(program, args, { owner = "archive-fixture-" .. process_serial, timeout_ms = 10000, max_output_bytes = 65536 }, function(value) result = value end)
	while not op:is_settled() do uv.run("once") end
	expect(not uv.loop_alive(), "every native handle physically closed")
	expect(op.started and result and result.ok and result.exit_code == 0, "actual successful owned helper receipt")
	return result
end
local function copy_archive(path)
	local input = assert(io.open(fixture_archive, "rb")) local bytes = assert(input:read("*a")) assert(input:close())
	local output = assert(io.open(path, "wb")) assert(output:write(bytes)) assert(output:close())
end
local fixture_serial = 0
local function fixture()
	fixture_serial = fixture_serial + 1
	local parent = root .. "/fixture-" .. fixture_serial
	assert(uv.fs_mkdir(parent, 448))
	local owner = assert(Files.new(parent .. "/ollama"))
	local paths = assert(owner.prepare())
	copy_archive(paths.archive)
	local asset = { bytes = tonumber(fixture_bytes), sha256 = fixture_digest }
	return { parent = parent, owner = owner, paths = paths, asset = asset }
end
local function verify(f)
	expect(f.owner.admit_size(f.asset), "independent Python byte count")
	local program, args = f.owner.hash_command()
	expect(f.owner.admit_checksum(f.asset, process(program, args)), "independent Python digest matches actual GNU receipt")
end
local function extract(f)
	local program, args = f.owner.extract_command()
	expect(f.owner.admit_extraction(process(program, args)), "actual GNU zstd tree extraction")
end
local function publish(f)
	local program, args = f.owner.publish_command()
	return process(program, args)
end

test("real native prerequisite receipts", function()
	local definitions = {
		{ "sha256sum", { "--help" }, { "GNU coreutils", "--zero" } },
		{ "tar", { "--version" }, { "GNU tar" } },
		{ "tar", { "--help" }, { "--zstd", "--no-same-owner", "--no-same-permissions" } },
		{ "mv", { "--help" }, { "GNU coreutils", "--no-clobber", "--no-target-directory" } },
		{ "zstd", { "--version" }, { "Zstandard CLI" } },
	}
	for _, definition in ipairs(definitions) do
		local result = process(definition[1], definition[2])
		for _, expected in ipairs(definition[3]) do expect(result.stdout:find(expected, 1, true), "actual required native semantics") end
	end
end)

test("tiny independently hashed archive extracts and publishes full tree", function()
	local f = fixture() verify(f) extract(f)
	expect(f.owner.admit_publication(publish(f)) and f.owner.published, "actual no-clobber inode transfer")
	expect(uv.fs_lstat(f.owner.directory .. "/lib/ollama/native-fixture.txt").type == "file", "full sibling library tree preserved")
	expect(f.owner.cleanup() and uv.fs_lstat(f.owner.directory).type == "directory", "installed runtime kept")
end)

test("actual file transaction composes exact native helpers with local copy port", function()
	fixture_serial = fixture_serial + 1
	local parent = root .. "/fixture-" .. fixture_serial
	assert(uv.fs_mkdir(parent, 448))
	local files = assert(Files.new(parent .. "/ollama"))
	local completion, copy_count
	copy_count = 0
	local op = Installer.start({
		files = files, process = { start = Process.start },
		http = { get_owned = function(_, _, options, callback)
			expect(options.owner == "llm-ollama-install:" .. files.directory, "actual string HTTP owner ABI")
			copy_archive(options.output_path)
			copy_count = copy_count + 1
			local capability = { started = true }
			function capability:is_settled() return true end
			function capability:cancel() return true end
			function capability:on_settled(listener) listener() return true end
			callback({ ok = true, status = 200 })
			return capability
		end },
	}, {
		explicit_consent = true, authorized = function() return true end,
		timeout_ms = 10000, helper_timeout_ms = 10000,
		asset = { version = "0.24.0", name = "ollama-linux-amd64.tar.zst", bytes = tonumber(fixture_bytes), sha256 = fixture_digest,
			url = "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst" },
	}, function(result) completion = result end)
	while not op:is_settled() do uv.run("once") end
	expect(completion and completion.ok and completion.installed and copy_count == 1, "one local-copy fixture composes actual helpers and file receipts")
	expect(uv.fs_lstat(files.directory .. "/lib/ollama/native-fixture.txt").type == "file", "composed transaction preserves full library tree")
	expect(not uv.loop_alive(), "composed transaction returns after exact native cleanup")
end)

test("actual raced empty foreign destination survives mv no-clobber", function()
	local f = fixture() verify(f) extract(f)
	assert(uv.fs_mkdir(f.owner.directory, 448))
	local before = assert(uv.fs_lstat(f.owner.directory))
	local ok, reason = f.owner.admit_publication(publish(f))
	expect(not ok and reason == "install_publication_not_owned", "GNU zero skip not borrowed as success")
	expect(f.owner.cleanup(), "private stage/archive removed")
	local after = assert(uv.fs_lstat(f.owner.directory))
	expect(before.ino == after.ino and before.dev == after.dev, "foreign exact destination remains")
end)

test("actual hash cannot admit a wrong independent digest", function()
	local f = fixture() f.asset.sha256 = string.rep("b", 64)
	local program, args = f.owner.hash_command()
	local ok, reason = f.owner.admit_checksum(f.asset, process(program, args))
	expect(not ok and reason == "archive_checksum_mismatch" and f.owner.extract_command() == nil, "bad digest cannot extract")
	expect(f.owner.cleanup(), "bad archive cleaned after actual helper retirement")
end)

test("native post-hash archive replacement is refused before tar", function()
	local f = fixture() verify(f)
	assert(uv.fs_rename(f.paths.archive, f.paths.archive .. "-original"))
	copy_archive(f.paths.archive)
	local program, reason = f.owner.extract_command()
	expect(program == nil and reason == "archive_identity_changed", "native same-name new inode cannot borrow checksum")
	expect(f.owner.cleanup(), "owned workspace includes original and replacement")
end)

test("native intermediate bin link cannot chmod outside executable", function()
	local f = fixture() verify(f) extract(f)
	local outside = f.parent .. "/outside-bin"
	assert(uv.fs_mkdir(outside, 448))
	local output = assert(io.open(outside .. "/ollama", "wb")) assert(output:write("outside executable")) assert(output:close())
	assert(uv.fs_chmod(outside .. "/ollama", 384))
	assert(uv.fs_rename(f.paths.stage .. "/bin", f.paths.stage .. "/bin-original"))
	assert(uv.fs_symlink(outside, f.paths.stage .. "/bin"))
	local before = assert(uv.fs_lstat(outside .. "/ollama"))
	local ok, reason = f.owner.admit_extraction({ ok = true, exit_code = 0 })
	expect(not ok and reason == "archive_runtime_tree_incomplete", "native bin symlink refused")
	local after = assert(uv.fs_lstat(outside .. "/ollama"))
	expect(before.mode == after.mode and before.ino == after.ino, "outside exact executable untouched")
	expect(f.owner.publish_command() == nil and f.owner.cleanup(), "refused repeated receipt clears publication admission")
end)

test("native intermediate lib link cannot admit outside runtime tree", function()
	local f = fixture() verify(f) extract(f)
	local outside = f.parent .. "/outside-lib"
	assert(uv.fs_mkdir(outside, 448)) assert(uv.fs_mkdir(outside .. "/ollama", 448))
	assert(uv.fs_rename(f.paths.stage .. "/lib", f.paths.stage .. "/lib-original"))
	assert(uv.fs_symlink(outside, f.paths.stage .. "/lib"))
	assert(uv.fs_chmod(f.paths.stage .. "/bin/ollama", 384))
	local ok, reason = f.owner.admit_extraction({ ok = true, exit_code = 0 })
	expect(not ok and reason == "archive_runtime_tree_incomplete", "native lib symlink refused")
	expect(assert(uv.fs_lstat(f.paths.stage .. "/bin/ollama")).mode % 512 == 384, "binary chmod avoided on refused library root")
	expect(f.owner.publish_command() == nil and f.owner.cleanup(), "unpublishable staged tree cleaned")
end)

test("late cancelled publication retains actual verified tree", function()
	local f = fixture() verify(f) extract(f) publish(f)
	-- Deliberately suppress publication admission, as cancelled source delivery does.
	expect(f.owner.cleanup() and f.owner.published, "native identity observed independently during cleanup")
	expect(uv.fs_lstat(f.owner.directory .. "/bin/ollama").type == "file", "late cancellation does not erase installation")
end)

test("native cleanup unlinks a symlink without touching its outside target", function()
	local f = fixture()
	local outside = f.parent .. "/outside"
	assert(uv.fs_mkdir(outside, 448))
	local output = assert(io.open(outside .. "/keep.txt", "wb")) assert(output:write("outside")) assert(output:close())
	assert(uv.fs_symlink(outside, f.paths.stage .. "/outside-link"))
	expect(f.owner.cleanup(), "owned stage removed")
	expect(uv.fs_lstat(outside .. "/keep.txt").type == "file", "outside data preserved")
end)

test("native staging replacement keeps exact foreign inode", function()
	local f = fixture()
	assert(uv.fs_rename(f.paths.stage, f.paths.stage .. "-original"))
	assert(uv.fs_mkdir(f.paths.stage, 448))
	local replacement = assert(uv.fs_lstat(f.paths.stage))
	expect(not f.owner.cleanup(), "replaced identity cannot be deleted")
	expect(assert(uv.fs_lstat(f.paths.stage)).ino == replacement.ino, "replacement physically kept")
end)

expect(not uv.loop_alive(), "fixture returns with no native handles")
io.write("Install native filesystem receipts: ", passed, " passed, 0 failed.\n")
