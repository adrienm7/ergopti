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

--- Discovers module-local launch helpers by their operational contract rather
--- than a pinned helper name. A strict helper must pin the exact task before a
--- conditional TaskLifecycle.start() and clear that pin on refusal.
--- @param code string Comment-stripped production source.
--- @return table[] helpers Strict helper descriptors.
local function discover_strict_start_helpers(code)
	local helpers_found = {}
	local search_at = 1
	while true do
		local start_at = code:find("TaskLifecycle.start", search_at, true)
		if not start_at then break end
		local declaration_at, helper_name = nil, nil
		local function_at = 1
		while true do
			local found_at, found_end, found_name = code:find(
				"local%s+function%s+([%a_][%w_]*)%s*%(", function_at)
			if not found_at or found_at > start_at then break end
			declaration_at, helper_name = found_at, found_name
			function_at = found_end + 1
		end
		if declaration_at and helper_name then
			local next_function = code:find("local%s+function%s+[%a_][%w_]*%s*%(", start_at + 1)
			local region = code:sub(declaration_at, (next_function or (#code + 1)) - 1)
			local relative_start = region:find("TaskLifecycle.start", 1, true)
			local task_name = region:match("TaskLifecycle%.start%s*%(%s*([%a_][%w_]*)")
			if relative_start and task_name then
				local before_start = region:sub(1, relative_start - 1)
				local from_start = region:sub(relative_start)
				local pin_pattern = "_active_tasks%s*%[%s*" .. task_name
					.. "%s*%]%s*=%s*true"
				local clear_pattern = "_active_tasks%s*%[%s*" .. task_name
					.. "%s*%]%s*=%s*nil"
				local conditional = region:find("if%s+.-TaskLifecycle%.start%s*%(") ~= nil
				if conditional and before_start:find(pin_pattern)
					and from_start:find(clear_pattern) then
					helpers_found[#helpers_found + 1] = { name = helper_name }
				end
			end
		end
		search_at = start_at + 1
	end
	return helpers_found
end

--- True when one native construction window hands its exact assigned task to a
--- dynamically discovered strict launch helper.
--- @param window string Source from this native site to the next one.
--- @param task_name string Exact local receiving TaskLifecycle.native().
--- @param strict_helpers table[] Discovered helper descriptors.
--- @return boolean delegated
local function delegates_to_strict_helper(window, task_name, strict_helpers)
	for _, helper in ipairs(strict_helpers) do
		local cursor = 1
		while true do
			local call_at, args_end, args = window:find(
				helper.name .. "%s*(%b())", cursor)
			if not call_at then break end
			if args:find("%f[%w_]" .. task_name .. "%f[^%w_]") then return true end
			cursor = args_end + 1
		end
	end
	return false
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

			local strict_helpers = discover_strict_start_helpers(code)
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
					local start_call = window:find("TaskLifecycle.start", 1, true)
					local after_start = start_call and window:sub(start_call) or ""
					-- Strict owners may call start through xpcall/acquisition helpers, then
					-- validate the captured result and roll the exact task back. Requiring
					-- `if` to precede the call only recognizes the obsolete inline form.
					local exact_result_guard = after_start:find("[%a_][%w_]*%s*~=%s*true")
						or after_start:find("if%s+not%s+[%a_][%w_]*")
					local rollback_path = after_start:find("terminate", 1, true)
						or after_start:find("cancel", 1, true)
						or after_start:find("release", 1, true)
						or after_start:find("clear_", 1, true)
						or after_start:find("signal_", 1, true)
					local inline_guard = window:find(
						"if%s+not%s+TaskLifecycle%.start%s*%(")
					local conditional_start = inline_guard ~= nil or (start_call ~= nil
						and exact_result_guard ~= nil and rollback_path ~= nil)
					local assignment_prefix = code:sub(math.max(1, launch_at - 120), launch_at - 1)
					local task_name = assignment_prefix:match("([%a_][%w_]*)%s*=%s*$")
					local delegated = task_name ~= nil
						and delegates_to_strict_helper(window, task_name, strict_helpers)
					if not conditional_start and not delegated then
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
		helpers.assert_true(code:find("if ok and started then", 1, true) ~= nil
			and code:find("_lifecycle = \"start_failed\"", 1, true) ~= nil
			and code:find("if not ok then", 1, true) ~= nil,
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
