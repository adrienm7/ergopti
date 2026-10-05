--- tests/unit/modules/test_common_autocorrection_publication_recovery.lua
--- Actual controller with an independent capability/transport double. These
--- cases do not qualify physical locks or the native adapter/Writer producer.
local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local function fixture(body)
	helpers.with_fresh_modules({ "adapters.file_system", "modules.hotstrings.hotstrings_config",
		"hotstrings.common_autocorrection_migration", "hotstrings.publication_recovery" }, function()
		local f = { path = "overrides", configured_path = "overrides", route = "owned", writes = 0,
			retries = 0, release = false, acknowledge = false, records = {} }
		f.original = '# independently authored legacy source\n[autocorrection.caps]\ndelay = 0.3\n'
		f.source = f.original
		local files = { read_with_status = function(path)
			if path == f.path then return f.source, f.source and "ok" or "absent" end
			local handle = io.open(path, "rb")
			if not handle then return nil, "absent" end
			local source = handle:read("*a"); assert(handle:close()); return source, "ok"
		end, write = function() error("an unconditional consumer publication") end }
		files.publication_receipt_view = function(native, path, expected, candidate, on_error)
			local r = f.records[native]
			if f.reject_view or not r or path ~= r.path or expected.status ~= r.expected.status
				or expected.content ~= r.expected.content or candidate ~= r.candidate or on_error ~= r.on_error then return nil end
			return { published = r.published, source = { status = r.published and "ok" or r.expected.status,
				content = r.published and r.candidate or r.expected.content } }
		end
		files.write_if_unchanged = function(path, candidate, expected, on_error)
			helpers.assert_eq(path, f.path); f.writes = f.writes + 1
			if expected.status ~= (f.source and "ok" or "absent") or expected.content ~= f.source then return false end
			local r = { path = path, expected = { status = expected.status, content = expected.content },
				candidate = candidate, on_error = on_error, published = not f.release_only, route = f.route, settled = false }
			if r.published then f.source = candidate end
			local native = { matches_source = function()
				return f.route == r.route and f.source == (r.published and candidate or expected.content)
			end, retry = function()
				f.retries = f.retries + 1
				if f.release then r.settled = true; return true end
				return false
			end, is_settled = function() return r.settled end }
			f.records[native] = r
			if f.on_publish then f.on_publish() end
			if f.acknowledge then r.settled = true; return true, nil, native end
			return false, "independent native release refusal", native
		end
		package.loaded["adapters.file_system"] = files
		local Writer = require("toml_codec.writer")
		local original_publish = Writer.publish_if_unchanged
		Writer.publish_if_unchanged = function(path, candidate, adapter, expected, on_error)
			return adapter.write_if_unchanged(path, candidate, expected, on_error)
		end
		f.Config = require("modules.hotstrings.hotstrings_config")
		f.options = { override_path = f.path, toml_resolver = function() return nil end,
			current_override_path = function()
				if f.on_current_path then f.on_current_path() end
				return f.configured_path
			end }
		local ok, detail = xpcall(function() body(f) end, debug.traceback)
		Writer.publish_if_unchanged = original_publish
		if not ok then error(detail) end
	end)
end

local function terminal_fixture(config, body)
	helpers.with_fresh_modules({ "infra.termination_coordinator", "infra.emergency_exit" }, function()
		local f = { leases = 0, watchdogs = 0, teardowns = 0, reloads = 0, exits = 0 }
		local coordinator = require("infra.termination_coordinator")
		helpers.assert_true(coordinator.init({
			capture_publication_admission = config.capture_terminal_admission,
			request_lease = function(_, callback) f.leases = f.leases + 1; f.lease = callback; return true end,
			drain_input = function(callback) callback(); return true end,
			teardown = function() f.teardowns = f.teardowns + 1; return true end,
			begin_drain = function(callback) callback(true); return true end,
			finalize_teardown = function() return true end,
			reload = function() f.reloads = f.reloads + 1; return true end,
			exit = function() f.exits = f.exits + 1 end,
			fatal_exit = function() f.exits = f.exits + 1 end,
			fatal_exit_code = 70,
			schedule = function() f.watchdogs = f.watchdogs + 1; return { stop = function() return true end } end,
			user_exit_deadline_seconds = 12,
			mark_reload = function() return true end, clear_reload = function() return true end,
		}))
		f.coordinator = coordinator
		body(f)
	end)
end

helpers.describe("common autocorrection native consumer recovery", function()
	helpers.it("(common-autocorrection-recovery) an unowned scope cannot publish through terminal admission", function()
		fixture(function(f)
			f.acknowledge = true
			helpers.assert_true(f.Config.init(f.options))
			local original, calls = f.source, 0
			local source = { status = "ok", content = '[autocorrection.names]\ndelay = 0.9\n' }
			local function publish() calls = calls + 1; return true end
			helpers.assert_eq(f.Config.adopt_scope_source(nil, source, publish), false)
			helpers.assert_eq(calls, 0, "nil never identifies an acquired configuration owner")
			local token = assert(f.Config.capture_terminal_admission())
			helpers.assert_eq(f.Config.adopt_scope_source(nil, source, publish), false)
			helpers.assert_eq(f.Config.adopt_scope_source({}, source, publish), false)
			helpers.assert_eq(calls, 0, "a held terminal cannot enter physical publication")
			helpers.assert_true(token.current())
			helpers.assert_eq(f.Config.get_user_override("autocorrection", "names").delay, 0.3)
			helpers.assert_eq(f.source, original)
			helpers.assert_eq(f.writes, 1)
			helpers.assert_true(token.abort())
		end)
	end)

	helpers.it("(common-autocorrection-recovery) normal reload and quit cannot discard the actual failed source receipt", function()
		fixture(function(f)
			helpers.assert_eq(f.Config.init(f.options), false)
			local candidate = f.source
			terminal_fixture(f.Config, function(terminal)
				helpers.assert_eq(terminal.coordinator.request_reload("native-debt"), false)
				helpers.assert_eq(terminal.coordinator.request_user_exit("native-debt"), false)
				helpers.assert_eq(terminal.leases, 0)
				helpers.assert_eq(terminal.watchdogs, 0)
				helpers.assert_eq(terminal.exits, 0)
				helpers.assert_eq(terminal.teardowns, 0)
				helpers.assert_true(f.Config.has_pending_publication())
				helpers.assert_eq(f.source, candidate)
				helpers.assert_eq(f.writes, 1)
				f.release, f.acknowledge = true, true
				helpers.assert_true(f.Config.reload())
				helpers.assert_true(terminal.coordinator.request_reload("settled"))
				helpers.assert_eq(terminal.leases, 1)
			end)
		end)
	end)

	helpers.it("(common-autocorrection-recovery) a held personal scope refuses normal user quit before its watchdog", function()
		fixture(function(f)
			f.acknowledge = true
			helpers.assert_true(f.Config.init(f.options))
			local owner = {}
			helpers.assert_true(f.Config.acquire(owner))
			terminal_fixture(f.Config, function(terminal)
				helpers.assert_eq(terminal.coordinator.request_user_exit("held-personal-inverse"), false)
				helpers.assert_eq(terminal.leases, 0)
				helpers.assert_eq(terminal.watchdogs, 0)
				helpers.assert_eq(terminal.exits, 0)
				helpers.assert_true(f.Config.capture_scope_owner(owner)())
				helpers.assert_true(f.Config.release(owner))
				helpers.assert_true(terminal.coordinator.request_user_exit("released-personal-inverse"))
				helpers.assert_eq(terminal.watchdogs, 1)
			end)
		end)
	end)

	helpers.it("(common-autocorrection-recovery) actual terminal admission blocks new publication until the delayed fence aborts", function()
		fixture(function(f)
			f.acknowledge = true
			helpers.assert_true(f.Config.init(f.options))
			local original = f.source
			terminal_fixture(f.Config, function(terminal)
				helpers.assert_true(terminal.coordinator.request_reload("delayed"))
				helpers.assert_nil(f.Config.capture_terminal_admission())
				helpers.assert_eq(f.Config.reload(), false)
				helpers.assert_eq(f.Config.acquire({}), false)
				helpers.assert_eq(f.Config.set_override("autocorrection", "names", "delay", 0.8), false)
				helpers.assert_eq(f.Config.init(f.options), false)
				helpers.assert_eq(f.source, original)
				helpers.assert_eq(f.writes, 1)
				terminal.lease(false, "refused")
				helpers.assert_eq(terminal.teardowns, 0)
				helpers.assert_true(f.Config.set_override("autocorrection", "names", "delay", 0.8))
				helpers.assert_eq(f.Config.resolve("autocorrection", "names").delay, 0.8)
			end)
		end)
	end)

	helpers.it("(common-autocorrection-recovery) early-boot admission cannot authorize initialization before its exact abort", function()
		fixture(function(f)
			local token = assert(f.Config.capture_terminal_admission())
			helpers.assert_true(token.current())
			helpers.assert_eq(f.Config.init(f.options), false)
			helpers.assert_eq(f.writes, 0)
			helpers.assert_true(token.abort())
			helpers.assert_eq(token.current(), false)
			helpers.assert_eq(token.abort(), false)
			f.acknowledge = true
			helpers.assert_true(f.Config.init(f.options))
		end)
	end)

	helpers.it("(common-autocorrection-recovery) active native publication cannot admit reentrant termination", function()
		fixture(function(f)
			f.acknowledge = true
			f.on_publish = function() helpers.assert_nil(f.Config.capture_terminal_admission()) end
			helpers.assert_true(f.Config.init(f.options))
			local token = assert(f.Config.capture_terminal_admission())
			helpers.assert_true(token.current())
			helpers.assert_true(token.abort())
		end)
	end)

	helpers.it("(common-autocorrection-recovery) no-caps bytes cannot acknowledge a failed native publication", function()
		fixture(function(f)
			helpers.assert_eq(f.Config.init(f.options), false)
			helpers.assert_nil(Codec.decode(f.source).autocorrection.caps)
			helpers.assert_true(f.Config.has_pending_publication())
			helpers.assert_eq(f.Config.common_autocorrection_admitted(), false)
			helpers.assert_eq(f.Config.reload(), false)
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.Config.set_override("autocorrection", "names", "delay", 0.7), false)
			helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_nil(f.Config.get_user_override("autocorrection", "names"))
			f.release = true; f.acknowledge = true
			helpers.assert_true(f.Config.reload())
			helpers.assert_eq(f.writes, 3, "owned inverse precedes a new acknowledged migration")
			helpers.assert_eq(f.Config.has_pending_publication(), false)
			for _, family in ipairs({ "names", "abbreviations", "technical_terms" }) do
				helpers.assert_eq(f.Config.get_user_override("autocorrection", family).delay, 0.3)
			end
		end)
	end)
	helpers.it("(common-autocorrection-recovery) reinitialization cannot replace the retained owner", function()
		fixture(function(f)
			helpers.assert_eq(f.Config.init(f.options), false)
			helpers.assert_eq(f.Config.init({ override_path = "foreign", toml_resolver = function() return nil end }), false)
			helpers.assert_eq(f.Config.get_override_path(), f.path)
			helpers.assert_true(f.Config.has_pending_publication()); helpers.assert_eq(f.writes, 1)
		end)
	end)
	for _, foreign in ipairs({ "configured-path", "equal-byte-route", "unverified-receipt" }) do
		helpers.it("(common-autocorrection-recovery) retains debt after " .. foreign, function()
			fixture(function(f)
				helpers.assert_eq(f.Config.init(f.options), false)
				local published = f.source; f.release = true
				if foreign == "configured-path" then f.configured_path = "foreign" end
				if foreign == "equal-byte-route" then f.route = "foreign" end
				if foreign == "unverified-receipt" then f.reject_view = true end
				helpers.assert_eq(f.Config.reload(), false); helpers.assert_eq(f.source, published)
				helpers.assert_eq(f.retries, 0); helpers.assert_true(f.Config.has_pending_publication())
			end)
		end)
	end
	helpers.it("(common-autocorrection-recovery) callback reentry cannot borrow the in-flight owner", function()
		fixture(function(f)
			f.on_publish = function()
				helpers.assert_eq(f.Config.reload(), false); helpers.assert_eq(f.Config.init(f.options), false)
				helpers.assert_eq(f.Config.acquire({}), false)
			end
			helpers.assert_eq(f.Config.init(f.options), false)
			helpers.assert_eq(f.writes, 1); helpers.assert_true(f.Config.has_pending_publication())
		end)
	end)
	helpers.it("(common-autocorrection-recovery) retains inverse debt until its physical release settles", function()
		fixture(function(f)
			helpers.assert_eq(f.Config.init(f.options), false)
			f.release = true; f.on_publish = function() if f.writes == 2 then f.release = false end end
			helpers.assert_eq(f.Config.reload(), false)
			helpers.assert_eq(f.source, f.original, "the inverse restores the original complete byte image")
			helpers.assert_true(f.Config.has_pending_publication()); helpers.assert_eq(f.Config.reload(), false)
			helpers.assert_eq(f.writes, 2)
			f.release = true; f.acknowledge = true; f.on_publish = nil
			helpers.assert_true(f.Config.reload()); helpers.assert_eq(f.writes, 3)
		end)
	end)
	helpers.it("(common-autocorrection-recovery) release-only debt does not authorize an inverse", function()
		fixture(function(f)
			f.release_only = true
			helpers.assert_eq(f.Config.init(f.options), false); helpers.assert_eq(f.source, f.original)
			f.release = true; f.release_only = false; f.acknowledge = true
			helpers.assert_true(f.Config.reload()); helpers.assert_eq(f.writes, 2)
		end)
	end)
	helpers.it("(common-autocorrection-recovery) path callback reentry cannot recapture a released scope", function()
		fixture(function(f)
			f.acknowledge = true
			helpers.assert_true(f.Config.init(f.options))
			local owner = {}
			helpers.assert_true(f.Config.acquire(owner))
			f.on_current_path = function()
				helpers.assert_true(f.Config.release(owner))
				helpers.assert_true(f.Config.acquire(owner))
			end
			helpers.assert_nil(f.Config.capture_scope_owner(owner),
				"same owner identity cannot hide release and reacquisition during capture")
			f.on_current_path = nil
			local current = assert(f.Config.capture_scope_owner(owner))
			helpers.assert_true(current())
			f.on_current_path = function() helpers.assert_true(f.Config.release(owner)) end
			helpers.assert_eq(current(), false, "all held owner fields are checked after the path callback")
			f.on_current_path = nil
			helpers.assert_nil(f.Config.capture_scope_owner(owner))
			helpers.assert_eq(f.writes, 1, "held guard capture never publishes an override")
		end)
	end)

end)
