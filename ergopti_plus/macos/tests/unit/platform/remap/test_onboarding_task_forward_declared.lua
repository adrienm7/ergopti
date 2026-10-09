--- tests/unit/platform/remap/test_onboarding_task_forward_declared.lua

--- ==============================================================================
--- MODULE: Regression — onboarding installer task ownership transaction
--- DESCRIPTION:
--- onboarding.lua constructs four native installer tasks. Each exact handle must
--- enter both the installer owner and the GC root before native start, then leave
--- both roots on start refusal or callback settlement. The callback must capture
--- the forward-declared handle; an inline declaration binds the nil global and
--- silently leaves ownership behind after completion.
---
--- These guards follow the current start_owned_task/release_install_task owner
--- helpers instead of pinning the retired raw hs.task.new spelling.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner/onboarding: every installer task has one exact owner transaction", function()
	local function read_src()
		local src, err = helpers.read_driver_unit("local function start_owned_task")
		helpers.assert_true(src ~= nil,
			"the onboarding task-owner unit must be uniquely locatable: " .. tostring(err))
		return src
	end

	local function count_literal(src, needle)
		local count, cursor = 0, 1
		while true do
			local position = src:find(needle, cursor, true)
			if not position then return count end
			count = count + 1
			cursor = position + #needle
		end
	end

	helpers.it("routes all four native constructors through the exact owner helper", function()
		local src = read_src()
		helpers.assert_eq(count_literal(src, "task = TaskLifecycle.native("), 4,
			"the owner inventory must include checksum, download, mount, and install")
		helpers.assert_eq(count_literal(src, "start_owned_task(owner, task, \""), 4,
			"every native installer candidate must enter the shared owner helper")
		for _, stage in ipairs({ "checksum", "download", "mount", "install" }) do
			helpers.assert_eq(count_literal(src,
				"start_owned_task(owner, task, \"" .. stage .. "\""), 1,
				stage .. " must have one exact owner admission")
		end
	end)

	helpers.it("pins both owner roots before literal native start commitment", function()
		local src = read_src()
		local helper_start = assert(src:find("local function start_owned_task", 1, true))
		local helper_end = assert(src:find("--- Latches one exact native task completion",
			helper_start, true))
		local body = src:sub(helper_start, helper_end - 1)
		local owner_pin = assert(body:find("owner.tasks[task] = stage", 1, true))
		local gc_pin = assert(body:find("M._active_tasks[task] = true", 1, true))
		local start = assert(body:find("TaskLifecycle.start(task, label) ~= true", 1, true))
		local gc_release = assert(body:find("M._active_tasks[task] = nil", start, true))
		local owner_release = assert(body:find("release_install_task(owner, task)",
			gc_release, true))
		helpers.assert_true(owner_pin < start and gc_pin < start,
			"both exact ownership roots must commit before native start")
		helpers.assert_true(start < gc_release and gc_release < owner_release,
			"a refused start must release the GC root and installer owner in order")
	end)

	helpers.it("all four callbacks release the exact task from both roots", function()
		local src = read_src()
		local stages = {
			{ name = "checksum", owner = "local function verify_sha256_async" },
			{ name = "download", owner = "local function download_async" },
			{ name = "mount", owner = "local function mount_dmg_async" },
			{ name = "install", owner = "local function run_pkg_with_sudo_async" },
		}
		for _, stage in ipairs(stages) do
			local owner = src:find(stage.owner, 1, true)
			local declaration = owner and src:find("local task\n", owner, true)
			local latch = declaration and src:find(
				"latch_install_task_completion(owner, \"" .. stage.name .. "\"",
				declaration, true)
			local gc_release = latch and src:find(
				"if task then M._active_tasks[task] = nil end", latch, true)
			local owner_release = gc_release and src:find(
				"release_install_task(owner, task)", gc_release, true)
			local construction = owner_release and src:find(
				"task = TaskLifecycle.native", owner_release, true)
			local admission = construction and src:find(
				"start_owned_task(owner, task, \"" .. stage.name .. "\"",
				construction, true)
			helpers.assert_true(owner and declaration and latch and gc_release
				and owner_release and construction and admission,
				stage.name .. " must expose one complete task ownership transaction")
			helpers.assert_true(owner < declaration and declaration < latch
				and latch < gc_release and gc_release < owner_release
				and owner_release < construction and construction < admission,
				stage.name .. " must release the callback's exact captured task")
		end
	end)
end)
