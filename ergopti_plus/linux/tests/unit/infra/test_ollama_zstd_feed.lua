--- tests/unit/infra/test_ollama_zstd_feed.lua

--- ==============================================================================
--- MODULE: Fixed Ollama Zstandard Feed Admission
--- DESCRIPTION:
--- Executes the actual lexical private feeder over controlled process/reader
--- ports. A fixture-owned native pipe is independently closed; command selection
--- is proven separately from zstd process, archive and kernel qualification.
--- ==============================================================================

local helpers = require("tests.helpers")

local function receive(mode)
	local actual_uv = require("luv")
	local path = require("infra.paths").driver_root() .. "/infra/archive_output.lua"
	local file = assert(io.open(path, "rb"))
	local source = assert(file:read("*a")); assert(file:close())
	local first = assert(source:find("local retained_tar_operations =", 1, true))
	local last = assert(source:find("--- Constructs only the fixed native registry;", first, true))
	local compile = loadstring or _G.load
	local construct = assert(compile(source:sub(first, last - 1) .. "\nreturn new_private_tar_feeder\n", "@actual-ollama-zstd-feeder"))()
	local names = { "luv", "infra.managed_http_deadline", "adapters.owned_process" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local pipe, captured, reads = nil, nil, 0
	local ok, reason = xpcall(function()
		pipe = assert(actual_uv.new_pipe(false))
		local uv = { hrtime = function() return 100000000 end, new_pipe = function() return pipe end }
		for _, name in ipairs({ "fs_read", "fs_close", "write", "shutdown" }) do
			uv[name] = function() error("no reader I/O in argument receiving model") end
		end
		local timer = { started = true }
		function timer:cancel() return true end
		function timer:is_settled() return true end
		function timer:on_settled(listener) listener(); return true end
		package.loaded.luv = uv
		package.loaded["infra.managed_http_deadline"] = { start = function() return timer end }
		package.loaded["adapters.owned_process"] = { start = function(program, args, options)
			assert(program == "tar" and options.stdin_owner.handle == pipe)
			captured = { args = args, options = options }
			local actor = { started = true }
			function actor:cancel() options.stdin_owner:cancel(); return true end
			function actor:is_settled() return false end
			function actor:on_settled() return true end
			return actor -- Modeled unresolved process, never a native settlement receipt.
		end }
		local feeder = assert(construct({ ffi = { new = function() return { [0] = -1 } end },
			symbols = { allocate_reader = function() reads = reads + 1; return -1 end } }, nil, true))
		local operation = feeder({ pointer = {}, committed = true }, mode, "/controlled/ollama-stage", 3,
			function() return true end, 200, function() end)
		if mode == "extract" then assert(operation and captured and reads == 1)
		else assert(operation == nil and captured == nil and reads == 0) end
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	local closed = false
	if pipe then actual_uv.close(pipe, function() closed = true end); actual_uv.run("nowait") end
	assert(not pipe or closed, "original fixture pipe requires actual close acknowledgement")
	if not ok then error(reason, 0) end
	return captured
end

helpers.describe("Fixed Ollama zstd feeder", function()
	helpers.it("extracts only the fixed zstd stdin command into the exact stage", function()
		local result = receive("extract")
		assert(helpers.deep_equal(result.args, { "--zstd", "--extract", "--file", "-", "--directory",
			"/controlled/ollama-stage", "--no-same-owner", "--no-same-permissions" }))
		assert(result.options.max_output_bytes == nil, "existing generic process output bound remains authoritative")
	end)
	helpers.it("refuses gzip names selection before any reader or process", function()
		assert(receive("names") == nil)
	end)
	helpers.it("refuses gzip verbose selection before any reader or process", function()
		assert(receive("verbose") == nil)
	end)
end)
