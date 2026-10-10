--- tests/unit/ui/test_onboarding_write_failure_surfaced.lua

--- ==============================================================================
--- MODULE: Regression — a failed onboarding write must not report success
--- DESCRIPTION:
--- The first-run wizard silently discarded the user's answers when the write
--- failed.
---
--- ROOT CAUSE ENCODED:
--- commit() wrapped the write in a pcall whose closure had no `return`, and
--- toml_codec's batch_write never raises on I/O failure: it RETURNS false plus a
--- reason. The wizard therefore logged success and called hs.reload() with
--- nothing on disk. The finish handler is now driven end to end: every way the
--- writer can refuse (false, nil, a raise) and an unreadable destination must
--- surface an error and schedule no reload.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_finish = require("tests.support.onboarding_finish_fixture").with_finish

-- A valid finish payload whose rows reach the writer.
local ANSWERS = {
	locale = "en",
	config_dir = "",
	operations = { { path = "llm.enabled", value = true }, { path = "hotstrings.trigger_char", value = "ù" } },
}

--- Asserts the refusal every failed commit must produce.
--- @param state table Fixture state.
--- @param detail string|nil Text the error dialog must quote.
local function assert_refused(state, detail)
	helpers.assert_eq(state.notifications, 0, "no success notification")
	helpers.assert_eq(state.deferred, 0, "no reload over unwritten answers")
	helpers.assert_eq(#state.alerts, 1)
	helpers.assert_true(state.alerts[1].body:find("onboarding.error.write_failed", 1, true) ~= nil)
	if detail then
		helpers.assert_true(state.alerts[1].body:find(detail, 1, true) ~= nil,
			"the writer's own reason reaches the dialog: " .. state.alerts[1].body)
	end
end





-- ===============================================
-- ===============================================
-- ======= 1/ Every Failure Mode Surfaces ========
-- ===============================================
-- ===============================================

helpers.describe("onboarding surfaces a write that failed without raising", function()
	helpers.it("reports failure when batch_write RETURNS false", function()
		with_finish({ answers = ANSWERS, write = "false" }, function(state)
			helpers.assert_eq(#state.writes, 1)
			assert_refused(state, "rename failed")
		end)
	end)

	helpers.it("reports failure when batch_write returns nil", function()
		with_finish({ answers = ANSWERS, write = "nil" }, function(state)
			assert_refused(state)
		end)
	end)

	helpers.it("still reports failure when batch_write raises", function()
		with_finish({ answers = ANSWERS, write = "throw" }, function(state)
			assert_refused(state, "disk on fire")
		end)
	end)

	helpers.it("reports success only when the write is confirmed, with the answers as rows", function()
		with_finish({ answers = ANSWERS, write = "true" }, function(state)
			helpers.assert_eq(#state.writes, 1)
			helpers.assert_eq(state.writes[1].path, "/virtual/onboarding-config.toml")
			helpers.assert_eq(state.writes[1].rows, {
				{ section = "llm", key = "enabled", value = true },
				{ section = "hotstrings", key = "trigger_char", value = "ù" },
			})
			helpers.assert_eq(state.notifications, 1)
			helpers.assert_eq(state.deferred, 1)
			helpers.assert_eq(#state.alerts, 0)
		end)
	end)

	helpers.it("refuses a dangling destination before invoking batch_write", function()
		with_finish({
			answers = ANSWERS,
			read = function() return nil, "error", "dangling final symlink" end,
		}, function(state)
			helpers.assert_eq(#state.writes, 0,
				"onboarding must not let a lower writer replace a dangling symlink")
			assert_refused(state, "dangling final symlink")
		end)
	end)
end)


helpers.describe("onboarding retains actual native publication cleanup across UI lifetime", function()
	helpers.it("blocks another Finish and reopened wizard until the original no-effect release settles", function()
		local settled, cleanups, writes = false, 0, 0
		local function actual_cleanup()
			cleanups = cleanups + 1
			return settled, nil, false
		end
		with_finish({ answers = ANSWERS, native_writer = function(_, _, expected_source)
			helpers.assert_eq(expected_source, { status = "absent" }, "the captured source reaches the native port")
			writes = writes + 1
			if writes == 1 then return false, "release pending", nil, actual_cleanup, "[llm]\nenabled = true\n" end
			return true
		end }, function(state, onboarding)
			helpers.assert_eq(writes, 1)
			helpers.assert_eq(cleanups, 0)
			state.finish(ANSWERS)
			helpers.assert_eq(writes, 1, "an indebted Finish cannot write another configuration")
			helpers.assert_eq(cleanups, 1)
			helpers.assert_eq(onboarding.run("/virtual/changed-folder.toml"), false,
				"a reopened native view cannot discard the original publication owner")
			helpers.assert_eq(cleanups, 2)
			helpers.assert_eq(state.notifications, 0)
			helpers.assert_eq(state.deferred, 0)
			settled = true
			state.finish(ANSWERS)
			helpers.assert_eq(cleanups, 3)
			helpers.assert_eq(writes, 2, "only a new request after exact no-effect settlement can publish")
			helpers.assert_eq(state.notifications, 1)
			helpers.assert_eq(state.deferred, 1)
		end)
	end)

	helpers.it("refuses an unbound table receipt without calling forged cleanup methods", function()
		local invoked = 0
		with_finish({ answers = ANSWERS, native_writer = function()
			return false, "unbound receipt", nil, { retry = function() invoked = invoked + 1; return true end },
				"[llm]\nenabled = true\n"
		end }, function(state, onboarding)
			state.finish(ANSWERS)
			helpers.assert_eq(onboarding.run("/virtual/changed-folder.toml"), false)
			helpers.assert_eq(#state.writes, 1)
			helpers.assert_eq(invoked, 0)
			helpers.assert_eq(state.notifications, 0)
			helpers.assert_eq(state.deferred, 0)
		end)
	end)
end)


--- Drives the real Finish handler with generic exact-byte publication effects.
--- The controlled prepare installs no native configuration admission journal.
local function with_published_boundary(scenario)
	local before = '[_meta]\nschema_version = 12\n[llm]\nenabled = false\n'
	local candidate = '[_meta]\nschema_version = 12\n[llm]\nenabled = true\n'
	local f = { bytes = before, writes = 0, cleanups = 0, inverses = 0,
		inverse_cleanups = 0, settled = false }
	local function inverse(path, content, expected, _, admission)
		helpers.assert_eq(path, "/virtual/onboarding-config.toml")
		helpers.assert_eq(content, before)
		helpers.assert_eq(expected, { status = "ok", content = candidate })
		if admission ~= nil then helpers.assert_eq(admission(), true) end
		if f.bytes ~= candidate then return false, "foreign candidate refused" end
		f.inverses = f.inverses + 1
		f.bytes = content
		if f.inverse_debt then
			return false, "inverse release pending", function()
				f.inverse_cleanups = f.inverse_cleanups + 1
				return f.inverse_settled == true, nil, true
			end
		end
		return true
	end
	with_finish({ read = function() return f.bytes, "ok" end,
		prepare_destination = function(path)
			-- This fixture prepares generic exact bytes and grants no native
			-- configuration initialization or migration acknowledgment.
			helpers.assert_eq(path, "/virtual/onboarding-config.toml")
			helpers.assert_eq(f.bytes, before, "the generic control prepares the actual original source")
			return true
		end,
		native_files = { write_if_unchanged = inverse, write_if_unchanged_admitted = inverse },
		native_writer = function(_, _, source)
			f.writes = f.writes + 1
			helpers.assert_eq(source, { status = "ok", content = before })
			f.bytes = candidate
			return false, "published release pending", nil, function()
				f.cleanups = f.cleanups + 1
				return f.settled, nil, true
			end, candidate
		end }, function(state, onboarding)
		f.state, f.onboarding, f.before, f.candidate = state, onboarding, before, candidate
		state.finish(ANSWERS)
		scenario(f)
	end)
end

helpers.describe("macOS wizard generic publication compensation at actual Finish", function()
	helpers.it("releases and inverses the published file before another native Finish can write", function()
		with_published_boundary(function(f)
			helpers.assert_eq(f.writes, 1)
			f.state.finish(ANSWERS)
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.inverses, 0)
			helpers.assert_eq(f.bytes, f.candidate)
			f.settled = true
			f.state.finish(ANSWERS)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.writes, 2, "a new attempt follows compensation, never replaces its receipt")
			helpers.assert_eq(f.cleanups, 2)
			helpers.assert_eq(f.state.notifications, 0)
			helpers.assert_eq(f.state.deferred, 0)
		end)
	end)

	helpers.it("keeps the original publication owner across reopen and an unrelated successor", function()
		with_published_boundary(function(f)
			local foreign = '[_meta]\nschema_version = 12\n[llm]\nenabled = false\n# external successor\n'
			f.bytes, f.settled = foreign, true
			helpers.assert_eq(f.onboarding.run("/virtual/another-destination.toml"), false)
			f.state.finish(ANSWERS)
			helpers.assert_eq(f.bytes, foreign)
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.inverses, 0)
			helpers.assert_eq(f.cleanups, 1)
			helpers.assert_eq(f.state.notifications, 0)
			helpers.assert_eq(f.state.deferred, 0)
		end)
	end)

	helpers.it("settles the inverse's own native release without replaying its accepted write", function()
		with_published_boundary(function(f)
			f.settled, f.inverse_debt = true, true
			f.state.finish(ANSWERS)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.bytes, f.before)
			helpers.assert_eq(f.writes, 1)
			f.state.finish(ANSWERS)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.writes, 1)
			f.inverse_settled = true
			f.state.finish(ANSWERS)
			helpers.assert_eq(f.inverses, 1)
			helpers.assert_eq(f.writes, 2)
			helpers.assert_eq(f.inverse_cleanups, 2)
			helpers.assert_eq(f.cleanups, 1)
			helpers.assert_eq(f.state.notifications, 0)
			helpers.assert_eq(f.state.deferred, 0)
		end)
	end)
end)


--- Constructs the real canonical provider and publishes real private file bytes.
--- Hammerspoon SDK filesystem primitives are controlled by the existing fixture;
--- its genuine issuer, classified reader and admitted publisher remain unchanged.
local function with_canonical_finish(scenario, fresh_writer_after_inverse)
	local with_files = require("tests.support.file_system_transaction_fixture").with_fixture
	with_files(function(physical)
		local temporary = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
		local path = temporary:gsub("[/\\]+$", "") .. "/ergopti_wizard_native_"
			.. tostring(os.time()) .. "_" .. tostring({}):gsub("[^%w]", "") .. ".toml"
		local before = '# native Finish original\n[_meta]\nschema_version = 12\n[llm]\nenabled = false\n[future]\nkeep = "owned by another feature"\n'
		local created = assert(io.open(path, "w")); assert(created:write(before)); assert(created:close())
		local f = { path = path, before = before, unlocks = 0, close_refusals = 0, refuse_unlock = false }
		local adapter = physical.make_adapter(nil, nil, nil, nil, nil, function()
			f.unlocks = f.unlocks + 1
			return f.refuse_unlock ~= true
		end)
		local original_open = io.open
		local called, detail = xpcall(function()
			-- A genuine native release accepts unlock OR close. Model refusal of
			-- both primitives only for this private adjacent lock, as the canonical
			-- conditional-remove fixture does; all payload IO remains real.
			io.open = function(target, mode)
				local opened, open_error = original_open(target, mode)
				if opened == nil or target ~= path .. physical.WRITE_LOCK_SUFFIX or mode ~= "a+" then
					return opened, open_error
				end
				return { close = function()
					if f.refuse_unlock then
						f.close_refusals = f.close_refusals + 1
						return false, "private native lock close refused"
					end
					return opened:close()
				end }
			end
			with_finish({ canonical_files = adapter, config_path = path,
				fresh_writer_after_inverse = fresh_writer_after_inverse }, function(state, onboarding)
				f.files, f.state, f.onboarding = adapter, state, onboarding
				local issuer = assert(rawget(adapter, "configuration_ports"))
				local owner, reader, _, publisher = issuer()
				helpers.assert_eq(rawequal(owner, adapter), true, "the real initializer issues its original owner")
				helpers.assert_eq(reader, rawget(adapter, "read_with_status"))
				helpers.assert_eq(publisher, rawget(adapter, "write_if_unchanged_admitted"))
				helpers.assert_eq(adapter.read_with_status(path), before)
				local scenario_ok, scenario_error = xpcall(function() scenario(f) end, debug.traceback)
				if not scenario_ok then
					-- Release the exact owned continuation while its native issuer and
					-- module identities are still live. Recovery never hides the failure.
					f.refuse_unlock = false
					local recovered, recovery_error = pcall(state.finish,
						{ locale = "unavailable-locale", config_dir = "", operations = {} })
					if not recovered then
						error(scenario_error .. "\nPrivate native cleanup attempt raised: " .. tostring(recovery_error), 0)
					end
					error(scenario_error, 0)
				end
			end)
		end, debug.traceback)
		io.open = original_open
		os.remove(path)
		os.remove(path .. physical.WRITE_LOCK_SUFFIX)
		if not called then error(detail, 0) end
	end)
end

helpers.describe("wizard genuine canonical admitted native Finish with private physical files", function()
	helpers.it("publishes an actual initialized native candidate before reporting Finish success", function()
		with_canonical_finish(function(f)
			f.state.finish(ANSWERS)
			local content, status = f.files.read_with_status(f.path)
			helpers.assert_eq(status, "ok")
			local decoded = require("toml_codec").decode(content)
			helpers.assert_eq(decoded._meta.schema_version, 12)
			helpers.assert_eq(decoded.llm.enabled, true)
			helpers.assert_eq(decoded.hotstrings.trigger_char, "ù")
			helpers.assert_eq(decoded.future.keep, "owned by another feature")
			helpers.assert_true(f.unlocks > 0, "the actual admitted publisher must reach its physical lock primitive")
			helpers.assert_eq(f.state.notifications, 1)
			helpers.assert_eq(f.state.deferred, 1)
			helpers.assert_eq(#f.state.alerts, 0)
		end)
	end)

	helpers.it("settles the actual publisher continuation and admits its physical exact-source inverse", function()
		with_canonical_finish(function(f)
			f.refuse_unlock = true
			f.state.finish(ANSWERS)
			helpers.assert_true(f.close_refusals > 0, "the genuine retained owner must refuse both unlock and close")
			local candidate, status = f.files.read_with_status(f.path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(require("toml_codec").decode(candidate).llm.enabled, true)
			helpers.assert_eq(f.state.notifications, 0)
			helpers.assert_eq(f.state.deferred, 0)
			helpers.assert_eq(f.onboarding.run(f.path .. ".other"), false,
				"refused actual release must retain native publication through reopen")
			f.refuse_unlock = false
			local previous_unlocks = f.unlocks
			-- An invalid new request performs no forward publication. The receiving
			-- gate first settles the original continuation and actual admitted inverse.
			f.state.finish({ locale = "unavailable-locale", config_dir = "", operations = {} })
			helpers.assert_eq(f.files.read_with_status(f.path), f.before)
			helpers.assert_true(f.unlocks > previous_unlocks, "the genuine inverse must cross the native admitted publisher")
			helpers.assert_eq(f.state.notifications, 0)
			helpers.assert_eq(f.state.deferred, 0)
			local settled_unlocks = f.unlocks
			f.state.finish({ locale = "unavailable-locale", config_dir = "", operations = {} })
			helpers.assert_eq(f.files.read_with_status(f.path), f.before)
			helpers.assert_eq(f.unlocks, settled_unlocks, "accepted cleanup and inverse must not repeat")
		end)
	end)
end)

helpers.describe("wizard canonical successor inverse helper cohort", function()
	helpers.it("settles actual native cleanup and inverse after reloading its registered canonical writer", function()
		with_canonical_finish(function(f)
			helpers.assert_true(not rawequal(f.state.previous_shared_writer, f.state.current_shared_writer))
			helpers.assert_eq(package.loaded["toml_codec.writer"], f.state.current_shared_writer)
			helpers.assert_eq(package.loaded["config_file_inverse"], f.state.retained_inverse_module)
			f.refuse_unlock = true
			f.state.finish(ANSWERS)
			helpers.assert_true(f.close_refusals > 0, "actual retained cleanup refuses both native release primitives")
			local candidate, status = f.files.read_with_status(f.path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(require("toml_codec").decode(candidate).llm.enabled, true)
			helpers.assert_eq(f.state.notifications, 0)
			helpers.assert_eq(f.state.deferred, 0)
			helpers.assert_eq(f.onboarding.run(f.path .. ".other"), false)
			f.refuse_unlock = false
			local previous_unlocks = f.unlocks
			f.state.finish({ locale = "unavailable-locale", config_dir = "", operations = {} })
			helpers.assert_eq(f.files.read_with_status(f.path), f.before,
				"the registered destination admits its genuine new-cohort inverse after exact cleanup")
			helpers.assert_true(f.unlocks > previous_unlocks,
				"the actual inverse must reach the canonical admitted native publisher")
			local settled_unlocks = f.unlocks
			f.state.finish({ locale = "unavailable-locale", config_dir = "", operations = {} })
			helpers.assert_eq(f.files.read_with_status(f.path), f.before)
			helpers.assert_eq(f.unlocks, settled_unlocks, "accepted physical cleanup and inverse cannot replay")
			helpers.assert_eq(f.state.notifications, 0)
			helpers.assert_eq(f.state.deferred, 0)
		end, true)
	end)
end)
