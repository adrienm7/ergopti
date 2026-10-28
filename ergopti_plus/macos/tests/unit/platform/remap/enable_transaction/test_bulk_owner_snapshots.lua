--- tests/unit/platform/remap/enable_transaction/test_bulk_owner_snapshots.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.enable_transaction.bulk_owner_fixture"] = nil
local Fixture = require("tests.support.platform.remap.enable_transaction.bulk_owner_fixture")
local with_fixture = Fixture.with_fixture





helpers.describe("HS-022 Karabiner snapshots share the exact bulk owner", function()
	helpers.it("captures only detached persisted settings", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			helpers.assert_true(remap.set_combo_symmetric(true))

			local snapshot = remap.snapshot_settings()
			helpers.assert_type(snapshot, "table")
			helpers.assert_eq(snapshot.tap_hold_config.left_shift.tap, "escape")
			helpers.assert_true(snapshot.combo_symmetric == true)
			helpers.assert_nil(snapshot.watcher)
			helpers.assert_nil(snapshot.hotkey_cycle_windows)

			snapshot.tap_hold_config.left_shift.tap = "none"
			snapshot.combo_symmetric = false
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape",
				"mutating the parent snapshot must not mutate live state")
			helpers.assert_true(remap.get_combo_symmetric() == true)
		end)
	end)

	helpers.it("restores a detached snapshot only after one exact terminal", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			helpers.assert_true(remap.set_hold_action("left_shift", "layer"))
			local snapshot = remap.snapshot_settings()
			local original_snapshot = fixture.clone_payload(snapshot)
			helpers.assert_true(remap.set_tap_action("left_shift", "none"))
			helpers.assert_true(remap.set_hold_action("left_shift", "none"))

			local terminals = {}
			local callback_count = 0
			local outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end
			helpers.assert_true(remap.restore_settings(snapshot, function(ok)
				callback_count = callback_count + 1
				outcome = ok
			end))
			helpers.assert_nil(outcome)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_eq(remap.get_hold_action("left_shift"), "layer")
			helpers.assert_true(helpers.deep_equal(snapshot, original_snapshot),
				"restore must never consume or rewrite its caller-owned snapshot")

			terminals[1](true, "ready")
			terminals[1](false, "late-duplicate")
			helpers.assert_true(outcome == true)
			helpers.assert_eq(callback_count, 1)
		end)
	end)

	helpers.it("rejects malformed snapshots and enabled-intent drift exactly once", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap()
			local callback_count = 0
			local outcome, reason = nil, nil
			helpers.assert_eq(remap.restore_settings({}, function(ok, detail)
				callback_count = callback_count + 1
				outcome, reason = ok, detail
			end), false)
			helpers.assert_eq(callback_count, 1)
			helpers.assert_true(outcome == false)
			helpers.assert_eq(reason, "invalid-settings-snapshot")

			local snapshot = remap.snapshot_settings()
			snapshot.enabled = false
			helpers.assert_eq(remap.restore_settings(snapshot, function(ok, detail)
				callback_count = callback_count + 1
				outcome, reason = ok, detail
			end), false)
			helpers.assert_eq(callback_count, 2)
			helpers.assert_true(outcome == false)
			helpers.assert_eq(reason, "enabled-intent-changed")
		end)
	end)

	helpers.it("retains the same snapshot until older bulk recovery settles", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			local snapshot = remap.snapshot_settings()
			local snapshot_before = fixture.clone_payload(snapshot)
			calls.set_save_results({ "true", "false", "true", "true" })
			local terminals = {}
			local rejected_outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok)
				rejected_outcome = ok
			end))
			terminals[1](false, "candidate-failed")
			helpers.assert_true(rejected_outcome == false)

			local blocked_count = 0
			helpers.assert_eq(remap.restore_settings(snapshot, function(ok)
				blocked_count = blocked_count + 1
				helpers.assert_true(ok == false)
			end), false,
				"the retrying call must settle older debt without overlapping a new inverse")
			helpers.assert_eq(blocked_count, 1)
			helpers.assert_eq(#terminals, 2)
			terminals[2](true, "older-inverse-ready")

			local restored_count = 0
			local restored_outcome = nil
			helpers.assert_true(remap.restore_settings(snapshot, function(ok)
				restored_count = restored_count + 1
				restored_outcome = ok
			end))
			helpers.assert_eq(#terminals, 3)
			helpers.assert_nil(restored_outcome)
			terminals[3](true, "snapshot-ready")
			helpers.assert_true(restored_outcome == true)
			helpers.assert_eq(restored_count, 1)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_true(helpers.deep_equal(snapshot, snapshot_before),
				"every retry must use the same untouched detached snapshot")
		end)
	end)
end)

helpers.describe("configured navigation reservations share actual remap settings", function()
	local sequence = 0
	local function with_navigation_case(scenario, settings, catalogue, real_writes)
		local lfs = require("lfs")
		sequence = sequence + 1
		local directory = helpers.temp_dir() .. "/mac-remap-nav-" .. tostring(os.time()) .. "-" .. tostring(sequence)
		assert(lfs.mkdir(directory))
		local config = directory .. "/config_karabiner.toml"
		local layer = directory .. "/layers.toml"
		local function write(path, text)
			local stream = assert(io.open(path, "wb")); assert(stream:write(text)); assert(stream:close())
		end
		local settings_text = settings or '[karabiner]\nintegration_enabled = true\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\ntap = "none"\nhold = "layer"\n'
		local layer_text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyJ" = "none"\n'
		write(config, settings_text); write(layer, layer_text)
		local called, detail = xpcall(function()
			helpers.with_stub_scope({ "platform.remap.nav_layer" }, function()
				package.loaded["platform.remap.nav_layer"] = nil
				with_fixture(function(fixture)
					local options = { real_user_config_path = config, initially_enabled = false, real_user_config_writes = real_writes == true }
					if catalogue ~= false then options.real_action_catalogue_path = helpers.driver_root() .. "platform/remap/data/actions.json" end
					local remap, calls = fixture.load_enabled_remap(options)
					local paths = package.loaded["infra.config_paths"]
					paths.get = function() return config end
					paths.get_config_dir = function() return directory end
					calls.nav_regenerate = function()
						local terminal, reason
						local accepted = remap.regenerate(function(ok, detail) terminal, reason = ok, detail end)
						if calls.start_paused_callback ~= nil then calls.deliver_ready(true, "owned-fixture-ready") end
						if #calls.resume_callbacks > 0 then calls.deliver_resumed(true, "owned-fixture-resumed") end
						calls.nav_terminal_reason = reason
						return accepted, terminal
					end
					calls.nav_fixture_regenerated, calls.nav_fixture_completed = calls.nav_regenerate()
					scenario(remap, calls, function(text) write(config, text) end, function(text) write(layer, text) end,
						settings_text, layer_text, config)
				end)
			end)
		end, debug.traceback)
		if real_writes then
			local guard = config .. ".ergoptiplus-write-lock-v1"
			local attributes = lfs.attributes(guard)
			if attributes ~= nil then
				assert(attributes.mode == "file" and attributes.size == 0, "only the actual owned empty cooperative guard may be removed")
				assert(os.remove(guard))
			end
		end
		assert(os.remove(config)); assert(os.remove(layer)); assert(lfs.rmdir(directory))
		if not called then error(detail, 0) end
	end

	helpers.it("nav-configured remap joins a reachable layer without any native acquisition", function()
		with_navigation_case(function(remap, calls)
			helpers.assert_eq(calls.nav_fixture_completed, true, "the original native fixture must complete its real final publication fence: " .. tostring(calls.nav_terminal_reason))
			local builds, deployments, starts = calls.build, calls.deploy, calls.start
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(capture.codes, { 38 })
			helpers.assert_eq(capture.current(), true)
			helpers.assert_eq({ calls.build, calls.deploy, calls.start }, { builds, deployments, starts })
		end)
	end)

	for _, settings in ipairs({
		'[karabiner]\nintegration_enabled = false\n[tap_holds.config.left_shift]\nhold = "layer"\n',
		'[karabiner]\nintegration_enabled = true\n[tap_holds]\nenabled = false\n[tap_holds.config.left_shift]\nhold = "layer"\n',
		'[karabiner]\nintegration_enabled = true\n[tap_holds.config.left_shift]\nhold = "none"\n',
	}) do
		helpers.it("nav-configured remap leaves unreachable Navigation inputs unreserved: " .. settings, function()
			with_navigation_case(function(remap, calls)
				local capture = remap.capture_configured_navigation_inventory()
				if calls.nav_fixture_regenerated ~= true then
					helpers.assert_nil(capture, "an uncompiled disabled owner must not invent an empty original-map receipt")
				else
					helpers.assert_type(capture, "table")
					helpers.assert_eq(capture.codes, {})
					helpers.assert_eq(capture.current(), true)
				end
			end, settings)
		end)
	end

	helpers.it("nav-configured remap refuses observed settings source replacement", function()
		with_navigation_case(function(remap, _, write, _, text)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			write(text .. "# external successor\n")
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap refuses Navigation source replacement", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			write(text .. "# external successor\n")
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap refuses a live setting mutation without inventing source currency", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(remap.set_tap_action("left_shift", "escape"), true)
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap recognizes the real layer_on action", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(capture.codes, { 38 })
			helpers.assert_eq(capture.current(), true)
		end, '[karabiner]\nintegration_enabled = true\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\ntap = "layer_on"\nhold = "none"\n')
	end)

	helpers.it("nav-configured remap cannot activate a layer action absent from its actual catalogue", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(capture.codes, {})
			helpers.assert_eq(capture.current(), true)
		end, nil, false)
	end)

	helpers.it("nav-configured remap refuses an observed action activation change", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			local observed = 0
			for _, action in ipairs(remap.AVAILABLE_ACTIONS) do
				if action.id == "layer" then
					for _, event in ipairs(action.karabiner_to) do
						if event.set_variable and event.set_variable.name == "layer_active" then
							event.set_variable.value = 0; observed = observed + 1
						end
					end
				end
			end
			helpers.assert_eq(observed, 1, "the real action's actual activation event changed")
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap refuses disk replacement after the actual original compilation", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			helpers.assert_eq(calls.nav_fixture_regenerated, true)
			write(text:gsub("KeyJ", "KeyG"))
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "a fresh disk load cannot replace the actual compiled-map baseline")
		end)
	end)

	helpers.it("nav-configured remap retires the old captured map after real regeneration", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			write(text:gsub("KeyJ", "KeyG"))
			local accepted, completed = calls.nav_regenerate()
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true)
			helpers.assert_eq(capture.current(), false)
			local successor = remap.capture_configured_navigation_inventory()
			helpers.assert_type(successor, "table")
			helpers.assert_eq(successor.codes, { 5 })
			helpers.assert_eq(successor.current(), true)
		end)
	end)

	helpers.it("nav-configured remap refuses settings removed after compilation even when saved bytes agree", function()
		with_navigation_case(function(remap, _, write, _, text)
			helpers.assert_eq(remap.set_hold_action("left_shift", "none"), true)
			write(text:gsub('hold = "layer"', 'hold = "none"'))
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "newly saved settings do not own the old compiled rules")
		end)
	end)

	helpers.it("nav-configured remap refuses a changed nested activator definition", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			remap.TAP_HOLD_KEYS[1].id = "retired-definition"
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	for _, phase in ipairs({ "build", "deploy" }) do
		helpers.it("nav-configured remap grants no receipt after actual " .. phase .. " refusal", function()
			with_navigation_case(function(remap, calls)
				local before = remap.capture_configured_navigation_inventory()
				helpers.assert_type(before, "table")
				local generator = package.loaded["platform.remap.generator"]
				local original = generator.build_karabiner_json
				if phase == "build" then generator.build_karabiner_json = function() return nil, "controlled original compiler refusal" end
				else calls.fail_deploy = true end
				local accepted = remap.regenerate()
				generator.build_karabiner_json = original; calls.fail_deploy = false
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(before.current(), false)
				helpers.assert_nil(remap.capture_configured_navigation_inventory(), "a failed or ambiguous publication gives no original-map authority")
			end)
		end)
	end

	helpers.it("nav-configured remap admits no prepared receipt inside the original deployment callback", function()
		with_navigation_case(function(remap, calls)
			local entered, during = 0, false
			calls.deploy_override = function()
				entered = entered + 1
				during = remap.capture_configured_navigation_inventory()
				return true, "owned-fixture-deployment"
			end
			local accepted, completed = calls.nav_regenerate()
			calls.deploy_override = nil
			helpers.assert_eq(entered, 1, "the original publisher actually reaches the held deployment boundary")
			helpers.assert_nil(during, "prepared input facts cannot authenticate successful publication")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true)
			helpers.assert_type(remap.capture_configured_navigation_inventory(), "table")
		end)
	end)

	helpers.it("nav-configured remap refuses source changed inside an otherwise successful deployment", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			local entered = 0
			calls.deploy_override = function()
				entered = entered + 1
				write(text:gsub("KeyJ", "KeyG"))
				return true, "owned-fixture-deployment"
			end
			local accepted, completed = calls.nav_regenerate()
			calls.deploy_override = nil
			helpers.assert_eq(entered, 1)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true, "the original publisher's own success remains unchanged")
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "changed source cannot admit the compiled predecessor")
		end)
	end)
	helpers.it("nav-configured remap refuses actual compiler callback input mutation", function()
		with_navigation_case(function(remap, calls)
			local generator = package.loaded["platform.remap.generator"]
			local build, consumed = generator.build_karabiner_json, nil
			generator.build_karabiner_json = function(state, ...)
				state.nav_layer.registry.keys.KeyJ.karabiner.key_code = "g"
				local actual = require("platform.remap.nav_layer").build_rule(state.nav_layer.bindings, state.nav_layer.registry, "ansi")
				consumed = actual.manipulators[1].from.key_code
				return build(state, ...)
			end
			local accepted, completed = calls.nav_regenerate()
			generator.build_karabiner_json = build
			helpers.assert_eq(consumed, "g", "the existing compiler callback sees the genuinely changed input")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true, "native fixture admission is preserved")
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "HS equality does not own a different compiled input")
		end)
	end)

	for _, phase in ipairs({ "prepare", "settle" }) do
	helpers.it("nav-configured " .. phase .. " predecessor read failure cannot erase a real successor", function()
		with_navigation_case(function(remap, calls)
			local original_open = io.open
			local logger = package.loaded["infra.logger"]
			local original_error, armed, entered = logger.error, false, 0
			local successor_accepted, successor_completed, successor
			logger.error = function(...)
				if armed then
					armed = false; io.open = original_open; calls.deploy_override = nil
					entered = entered + 1
					successor_accepted, successor_completed = calls.nav_regenerate()
					successor = remap.capture_configured_navigation_inventory()
				end
				return original_error(...)
			end
			local reads = 0
			local function arm_read_failure()
				armed = true
				io.open = function(path, mode)
					local handle, detail = original_open(path, mode)
					if armed and handle and mode == "r" and path:match("/config_karabiner%.toml$") then
						reads = reads + 1
						if phase == "prepare" and reads ~= 4 then return handle, detail end
						return { read = function(_, ...) return handle:read(...) end,
							close = function() assert(handle:close()); return false, "controlled real read close refusal" end }
					end
					return handle, detail
				end
			end
			if phase == "prepare" then arm_read_failure()
			else calls.deploy_override = function() arm_read_failure(); return true, "owned-fixture-deployment" end end
			local invoked, accepted, completed = pcall(calls.nav_regenerate)
			io.open = original_open; logger.error = original_error; calls.deploy_override = nil
			helpers.assert_eq(invoked, true)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true)
			helpers.assert_eq(entered, 1, "a genuine original FileSystem failure invokes the diagnostic callback")
			helpers.assert_eq(successor_accepted, true)
			helpers.assert_eq(successor_completed, true, "the successor reaches its original final publication fence")
			helpers.assert_type(successor, "table")
			helpers.assert_eq(successor.current(), true)
			helpers.assert_type(remap.capture_configured_navigation_inventory(), "table", "the predecessor cannot clear the successor receipt")
		end)
	end)

	end
	helpers.it("nav-configured off-to-on joins the exact original acknowledged enable publication", function()
		with_navigation_case(function(remap, calls)
			helpers.assert_nil(remap.capture_configured_navigation_inventory())
			local terminal, reason
			local accepted = remap.set_enabled(true, function(ok, detail) terminal, reason = ok, detail end)
			if calls.start_paused_callback ~= nil then calls.deliver_ready(true, "owned-fixture-ready") end
			if #calls.resume_callbacks > 0 then calls.deliver_resumed(true, "owned-fixture-resumed") end
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(terminal, true, "the original enable must actually complete: " .. tostring(reason))
			local inventory = remap.capture_configured_navigation_inventory()
			helpers.assert_type(inventory, "table", "the original write receipt owns the new enabled bytes")
			helpers.assert_eq(inventory.codes, { 38 })
			helpers.assert_eq(inventory.current(), true)
		end, '[karabiner]\nintegration_enabled = false\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\nhold = "layer"\n', nil, true)
	end)

	for _, phase in ipairs({ "before_ready", "before_resumed" }) do
		helpers.it("nav-configured enable refuses external settings replacement " .. phase, function()
			with_navigation_case(function(remap, calls, write, _, _, _, path)
				local terminal, reason
				local accepted = remap.set_enabled(true, function(ok, detail) terminal, reason = ok, detail end)
				local function replace()
					local stream = assert(io.open(path, "rb")); local content = assert(stream:read("*a")); assert(stream:close())
					write(content .. "# independent enable-time successor\n")
				end
				if phase == "before_ready" then replace() end
				if calls.start_paused_callback ~= nil then calls.deliver_ready(true, "owned-fixture-ready") end
				if phase == "before_resumed" then replace() end
				if #calls.resume_callbacks > 0 then calls.deliver_resumed(true, "owned-fixture-resumed") end
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(terminal, true, "original native enable admission is unchanged: " .. tostring(reason))
				helpers.assert_nil(remap.capture_configured_navigation_inventory(), "a later read cannot replace the original compile/write source custody")
			end, '[karabiner]\nintegration_enabled = false\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\nhold = "layer"\n', nil, true)
		end)
	end

end)
