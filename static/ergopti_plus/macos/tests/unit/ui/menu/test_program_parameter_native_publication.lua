--- tests/unit/ui/menu/test_program_parameter_native_publication.lua

--- Actual native file publication, keyboard setter, preferences, save checkpoint
--- and retained program owner. Native advisory primitives are fault-injected;
--- real hs.fs interprocess qualification remains a separate macOS CI obligation.
local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
local SCALAR = '{"version":1,"executable":"/private/probe-tool","arguments":["private-probe-argument"]}'
local function copy(value) local result = {}; for key, child in pairs(value) do result[key] = child end; return result end

local function with_subject(stage, body, options)
	local saved, prior_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do saved[key] = value end
	local ok, failure = xpcall(function()
		with_fixture(function(fixture)
			local source_path = os.tmpname():gsub("\\", "/")
			local path = options and options.alias_route and (source_path .. ".alias") or source_path
			local original = '[gestures]\naction_parameters = { retained = "unrelated" }\n[shortcuts.keyboard]\ncmd_1 = "none"\n'
			local seeded = assert(io.open(source_path, "w")); assert(seeded:write(original)); assert(seeded:close())
			local original_open, original_rename = io.open, os.rename
			local control = { locks = 0, unlocks = 0, refusal = stage ~= "healthy", fail_operation = stage == "assignment" and 1 or 2 }
			control.source_path, control.alias_target = source_path, source_path
			local handles = {}
			local routes = options and options.alias_route and { [path] = function() return control.alias_target end } or nil
			local adapter = fixture.make_adapter(routes, nil, nil, nil,
				function(handle) control.locks = control.locks + 1; handle.operation = control.locks; handles[#handles + 1] = handle; return true end,
				function(handle)
					control.unlocks = control.unlocks + 1
					if control.refusal and handle.operation == control.fail_operation then return false, "injected unlock refusal" end
					return true
				end)
			local native_publish = adapter.write_if_unchanged
			adapter.write_if_unchanged = function(target, value, expected, reporter)
				local result = table.pack(native_publish(target, value, expected, reporter))
				local receipt = result[3]
				if receipt then control.last_receipt = receipt; control.last_expected = expected; control.last_candidate = value; control.last_reporter = reporter end
				return table.unpack(result, 1, result.n)
			end
			io.open = function(target, mode)
				local handle, detail = original_open(target, mode)
				if handle and mode == "w" and target:match("/payload$") and options and options.fail_before_publication
					and control.refusal and control.locks == control.fail_operation then
					return { write = function() return nil, "injected write refusal" end, close = function() return handle:close() end }
				end
				if not handle or mode ~= "a+" or target ~= source_path .. fixture.WRITE_LOCK_SUFFIX then return handle, detail end
				local proxy = { raw = handle }
				function proxy:close()
					if control.refusal and self.operation == control.fail_operation then return false, "injected close refusal" end
					return handle:close()
				end
				return proxy
			end
			os.rename = function(from, target)
				if package.config:sub(1, 1) == "\\" and target == source_path then os.remove(target) end -- model native Darwin replacement
				local renamed, detail = original_rename(from, target)
				if renamed and target == source_path and control.locks == control.fail_operation then
					local file = assert(original_open(source_path, "rb")); control.published_candidate = file:read("*a"); file:close()
					if control.foreign_after_rename or (options and options.foreign_after_rename) then
						local foreign = assert(original_open(source_path, "w")); assert(foreign:write("[foreign]\nkeep = true\n")); assert(foreign:close())
					end
				end
				return renamed, detail
			end
			local ran, problem = xpcall(function()
				for _, name in ipairs({ "infra.preferences", "toml_codec.writer", "ui.menu.preferences_transaction", "ui.menu.program_parameter_transaction", "ui.menu.global_actions_transaction", "modules.shortcuts.keyboard_shortcuts" }) do package.loaded[name] = nil end
				local logs, logger = {}, helpers.make_logger_stub()
				for _, level in ipairs({ "error", "warn", "info", "debug" }) do logger[level] = function(_, template, ...) logs[#logs + 1] = string.format(template, ...) end end
				package.loaded["infra.logger"] = logger
				package.loaded["infra.paths"] = { shared = helpers.shared, shared_root = function() return helpers.shared() end }
				package.loaded["infra.config_paths"] = { get = function() return path end }
				package.loaded["modules.gestures.actions"] = { is_assignable = function() return true end }
				local preferences = require("infra.preferences"); preferences.load(path)
				local keyboard = require("modules.shortcuts.keyboard_shortcuts")
				helpers.assert_eq(keyboard.get_action("cmd_1"), "none")
				local parameters, state = { retained = "unrelated" }, {}
				local gestures = {
					is_assignable = function() return true end,
					get_all_action_parameters = function() return copy(parameters) end,
					set_action_parameter = function(binding, action, value) parameters[binding .. "__" .. action] = value; return true end,
					replace_action_parameters = function(snapshot) parameters = copy(snapshot); return true end,
				}
				local noop = function() return true end
				local save, checkpoint = require("ui.menu.preferences_transaction").bind(preferences, {
					path = path, state = state, hotfiles = {}, core_modules = { gestures = gestures }, initial_state = state,
					initial_preferences = preferences.snapshot(state, {}, { gestures = gestures }), restore_runtime = noop,
				})
				local global = assert(require("ui.menu.global_actions_transaction").create({
					state = state, capture_preferences = function() return {} end, sync_runtime = noop, restore_state = noop,
					settings = { get = function() end, set = noop, get_keys = function() return {} end },
					file_mover = { capture = function() return {} end, move = noop, restore = noop },
					reset_journal = { prepare = noop, mark_commit = noop, mark_prepared = noop, clear = noop },
					gestures = { get_action = function() return "none" end, set_action = noop, enable_all = noop, disable_all = noop },
					shortcuts = { set_shortcut_action = noop, get_keyboard_action = keyboard.get_action, set_keyboard_action = keyboard.set_action, get_keyboard_assignments = keyboard.get_assignments },
					karabiner = { snapshot_settings = function() return {} end, reset_to_defaults = noop, restore_settings = noop }, request_reload = noop, terminal_pending = function() return false end,
				}))
				local owner = require("ui.menu.program_parameter_transaction").new({
					path = path, files = adapter, gestures = gestures, preferences = preferences, checkpoint = checkpoint,
					admission = global.run_exclusive, paused = function() return false end, save_prefs = save, current_path = function() return path end,
					capture_checkpoint_candidate = function() return { state = require("ui.menu.preferences_transaction").clone(state), preferences = preferences.snapshot(state, {}, { gestures = gestures }) } end,
				})
				local mutation = { publishes_assignment = true, section = "shortcuts.keyboard", key = "cmd_1",
					read = function() return keyboard.get_action("cmd_1") end,
					-- Keep actual provider boolean coercion: the observer must survive it.
					apply = function(reporter, observer) return keyboard.set_action("cmd_1", "run_program", reporter, observer) == true end,
					restore = function(previous, reporter, observer) return keyboard.set_action("cmd_1", previous, reporter, observer) == true end,
				}
				local function apply()
					local result = owner.apply("keyboard__cmd_1", "run_program", SCALAR, mutation)
					if stage ~= "healthy" and not (options and options.fail_before_publication) then
						helpers.assert_eq(type(control.published_candidate), "string",
							"postpublication control must observe its actual native rename")
						helpers.assert_true(control.published_candidate ~= original,
							"prepublication mutex debt cannot stand in for an assignment publication")
						helpers.assert_eq(control.published_candidate, control.last_candidate,
							"the native rename must publish this exact independently observed candidate")
					end
					return result
				end
				local function inspect() return { content = adapter.read_with_status(path), parameters = copy(parameters), action = keyboard.get_action("cmd_1") } end
				local function reinstate_candidate() local file = assert(original_open(source_path, "w")); assert(file:write(control.published_candidate)); assert(file:close()) end
				body(owner, apply, inspect, control, global, preferences, checkpoint, original, adapter, path, logs, reinstate_candidate)
			end, debug.traceback)
			io.open, os.rename = original_open, original_rename
			for _, handle in ipairs(handles) do pcall(handle.raw.close, handle.raw) end
			os.remove(path); os.remove(source_path); os.remove(source_path .. fixture.WRITE_LOCK_SUFFIX)
			if control.foreign_path then os.remove(control.foreign_path) end
			if not ran then error(problem, 0) end
		end)
	end, debug.traceback)
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	_G.hs = prior_hs
	if not ok then error(failure, 0) end
end

helpers.describe("actual private native publication ownership", function()
	for _, stage in ipairs({ "assignment", "fullsave" }) do
		helpers.it("recovers its actual " .. stage .. " rename after both native releases refuse", function()
			with_subject(stage, function(owner, apply, inspect, control, global, preferences, checkpoint, original, _, path, logs)
				helpers.assert_eq(apply(), false)
				helpers.assert_eq(control.locks, stage == "assignment" and 1 or 2)
				helpers.assert_eq(owner.pending(), true)
				helpers.assert_eq(global.is_pending(), true)
				helpers.assert_eq(preferences.publication_receipt(path), { id = 0 }, "a partial native publication is not a save receipt")
				helpers.assert_eq(checkpoint.capture().revision, 0)
				helpers.assert_eq(preferences.source_snapshot(path).content, inspect().content, "own physical publication must retain its source ownership")
				control.refusal = false
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(global.is_pending(), false)
				helpers.assert_eq(inspect(), { content = original, parameters = { retained = "unrelated" }, action = "none" })
				helpers.assert_eq(preferences.publication_receipt(path), { id = 0 })
				helpers.assert_eq(checkpoint.capture().revision, 0)
				for _, line in ipairs(logs) do helpers.assert_eq(line:find("private-probe-argument", 1, true), nil) end
			end)
		end)
	end
	for _, stage in ipairs({ "assignment", "fullsave" }) do
		helpers.it("preserves foreign " .. stage .. " source and resumes only its exact native candidate", function()
			with_subject(stage, function(owner, apply, inspect, control, _, _, _, original, _, _, _, reinstate)
				helpers.assert_eq(apply(), false)
				local foreign = inspect().content
				control.refusal = false
				helpers.assert_eq(owner.retry_restore(), false)
				helpers.assert_eq(inspect().content, foreign)
				helpers.assert_eq(owner.pending(), true)
				reinstate()
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(inspect(), { content = original, parameters = { retained = "unrelated" }, action = "none" })
			end, { foreign_after_rename = true })
		end)
	end
	for _, inverse in ipairs({ { name = "assignment", operation = 3 }, { name = "disk", operation = 4 } }) do
		helpers.it("recovers a second refused native " .. inverse.name .. " publication during compensation", function()
			with_subject("fullsave", function(owner, apply, inspect, control, global, preferences, checkpoint, original, _, path)
				helpers.assert_eq(apply(), false)
				control.fail_operation = inverse.operation
				helpers.assert_eq(owner.retry_restore(), false)
				helpers.assert_eq(owner.pending(), true)
				helpers.assert_eq(global.is_pending(), true)
				control.refusal = false
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(inspect(), { content = original, parameters = { retained = "unrelated" }, action = "none" })
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(preferences.publication_receipt(path), { id = 0 })
				helpers.assert_eq(checkpoint.capture().revision, 0)
			end)
		end)
	end
	helpers.it("adopts its delayed native disk inverse after foreign recreation without publishing again", function()
		with_subject("fullsave", function(owner, apply, inspect, control, _, _, _, original, _, _, _, reinstate)
			helpers.assert_eq(apply(), false)
			control.fail_operation, control.foreign_after_rename = 4, true
			helpers.assert_eq(owner.retry_restore(), false)
			local foreign = inspect().content
			control.refusal, control.foreign_after_rename = false, false
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(inspect().content, foreign)
			reinstate()
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(control.locks, 4, "the already published exact inverse is adopted, never republished")
			helpers.assert_eq(inspect(), { content = original, parameters = { retained = "unrelated" }, action = "none" })
		end)
	end)
	helpers.it("releases its actual prepublication mutex debt without inventing a physical publication", function()
		with_subject("assignment", function(owner, apply, inspect, control, _, preferences, _, original, adapter, path)
			helpers.assert_eq(apply(), false)
			helpers.assert_eq(inspect().content, original)
			local view = adapter.publication_receipt_view(control.last_receipt, path, control.last_expected, control.last_candidate, control.last_reporter)
			helpers.assert_eq(view.published, false)
			helpers.assert_eq(view.source, { status = "ok", content = original })
			control.refusal = false
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(inspect(), { content = original, parameters = { retained = "unrelated" }, action = "none" })
			helpers.assert_eq(preferences.publication_receipt(path), { id = 0 })
		end, { fail_before_publication = true })
	end)
	helpers.it("does not release its native owner over a foreign checkpoint", function()
		with_subject("fullsave", function(owner, apply, _, control, _, _, checkpoint)
			helpers.assert_eq(apply(), false)
			local before = control.unlocks
			helpers.assert_eq(checkpoint.replace(checkpoint.capture(), { foreign = true }, {}), true)
			control.refusal = false
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(control.unlocks, before, "foreign checkpoint guard precedes native release")
			helpers.assert_eq(checkpoint.capture().state, { foreign = true })
		end)
	end)
	helpers.it("does not release its native owner over a foreign runtime assignment", function()
		with_subject("fullsave", function(owner, apply, _, control)
			helpers.assert_eq(apply(), false)
			local keyboard = require("modules.shortcuts.keyboard_shortcuts")
			helpers.assert_eq(keyboard.apply_configuration({ shortcuts = { keyboard = { cmd_1 = "copy_selection" } } }), true)
			local before = control.unlocks
			control.refusal = false
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(control.unlocks, before)
			helpers.assert_eq(keyboard.get_action("cmd_1"), "copy_selection")
		end)
	end)
	helpers.it("does not release or inverse through a foreign symlink route even when candidate bytes are equal", function()
		with_subject("fullsave", function(owner, apply, inspect, control, _, _, _, original)
			helpers.assert_eq(apply(), false)
			control.foreign_path = control.source_path .. ".foreign"
			local file = assert(io.open(control.foreign_path, "w")); assert(file:write(control.published_candidate)); assert(file:close())
			local before, candidate = control.unlocks, inspect().content
			control.alias_target, control.refusal = control.foreign_path, false
			helpers.assert_eq(inspect().content, candidate, "equal bytes alone cannot authorize a changed route")
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(control.unlocks, before)
			control.alias_target = control.source_path
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(inspect(), { content = original, parameters = { retained = "unrelated" }, action = "none" })
			local foreign = assert(io.open(control.foreign_path, "rb")); helpers.assert_eq(foreign:read("*a"), candidate); foreign:close()
		end, { alias_route = true })
	end)
	helpers.it("native equal bytes cannot manufacture or transfer a publication capability", function()
		with_subject("assignment", function(_, apply, _, control, _, _, _, _, adapter, path)
			helpers.assert_eq(apply(), false)
			local receipt = control.last_receipt
			helpers.assert_not_nil(receipt)
			helpers.assert_not_nil(adapter.publication_receipt_view(receipt, path, control.last_expected, control.last_candidate, control.last_reporter))
			helpers.assert_throws(function() receipt.retry = function() return true end end)
			helpers.assert_eq(adapter.publication_receipt_view({}, path, control.last_expected, control.last_candidate, control.last_reporter), nil)
			helpers.assert_eq(adapter.publication_receipt_view(receipt, path, control.last_expected, control.last_candidate, function() end), nil)
			helpers.assert_eq(adapter.publication_receipt_view(receipt, path, { status = "ok", content = "foreign" }, control.last_candidate, control.last_reporter), nil)
		end)
	end)
	helpers.it("ordinary native and shared publisher return counts stay unchanged", function()
		with_subject("healthy", function(_, _, _, _, _, _, _, _, adapter, path)
			local prior = adapter.read_with_status(path)
			helpers.assert_eq(select("#", adapter.write(path, prior)), 2)
			helpers.assert_eq(select("#", adapter.write_if_unchanged(path, prior, { status = "ok", content = prior })), 2)
			local writer = require("toml_codec.writer")
			helpers.assert_eq(select("#", writer.publish_if_unchanged(path, prior, adapter, { status = "ok", content = prior })), 1)
			helpers.assert_eq(select("#", writer.batch_write(path, {}, adapter, { status = "ok", content = prior })), 3)
		end)
	end)
end)
