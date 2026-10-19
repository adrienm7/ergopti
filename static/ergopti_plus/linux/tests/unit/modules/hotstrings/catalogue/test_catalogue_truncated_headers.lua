--- tests/unit/modules/hotstrings/catalogue/test_catalogue_truncated_headers.lua

--- ==============================================================================
--- MODULE: Real Catalogue Reloads Retain Complete Header Sources
--- DESCRIPTION:
--- Exercises the genuine reader, Linux configuration owner and shared matcher
--- against private files. A partial editor save must not replace healthy
--- expansions with a successful empty parse or poison their source snapshot.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv, Shell = require("luv"), require("adapters.shell_runner")
local Json = require("json")

--- Runs an isolated real catalogue without replacing any native file owner.
--- @param body function Receives config, engine, source path and write helper.
local function with_catalogue(body)
	-- Complete genuine constructor dependencies before any private owner exists.
	require("toml_codec.writer")
	require("config_file_inverse")
	local names = { "modules.hotstrings.hotstrings_config", "modules.hotstrings.loader", "toml_codec.reader" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-header-reload-XXXXXX"))
	local function write(path, content)
		local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
	end
	local Config
	local okay, detail = pcall(function()
		local choices = root .. "/choices.toml"
		write(choices, '[hotstrings.groups]\nmagickey = true\n[hotstrings.modules.magickey]\nprobe = true\n')
		Config = require("modules.hotstrings.hotstrings_config")
		assert(Config._set_config_file_for_test(choices)); assert(Config._set_override_config_dir_for_test(root))
		local engine = require("hotstring_engine").new()
		local path = root .. "/magickey.toml"
		assert(Config.init(engine, path))
		body(Config, engine, path, write)
	end)
	if Config then Config._set_config_file_for_test(nil); Config._set_override_config_dir_for_test(nil) end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
	if not okay then error(detail, 0) end
end

--- Independent editor source, accepted by the canonical hotstring dialect.
--- @param output string
--- @return string
local function source(output)
	return '[[probe]]\n"audit" = { output = ' .. Json.quote(output) .. ', auto_expand = true }\n'
end

--- Types through the real matcher rather than inspecting its internal mappings.
--- @param engine table
--- @return table|nil expansion
local function expand(engine)
	engine:reset()
	local result
	for character in ("audit"):gmatch(".") do result = engine:on_char(character) end
	return result
end

helpers.describe("real hotstring reload header integrity", function()
	for _, header in ipairs({ "[probe", "[[probe", "[[probe]", '["open]', "[probe] trailing" }) do
		helpers.it("(catalogue-header-reload) retains the last complete source through " .. header, function()
			with_catalogue(function(Config, engine, path, write)
				write(path, source("kept"))
				local count, committed = Config.load_all()
				helpers.assert_eq(committed, true); helpers.assert_eq(count, 1)
				helpers.assert_eq(expand(engine).replacement, "kept")
				write(path, header)
				local retained, accepted = Config.reload()
				helpers.assert_eq(accepted, true, "a known healthy source permits the aggregate to remain usable")
				helpers.assert_eq(retained, 1, "a partial header must not erase its active expansion")
				helpers.assert_eq(Config.parse_error_count(), 1, "the partial source is reported honestly")
				helpers.assert_eq(expand(engine).replacement, "kept")
				local file = assert(io.open(path, "rb"))
				helpers.assert_eq(assert(file:read("*a")), header, "reload must not rewrite the editor's partial source")
				assert(file:close())
				-- Another partial save must still find the original healthy snapshot.
				write(path, '[[probe]]\n"audit" = { output = "unfinished }\n')
				local again, recovered = Config.reload()
				helpers.assert_eq(recovered, true); helpers.assert_eq(again, 1)
				helpers.assert_eq(expand(engine).replacement, "kept")
				write(path, source("repaired"))
				local repaired, published = Config.reload()
				helpers.assert_eq(published, true); helpers.assert_eq(repaired, 1)
				helpers.assert_eq(Config.parse_error_count(), 0)
				helpers.assert_eq(expand(engine).replacement, "repaired", "repair must not retain a stale refusal")
			end)
		end)
	end

	helpers.it("(catalogue-header-reload) refuses a never-healthy header and publishes its later repair", function()
		with_catalogue(function(Config, engine, path, write)
			write(path, "[[probe")
			local count, committed = Config.load_all()
			helpers.assert_eq(committed, false, "an absent healthy snapshot never authorizes an empty publication")
			helpers.assert_eq(count, 0); helpers.assert_eq(Config.parse_error_count(), 1)
			helpers.assert_nil(expand(engine))
			write(path, source("repaired"))
			local repaired, published = Config.reload()
			helpers.assert_eq(published, true); helpers.assert_eq(repaired, 1)
			helpers.assert_eq(expand(engine).replacement, "repaired")
		end)
	end)
end)

helpers.describe("real hotstring reload logical-value integrity", function()
	for index, vector in ipairs({
		{ open = 'future_matrix = [\n', close = ']\n' },
		{ open = 'future_matrix = [\n [1, 2],\n', close = ']\n' },
		{ open = 'future_text = """\n[[not a header\n', close = '"""\n' },
		{ open = "future_text = '''\n[[not a header\n", close = "'''\n" },
	}) do
		helpers.it("(catalogue-value-eof) retains the healthy source until its logical value closes " .. index, function()
			with_catalogue(function(Config, engine, path, write)
				write(path, source("kept"))
				local count, committed = Config.load_all()
				helpers.assert_eq(committed, true); helpers.assert_eq(count, 1)
				helpers.assert_eq(expand(engine).replacement, "kept")
				local partial = '[_meta]\n' .. vector.open
				write(path, partial)
				local retained, accepted = Config.reload()
				helpers.assert_eq(accepted, true); helpers.assert_eq(retained, 1, "unfinished metadata must retain the healthy mapping")
				helpers.assert_eq(Config.parse_error_count(), 1)
				helpers.assert_eq(expand(engine).replacement, "kept")
				local _, reader_committed = require("toml_codec.reader").parse(path)
				helpers.assert_eq(reader_committed, false)
				local file = assert(io.open(path, "rb"))
				helpers.assert_eq(assert(file:read("*a")), partial); assert(file:close())
				-- Downstream header-looking data cannot make an open value complete.
				write(path, partial .. source("not committed"))
				local again, recovered = Config.reload()
				helpers.assert_eq(recovered, true); helpers.assert_eq(again, 1)
				helpers.assert_eq(Config.parse_error_count(), 1)
				helpers.assert_eq(expand(engine).replacement, "kept")
				write(path, partial .. vector.close .. source("repaired"))
				local repaired, published = Config.reload()
				helpers.assert_eq(published, true); helpers.assert_eq(repaired, 1)
				helpers.assert_eq(Config.parse_error_count(), 0)
				helpers.assert_eq(expand(engine).replacement, "repaired")
			end)
		end)
	end
end)
