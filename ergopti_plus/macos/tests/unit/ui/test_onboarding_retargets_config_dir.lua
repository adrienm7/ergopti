--- tests/unit/ui/test_onboarding_retargets_config_dir.lua

--- ==============================================================================
--- MODULE: Onboarding Wizard — Config-Dir Retarget (regression)
--- DESCRIPTION:
--- Locks down that the first-run wizard re-resolves its config.toml write target
--- through MenuPaths after persisting a user-chosen config directory.
---
--- ROOT CAUSE ENCODED — A STALE CAPTURED PATH, not "the wizard shows twice":
--- _config_path was captured once in M.run() from the config dir as it stood
--- BEFORE the wizard opened. commit() then persisted the user's chosen directory
--- (rewriting paths.toml and MOVING the resolver) yet still wrote through that
--- stale capture. The NEW directory therefore never received a config.toml, so
--- should_run() was true again after the post-wizard reload and the wizard
--- re-opened BLANK — every answer lost, the orphaned file left behind in the old
--- directory where nothing reads it. Only the locale survived, because it
--- persists via hs.settings rather than config.toml, which made the failure read
--- as "the wizard forgot some things" instead of "it wrote to the wrong place".
---
--- The retarget lives in the pure M._resolve_commit_path so the decision is
--- testable without standing up a webview.
--- ==============================================================================

local helpers = require("tests.helpers")

local Onboarding = helpers.load_with_stubs("ui.onboarding")

-- The directory the wizard was launched from (the stale capture) and the one the
-- user picked mid-wizard. The retarget must land on the latter.
local OLD_CONFIG_PATH = "/old/hammerspoon/config.toml"
local NEW_CONFIG_PATH = "/new/hammerspoon/config.toml"

-- The same two locations as directories, for the block that drives the real
-- menu_paths module rather than a double.
local OLD_DIR = "/old/"
local NEW_DIR = "/new/"

--- Builds a menu_paths double whose get() returns whatever the resolver yields.
--- @param resolver function Called with the requested path key.
--- @return table The menu_paths double.
local function menu_paths_double(resolver)
	return { get = resolver }
end





-- ============================================
-- ============================================
-- ======= 1/ Happy Path — The Retarget =======
-- ============================================
-- ============================================

helpers.describe("onboarding retargets config.toml after a config-dir change", function()
	helpers.it("writes to the NEWLY resolved directory, not the stale capture", function()
		local seen_key
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function(key)
				seen_key = key
				return NEW_CONFIG_PATH
			end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, NEW_CONFIG_PATH,
			"the wizard must write into the directory the user just chose — writing "
			.. "through the pre-wizard capture leaves the new dir with no config.toml")
		helpers.assert_eq(seen_key, "ConfigTomlPath",
			"the retarget must go through the canonical MenuPaths key")
	end)

	helpers.it("keeps the fallback when the resolver yields the same path", function()
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function() return OLD_CONFIG_PATH end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, OLD_CONFIG_PATH)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Degraded Resolver Fallbacks =======
-- ==============================================
-- ==============================================

helpers.describe("onboarding retarget falls back rather than losing the answers", function()
	helpers.it("returns the fallback verbatim when the resolver raises", function()
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function() error("resolver exploded") end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, OLD_CONFIG_PATH,
			"a throwing resolver must not redirect the write — the answers still "
			.. "need a readable destination")
	end)

	helpers.it("returns the fallback verbatim when the resolver yields an empty string", function()
		local resolved = Onboarding._resolve_commit_path(
			menu_paths_double(function() return "" end),
			OLD_CONFIG_PATH
		)
		helpers.assert_eq(resolved, OLD_CONFIG_PATH,
			"an empty target would drop the answers on the floor")
	end)

	helpers.it("returns the fallback verbatim when the resolver yields a non-string", function()
		for _, bad in ipairs({ 42, true, {} }) do
			local resolved = Onboarding._resolve_commit_path(
				menu_paths_double(function() return bad end),
				OLD_CONFIG_PATH
			)
			helpers.assert_eq(resolved, OLD_CONFIG_PATH,
				"a non-string resolution is not a path — keep the fallback")
		end
		-- nil is the same class of failure and must behave identically.
		helpers.assert_eq(
			Onboarding._resolve_commit_path(menu_paths_double(function() return nil end), OLD_CONFIG_PATH),
			OLD_CONFIG_PATH)
	end)

	helpers.it("returns the fallback when menu_paths itself is unusable", function()
		helpers.assert_eq(Onboarding._resolve_commit_path(nil, OLD_CONFIG_PATH), OLD_CONFIG_PATH)
		helpers.assert_eq(Onboarding._resolve_commit_path({}, OLD_CONFIG_PATH), OLD_CONFIG_PATH)
		helpers.assert_eq(Onboarding._resolve_commit_path({ get = "not callable" }, OLD_CONFIG_PATH),
			OLD_CONFIG_PATH)
	end)
end)





-- =================================================
-- =================================================
-- ======= 3/ The Retarget Is Actually Wired =======
-- =================================================
-- =================================================

helpers.describe("onboarding commit() honours the retarget", function()
	helpers.it("(onboarding-retarget-behavior) finish writes to the newly persisted resolver destination", function()
		helpers.with_fresh_modules({ "infra.toml.writer", "adapters.file_system", "ui.menu.menu_paths",
			"infra.notifications" }, function()
			return require("tests.support.onboarding_finish_fixture").with_migration_reader(function()
			local destination, persisted, writes, notified = OLD_CONFIG_PATH, 0, {}, 0
			package.loaded["ui.menu.menu_paths"] = {
				persist_config_dir_for_wizard = function(directory)
					helpers.assert_eq(directory, NEW_DIR)
					persisted = persisted + 1
					destination = NEW_CONFIG_PATH
					return true
				end,
				get = function(key)
					helpers.assert_eq(key, "ConfigTomlPath")
					return destination
				end,
			}
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return nil, "absent" end,
			}
			package.loaded["infra.toml.writer"] = {
				batch_write = function(path, updates)
					helpers.assert_eq(persisted, 1, "the destination must be persisted before writing answers")
					writes[#writes + 1] = { path = path, updates = updates }
					return true
				end,
			}
			package.loaded["infra.notifications"] = { notify = function() notified = notified + 1; return true end }
			require("tests.support.dashboard_window_fixture")("ui.onboarding", function(onboarding, state)
				require("tests.support.onboarding_shared_data").install()
				package.loaded["infra.i18n"].persist_locale = function() return true end
				helpers.assert_true(onboarding.run(OLD_CONFIG_PATH))
				state.receiver({ body = { action = "finish", answers = {
					locale = "en", config_dir = NEW_DIR,
					operations = { { path = "hotstrings.trigger_char", value = "X" } },
				} } })
				helpers.assert_eq(#writes, 1)
				helpers.assert_eq(writes[1].path, NEW_CONFIG_PATH,
					"the real finish handler must not write through its pre-wizard capture")
				helpers.assert_eq(writes[1].updates, { { section = "hotstrings", key = "trigger_char", value = "X" } },
					"the selected answers must reach the writer as manifest rows")
				helpers.assert_eq(notified, 1)
				helpers.assert_eq(state.deleted, 1)
			end)
			end)
		end)
	end)
end)





-- ===========================================================
-- ===========================================================
-- ======= 4/ The Real menu_paths Honours The Retarget =======
-- ===========================================================
-- ===========================================================

--- Every block above drives a menu_paths DOUBLE whose get() returns whatever the
--- test supplies. That proves the onboarding calls the retarget in the right
--- order, but it assumes the real module actually honours it — and a double is
--- free to agree with a resolver that reality would contradict. This block drops
--- the double and drives the module itself, so the assumption is checked rather
--- than asserted.
helpers.describe("menu_paths really retargets after persist_config_dir_for_wizard", function()
	local function make_real_base_dir()
		local path = os.tmpname()
		os.remove(path)
		os.execute('mkdir "' .. path .. '"')
		return path .. "/"
	end

	--- Loads the real menu_paths with the filesystem side effects neutralised.
	--- @return table
	local function fresh_menu_paths()
		package.loaded["ui.menu.menu_paths"] = nil
		package.loaded["infra.config_paths"] = nil
		local saved_file_system = package.loaded["adapters.file_system"]
		local bootstrap_content = nil
		package.loaded["adapters.file_system"] = {
			read_with_status = function()
				if bootstrap_content == nil then return nil, "absent" end
				return bootstrap_content, "ok"
			end,
			create_if_absent = function(_, content)
				if bootstrap_content ~= nil then return false, "exists" end
				bootstrap_content = content
				return true, "created"
			end,
			write_if_unchanged = function(_, content)
				bootstrap_content = content
				return true
			end,
		}
		local MP = helpers.load_with_stubs("ui.menu.menu_paths", {
			fs = {
				-- Report every directory as already present so ensure_dir does no
				-- work; the assertion is about the resolved path, not about mkdir.
				attributes = function() return { mode = "directory" } end,
				mkdir      = function() return true end,
				currentDir = function() return "/" end,
			},
		})
		local initialized = MP.init(make_real_base_dir(), function() end)
		package.loaded["adapters.file_system"] = saved_file_system
		helpers.assert_eq(initialized, true,
			"the real menu_paths fixture must commit its bootstrap before retargeting")
		return MP
	end

	helpers.it("resolves the new directory after the wizard persists it", function()
		local MP = fresh_menu_paths()
		-- Captured rather than asserted: what init() resolves to depends on the
		-- host's paths.toml and default location, neither of which this case is
		-- about. What matters is that the retarget MOVES it, so compare before
		-- against after and require the move to have happened.
		local before = MP.get_config_dir()
		helpers.assert_true(before:find(NEW_DIR, 1, true) == nil,
			"the module must not already resolve the target directory, or the assertion "
			.. "below would hold without the retarget doing anything. Got: " .. before)

		MP.persist_config_dir_for_wizard(NEW_DIR)

		helpers.assert_true(MP.get_config_dir():find(NEW_DIR, 1, true) ~= nil, string.format(
			"after persist_config_dir_for_wizard the module must resolve the directory the "
			.. "user picked. The blocks above only prove onboarding CALLS this in the right "
			.. "order; if the call did not actually move the resolver, the wizard would still "
			.. "write config.toml into the pre-wizard directory and every one of those tests "
			.. "would keep passing. Got: %s", MP.get_config_dir()))
	end)

	helpers.it("appends a trailing separator so path joins stay well-formed", function()
		local MP = fresh_menu_paths()
		MP.persist_config_dir_for_wizard((NEW_DIR:gsub("[/\\]$", "")))

		helpers.assert_true(MP.get_config_dir():match("[/\\]$") ~= nil,
			"a directory persisted without a trailing separator must gain one, or every "
			.. "path built by concatenation silently becomes a sibling FILE name rather than "
			.. "a child of the directory")
	end)
end)


helpers.describe("the controlled onboarding migration context retains no native grant", function()
	local Context = require("tests.support.onboarding_finish_fixture")

	helpers.it("uses the real registry and custom reader without admitting the virtual destination", function()
		helpers.with_fresh_modules({ "adapters.file_system" }, function()
			local reads, writes = 0, 0
			local adapter = {
				read_with_status = function() reads = reads + 1; return nil, "absent" end,
				write_if_unchanged = function() writes = writes + 1; return true end,
			}
			package.loaded["adapters.file_system"] = adapter
			Context.with_migration_reader(function()
				local migration = require("config_migrate")
				local registry = assert(migration.load_registry(helpers.shared(migration.REGISTRY_PATH)))
				local options = { path = "/virtual/onboarding-context-absent.toml", driver = "hs",
					file_adapter = adapter, registry = registry }
				local result = migration.boot(options)
				helpers.assert_eq(result.status, "absent")
				helpers.assert_eq(result.read_only, false)
				helpers.assert_eq(reads, 1, "the captured explicit reader is invoked exactly once")
				helpers.assert_nil(options.read, "the original caller options are unchanged")
				local origin, capture, read_check = migration.writer_admission_factory()
				helpers.assert_true(rawequal(origin, migration), "the genuine constructor owns this classification")
				helpers.assert_eq(read_check(options.path, adapter), false, "no native read grant")
				helpers.assert_eq(capture(options.path, { status = "absent" }, "x = true\n", "publish", adapter),
					false, "no native write grant")
				helpers.assert_eq(require("toml_codec.writer").batch_write(options.path,
					{ { section = "metrics", key = "enabled", value = true } }, adapter), false)
				helpers.assert_eq(writes, 0, "classification cannot reach a virtual publisher")
			end)
		end)
	end)

	helpers.it("restores exact module entries and the real boot callback after success and throw", function()
		helpers.with_fresh_modules({ "config_migrate", "toml_codec.writer" }, function()
			for _, mode in ipairs({ "nil", "false", "existing" }) do
				local saved_migration, saved_writer
				if mode == "false" then saved_migration, saved_writer = false, false end
				if mode == "existing" then saved_migration, saved_writer = {}, {} end
				for _, throws in ipairs({ false, true }) do
					package.loaded["config_migrate"], package.loaded["toml_codec.writer"] = saved_migration, saved_writer
					local actual, overridden
					local ok, result = pcall(Context.with_migration_reader, function()
						actual = require("config_migrate")
						overridden = actual.boot
						if throws then error("owned migration callback failed") end
						return "accepted"
					end)
					helpers.assert_eq(ok, not throws)
					if throws then helpers.assert_true(result:find("owned migration callback failed", 1, true) ~= nil)
					else helpers.assert_eq(result, "accepted") end
					helpers.assert_true(rawequal(package.loaded["config_migrate"], saved_migration))
					helpers.assert_true(rawequal(package.loaded["toml_codec.writer"], saved_writer))
					helpers.assert_true(actual.boot ~= overridden, "the retained genuine owner has its original boot callback")
					helpers.assert_true(debug.getinfo(actual.boot, "S").source:find("/config_migrate.lua", 1, true) ~= nil)
				end
			end
		end)
	end)

	helpers.it("refuses a missing explicit reader and restores both prior constructors", function()
		local prior_migration, prior_writer = package.loaded["config_migrate"], package.loaded["toml_codec.writer"]
		local ok, detail = pcall(Context.with_migration_reader, function()
			return require("config_migrate").boot({ path = "/virtual/no-reader.toml", driver = "hs", file_adapter = {} })
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(detail:find("the migration fixture needs its explicit reader", 1, true) ~= nil)
		helpers.assert_true(rawequal(package.loaded["config_migrate"], prior_migration))
		helpers.assert_true(rawequal(package.loaded["toml_codec.writer"], prior_writer))
	end)
end)
