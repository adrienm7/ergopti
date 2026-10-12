--- tests/unit/ui/menu/menu_llm/test_mlx_download_trust_activation.lua

--- ==============================================================================
--- MODULE: MLX Downloader System Trust Admission
--- DESCRIPTION:
--- Receives the actual downloader and its independent session metadata, and
--- preserves the original process-failure window and model/server verdict.
--- ==============================================================================

local helpers = require("tests.helpers")
local receiver = require("tests.support.mlx_truststore_fixture")
local support = require("tests.support.mlx_download_fixture")

helpers.describe("MLX downloader system trust admission", function()
	helpers.it("admits the managed receiver before emitting the native downloader", function()
		local calls = 0
		local network = {
			managed_http_prelude = function(tag)
				helpers.assert_eq(tag, "MLX")
				calls = calls + 1
				return "# qualified managed MLX receiver", nil
			end,
			opaque_prelude = function() error("Managed MLX must not require opaque PAC admission") end,
		}
		support.with_fixture({network_env = network}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			helpers.assert_eq(calls, 1)
			local launchers = 0
			for path, body in pairs(fixture.controls.files) do
				if path:match("%.sh$") then
					launchers = launchers + 1
					local runtime = assert(body:find("PYTHON_BIN=", 1, true))
					local admission = assert(body:find("# qualified managed MLX receiver", 1, true))
					helpers.assert_true(runtime < admission, "The receiver uses the pinned interpreter")
				end
			end
			helpers.assert_eq(launchers, 1)
		end)
	end)

	helpers.it("refuses missing managed admission without an opaque fallback or child", function()
		local network = {
			managed_http_prelude = function() return nil, "native receiver unavailable" end,
			opaque_prelude = function() error("A managed refusal must not start an opaque client") end,
		}
		support.with_fixture({network_env = network}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			support.assert_cancelled(fixture, "network_policy_missing")
			helpers.assert_eq(#fixture.controls.tasks.launcher, 0)
			helpers.assert_eq(fixture.records.server_starts, 0)
			helpers.assert_eq(fixture.records.successes, 0)
		end)
	end)

	helpers.it("captures the actual emitted source and exact published exit owner", function()
		local packet = receiver.capture()
		helpers.assert_type(packet.source, "string")
		helpers.assert_type(packet.expected_exit_path, "string")
		helpers.assert_eq(packet.expected_exit_path, packet.log_path .. ".exit")
	end)

	helpers.it("keeps failed trust activation on the existing process failure window", function()
		support.with_fixture({}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			support.launch_detached_download(fixture)
			fixture.controls.finish_download(1)
			support.assert_cancelled(fixture, "process_failed")
			helpers.assert_eq(fixture.records.server_starts, 0)
			helpers.assert_eq(fixture.records.successes, 0)
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], false)
			helpers.assert_nil(fixture.records.completions[1][3], "trust activation is no gated-model receipt")
		end)
	end)
end)

local producer_name = "ui.menu.menu_llm.models_manager_mlx_download"
local producer_location = producer_name:gsub("%.", "/") .. ".lua"
-- Selected by a declaration unique to ui/menu/menu_llm/models_manager_mlx_download.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local producer_source = helpers.read_driver_source("local function create_download_presentation")
helpers.assert_true(type(producer_source) == "string" and producer_source ~= "",
	"the original download producer must be locatable")

local function with_source_root(directory, callback)
	local saved = package.preload[producer_name]
	package.preload[producer_name] = function()
		return assert(load(producer_source, "@" .. directory .. "/" .. producer_location))()
	end
	local ok, err = xpcall(callback, debug.traceback)
	package.preload[producer_name] = saved
	if not ok then error(err, 0) end
end

local function with_quote(quote, callback)
	local Json = require("json")
	local saved = Json.quote
	Json.quote = function(value) return quote(value, saved) end
	local ok, err = xpcall(callback, debug.traceback)
	Json.quote = saved
	if not ok then error(err, 0) end
end

local function assert_no_helper(fixture)
	helpers.assert_eq(#fixture.controls.tasks.launcher, 0)
	helpers.assert_eq(fixture.records.server_starts, 0)
	helpers.assert_eq(fixture.records.successes, 0)
	helpers.assert_eq(fixture.records.saves, 0)
	for path in pairs(fixture.controls.files) do
		helpers.assert_eq(path:match("%.py$"), nil, "refusal must not publish a Python helper")
	end
end

local scalar_packets = {}

helpers.describe("MLX Python producer native JSON contract", function()
	helpers.it("writes the actual helper with a table-only native encoder (issue94-scalar)", function()
		support.with_fixture({}, function(f)
			helpers.assert_true(f.controls.pull())
			local helpers_written = 0
			for path, source in pairs(f.controls.files) do
				if path:match("%.py$") then
					helpers_written = helpers_written + 1
					helpers.assert_true(source:find("sys.path.insert(0, ", 1, true) ~= nil)
				end
			end
			helpers.assert_eq(helpers_written, 1)
			helpers.assert_eq(#f.controls.tasks.launcher, 1)
			helpers.assert_eq(f.records.server_starts, 0)
			helpers.assert_eq(f.records.successes, 0)
		end)
	end)
end)

helpers.describe("MLX helper directory quotation ownership", function()
	local directories = {
		"/tmp/plain",
		"/tmp/with spaces/quote'\"",
		"/tmp/café/漢字/😀",
		"/tmp/control\tline\nreturn\r\b\f",
		"/tmp/semicolon; import os; #",
		"/tmp/line\226\128\168paragraph\226\128\169end",
	}
	for index, directory in ipairs(directories) do
		helpers.it("emits independently receivable Python directory vector " .. index .. " (issue94-scalar)", function()
			with_source_root(directory, function()
				support.with_fixture({}, function(f)
					helpers.assert_true(f.controls.pull())
					local source
					for path, body in pairs(f.controls.files) do
						if path:match("%.py$") then source = body end
					end
					helpers.assert_type(source, "string")
					scalar_packets[#scalar_packets + 1] = {
						expected = directory .. "/platform/network", source = source,
					}
				end)
			end)
		end)
	end

	for index, directory in ipairs({ "/tmp/invalid\255", "/tmp/overlong\192\175", "/tmp/surrogate\237\160\128", "/tmp/too-high\244\144\128\128" }) do
		helpers.it("refuses invalid UTF-8 source directory " .. index .. " (issue94-scalar)", function()
			with_source_root(directory, function()
				support.with_fixture({}, function(f)
					helpers.assert_eq(f.controls.pull(), false)
					support.assert_cancelled(f, "network_policy_missing")
					assert_no_helper(f)
				end)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw", "empty" }) do
		helpers.it("refuses canonical quotation " .. mode .. " without fallback (issue94-scalar)", function()
			with_quote(function()
				if mode == "throw" then error("canonical quotation failure") end
				if mode == "false" then return false end
				if mode == "empty" then return "" end
				return nil
			end, function()
				support.with_fixture({}, function(f)
					helpers.assert_eq(f.controls.pull(), false)
					support.assert_cancelled(f, "network_policy_missing")
					assert_no_helper(f)
				end)
			end)
		end)
	end

	helpers.it("fences helper publication when quotation reenters requirement PAUSE (issue94-scalar)", function()
		support.with_fixture({ requirement_lifecycle = true }, function(f)
			with_quote(function(value, quote)
				f.records.quote_pause = f.controls.requirement_pause_join()
				return quote(value)
			end, function()
				helpers.assert_eq(f.controls.pull(), false)
				assert_no_helper(f)
				helpers.assert_eq(f.records.requirement_settlements, 1)
				support.assert_cancelled(f, "script_paused")
			end)
		end)
	end)
end)

local receiving_path = os.getenv("ERGOPTI_MLX_SCALAR_RECEIPT")
if receiving_path then
	local file = assert(io.open(receiving_path, "w"))
	assert(file:write(require("json").encode(scalar_packets)))
	assert(file:close())
end
