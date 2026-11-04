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
assert(uv.fs_mkdir(literal .. "/toml_codec", 448))
local function copy(relative)
	local input = assert(io.open(shared .. "/" .. relative, "rb"))
	local bytes = assert(input:read("*a")); assert(input:close())
	local output = assert(io.open(literal .. "/" .. relative, "wb"))
	assert(output:write(bytes)); assert(output:close())
end
copy("config_migrate.lua"); copy("toml_codec/writer.lua")
local original = assert(uv.cwd())
local ok, failure = xpcall(function()
	assert(uv.chdir(literal))
	local directory = assert(require("module_source_directory").capture())
	assert(directory == literal and directory == require("lfs").currentdir())
	local Source = require("module_source_identity")
	local chunk = assert(loadfile("./config_migrate.lua"))
	local actual = debug.getinfo(chunk, "S").source
	local normalized = assert(Source.normalize(actual, directory))
	assert(Source.normalize(normalized, directory) == normalized, "native source normalization must be idempotent")
	assert(not Source.same("@" .. literal .. "/config_migrate.lua", "@" .. separated .. "/config_migrate.lua"),
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
		"toml_codec/writer.lua", "config_migrate.lua", directory)
	assert(Source.same(debug.getinfo(Migration.writer_admission_factory, "S").source, expected, directory))
end, debug.traceback)
assert(uv.chdir(original))
for _, path in ipairs({ literal .. "/toml_codec/writer.lua", literal .. "/config_migrate.lua" }) do assert(uv.fs_unlink(path)) end
for _, path in ipairs({ literal .. "/toml_codec", literal, separated, root .. "/native", root }) do assert(uv.fs_rmdir(path)) end
assert(ok, failure)
print("Native constructor source: actual cwd, distinct names, idempotence, writer/codec/migration accepted")
