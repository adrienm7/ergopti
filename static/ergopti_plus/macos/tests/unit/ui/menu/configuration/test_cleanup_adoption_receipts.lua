--- tests/unit/ui/menu/configuration/test_cleanup_adoption_receipts.lua

--- ==============================================================================
--- MODULE: Configuration Cleanup Adoption Receipts
--- DESCRIPTION:
--- Runs the macOS menu action with the real cleanup session, readers, engine
--- and preferences owner. A committed removal must retain its truthful result
--- while a refused save-baseline adoption reaches the existing error observer.
--- ==============================================================================

local helpers = require("tests.helpers")

local INITIAL = "[script]\nlog_level = \"debug\"\n[stale]\nkey = 1\n"
local EDITED = INITIAL:gsub("key = 1", "key = 2")
local CLEANED = "[script]\nlog_level = \"debug\"\n"
local PATH = "/synthetic/cleanup-adoption/config.toml"


--- Gives each case explicit configuration bytes and real shipped reader assets.
--- @param callback function Public menu/session exercise.
local function with_cleanup(callback)
	helpers.with_stub_scope({
		"adapters.file_system", "infra.preferences", "config_cleanup_session",
		"config_unused_keys", "infra.logger", "ui.menu.unused_keys_cleanup",
		"infra.config_overrides", "ui.onboarding", "modules.shortcuts.tap_keys",
		"modules.shortcuts.keyboard_shortcuts",
		"adapters.hotkey_registrar", "adapters.json_codec", "adapters.keyboard_geometry",
		"adapters.storage", "adapters.timer_scheduler", "config_migrate", "infra.config_paths",
		"infra.deferred_work", "infra.hotstring_choice_catalogue", "infra.manifest_reader",
		"infra.notifications", "infra.personal_file_adoption", "infra.toml.writer",
		"modules.shortcuts.ai_actions", "toml_codec.reader",
		"toml_codec.writer", "hotstrings.personal_adoption",
	}, function()
		local files, errors, writes = { [PATH] = INITIAL }, {}, {}
		local adapter = {}
		function adapter.read_with_status(path)
			if files[path] == nil then return nil, "absent" end
			return files[path], "ok"
		end
		function adapter.read(path)
			if files[path] ~= nil then return files[path] end
			if not path:find("/_shared/", 1, true) then return nil end
			local file = assert(io.open(path, "rb"), "a canonical reader asset must exist")
			local content = assert(file:read("a"))
			assert(file:close())
			return content
		end
		function adapter.write_if_unchanged(path, content, expected)
			local current = files[path]
			if expected.status == "absent" and current ~= nil then return false end
			if expected.status == "ok" and current ~= expected.content then return false end
			files[path] = content
			writes[#writes + 1] = path
			return true
		end
		local logger = helpers.make_logger_stub()
		logger.error = function(_, template, ...)
			errors[#errors + 1] = string.format(template, ...)
		end
		package.loaded["adapters.file_system"] = adapter
		package.loaded["infra.logger"] = logger
		local preferences = helpers.load_with_stubs("infra.preferences")
		helpers.assert_eq(select(2, preferences.load(PATH)), "ok")
		callback({ files = files, errors = errors, writes = writes, adapter = adapter,
			preferences = preferences, cleanup = require("ui.menu.unused_keys_cleanup") })
	end)
end


--- Opens the actual menu entry and creates its real shared page session.
--- @param fixture table Owned file and preference ports.
--- @param owner table|nil Optional strict adoption owner.
--- @return table session Shared cleanup session.
local function open_session(fixture, owner)
	local session
	local opened = fixture.cleanup.run_from_menu({
		path = PATH, file_adapter = fixture.adapter,
		preferences = owner or fixture.preferences,
		host = { open = function(options)
			session = require("config_cleanup_session").new(options)
			return true
		end },
	})
	helpers.assert_eq(opened, true)
	return assert(session)
end


--- Commits the exact public preview and proves publication before adoption.
--- @param fixture table Owned file ports.
--- @param session table Shared cleanup session.
--- @param previous string Exact bytes the preview owns.
local function remove_unused(fixture, session, previous)
	local ready = session:handle("ready")
	helpers.assert_eq(ready.status, "ready")
	helpers.assert_eq(#ready.keys, 1)
	helpers.assert_eq(#fixture.writes, 0, "opening and previewing must never publish")
	local result = session:handle({ action = "clean", session = ready.session })
	helpers.assert_eq(result.status, "removed", "the file was published even if adoption refused")
	helpers.assert_eq(fixture.files[PATH], CLEANED)
	helpers.assert_eq(fixture.files[result.backup], previous, "the exact preview bytes must remain backed up")
	helpers.assert_eq(#fixture.writes, 2, "backup and cleaned file must publish exactly once")
end


helpers.describe("macOS cleanup observes preference adoption receipts", function()
	helpers.it("reports a real stale-baseline refusal after an external unused-key edit (cleanup-adoption-receipt)", function()
		with_cleanup(function(f)
			f.files[PATH] = EDITED
			remove_unused(f, open_session(f), EDITED)
			helpers.assert_eq(f.preferences.source_snapshot(PATH), { status = "ok", content = INITIAL },
				"a refused adoption must preserve the original save baseline")
			helpers.assert_eq(#f.errors, 1, "the committed cleanup must expose its refused adoption")
			helpers.assert_true(f.errors[1]:find("Configuration was cleaned but adoption failed", 1, true) ~= nil)
		end)
	end)

	helpers.it("adopts a matching real preference baseline without an error (cleanup-adoption-receipt)", function()
		with_cleanup(function(f)
			remove_unused(f, open_session(f), INITIAL)
			helpers.assert_eq(f.preferences.source_snapshot(PATH), { status = "ok", content = CLEANED })
			helpers.assert_eq(f.errors, {})
		end)
	end)

	for _, receipt in ipairs({ { name = "nil" }, { name = "false", value = false },
		{ name = "truthy non-boolean", value = "accepted" } }) do
		helpers.it("reports a " .. receipt.name .. " adoption receipt without undoing publication (cleanup-adoption-receipt)", function()
			with_cleanup(function(f)
				local attempts = 0
				local received
				local session = open_session(f, { adopt_cleanup = function(...)
					attempts = attempts + 1
					received = table.pack(...)
					return receipt.value
				end })
				remove_unused(f, session, INITIAL)
				helpers.assert_eq(attempts, 1)
				helpers.assert_eq(received, { n = 3, PATH, INITIAL, CLEANED },
					"the adoption observer must receive the exact native argument tuple")
				helpers.assert_eq(#f.errors, 1)
				helpers.assert_eq(f.preferences.source_snapshot(PATH).content, INITIAL)
			end)
		end)
	end

	helpers.it("keeps the existing thrown-adoption observer and committed result (cleanup-adoption-receipt)", function()
		with_cleanup(function(f)
			remove_unused(f, open_session(f, { adopt_cleanup = function()
				error("synthetic adoption exception", 0)
			end }), INITIAL)
			helpers.assert_eq(#f.errors, 1)
			helpers.assert_true(f.errors[1]:find("synthetic adoption exception", 1, true) ~= nil)
		end)
	end)
end)
