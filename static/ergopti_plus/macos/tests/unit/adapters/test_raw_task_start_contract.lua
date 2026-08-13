--- tests/unit/adapters/test_raw_task_start_contract.lua

--- ==============================================================================
--- MODULE: Raw task start contract coverage
--- DESCRIPTION:
--- Enumerates every production consumer that launches a native hs.task. The
--- shared adapter is exercised behaviorally in
--- test_task_lifecycle; this guard ensures the invariant is transitive instead of
--- protecting only the historical sites named by one audit pass. ShellRunner is
--- the sole lower-level owner and has its own behavioral contract suite.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function all_driver_sources()
	local out = {}
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir, prefix)
			for entry in lfs.dir(DRIVER_ROOT .. dir) do
				if entry ~= "." and entry ~= ".." then
					local rel = prefix .. entry
					local attr = lfs.attributes(DRIVER_ROOT .. rel)
					if attr and attr.mode == "directory" then
						walk(rel .. "/", rel .. "/")
					elseif entry:match("%.lua$") then
						out[#out + 1] = rel
					end
				end
			end
		end
		for _, dir in ipairs({ "adapters", "infra", "modules", "platform", "ui" }) do
			walk(dir .. "/", dir .. "/")
		end
		for entry in lfs.dir(DRIVER_ROOT) do
			if entry:match("%.lua$") then out[#out + 1] = entry end
		end
		return out
	end

	local sep = package.config:sub(1, 1)
	local cmd = sep == "\\"
		and ('cmd /c dir /b /s /a-d "' .. DRIVER_ROOT:gsub("/", "\\") .. '*.lua"')
		or ("find '" .. DRIVER_ROOT .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return out end
	for line in pipe:lines() do
		local norm = line:gsub("\\", "/"):gsub("%s+$", "")
		local rel = norm:gsub("^.*/macos/", "")
		if rel:match("%.lua$") and not rel:match("^tests/")
				and not rel:match("^vendor/") and not rel:match("^_generated/") then
			out[#out + 1] = rel
		end
	end
	pipe:close()
	return out
end

local function read_relative(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "rb")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	return src
end





-- ===========================================================
-- ===========================================================
--- ======= 1/ All Raw Task Consumers =========================
-- ===========================================================
-- ===========================================================

helpers.describe("raw task launchers: nullable construction and false start are covered", function()
	helpers.it("routes every direct task consumer through TaskLifecycle", function()
		local files = all_driver_sources()
		helpers.assert_true(#files >= 50,
			"whole-tree task guard must enumerate production files; found " .. #files)
		local saw_root, native_files, native_sites = false, 0, 0
		local offenders = {}
		for _, rel in ipairs(files) do
			if rel == "init.lua" then saw_root = true end
			local src = read_relative(rel)
			helpers.assert_true(src ~= nil, "production source must remain readable: " .. rel)
			local code = src:gsub("%-%-[^\n]*", "")
			local owns_raw = rel == "adapters/task_lifecycle.lua"
				or rel == "adapters/shell_runner.lua"
			if not owns_raw and (code:find("hs%.task%.new%s*%(")
					or code:find("pcall%s*%(%s*hs%.task%.new")) then
				offenders[#offenders + 1] = rel .. ": raw hs.task.new ownership"
			end

			local _, site_count = code:gsub("TaskLifecycle%.native", "")
			if site_count > 0 then
				native_files = native_files + 1
				native_sites = native_sites + site_count
				if not code:find('require%s*%("adapters%.task_lifecycle"%)') then
					offenders[#offenders + 1] = rel .. ": native launch without adapter import"
				end
				local cursor = 1
				while true do
					local launch_at = code:find("TaskLifecycle.native", cursor, true)
					if not launch_at then break end
					local next_at = code:find("TaskLifecycle.native", launch_at + 1, true)
					local window = code:sub(launch_at, (next_at or (#code + 1)) - 1)
					-- Each launch must be committed only by a branch that inspects
					-- TaskLifecycle.start. A bare start cannot compensate its pin,
					-- latch, UI or callback when native start returns false.
					local conditional_start = window:find("if%s+.-TaskLifecycle%.start%s*%(")
					if not conditional_start then
						offenders[#offenders + 1] = rel
							.. ": native launch has no conditional start/rollback branch"
					end
					cursor = next_at or (#code + 1)
					if not next_at then break end
				end
			end
		end
		helpers.assert_true(saw_root,
			"whole-tree task guard must include root-level init.lua")
		helpers.assert_true(native_files >= 10 and native_sites >= 20,
			string.format("task guard matched too little production code (%d files, %d sites)",
				native_files, native_sites))

		helpers.assert_eq(0, #offenders,
		"a task consumer bypasses the strict constructor/callback/start contract:\n  "
				.. table.concat(offenders, "\n  "))
	end)

	helpers.it("keeps ShellRunner as the sole strict lower-level task owner", function()
		local src, err = helpers.read_driver_unit("local LOG = \"adapters.shell_runner\"")
		helpers.assert_true(src ~= nil, "ShellRunner must remain reachable: " .. tostring(err))
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("pcall(hs.task.new", 1, true) ~= nil,
			"ShellRunner must protect nullable/throwing native construction")
		helpers.assert_true(code:find("if not ok or task_or_err == nil then", 1, true) ~= nil,
			"ShellRunner must reject a nil native handle")
		helpers.assert_true(code:find("local ok, started = pcall(function() return task:start() end)", 1, true) ~= nil,
			"ShellRunner must protect start exceptions and inspect the operational result")
		helpers.assert_true(code:find("if not ok then", 1, true) ~= nil
			and code:find("if not started then", 1, true) ~= nil,
			"ShellRunner must reject both a thrown and a false native start")
	end)

	helpers.it("does not relitigate discovery after its ShellRunner migration", function()
		local src, err = helpers.read_driver_unit("local _endpoint_probe_in_flight")
		helpers.assert_true(src ~= nil, "MLX discovery must remain reachable: " .. tostring(err))
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("hs.task.new", 1, true) == nil,
			"MLX discovery already delegates subprocess ownership to ShellRunner; adding "
				.. "a second raw-task contract there would be a regression, not a fix")
	end)
end)
