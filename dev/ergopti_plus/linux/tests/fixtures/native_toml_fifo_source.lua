--- tests/fixtures/native_toml_fifo_source.lua

--- ==============================================================================
--- MODULE: Native TOML FIFO Source Fixture
--- DESCRIPTION:
--- Reads actual FIFOs, a FIFO symlink and regular/missing controls through the
--- classified FileSystem port, the shared TOML reader and an unchanged-source
--- publication. A regression blocks in open(2); the caller's deadline fails it.
--- The FIFOs have no writer, so no peer process or signal is simulated.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_toml_fifo_source%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local function run(command)
	local result = os.execute(command)
	assert(result == true or result == 0, "fixture command failed: " .. command)
end

local folder = os.tmpname()
os.remove(folder)
run("mkdir -m 700 " .. quote(folder))
local fifo, link = folder .. "/config.toml", folder .. "/linked.toml"
local regular, missing = folder .. "/regular.toml", folder .. "/missing.toml"
run("mkfifo " .. quote(fifo))
run("ln -s " .. quote(fifo) .. " " .. quote(link))
local file = assert(io.open(regular, "w"))
assert(file:write("[s]\nk = \"v\"\n"))
assert(file:close())

local FileSystem = require("adapters.file_system")
local Reader = require("toml_codec.reader")
local Writer = require("toml_codec.writer")
local checks, failures = 0, 0
local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, special in ipairs({ { "FIFO", fifo }, { "FIFO symlink", link } }) do
	local name, path = special[1], special[2]
	check(name .. " classified read is an error, not absence", function()
		local content, status = FileSystem.read_with_status(path)
		assert(content == nil and status == "error", tostring(status))
	end)
	check(name .. " shared TOML parse is refused", function()
		local _, committed = Reader.parse(path)
		assert(committed == false)
	end)
	check(name .. " create-only publication is refused", function()
		local committed = Writer.publish_if_unchanged(path, "k = 1\n", nil, { status = "absent" })
		assert(committed == false)
	end)
end
check("regular control keeps its bytes", function()
	local content, status = FileSystem.read_with_status(regular)
	assert(status == "ok" and content == "[s]\nk = \"v\"\n")
	local _, committed = Reader.parse(regular)
	assert(committed == true)
end)
check("missing control is a proven absence", function()
	local content, status = FileSystem.read_with_status(missing)
	assert(content == nil and status == "absent", tostring(status))
end)

os.remove(link); os.remove(fifo); os.remove(regular)
os.remove(fifo .. ".tmp"); os.remove(link .. ".tmp")
run("rmdir " .. quote(folder))
assert(checks == 8, "native TOML FIFO fixture lost a case")
print(string.format("Native TOML FIFO sources: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
