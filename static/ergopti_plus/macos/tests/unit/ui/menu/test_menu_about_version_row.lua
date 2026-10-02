--- tests/unit/ui/menu/test_menu_about_version_row.lua

--- ==============================================================================
--- MODULE: The About Version Row Names The Build And Its Commit (macOS)
--- DESCRIPTION:
--- The first row of the Version / Updates submenu read « ErgoptiPlus local »
--- for every source run and « ErgoptiPlus 0.0.0-dev.144 » for a release: no
--- commit, so nobody could tell which checkout or build a demo was running.
--- It now names the build kind and the commit through the shared formatter:
--- « Version 0.0.0-dev.144 (c3005e0b9) » for a stamped release, « Version
--- locale (c3005e0b9) » for a run from a source checkout, and « commit
--- inconnu » with a logged WARNING when neither the build stamp nor .git says.
---
--- The identity goes through the real resolver on in-memory fixtures of each
--- .git shape (loose ref, packed ref, detached HEAD, linked worktree) and the
--- row through the real builder and renderer with the shipped French wording.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Snapshot = require("diagnostics.snapshot")

local SHA = "c3005e0b9aaaabbbbccccddddeeeeffff0000111"
local SHORT = "c3005e0b9"
local REPO = "/Users/dev/ergopti"
local SOURCE_DIR = REPO .. "/static/ergopti_plus/macos/infra"
local SHARED = REPO .. "/static/ergopti_plus/_shared"
local APP_SHARED = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/_shared"
local APP_SOURCE = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos/infra"

-- The modules a case replaces or reloads; restored after each case.
local FIXTURE_MODULES = {
	"infra.logger",
	"infra.diagnostic_snapshot",
	"modules.updater",
	"ui.menu.menu_about",
}




-- ================================
-- ================================
-- ======= 1/ Fixtures ============
-- ================================
-- ================================

--- Collapses "dir/.." segments, as the filesystem does for a relative
--- `commondir` pointer.
--- @param path string
--- @return string
local function normalise(path)
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == ".." then parts[#parts] = nil elseif part ~= "." then parts[#parts + 1] = part end
	end
	return "/" .. table.concat(parts, "/")
end

--- Builds an in-memory filesystem from a path → content table.
--- @param files table
--- @return table
local function fixture_fs(files)
	return {
		read = function(path) return files[normalise(path)] end,
		exists = function(path) return files[normalise(path)] ~= nil end,
	}
end

-- One checkout per .git shape, each resolving to SHA.
local CHECKOUTS = {
	loose_ref = {
		[REPO .. "/.git/HEAD"] = "ref: refs/heads/dev\n",
		[REPO .. "/.git/refs/heads/dev"] = SHA .. "\n",
	},
	packed_ref = {
		[REPO .. "/.git/HEAD"] = "ref: refs/heads/dev\n",
		[REPO .. "/.git/packed-refs"] = "# pack-refs with: peeled fully-peeled sorted\n"
			.. "3b924cd46aaaabbbbccccddddeeeeffff0000111 refs/heads/main\n"
			.. SHA .. " refs/heads/dev\n",
	},
	detached_head = {
		[REPO .. "/.git/HEAD"] = SHA .. "\n",
	},
	worktree_file = {
		[REPO .. "/.git"] = "gitdir: /Users/dev/main/.git/worktrees/ergopti\n",
		["/Users/dev/main/.git/worktrees/ergopti/HEAD"] = "ref: refs/heads/wip/about-menu\n",
		["/Users/dev/main/.git/worktrees/ergopti/commondir"] = "../..\n",
		["/Users/dev/main/.git/refs/heads/wip/about-menu"] = SHA .. "\n",
	},
}

--- The shipped French catalogue, so the row is checked against real wording.
--- @return table
local function french()
	local handle = assert(io.open(helpers.shared("data/locales/fr.json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

--- Loads the updater facade under a logger that records every warning and error.
--- @param is_local boolean What the process reports about its bundle.
--- @param version string What the launcher injected.
--- @return table Updater, table warnings, table errors
local function load_updater(is_local, version)
	local logger = helpers.make_logger_stub()
	local warnings, errors = {}, {}
	logger.warn = function(tag, fmt, ...)
		warnings[#warnings + 1] = tostring(tag) .. ": " .. string.format(fmt, ...)
	end
	logger.error = function(tag, fmt, ...)
		errors[#errors + 1] = tostring(tag) .. ": " .. string.format(fmt, ...)
	end
	helpers.load_with_stubs("infra.logger")
	package.loaded["infra.logger"] = logger
	package.loaded["infra.diagnostic_snapshot"] = nil
	package.loaded["modules.updater"] = nil
	local Updater = require("modules.updater")
	Updater.is_local_source = function() return is_local end
	Updater.current_version = function() return version end
	return Updater, warnings, errors
end

--- The first row of the About submenu for an identity, in French.
--- @param Updater table The facade whose identity the menu reads.
--- @return string title
local function version_row(Updater)
	package.loaded["ui.menu.menu_about"] = nil
	local About = helpers.load_with_stubs("ui.menu.menu_about")
	local catalogue = french()
	require("infra.i18n").get = function(key) return catalogue[key] or key end
	local owner = { get = function() return "dev" end, set = function() end }
	local rows = About.build({ channel_owner = owner }, {
		start_at_login = function() error("Building About must not change startup.") end,
		uninstall = function() error("Building About must not uninstall the application.") end,
	}).submenu
	return rows[1].title
end




-- ================================
-- ================================
-- ======= 2/ Cases ===============
-- ================================
-- ================================

helpers.describe("menu_about: the version row names the build and its commit", function()
	helpers.it("a packaged release shows its version and its stamped commit", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local Updater, warnings = load_updater(false, "0.0.0-dev.144")
			local identity = Updater.resolve_build_identity({
				fs = fixture_fs({ [APP_SHARED .. "/" .. Snapshot.BUILD_STAMP_FILE] = "commit=" .. SHA .. "\n" }),
				shared_root = APP_SHARED, source_dir = APP_SOURCE,
			})
			helpers.assert_eq(identity, { kind = "release", version = "0.0.0-dev.144", commit = SHORT })
			Updater.build_identity = function() return identity end
			helpers.assert_eq(version_row(Updater), "Version 0.0.0-dev.144 (" .. SHORT .. ")")
			helpers.assert_eq(#warnings, 0, "a stamped commit logs no warning")
		end)
	end)

	for shape, files in pairs(CHECKOUTS) do
		helpers.it("a source checkout says it is local and names its commit (" .. shape .. ")", function()
			helpers.with_stub_scope(FIXTURE_MODULES, function()
				local Updater, warnings = load_updater(true, "local")
				local identity = Updater.resolve_build_identity({
					fs = fixture_fs(files), shared_root = SHARED, source_dir = SOURCE_DIR,
				})
				helpers.assert_eq(identity, { kind = "local", version = "", commit = SHORT })
				Updater.build_identity = function() return identity end
				helpers.assert_eq(version_row(Updater), "Version locale (" .. SHORT .. ")")
				helpers.assert_eq(#warnings, 0, "a resolved commit logs no warning")
			end)
		end)
	end

	helpers.it("missing git data reads as an unknown commit, logged with its reason", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local Updater, warnings = load_updater(true, "local")
			local identity = Updater.resolve_build_identity({
				fs = fixture_fs({}), shared_root = SHARED, source_dir = SOURCE_DIR,
			})
			helpers.assert_eq(identity, { kind = "local", version = "", commit = "" })
			Updater.build_identity = function() return identity end
			helpers.assert_eq(version_row(Updater), "Version locale (commit inconnu)")
			helpers.assert_eq(#warnings, 1, "exactly one warning explains the unknown commit")
			helpers.assert_true(warnings[1]:find("Build commit unknown", 1, true) ~= nil, warnings[1])
			helpers.assert_true(warnings[1]:find(SOURCE_DIR, 1, true) ~= nil, warnings[1])
		end)
	end)

	helpers.it("a resolver that raises is logged as an ERROR and reads as an unknown commit", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local Updater, _, errors = load_updater(false, "1.2.3")
			package.loaded["infra.diagnostic_snapshot"] = {
				resolve_commit = function() error("stamp read exploded", 0) end,
			}
			local identity = Updater.resolve_build_identity()
			helpers.assert_eq(identity, { kind = "release", version = "1.2.3", commit = "" })
			Updater.build_identity = function() return identity end
			helpers.assert_eq(version_row(Updater), "Version 1.2.3 (commit inconnu)")
			local raised = {}
			for _, line in ipairs(errors) do
				if line:find("stamp read exploded", 1, true) then raised[#raised + 1] = line end
			end
			helpers.assert_eq(#raised, 1, "the raise is logged once as an error: " .. table.concat(errors, " | "))
		end)
	end)

	helpers.it("the identity is resolved once, then served to every rebuild", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local Updater = load_updater(true, "local")
			local calls = 0
			package.loaded["infra.diagnostic_snapshot"] = {
				resolve_commit = function()
					calls = calls + 1
					return SHORT, Snapshot.COMMIT_SOURCE_GIT
				end,
			}
			local first = Updater.build_identity()
			helpers.assert_eq(version_row(Updater), "Version locale (" .. SHORT .. ")")
			helpers.assert_true(Updater.build_identity() == first, "the same identity is served again")
			helpers.assert_eq(calls, 1, "the commit is read once per Lua state")
		end)
	end)
end)
