--- tests/unit/modules/shortcuts/test_system_pixel_pause_ownership.lua

--- ==============================================================================
--- MODULE: Pixel/Screenshot Async Pause Ownership
--- DESCRIPTION:
--- Drives the real system_pixel owner and TaskLifecycle adapter against native
--- task doubles whose start/terminate/callback boundaries are independently
--- observable. Pause must retain the exact task until terminal proof, and every
--- late or duplicate callback must remain behind the revoked admission epoch.
--- ==============================================================================

local helpers = require("tests.helpers")


-- ======================================================
-- ======================================================
-- ======= 1/ Faithful Native Task Harness ===============
-- ======================================================
-- ======================================================

local function fresh_pixel_owner()
	local subject
	local fixture = {
		tasks = {},
		notifications = {},
		clipboard_writes = {},
		next_task_options = {},
		temp_paths = {},
		removed_temp_paths = {},
		existing_temp_paths = {},
		next_temp_modes = {},
		next_remove_modes = {},
	}

	local hs_stub = {
		mouse = {
			absolutePosition = function() return { x = 10, y = 20 } end,
		},
		pasteboard = {
			setContents = function(value)
				fixture.clipboard_writes[#fixture.clipboard_writes + 1] = value
				return true
			end,
		},
		task = {},
	}

	function fixture.queue_task(options)
		fixture.next_task_options[#fixture.next_task_options + 1] = options or {}
	end
	function fixture.queue_temp_mode(mode)
		fixture.next_temp_modes[#fixture.next_temp_modes + 1] = mode
	end
	function fixture.queue_remove_mode(mode)
		fixture.next_remove_modes[#fixture.next_remove_modes + 1] = mode
	end

	hs_stub.task.new = function(executable, callback, args)
		local options = table.remove(fixture.next_task_options, 1) or {}
		local task = {
			executable = executable,
			args = args,
			callback = callback,
			running_state = options.construct_running == true,
			start_calls = 0,
			terminate_calls = 0,
			terminate_identities = {},
			start_mode = options.start_mode or "true",
			terminate_mode = options.terminate_mode or "pending",
			sync_terminal = options.sync_terminal,
		}
		function task:deliver(exit_code, stdout, stderr)
			self.running_state = false
			return self.callback(exit_code, stdout, stderr)
		end
		function task:start()
			self.start_calls = self.start_calls + 1
			local mode = self.start_mode
			if mode == "false_mutate" or mode == "nil_mutate" or mode == "throw_mutate"
				or mode == "sync_true" or mode == "sync_false" then
				self.running_state = true
			end
			if options.reenter_pause_on_start == true then
				self.running_state = true
				fixture.nested_start_pause = subject.pause_pixel_actions()
				-- Model the hostile native boundary mutating after the re-entrant
				-- lifecycle callback (including after a synchronous terminate terminal).
				self.running_state = true
			end
			if self.sync_terminal then
				self:deliver(table.unpack(self.sync_terminal, 1, self.sync_terminal.n))
			end
			if mode == "false_mutate" or mode == "sync_false" then return false end
			if mode == "nil_mutate" then return nil end
			if mode == "throw_mutate" then error("native task start exploded") end
			self.running_state = self.sync_terminal == nil
			return self
		end
		function task:isRunning() return self.running_state end
		function task:terminate()
			self.terminate_calls = self.terminate_calls + 1
			self.terminate_identities[self.terminate_calls] = self
			if self.terminate_mode == "false" then return false end
			if self.terminate_mode == "nil" then return nil end
			if self.terminate_mode == "throw" then error("native task terminate exploded") end
			if self.terminate_mode == "sync" then
				self:deliver(-15, "", "terminated")
			end
			-- A truthy terminate only accepts SIGTERM; the completion callback is
			-- the exact terminal proof and may arrive later.
			return self
		end
		fixture.tasks[#fixture.tasks + 1] = task
		if options.reenter_pause_on_construct == true then
			fixture.nested_constructor_pause = subject.pause_pixel_actions()
		end
		return helpers.attach_native_task_environment(task)
	end

	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.notifications"] = {
		notify = function(message, _, level)
			fixture.notifications[#fixture.notifications + 1] = {
				message = message,
				level = level,
			}
		end,
	}
	package.loaded["adapters.file_system"] = {
		create_secure_temp_file = function()
			local mode = table.remove(fixture.next_temp_modes, 1)
			if mode == "false" then return false, "allocation refused" end
			if mode == "nil" then return nil, "allocation refused" end
			if mode == "throw" then error("allocation exploded") end
			local path = string.format("/private/tmp/ergopti-pixel-%d", #fixture.temp_paths + 1)
			fixture.temp_paths[#fixture.temp_paths + 1] = path
			fixture.existing_temp_paths[path] = true
			return path
		end,
		remove_exact = function(path)
			fixture.removed_temp_paths[#fixture.removed_temp_paths + 1] = path
			local mode = table.remove(fixture.next_remove_modes, 1)
			if mode == "false" then return false, "cleanup refused" end
			if mode == "nil" then return nil, "cleanup refused" end
			if mode == "throw" then error("cleanup exploded") end
			fixture.existing_temp_paths[path] = nil
			return true
		end,
		classify_no_follow = function(path)
			if fixture.existing_temp_paths[path] == true then
				return { mode = "file" }, "ok"
			end
			return nil, "absent"
		end,
	}
	package.loaded["adapters.task_lifecycle"] = nil
	package.loaded["modules.shortcuts.actions.system_pixel"] = nil
	subject = require("modules.shortcuts.actions.system_pixel")
	return subject, fixture
end

local function reach_phase(subject, fixture, phase)
	if phase == "interactive" then
		helpers.assert_eq(subject.interactive_screenshot(), true)
		return fixture.tasks[1]
	end
	helpers.assert_eq(subject.copy_pixel_color(), true)
	if phase == "capture" then return fixture.tasks[1] end
	fixture.tasks[1]:deliver(0, "", "")
	helpers.assert_eq(#fixture.tasks, 2,
		"a committed capture terminal must acquire one Python successor while ACTIVE")
	return fixture.tasks[2]
end





-- ========================================================
-- ========================================================
-- ======= 2/ Positive and Atomic Terminal Controls =======
-- ========================================================
-- ========================================================

helpers.describe("system_pixel exact async owner: positive controls", function()
	helpers.it("uses and releases a unique secure capture path per invocation", function()
		local subject, fixture = fresh_pixel_owner()
		for index = 1, 2 do
			helpers.assert_eq(subject.copy_pixel_color(), true)
			local capture = fixture.tasks[(index - 1) * 2 + 1]
			helpers.assert_eq(capture.args[#capture.args], fixture.temp_paths[index])
			capture:deliver(0, "", "")
			local extractor = fixture.tasks[index * 2]
			helpers.assert_eq(extractor.args[#extractor.args], fixture.temp_paths[index])
			extractor:deliver(0, "#a1b2c3\n", "")
			helpers.assert_eq(fixture.removed_temp_paths[index], fixture.temp_paths[index])
		end
		helpers.assert_true(fixture.temp_paths[1] ~= fixture.temp_paths[2],
			"two pixel operations must never share a capture pathname")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains " .. mode .. " capture cleanup and blocks every successor", function()
			local subject, fixture = fresh_pixel_owner()
			fixture.queue_remove_mode(mode)
			fixture.queue_remove_mode(mode)
			helpers.assert_eq(subject.copy_pixel_color(), true)
			fixture.tasks[1]:deliver(0, "", "")
			fixture.tasks[2]:deliver(0, "#a1b2c3\n", "")
			helpers.assert_eq(subject.has_pending_pixel_action(), true,
				"cleanup refusal must remain visible as exact operation debt")
			helpers.assert_eq(subject.copy_pixel_color(), false,
				"a second refusal must prevent allocating a successor")
			helpers.assert_eq(#fixture.temp_paths, 1)
			helpers.assert_eq(#fixture.tasks, 2)
			helpers.assert_eq(fixture.removed_temp_paths,
				{ fixture.temp_paths[1], fixture.temp_paths[1] })

			helpers.assert_eq(subject.copy_pixel_color(), true,
				"the next action may proceed only after exact cleanup succeeds")
			helpers.assert_eq(#fixture.temp_paths, 2)
			helpers.assert_eq(fixture.removed_temp_paths[3], fixture.temp_paths[1])
			fixture.tasks[3]:deliver(1, "", "capture failed")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fails closed when secure temp allocation returns " .. mode, function()
			local subject, fixture = fresh_pixel_owner()
			fixture.queue_temp_mode(mode)
			helpers.assert_eq(subject.copy_pixel_color(), false)
			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_eq(subject.has_pending_pixel_action(), false)
		end)
	end

	helpers.it("publishes pixel and screenshot results once while ACTIVE", function()
		local subject, fixture = fresh_pixel_owner()
		helpers.assert_eq(subject.copy_pixel_color(), true)
		helpers.assert_eq(#fixture.tasks, 1)
		fixture.tasks[1]:deliver(0, "", "")
		helpers.assert_eq(#fixture.tasks, 2)
		fixture.tasks[2]:deliver(0, "#a1b2c3\n", "")
		helpers.assert_eq(fixture.clipboard_writes, { "#a1b2c3" })
		helpers.assert_eq(#fixture.notifications, 1)
		helpers.assert_eq(fixture.notifications[1].level, "success")

		fixture.tasks[1]:deliver(0, "", "")
		fixture.tasks[2]:deliver(0, "#ffffff\n", "")
		helpers.assert_eq(#fixture.tasks, 2)
		helpers.assert_eq(fixture.clipboard_writes, { "#a1b2c3" },
			"duplicate terminals must not re-enter either phase")

		helpers.assert_eq(subject.interactive_screenshot(), true)
		fixture.tasks[3]:deliver(0, "", "")
		fixture.tasks[3]:deliver(0, "", "")
		helpers.assert_eq(#fixture.notifications, 2,
			"interactive screenshot completion must publish exactly once")
	end)

	helpers.it("buffers a synchronous terminal until start commits", function()
		local subject, fixture = fresh_pixel_owner()
		fixture.queue_task({
			start_mode = "sync_true",
			sync_terminal = table.pack(0, "", ""),
		})
		helpers.assert_eq(subject.copy_pixel_color(), true)
		helpers.assert_eq(#fixture.tasks, 2,
			"sync capture success may dispatch Python only after start returns true")
		helpers.assert_eq(#fixture.clipboard_writes, 0)
		fixture.tasks[2]:deliver(0, "#102030\n", "")
		helpers.assert_eq(fixture.clipboard_writes, { "#102030" })
	end)

	helpers.it("drops a synchronous terminal when start later refuses", function()
		local subject, fixture = fresh_pixel_owner()
		fixture.queue_task({
			start_mode = "sync_false",
			sync_terminal = table.pack(0, "", ""),
		})
		helpers.assert_eq(subject.copy_pixel_color(), false)
		helpers.assert_eq(#fixture.tasks, 1)
		helpers.assert_eq(#fixture.clipboard_writes, 0)
		helpers.assert_eq(#fixture.notifications, 0)
		helpers.assert_eq(subject.has_pending_pixel_action(), false,
			"the sync terminal is exact settlement even though its business result is rejected")
		fixture.tasks[1]:deliver(0, "", "")
		helpers.assert_eq(#fixture.tasks, 1)
		helpers.assert_eq(subject.interactive_screenshot(), true,
			"a rejected sync acquisition must not leave phantom admission debt")
		fixture.tasks[2]:deliver(1, "", "cancelled")
	end)
end)


-- ========================================================
-- ========================================================
-- ======= 3/ Pause Settlement Across Every Phase =========
-- ========================================================
-- ========================================================

helpers.describe("system_pixel exact async owner: pause settlement", function()
	for _, phase in ipairs({ "interactive", "capture", "python" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains " .. phase .. " task after terminate " .. mode, function()
				local subject, fixture = fresh_pixel_owner()
				local target = reach_phase(subject, fixture, phase)
				local task_count = #fixture.tasks
				target.terminate_mode = mode

				helpers.assert_eq(subject.pause_pixel_actions(), false)
				helpers.assert_eq(subject.is_pixel_actions_paused(), true)
				helpers.assert_eq(subject.has_pending_pixel_action(), true)
				helpers.assert_eq(target.terminate_calls, 1)
				helpers.assert_eq(target.terminate_identities[1] == target, true)
				helpers.assert_eq(subject.copy_pixel_color(), false,
					"closed admission must reject a second action without a successor")
				helpers.assert_eq(subject.interactive_screenshot(), false)
				helpers.assert_eq(#fixture.tasks, task_count)

				target.terminate_mode = "pending"
				helpers.assert_eq(subject.pause_pixel_actions(), false,
					"truthy terminate remains pending until the exact callback")
				helpers.assert_eq(target.terminate_calls, 2)
				helpers.assert_eq(target.terminate_identities[2] == target, true)

				local stdout = phase == "python" and "#abcdef\n" or ""
				target:deliver(0, stdout, "")
				target:deliver(0, stdout, "")
				helpers.assert_eq(#fixture.tasks, task_count,
					"a revoked capture may not launch the Python successor")
				helpers.assert_eq(#fixture.clipboard_writes, 0)
				helpers.assert_eq(#fixture.notifications, 0,
					"revoked and duplicate terminals may not publish UI")
				helpers.assert_eq(subject.has_pending_pixel_action(), false)
				helpers.assert_eq(subject.pause_pixel_actions(), true)
				helpers.assert_eq(subject.resume_pixel_actions(), true)
				helpers.assert_eq(subject.is_pixel_actions_paused(), false)
				helpers.assert_eq(#fixture.tasks, task_count,
					"RESUME reopens admission without replaying the user action")
			end)
		end
	end
end)


-- ========================================================
-- ========================================================
-- ======= 4/ Mutate-Then-Refuse Start Rollback ===========
-- ========================================================
-- ========================================================

helpers.describe("system_pixel exact async owner: refused start ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a mutate-then-" .. mode .. " start until terminal proof", function()
			local subject, fixture = fresh_pixel_owner()
			fixture.queue_task({
				start_mode = mode .. "_mutate",
				terminate_mode = mode,
			})
			helpers.assert_eq(subject.copy_pixel_color(), false)
			local target = fixture.tasks[1]
			helpers.assert_eq(target.running_state, true,
				"the hostile start must mutate before refusing")
			helpers.assert_eq(target.terminate_calls, 1)
			helpers.assert_eq(target.terminate_identities[1] == target, true)
			helpers.assert_eq(subject.has_pending_pixel_action(), true)

			helpers.assert_eq(subject.copy_pixel_color(), false)
			helpers.assert_eq(#fixture.tasks, 1,
				"cleanup debt may not be overwritten by a successor capture")
			helpers.assert_eq(target.terminate_calls, 2)
			helpers.assert_eq(target.terminate_identities[2] == target, true)

			target.terminate_mode = "pending"
			helpers.assert_eq(subject.stop_pixel_actions(), false)
			helpers.assert_eq(target.terminate_calls, 3)
			helpers.assert_eq(target.terminate_identities[3] == target, true)
			target:deliver(0, "", "")
			target:deliver(0, "", "")
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_eq(#fixture.clipboard_writes, 0)
			helpers.assert_eq(#fixture.notifications, 0)
			helpers.assert_eq(subject.stop_pixel_actions(), true)
			helpers.assert_eq(subject.resume_pixel_actions(), true)
	end)
	end
end)


-- ========================================================
-- ========================================================
-- ======= 5/ Re-entrant Native Construction ==============
-- ========================================================
-- ========================================================

helpers.describe("system_pixel exact async owner: constructor admission", function()
	for _, mode in ipairs({ "false", "nil", "throw", "pending" }) do
		helpers.it("retains the constructed identity after re-entrant PAUSE and terminate "
			.. mode, function()
				local subject, fixture = fresh_pixel_owner()
				fixture.queue_task({
					reenter_pause_on_construct = true,
					construct_running = true,
					terminate_mode = mode,
				})

				helpers.assert_eq(subject.copy_pixel_color(), false)
				local target = fixture.tasks[1]
				helpers.assert_eq(fixture.nested_constructor_pause, false,
					"PAUSE cannot settle while TaskLifecycle.native remains on-stack")
				helpers.assert_eq(target.start_calls, 0,
					"a constructor superseded by PAUSE may never launch afterwards")
				helpers.assert_eq(target.terminate_calls, 1)
				helpers.assert_eq(target.terminate_identities[1] == target, true)
				helpers.assert_eq(subject.is_pixel_actions_paused(), true)
				helpers.assert_eq(subject.has_pending_pixel_action(), true,
					"the exact hostile constructor identity remains owned until terminal proof")

				helpers.assert_eq(subject.pause_pixel_actions(), false)
				helpers.assert_eq(target.terminate_calls, 2)
				helpers.assert_eq(target.terminate_identities[2] == target, true)
				target:deliver(-15, "", "terminated")
				target:deliver(-15, "", "terminated")
				helpers.assert_eq(subject.has_pending_pixel_action(), false)
				helpers.assert_eq(subject.pause_pixel_actions(), true)
				helpers.assert_eq(subject.resume_pixel_actions(), true)
				helpers.assert_eq(subject.is_pixel_actions_paused(), false)
			end)
	end
end)


-- ========================================================
-- ========================================================
-- ======= 6/ Re-entrant Native Start ======================
-- ========================================================
-- ========================================================

helpers.describe("system_pixel exact async owner: start admission", function()
	for _, mode in ipairs({ "sync", "pending", "false", "nil", "throw" }) do
		helpers.it("never commits a start that re-enters PAUSE with terminate " .. mode,
			function()
				local subject, fixture = fresh_pixel_owner()
				fixture.queue_task({
					reenter_pause_on_start = true,
					terminate_mode = mode,
				})

				helpers.assert_eq(subject.copy_pixel_color(), false)
				local target = fixture.tasks[1]
				helpers.assert_eq(fixture.nested_start_pause, false,
					"PAUSE cannot settle while native start remains on-stack")
				helpers.assert_eq(target.start_calls, 1)
				helpers.assert_eq(target.terminate_calls, 2,
					"the post-start probe must settle the exact superseded identity again")
				helpers.assert_eq(target.terminate_identities[1] == target, true)
				helpers.assert_eq(target.terminate_identities[2] == target, true)
				helpers.assert_eq(#fixture.clipboard_writes, 0)
				helpers.assert_eq(#fixture.notifications, 0)
				helpers.assert_eq(subject.is_pixel_actions_paused(), true)

				if mode == "sync" then
					helpers.assert_eq(subject.has_pending_pixel_action(), false,
						"only the fresh post-boundary terminal settles the restarted task")
				else
					helpers.assert_eq(subject.has_pending_pixel_action(), true)
					helpers.assert_eq(subject.pause_pixel_actions(), false)
					helpers.assert_eq(target.terminate_calls, 3)
					helpers.assert_eq(target.terminate_identities[3] == target, true)
					target:deliver(-15, "", "terminated")
					target:deliver(-15, "", "terminated")
					helpers.assert_eq(subject.has_pending_pixel_action(), false)
				end
				helpers.assert_eq(subject.pause_pixel_actions(), true)
				helpers.assert_eq(subject.resume_pixel_actions(), true)
			end)
	end
end)
