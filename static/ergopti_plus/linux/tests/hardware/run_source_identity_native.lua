--- tests/hardware/run_source_identity_native.lua
--- ==============================================================================
--- MODULE: Native Constructor Source Spelling
--- DESCRIPTION:
--- Genuine cwd, loaded chunks and TOML constructors retain POSIX filename bytes.
--- No path aliases, source overrides or admission doubles grant constructor trust.
--- ==============================================================================

local driver = assert(arg[1])
local shared = driver .. "/../_shared/lua"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv = require("luv")
local root = assert(uv.fs_mkdtemp(assert(uv.os_tmpdir()) .. "/source-id-XXXXXX"))
local literal = root .. "/native\\\nname"
local separated = root .. "/native/\nname"
assert(uv.fs_mkdir(literal, 448))
assert(uv.fs_mkdir(root .. "/native", 448)); assert(uv.fs_mkdir(separated, 448))
-- The two modules' files relative to the shared root, found the way require
-- finds them, so the copied tree follows wherever the layout puts them.
local search = shared .. "/?.lua;" .. shared .. "/?/init.lua"
local function shared_relative(found) return found:sub(#shared + 2) end
local MIGRATION_FILE = shared_relative(assert(package.searchpath("config_migrate", search)))
local WRITER_FILE = shared_relative(assert(package.searchpath("toml_codec.writer", search)))
local made = {}
for _, relative in ipairs({ MIGRATION_FILE, WRITER_FILE }) do
	local folder, parent = literal, relative:match("^(.*)/[^/]+$") or ""
	for part in parent:gmatch("[^/]+") do
		folder = folder .. "/" .. part
		if not uv.fs_stat(folder) then assert(uv.fs_mkdir(folder, 448)); made[#made + 1] = folder end
	end
end
local function copy(relative)
	local input = assert(io.open(shared .. "/" .. relative, "rb"))
	local bytes = assert(input:read("*a")); assert(input:close())
	local output = assert(io.open(literal .. "/" .. relative, "wb"))
	assert(output:write(bytes)); assert(output:close())
end
copy(MIGRATION_FILE); copy(WRITER_FILE)
local original = assert(uv.cwd())
local ok, failure = xpcall(function()
	assert(uv.chdir(literal))
	local directory = assert(require("module_source_directory").capture())
	assert(directory == literal and directory == require("lfs").currentdir())
	local Source = require("module_source_identity")
	local chunk = assert(loadfile("./" .. MIGRATION_FILE))
	local actual = debug.getinfo(chunk, "S").source
	local normalized = assert(Source.normalize(actual, directory))
	assert(Source.normalize(normalized, directory) == normalized, "native source normalization must be idempotent")
	assert(not Source.same("@" .. literal .. "/" .. MIGRATION_FILE, "@" .. separated .. "/" .. MIGRATION_FILE),
		"different native component names must not become one loader source")
	package.path = "./?.lua;./?/init.lua;" .. package.path
	local writer = require("toml_codec.writer")
	assert(type(writer.batch_write) == "function", "the real canonical writer constructor must initialize")
	local Migration = require("config_migrate")
	local Codec = require("toml_codec.codec")
	local source = '[owned]\ntext = "literal"\n'
	assert(Codec.decode(source).owned.text == "literal")
	local model = assert(Migration.model_from_source(source))
	assert(Migration.plain(model).owned.text == "literal", "real migration and codec must preserve the decoded value")
	local expected = Source.sibling(debug.getinfo(writer.batch_write, "S").source,
		WRITER_FILE, MIGRATION_FILE, directory)
	assert(Source.same(debug.getinfo(Migration.writer_admission_factory, "S").source, expected, directory))
end, debug.traceback)
assert(uv.chdir(original))
for _, relative in ipairs({ WRITER_FILE, MIGRATION_FILE }) do assert(uv.fs_unlink(literal .. "/" .. relative)) end
for index = #made, 1, -1 do assert(uv.fs_rmdir(made[index])) end
for _, path in ipairs({ literal, separated, root .. "/native", root }) do assert(uv.fs_rmdir(path)) end
assert(ok, failure)
print("Native constructor source: actual cwd, distinct names, idempotence, writer/codec/migration accepted")
