--- tests/unit/modules/llm/runtime/test_shared_loader_sources.lua
--- ==============================================================================
--- MODULE: Native Shared LLM Source Admission
--- DESCRIPTION:
--- Exercises the finite packaged catalogue family through the real installed
--- child-layout resolver. Native owned children bound FIFO regressions and retire
--- before fixture cleanup; valid file symlinks retain their supported semantics.
--- ==============================================================================

local helpers = require("tests.helpers")
local CHILD_TIMEOUT_MS = 3000
local SOURCES = {
	{ "local", "local_servers.json" }, { "local", "api_providers.json" },
	{ "environment", "managed_ollama_environment.json" },
	{ "profile", "models.json" }, { "profile", "inference.json" },
}

--- Reads an acknowledged regular fixture document.
local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return bytes
end

--- Writes one exact fixture-owned regular document.
local function write(path, bytes)
	local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
end

--- Removes only the native scenario's owned tree without following file symlinks.
local function remove(uv, path)
	local scanner = uv.fs_scandir(path)
	if scanner then
		while true do
			local name, kind = uv.fs_scandir_next(scanner); if not name then break end
			local child = path .. "/" .. name
			if kind == "directory" then remove(uv, child) else assert(uv.fs_unlink(child)) end
		end
	end
	assert(uv.fs_rmdir(path))
end

--- Runs one actual loader in an isolated, admitted installed child layout.
local function observe(family, target, mode)
	local uv, Json = require("luv"), require("json")
	local root = helpers.driver_root()
	local base = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-shared-loader-XXXXXX"))
	local operation, result
	local ok, err = xpcall(function()
		local driver = base .. "/driver"
		for _, dir in ipairs({ driver, driver .. "/infra", driver .. "/_shared", driver .. "/_shared/data",
			driver .. "/_shared/data/locales", driver .. "/_shared/modules", driver .. "/_shared/modules/llm" }) do
			assert(uv.fs_mkdir(dir, 448))
		end
		write(driver .. "/infra/paths.lua", read(root .. "/infra/paths.lua"))
		write(driver .. "/_shared/data/locales/en.json", read(root .. "/../_shared/data/locales/en.json"))
		for _, source in ipairs(SOURCES) do
			write(driver .. "/_shared/modules/llm/" .. source[2], read(root .. "/../_shared/modules/llm/" .. source[2]))
		end
		local path = driver .. "/_shared/modules/llm/" .. target
		if mode == "symlink" then
			assert(uv.fs_rename(path, path .. ".regular")); assert(uv.fs_symlink(path .. ".regular", path))
		elseif mode == "fifo" or mode == "symlink-fifo" then
			assert(uv.fs_unlink(path))
			local fifo = mode == "fifo" and path or (path .. ".fifo")
			local status = os.execute("mkfifo -- " .. require("text_utils").shell_quote(fifo))
			assert(status == true or status == 0)
			if mode == "symlink-fifo" then assert(uv.fs_symlink(fifo, path)) end
		elseif mode == "eacces" then
			assert(uv.fs_chmod(path, 0))
		elseif mode == "directory" then
			assert(uv.fs_unlink(path)); assert(uv.fs_mkdir(path, 448))
		end
		local receipt = base .. "/receipt.json"
		operation = require("adapters.owned_process").start(assert(uv.exepath()), {
			root .. "/tests/fixtures/native_shared_loader.lua", root, driver, family, target, mode, receipt,
		}, { owner = base, timeout_ms = CHILD_TIMEOUT_MS }, function() end)
		local deadline = uv.hrtime() + CHILD_TIMEOUT_MS * 2 * 1000000
		while not operation:is_settled() and uv.hrtime() < deadline do uv.run("nowait"); uv.sleep(1) end
		helpers.assert_eq(operation:is_settled(), true, "the native child must retire before its paths can be removed")
		helpers.assert_eq(operation.result.ok, true,
			"the installed source must refuse a special endpoint without hanging: " .. target .. "/" .. mode
				.. " " .. tostring(operation.result.error) .. " " .. operation.result.stderr)
		result = assert(Json.decode(read(receipt)))
		helpers.assert_eq(result.admitted_child_layout, true)
		if mode == "close-refusal" then helpers.assert_eq(result.close_calls, 1, "the real stream close must be exercised") end
	end, debug.traceback)
	if operation and not operation:is_settled() then
		operation:cancel()
		while not operation:is_settled() do uv.run("nowait"); uv.sleep(1) end
	end
	remove(uv, base)
	if not ok then error(err, 0) end
	return result
end

if package.config:sub(1, 1) == "/" then
	helpers.describe("native shared LLM loader sources", function()
		for _, source in ipairs(SOURCES) do
			for _, mode in ipairs({ "regular", "symlink", "fifo", "symlink-fifo", "eacces", "directory", "close-refusal" }) do
				helpers.it("shared-loader-source " .. source[2] .. " " .. mode, function()
					local result = observe(source[1], source[2], mode)
					local permitted = mode == "regular" or mode == "symlink"
					if source[1] == "local" then
						helpers.assert_eq(result.published, permitted)
						helpers.assert_eq(result.optional_auth_allowed, permitted,
							"unacknowledged catalogue bytes cannot grant the actual caller's optional-auth capability")
						if permitted then helpers.assert_true(#result.order > 0) else helpers.assert_eq(result.order, {}) end
					elseif source[1] == "environment" then
						if permitted then
							helpers.assert_eq(result.rows, assert(require("modules.llm.managed_ollama_environment").decode(
								read(helpers.driver_root() .. "/../_shared/modules/llm/managed_ollama_environment.json"))))
						else
							helpers.assert_eq(result.rows, false); helpers.assert_eq(result.reason, "managed_environment_unreadable")
						end
					else
						local policy = require("json").decode(read(helpers.driver_root() .. "/../_shared/modules/llm/inference.json")).profile_recommendation
						local expected = permitted and require("modules.llm.model_profile").recommend_from("unlisted:999b", {}, policy) or "basic"
						helpers.assert_eq(result.profile, expected, "source refusal retains the existing unavailable-profile contract")
					end
				end)
			end
		end
	end)
end
