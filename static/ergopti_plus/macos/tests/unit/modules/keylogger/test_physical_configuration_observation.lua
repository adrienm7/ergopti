--- tests/unit/modules/keylogger/test_physical_configuration_observation.lua

--- Exercises actual filter writers without claiming a native context history.
local helpers = require("tests.helpers")

local function with_core(callback)
	return helpers.with_stub_scope({ "modules.keylogger", "modules.keylogger.init",
		"modules.keylogger.physical_accounting_mode", "adapters.physical_observation_clock",
		"keylogger.physical_configuration_observation", "modules.keylogger.text_cipher",
		"modules.keylogger.text_migration", "modules.keylogger.kc_bridge" }, function()
		local encrypted, available, migrating = false, true, false
		package.loaded["modules.keylogger.text_cipher"] = {
			set_enabled = function(value) encrypted = value end,
			is_enabled = function() return encrypted end,
			is_available = function() return available end,
		}
		package.loaded["modules.keylogger.text_migration"] = { is_running = function() return migrating end }
		package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
		local core = helpers.load_with_stubs("modules.keylogger")
		local now, reads = 100, 0
		hs.timer.absoluteTime = function() now, reads = now + 1, reads + 1; return now end
		local controls = { time = function(value) now = value end, reads = function() return reads end,
			clock = function(reader) hs.timer.absoluteTime = reader end,
			available = function(value) available = value end,
			migrating = function(value) migrating = value end }
		callback(core, controls)
	end)
end

local function subscribe(core, owner, callback, capacity, refused)
	helpers.assert_eq(type(core.bind_physical_configuration_observer), "function")
	helpers.assert_eq(type(core.unbind_physical_configuration_observer), "function")
	return core.bind_physical_configuration_observer(owner, capacity or 32, callback, refused or function() end)
end

helpers.describe("dormant physical configuration observations", function()
	helpers.it("preserves unbound alias behavior without acquiring an observation clock", function()
		with_core(function(core, controls)
			local apps = {{ name = "Label", bundleID = "original.app" }}
			core.set_disabled_apps(apps)
			apps[1].bundleID = "legacy.alias"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "legacy.alias")
			core.set_private_filter_enabled(false)
			core.set_secure_field_filter_enabled(false)
			core.set_system_auth_filter_enabled(false)
			helpers.assert_eq(controls.reads(), 0)
		end)
	end)

	helpers.it("copies exact current filters without emitting a permission or application history", function()
		with_core(function(core, controls)
			local apps = {{ name = "Not emitted", bundleID = "excluded.app", appPath = "/Excluded.app" }}
			core.set_disabled_apps(apps)
			local records, owner = {}, {}
			local ok, token = subscribe(core, owner, function(record, identity)
				records[#records + 1] = record; helpers.assert_true(type(identity) == "table"); return true
			end)
			helpers.assert_true(ok)
			helpers.assert_eq(records, {{ kind = "physical_configuration", revision = 1, at = 101,
				private_filter_enabled = true, secure_field_filter_enabled = true,
				system_auth_filter_enabled = true, disabled_apps = {{ bundleID = "excluded.app", appPath = "/Excluded.app" }} }})
			apps[1].bundleID = "mutated.after.binding"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "excluded.app")
			helpers.assert_eq(controls.reads(), 1)
			helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
		end)
	end)

	helpers.it("publishes all actual filter setters in native observation order with independent copies", function()
		with_core(function(core)
			local records, owner = {}, {}
			local ok, token = subscribe(core, owner, function(record) records[#records + 1] = record; return true end)
			helpers.assert_true(ok)
			local apps = {{ name = "Preserved locally", bundleID = "first.app" }}
			core.set_disabled_apps(apps)
			apps[1].bundleID = "unobserved.alias"
			core.set_private_filter_enabled(false)
			core.set_secure_field_filter_enabled(false)
			core.set_system_auth_filter_enabled(false)
			helpers.assert_eq(#records, 5)
			for index, record in ipairs(records) do
				helpers.assert_eq(record.revision, index); helpers.assert_eq(record.at, 100 + index)
			end
			helpers.assert_eq(records[5].disabled_apps, {{ bundleID = "first.app" }})
			helpers.assert_eq(records[5].private_filter_enabled, false)
			helpers.assert_eq(records[5].secure_field_filter_enabled, false)
			helpers.assert_eq(records[5].system_auth_filter_enabled, false)
			records[5].disabled_apps[1].bundleID = "observer.mutation"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "first.app")
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].name, "Preserved locally")
			helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			apps = {{ bundleID = "after.unbind" }}
			core.set_disabled_apps(apps); apps[1].bundleID = "alias.restored"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "alias.restored")
			helpers.assert_eq(#records, 5)
		end)
	end)

	helpers.it("publishes one complete configuration transaction and nothing for rejected transactions", function()
		with_core(function(core, controls)
			local records, owner = {}, {}
			local ok, token = subscribe(core, owner, function(record) records[#records + 1] = record; return true end)
			helpers.assert_true(ok)
			local config = core.configuration_snapshot()
			config.options.encrypt, config.cipher_enabled = true, true
			config.disabled_apps = {{ bundleID = "scope.app" }}
			config.private_filter_enabled, config.secure_field_filter_enabled, config.system_auth_filter_enabled = false, false, false
			controls.available(false)
			helpers.assert_eq(core.apply_configuration(config), false); helpers.assert_eq(#records, 1)
			controls.available(true); controls.migrating(true)
			helpers.assert_eq(core.apply_configuration(config), false); helpers.assert_eq(#records, 1)
			controls.migrating(false)
			helpers.assert_true(core.apply_configuration(config)); helpers.assert_eq(#records, 2)
			config.disabled_apps[1].bundleID = "changed"
			helpers.assert_eq(records[2], { kind = "physical_configuration", revision = 2, at = 102,
				private_filter_enabled = false, secure_field_filter_enabled = false,
				system_auth_filter_enabled = false, disabled_apps = {{ bundleID = "scope.app" }} })
			helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
		end)
	end)

	helpers.it("retains exact token ownership and refuses a competing binding without clock or callback work", function()
		with_core(function(core, controls)
			local owner, calls = {}, 0
			local ok, token = subscribe(core, owner, function() calls = calls + 1; return true end)
			helpers.assert_true(ok)
			local before = controls.reads()
			helpers.assert_eq(subscribe(core, owner, function() error("competing callback") end), false)
			helpers.assert_eq(core.unbind_physical_configuration_observer({}, token), false)
			helpers.assert_eq(core.unbind_physical_configuration_observer(owner, {}), false)
			helpers.assert_eq(controls.reads(), before); helpers.assert_eq(calls, 1)
			helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			helpers.assert_eq(core.unbind_physical_configuration_observer(owner, token), false)
		end)
	end)

	for _, invalid in ipairs({ 101.0, -1, "101", math.huge, 0 / 0 }) do
		helpers.it("refuses an unknown native clock representation " .. tostring(invalid), function()
			with_core(function(core, controls)
				local calls, failures = 0, {}
				controls.clock(function() return invalid end)
				local ok = subscribe(core, {}, function() calls = calls + 1; return true end, 32,
					function(reason) failures[#failures + 1] = reason end)
				helpers.assert_eq(ok, false); helpers.assert_eq(calls, 0); helpers.assert_eq(#failures, 1)
				helpers.assert_true(failures[1]:find("native observation clock", 1, true) ~= nil)
				controls.clock(function() return 123 end)
				helpers.assert_true(subscribe(core, {}, function() calls = calls + 1; return true end))
				helpers.assert_eq(calls, 1, "A refused acquisition cannot retain phantom ownership")
			end)
		end)
	end

	helpers.it("retires before budget exhaustion or non-increasing clock publication and never evicts", function()
		for _, mode in ipairs({ "capacity", "clock" }) do
			with_core(function(core, controls)
				local records, failures, owner = {}, {}, {}
				local ok, token = subscribe(core, owner, function(record) records[#records + 1] = record; return true end,
					mode == "capacity" and 1 or 32, function(reason) failures[#failures + 1] = reason end)
				helpers.assert_true(ok)
				if mode == "clock" then controls.time(100) end
				core.set_private_filter_enabled(false)
				core.set_private_filter_enabled(true)
				helpers.assert_eq(#records, 1); helpers.assert_eq(#failures, 1)
				helpers.assert_true(failures[1]:find(mode == "capacity" and "budget exhausted" or "not ordered", 1, true) ~= nil)
				helpers.assert_eq(subscribe(core, {}, function() return true end), false)
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			end)
		end
	end)

	helpers.it("retires caught callback reentry before the outer publication can acknowledge success", function()
		with_core(function(core)
			local calls, failures, owner = 0, {}, {}
			local ok, token = subscribe(core, owner, function()
				calls = calls + 1
				if calls == 2 then core.set_secure_field_filter_enabled(false) end
				return true
			end, 32, function(reason) failures[#failures + 1] = reason end)
			helpers.assert_true(ok)
			core.set_private_filter_enabled(false)
			core.set_private_filter_enabled(true)
			helpers.assert_eq(calls, 2); helpers.assert_eq(#failures, 1)
			helpers.assert_true(failures[1]:find("reentered", 1, true) ~= nil)
			helpers.assert_eq(core.configuration_snapshot().secure_field_filter_enabled, false)
			helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
		end)
	end)

	helpers.it("does not clobber a successor bound inside an old callback", function()
		with_core(function(core)
			local old_owner, successor, calls, replacement_calls = {}, {}, 0, 0
			local replacement_token
			local ok = subscribe(core, old_owner, function(_, token)
				calls = calls + 1
				helpers.assert_true(core.unbind_physical_configuration_observer(old_owner, token))
				local accepted
				accepted, replacement_token = subscribe(core, successor, function() replacement_calls = replacement_calls + 1; return true end)
				helpers.assert_true(accepted)
				return true
			end)
			helpers.assert_eq(ok, false, "The old publication no longer owns its acknowledgement")
			core.set_private_filter_enabled(false)
			helpers.assert_eq(calls, 1); helpers.assert_eq(replacement_calls, 2)
			helpers.assert_true(core.unbind_physical_configuration_observer(successor, replacement_token))
		end)
	end)

	for _, verdict in ipairs({ "false", "throw" }) do
		helpers.it("contains subscriber " .. verdict .. " without undoing committed configuration", function()
			with_core(function(core)
				local calls, failures, owner = 0, {}, {}
				local ok, token = subscribe(core, owner, function()
					calls = calls + 1
					if calls > 1 then if verdict == "throw" then error("subscriber failed") else return false end end
					return true
				end, 32, function(reason) failures[#failures + 1] = reason; error("refusal observer failed") end)
				helpers.assert_true(ok)
				core.set_private_filter_enabled(false); core.set_secure_field_filter_enabled(false)
				helpers.assert_eq(core.configuration_snapshot().private_filter_enabled, false)
				helpers.assert_eq(calls, 2); helpers.assert_eq(#failures, 1)
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			end)
		end)
	end
end)

helpers.describe("physical configuration acquisition and clock independence", function()
	helpers.it("keeps its clock cursor independent of caller-mutated receipt metadata", function()
		with_core(function(core, controls)
			local calls, refused, owner = 0, 0, {}
			local ok, token = subscribe(core, owner, function(record)
				calls = calls + 1; record.at, record.revision = 0, 0; return true
			end, 32, function() refused = refused + 1 end)
			helpers.assert_true(ok)
			controls.time(99)
			core.set_private_filter_enabled(false)
			helpers.assert_eq(calls, 1, "Receipt mutation cannot authorize an earlier native timestamp")
			helpers.assert_eq(refused, 1)
			helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
		end)
	end)

	helpers.it("preserves the original unbound alias when initial clock acquisition is refused", function()
		with_core(function(core, controls)
			local apps = {{ bundleID = "before.refusal" }}
			core.set_disabled_apps(apps)
			controls.clock(function() return 100.0 end)
			helpers.assert_eq(subscribe(core, {}, function() return true end), false)
			apps[1].bundleID = "unbound.alias.after.refusal"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "unbound.alias.after.refusal")
		end)
	end)

	helpers.it("preserves configuration changed by a refused initial callback instead of restoring stale aliases", function()
		with_core(function(core)
			local old = {{ bundleID = "old.alias" }}
			core.set_disabled_apps(old)
			helpers.assert_eq(subscribe(core, {}, function()
				core.set_disabled_apps({{ bundleID = "committed.during.callback" }})
				return false
			end), false)
			old[1].bundleID = "old.external.mutation"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "committed.during.callback")
		end)
	end)
end)

helpers.describe("physical configuration plain-data ownership", function()
	helpers.it("refuses caller metamethods and cycles before installing an observation owner", function()
		with_core(function(core)
			local calls = 0
			local payload = setmetatable({}, { __pairs = function() calls = calls + 1; error("must not execute") end })
			core.set_disabled_apps({{ bundleID = "safe.selector", extra = payload }})
			local ok, reason = pcall(function() subscribe(core, {}, function() return true end) end)
			helpers.assert_eq(ok, false); helpers.assert_eq(calls, 0)
			helpers.assert_true(tostring(reason):find("plain and acyclic", 1, true) ~= nil)
			local cycle = {}; cycle.self = cycle
			core.set_disabled_apps({{ bundleID = "safe.selector", extra = cycle }})
			ok, reason = pcall(function() subscribe(core, {}, function() return true end) end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("plain and acyclic", 1, true) ~= nil)
			core.set_disabled_apps({{ bundleID = "valid" }})
			helpers.assert_true(subscribe(core, {}, function() return true end))
		end)
	end)

	helpers.it("refuses invalid bound assignment before changing policy and preserves the healthy subscriber", function()
		with_core(function(core)
			local calls, owner = 0, {}
			local ok, token = subscribe(core, owner, function() calls = calls + 1; return true end)
			helpers.assert_true(ok)
			local cycle = {}; cycle.self = cycle
			local accepted = pcall(core.set_disabled_apps, {{ bundleID = "bad", extra = cycle }})
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(core.configuration_snapshot().disabled_apps, {})
			helpers.assert_eq(calls, 1)
			core.set_disabled_apps({{ name = "Plain label", bundleID = "healthy" }})
			helpers.assert_eq(calls, 2)
			helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
		end)
	end)
end)

helpers.describe("physical configuration native-read cancellation", function()
	helpers.it("retires a reentered clock sample before any initial receipt is delivered", function()
		with_core(function(core, controls)
			local calls, failures = 0, 0
			controls.clock(function() core.set_private_filter_enabled(false); return 777 end)
			helpers.assert_eq(subscribe(core, {}, function() calls = calls + 1; return true end, 32,
				function() failures = failures + 1 end), false)
			helpers.assert_eq(calls, 0); helpers.assert_eq(failures, 1)
			controls.clock(function() return 888 end)
			helpers.assert_true(subscribe(core, {}, function(record)
				calls = calls + 1; helpers.assert_eq(record.private_filter_enabled, false); return true
			end))
			helpers.assert_eq(calls, 1)
		end)
	end)
end)

helpers.describe("physical configuration detach-only acquisition cancellation", function()
	helpers.it("restores the original unbound alias after the initial receiver detaches without a successor", function()
		with_core(function(core)
			local original, owner, calls = {{ bundleID = "original.before.detachment" }}, {}, 0
			core.set_disabled_apps(original)
			local accepted = subscribe(core, owner, function(_, token)
				calls = calls + 1
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
				return true
			end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(calls, 1)
			original[1].bundleID = "legacy.alias.after.detachment"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "legacy.alias.after.detachment")
			helpers.assert_true(subscribe(core, {}, function() return true end), "Detached acquisition leaves no phantom owner")
		end)
	end)
end)

helpers.describe("physical configuration validated bound transactions", function()
	for _, example in ipairs({
		{ label = "numeric selector", apps = {{ bundleID = 42 }} },
		{ label = "sparse array", apps = { [2] = { bundleID = "sparse" } } },
		{ label = "non-table row", apps = { false } },
	}) do
		helpers.it("rejects bound " .. example.label .. " before setter assignment or subscriber retirement", function()
			with_core(function(core)
				local calls, failures, owner = 0, 0, {}
				local ok, token = subscribe(core, owner, function() calls = calls + 1; return true end,
					32, function() failures = failures + 1 end)
				helpers.assert_true(ok)
				local accepted = pcall(core.set_disabled_apps, example.apps)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(core.configuration_snapshot().disabled_apps, {})
				helpers.assert_eq(calls, 1); helpers.assert_eq(failures, 0)
				core.set_disabled_apps({{ bundleID = "healthy.after.refusal" }})
				helpers.assert_eq(calls, 2)
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			end)
		end)
	end

	for _, kind in ipairs({ "cycle", "selector", "metatable" }) do
		helpers.it("refuses bound apply " .. kind .. " before foreign posture work or partial option mutation", function()
			with_core(function(core)
				local calls, owner, posture_calls = 0, {}, 0
				local ok, token = subscribe(core, owner, function() calls = calls + 1; return true end)
				helpers.assert_true(ok)
				local prior, candidate = core.configuration_snapshot(), core.configuration_snapshot()
				candidate.options.encrypt, candidate.cipher_enabled = true, true
				candidate.options.marker = "must.not.commit"
				if kind == "cycle" then
					local cycle = {}; cycle.self = cycle
					candidate.disabled_apps = {{ bundleID = "invalid", extra = cycle }}
				elseif kind == "selector" then candidate.disabled_apps = {{ bundleID = 42 }}
				else
					candidate.options = setmetatable({ encrypt = true }, {
						__pairs = function() error("caller options metamethod must not execute") end })
				end
				local cipher = package.loaded["modules.keylogger.text_cipher"]
				local original_set = cipher.set_enabled
				cipher.set_enabled = function(value) posture_calls = posture_calls + 1; original_set(value) end
				local accepted = pcall(core.apply_configuration, candidate)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(posture_calls, 0, "Invalid candidate must be refused before encryption changes")
				helpers.assert_eq(core.configuration_snapshot(), prior)
				helpers.assert_eq(calls, 1)
				core.set_private_filter_enabled(false)
				helpers.assert_eq(calls, 2, "Refused invalid candidate preserves the healthy observation owner")
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			end)
		end)
	end

	for _, foreign in ipairs({ "set_enabled", "is_available", "is_running" }) do
		helpers.it("copies its bound apply candidate before foreign " .. foreign .. " can mutate caller aliases", function()
			with_core(function(core)
				local records, owner = {}, {}
				local ok, token = subscribe(core, owner, function(record) records[#records + 1] = record; return true end)
				helpers.assert_true(ok)
				local candidate = core.configuration_snapshot()
				candidate.options.encrypt, candidate.cipher_enabled = true, true
				candidate.disabled_apps = {{ name = "Entry label", bundleID = "entry.app" }}
				candidate.private_filter_enabled, candidate.secure_field_filter_enabled, candidate.system_auth_filter_enabled = false, false, false
				local object = package.loaded[foreign == "is_running" and "modules.keylogger.text_migration" or "modules.keylogger.text_cipher"]
				local original = object[foreign]
				object[foreign] = function(...)
					candidate.disabled_apps[1].bundleID = "mutated.by.foreign.callback"
					candidate.options.encrypt = false
					candidate.private_filter_enabled, candidate.secure_field_filter_enabled, candidate.system_auth_filter_enabled = true, true, true
					return original(...)
				end
				helpers.assert_true(core.apply_configuration(candidate))
				helpers.assert_eq(#records, 2)
				helpers.assert_eq(records[2], { kind = "physical_configuration", revision = 2, at = 102,
					private_filter_enabled = false, secure_field_filter_enabled = false,
					system_auth_filter_enabled = false, disabled_apps = {{ bundleID = "entry.app" }} })
				local committed = core.configuration_snapshot()
				helpers.assert_eq(committed.options.encrypt, true)
				helpers.assert_eq(committed.cipher_enabled, true)
				helpers.assert_eq(committed.disabled_apps[1].bundleID, "entry.app")
				helpers.assert_eq(committed.disabled_apps[1].name, "Entry label")
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			end)
		end)
	end
end)


helpers.describe("physical configuration raw ownership identities", function()
	for _, identity in ipairs({ "owner", "token" }) do
		helpers.it("refuses forged " .. identity .. " without invoking caller equality or detaching the real owner", function()
			with_core(function(core)
				local owner, calls, equality_calls = {}, 0, 0
				local ok, token = subscribe(core, owner, function() calls = calls + 1; return true end)
				helpers.assert_true(ok)
				local forged = setmetatable({}, { __eq = function() equality_calls = equality_calls + 1; return true end })
				local detached = core.unbind_physical_configuration_observer(identity == "owner" and forged or owner,
					identity == "token" and forged or token)
				core.set_private_filter_enabled(false)
				helpers.assert_eq(detached, false, "Forged identity cannot release the exact owner")
				helpers.assert_eq(equality_calls, 0, "Ownership checks must not execute caller equality")
				helpers.assert_eq(calls, 2, "The original owner still receives the next policy")
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
			end)
		end)

		helpers.it("does not run forged " .. identity .. " equality that would detach and clobber a synchronous successor", function()
			with_core(function(core)
				local owner, successor, equality_calls, successor_calls = {}, {}, 0, 0
				local ok, token = subscribe(core, owner, function() return true end)
				helpers.assert_true(ok)
				local successor_token, inner_detached, inner_bound
				local forged = setmetatable({}, { __eq = function()
					equality_calls = equality_calls + 1
					inner_detached = core.unbind_physical_configuration_observer(owner, token)
					inner_bound, successor_token = subscribe(core, successor, function()
						successor_calls = successor_calls + 1; return true
					end)
					return true
				end })
				local detached = core.unbind_physical_configuration_observer(identity == "owner" and forged or owner,
					identity == "token" and forged or token)
				-- The corrected path executes no foreign equality. Complete an ordinary
				-- exact handover to exercise the same successor after that refusal.
				if equality_calls == 0 then
					inner_detached = core.unbind_physical_configuration_observer(owner, token)
					inner_bound, successor_token = subscribe(core, successor, function()
						successor_calls = successor_calls + 1; return true
					end)
				end
				core.set_system_auth_filter_enabled(false)
				helpers.assert_true(inner_detached); helpers.assert_true(inner_bound)
				helpers.assert_eq(successor_calls, 2, "A stale outer detach must not erase the successor installed during equality")
				helpers.assert_eq(equality_calls, 0, "No caller equality may enter ownership release")
				helpers.assert_eq(detached, false)
				helpers.assert_true(core.unbind_physical_configuration_observer(successor, successor_token))
			end)
		end)
	end

	helpers.it("preserves a genuinely committed metatable replacement after the initial receiver detaches", function()
		with_core(function(core)
			local original, owner, equality_calls = {{ bundleID = "old.unbound.alias" }}, {}, 0
			local replacement = setmetatable({{ bundleID = "committed.replacement" }}, {
				__eq = function() equality_calls = equality_calls + 1; return true end })
			core.set_disabled_apps(original)
			local accepted = subscribe(core, owner, function(_, token)
				helpers.assert_true(core.unbind_physical_configuration_observer(owner, token))
				core.set_disabled_apps(replacement)
				return true
			end)
			helpers.assert_eq(accepted, false)
			replacement[1].bundleID = "committed.alias.after.detachment"
			original[1].bundleID = "stale.original.mutation"
			helpers.assert_eq(core.configuration_snapshot().disabled_apps[1].bundleID, "committed.alias.after.detachment",
				"Failed acquisition must not restore over a genuinely committed replacement")
			helpers.assert_eq(equality_calls, 0, "Alias ownership checks must not execute replacement equality")
		end)
	end)
end)

helpers.describe("physical configuration native boundary strictness", function()
	helpers.it("refuses non-integer native budgets before reading time or invoking subscribers", function()
		for _, row in ipairs({ { value = 32.0 }, { value = 0 }, { value = -1 }, { value = 1.5 },
			{ value = math.huge }, { value = -math.huge }, { value = 0 / 0 }, { value = "32" },
			{ value = false }, { value = {} }, {} }) do
			with_core(function(core, controls)
				local calls, refused = 0, 0
				local accepted = pcall(core.bind_physical_configuration_observer, {}, row.value,
					function() calls = calls + 1; return true end, function() refused = refused + 1 end)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(controls.reads(), 0)
				helpers.assert_eq(calls, 0); helpers.assert_eq(refused, 0)
				helpers.assert_true(subscribe(core, {}, function() return true end), "Invalid budget installs no owner")
			end)
		end
	end)

	helpers.it("loads its clock without querying native time and returns exactly one unmodified integer read", function()
		with_core(function(_, controls)
			local clock = require("adapters.physical_observation_clock")
			helpers.assert_eq(controls.reads(), 0)
			helpers.assert_eq(type(clock.now), "function")
			helpers.assert_eq(clock.now(), 101)
			helpers.assert_eq(controls.reads(), 1)
		end)
	end)

	helpers.it("refuses native clock floats and invalid types before the shared numeric boundary", function()
		for _, row in ipairs({ { value = 101.0 }, { value = -1 }, { value = 1.5 },
			{ value = math.huge }, { value = -math.huge }, { value = 0 / 0 }, { value = "101" },
			{ value = false }, { value = {} }, {} }) do
			with_core(function(_, controls)
				local reads = 0
				controls.clock(function() reads = reads + 1; return row.value end)
				local ok, reason = pcall(require("adapters.physical_observation_clock").now)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(reason):find("native observation clock", 1, true) ~= nil)
				helpers.assert_eq(reads, 1, "Validation must not resample, coerce or synthesize native time")
			end)
		end
	end)
end)
