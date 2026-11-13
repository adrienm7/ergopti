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
local TIMINGS_SOURCE = require("core.timing.engine.timings_core").REGISTRY_REL_PATH
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
	local uv, Json = require("luv"), require("core.text.engine.json")
	local root = helpers.driver_root()
	local base = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-shared-loader-XXXXXX"))
	local operation, result
	local ok, err = xpcall(function()
		local driver = base .. "/driver"
		for _, dir in ipairs({ driver, driver .. "/infra", driver .. "/_shared", driver .. "/_shared/core", driver .. "/_shared/core/i18n", driver .. "/_shared/core/i18n/data", driver .. "/_shared/core/i18n/data/locales", driver .. "/_shared/ai", driver .. "/_shared/ai/data" }) do
			assert(uv.fs_mkdir(dir, 448))
		end
		-- The timings owner names its own place; each missing folder of it is made.
		local timings_dir = driver .. "/_shared"
		for part in require("core.fs.engine.native_path").dirname(TIMINGS_SOURCE):gmatch("[^/]+") do
			timings_dir = timings_dir .. "/" .. part
			if not uv.fs_stat(timings_dir) then assert(uv.fs_mkdir(timings_dir, 448)) end
		end
		write(driver .. "/core/fs/engine/paths.lua", assert(helpers.read_module_source("core.fs.engine.paths")))
		write(driver .. "/_shared/core/i18n/data/locales/en.json", read(root .. "/../_shared/core/i18n/data/locales/en.json"))
		-- The environment loader's shared timings owner reads this installed resource.
		write(driver .. "/_shared/" .. TIMINGS_SOURCE, read(root .. "/../_shared/" .. TIMINGS_SOURCE))
		for _, source in ipairs(SOURCES) do
			write(driver .. "/_shared/ai/data/" .. source[2], read(root .. "/../_shared/ai/data/" .. source[2]))
		end
		local path = driver .. "/_shared/ai/data/" .. target
		if mode == "symlink" then
			assert(uv.fs_rename(path, path .. ".regular")); assert(uv.fs_symlink(path .. ".regular", path))
		elseif mode == "fifo" or mode == "symlink-fifo" then
			assert(uv.fs_unlink(path))
			local fifo = mode == "fifo" and path or (path .. ".fifo")
			local status = os.execute("mkfifo -- " .. require("core.text.engine.utils_core").shell_quote(fifo))
			assert(status == true or status == 0)
			if mode == "symlink-fifo" then assert(uv.fs_symlink(fifo, path)) end
		elseif mode == "eacces" then
			assert(uv.fs_chmod(path, 0))
		elseif mode == "directory" then
			assert(uv.fs_unlink(path)); assert(uv.fs_mkdir(path, 448))
		end
		local receipt = base .. "/receipt.json"
		operation = require("core.process.adapters.owned_process").start(assert(uv.exepath()), {
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
								read(helpers.driver_root() .. "/../_shared/ai/data/managed_ollama_environment.json"))))
						else
							helpers.assert_eq(result.rows, false); helpers.assert_eq(result.reason, "managed_environment_unreadable")
						end
					else
						local policy = require("core.text.engine.json").decode(read(helpers.driver_root() .. "/../_shared/ai/data/inference.json")).profile_recommendation
						local expected = permitted and require("modules.llm.model_profile").recommend_from("unlisted:999b", {}, policy) or "basic"
						helpers.assert_eq(result.profile, expected, "source refusal retains the existing unavailable-profile contract")
					end
				end)
			end
		end
	end)
end

for _, case in ipairs({
	{ name = "remote provider catalogue", module = "modules.llm.api_remote", path = "ai/data/api_providers.json",
		invoke = function(owner) return owner.provider("openai") ~= nil end, returns_false = true },
	{ name = "reasoning policy", module = "modules.llm.api_remote", path = "ai/data/thinking_off.json",
		invoke = function(owner) return owner.ollama_think("gpt-oss:20b") end, returns_false = true },
	{ name = "inference", module = "modules.llm.inference", path = "ai/data/inference.json",
		invoke = function(owner) return owner.variant_temperature(0.5, 1) end, raises = true },
	{ name = "backend brands", module = "modules.llm.backend_brands", path = "ai/data/backends.json",
		invoke = function(owner) return owner.brand("ollama") end, raises = true },
	{ name = "translation prompt", module = "modules.llm.translation", path = "ai/data/translate.json",
		invoke = function(owner) return owner.data() end },
	{ name = "translation names", module = "modules.llm.translation", path = "core/i18n/data/locale_names.json",
		invoke = function(owner) return owner.data() end },
	{ name = "translation order", module = "modules.llm.translation", path = "core/i18n/data/locale_order.json",
		invoke = function(owner) return owner.data() end },
}) do
	helpers.it("shared config refuses FIFO in " .. case.name, function()
		local uv, Paths = require("luv"), require("core.fs.engine.paths")
		local original_shared, original_module = Paths.shared, package.loaded[case.module]
		local source = assert(original_shared(case.path))
		local dir = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-llm-config-XXXXXX"))
		local path = dir .. "/config"
		local made = os.execute("mkfifo '" .. path .. "'")
		assert(made == 0 or made == true)
		package.loaded[case.module] = nil
		local owner = require(case.module)
		Paths.shared = function(relative)
			if relative == case.path then return path end
			return original_shared(relative)
		end
		local exited, process = false, nil
		process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; cat "$2" > "$1"', "fixture", path, source } }, function()
			exited = true; process:close()
		end))
		local ok, value = pcall(case.invoke, owner)
		Paths.shared, package.loaded[case.module] = original_shared, original_module
		os.remove(path); os.remove(dir)
		while not exited do uv.run("once") end
		if case.raises then helpers.assert_eq(ok, false, "unreadable source must fail")
		elseif case.returns_false then helpers.assert_true(ok); helpers.assert_eq(value, false, "unreadable source must refuse")
		else helpers.assert_true(ok); helpers.assert_nil(value, "unreadable source must refuse") end
	end)
end
