--- tests/unit/ui/test_about_menu_version_row.lua

--- ==============================================================================
--- MODULE: The About Version Row Names The Build And Its Commit (Linux tray)
--- DESCRIPTION:
--- The first row of the Version / Updates submenu read « ErgoptiPlus local »
--- for every source run and « ErgoptiPlus 0.0.0-dev.144 » for a release: no
--- commit, so nobody could tell which checkout or package a demo was running.
--- It now names the build kind and the commit through the shared formatter:
--- « Version 0.0.0-dev.144 (c3005e0b9) » for a stamped release, « Version
--- locale (c3005e0b9) » for a source checkout, « Version inconnue (…) » for a
--- package whose stamp holds no version, and « commit inconnu » with a logged
--- WARNING when neither the build stamp nor .git says.
---
--- The identity goes through infra/version.lua and the real commit resolver on
--- in-memory fixtures of each .git shape (loose ref, packed ref, detached
--- HEAD, linked worktree), and the row through the real tray builder.
--- ==============================================================================

local helpers = require("tests.helpers")
local Snapshot = require("diagnostics.snapshot")

local SHA = "c3005e0b9aaaabbbbccccddddeeeeffff0000111"
local SHORT = "c3005e0b9"
local REPO = "/home/dev/ergopti"
local SOURCE_DIR = REPO .. "/static/ergopti_plus/linux"
local SHARED = REPO .. "/static/ergopti_plus/_shared"
local PACKAGE_SHARED = "/usr/lib/ergopti/_shared"




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
		[REPO .. "/.git"] = "gitdir: /home/dev/main/.git/worktrees/ergopti\n",
		["/home/dev/main/.git/worktrees/ergopti/HEAD"] = "ref: refs/heads/wip/about-menu\n",
		["/home/dev/main/.git/worktrees/ergopti/commondir"] = "../..\n",
		["/home/dev/main/.git/refs/heads/wip/about-menu"] = SHA .. "\n",
	},
}

-- The identity chain, reloaded per case: earlier suites leave logger stubs in
-- package.loaded, and a module cached under one of them logs nowhere.
local IDENTITY_MODULES = { "logger.shim", "infra.diagnostic_snapshot", "infra.version" }

--- Runs body(Version) over a freshly loaded identity chain bound to the real
--- logger, with every log line captured at DEBUG; restores the chain after.
--- @param body function Receives the fresh infra.version.
--- @return table lines
local function capture_logs(body)
	local saved = {}
	for _, name in ipairs(IDENTITY_MODULES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local Logger = require("logger")
	local lines = {}
	local previous_level = Logger.get_level()
	Logger.set_level(10)
	Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
	local ok, err = pcall(function() body(require("infra.version")) end)
	Logger.set_sink(nil)
	Logger.set_level(previous_level)
	for _, name in ipairs(IDENTITY_MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
	return lines
end

--- The lines of a capture that carry a level and a message fragment.
--- @param lines table
--- @param level string
--- @param fragment string
--- @return table
local function lines_with(lines, level, fragment)
	local found = {}
	for _, line in ipairs(lines) do
		if line:find("[" .. level .. "]", 1, true) and line:find(fragment, 1, true) then
			found[#found + 1] = line
		end
	end
	return found
end

--- The first row of the tray's About submenu for an identity.
--- @param identity table
--- @return string title
local function version_row(identity)
	local Version = require("infra.version")
	local real_identity = Version.identity
	Version.identity = function() return identity end
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ok, items = pcall(mb.build, { on_quit = function() end })
	Version.identity = real_identity
	if not ok then error(items, 0) end
	local title = require("infra.i18n").get("menu.about.title")
	for _, item in ipairs(items) do
		if item.title == title then return item.menu[1].title end
	end
	error("the tray has no About submenu")
end

--- The active locale's template for a key, filled by plain replacement.
--- @param key string
--- @param values table Placeholder → value.
--- @return string
local function expected(key, values)
	local text = require("infra.i18n").get(key)
	for placeholder, value in pairs(values) do
		local at = text:find(placeholder, 1, true)
		assert(at, key .. " must carry " .. placeholder)
		text = text:sub(1, at - 1) .. value .. text:sub(at + #placeholder)
	end
	return text
end




-- ================================
-- ================================
-- ======= 2/ Cases ===============
-- ================================
-- ================================

helpers.describe("tray (linux): the About version row names the build and its commit", function()
	helpers.it("a release package shows its version and its stamped commit", function()
		local identity, row
		local lines = capture_logs(function(Version)
			identity = Version.resolve_identity({
				source = Version.SOURCE_BUILD, version = "0.0.0-dev.144",
				commit_opts = {
					env = fixture_fs({ [PACKAGE_SHARED .. "/" .. Snapshot.BUILD_STAMP_FILE] = "commit=" .. SHA .. "\n" }),
					shared_root = PACKAGE_SHARED, source_dir = "/usr/lib/ergopti/linux",
				},
			})
			row = version_row(identity)
		end)
		helpers.assert_eq(identity, { kind = "release", version = "0.0.0-dev.144", commit = SHORT })
		helpers.assert_eq(row,
			expected("menu.about.version_release", { ["{version}"] = "0.0.0-dev.144", ["{commit}"] = SHORT }))
		helpers.assert_eq(#lines_with(lines, "WARNING", "Build commit unknown"), 0, "a stamped commit logs no warning")
		helpers.assert_eq(#lines_with(lines, "INFO", "Build identity: release"), 1,
			"the identity is logged once; got:\n" .. table.concat(lines, "\n"))
	end)

	for shape, files in pairs(CHECKOUTS) do
		helpers.it("a source checkout says it is local and names its commit (" .. shape .. ")", function()
			local identity, row
			local lines = capture_logs(function(Version)
				identity = Version.resolve_identity({
					source = Version.SOURCE_LOCAL, version = Version.LOCAL,
					commit_opts = { env = fixture_fs(files), shared_root = SHARED, source_dir = SOURCE_DIR },
				})
				row = version_row(identity)
			end)
			helpers.assert_eq(identity, { kind = "local", version = "", commit = SHORT })
			helpers.assert_eq(row, expected("menu.about.version_local", { ["{commit}"] = SHORT }))
			helpers.assert_eq(#lines_with(lines, "WARNING", "Build commit unknown"), 0, "a resolved commit logs no warning")
		end)
	end

	helpers.it("missing git data reads as an unknown commit, logged with its reason", function()
		local identity, row
		local lines = capture_logs(function(Version)
			identity = Version.resolve_identity({
				source = Version.SOURCE_LOCAL, version = Version.LOCAL,
				commit_opts = { env = fixture_fs({}), shared_root = SHARED, source_dir = SOURCE_DIR },
			})
			row = version_row(identity)
		end)
		helpers.assert_eq(identity, { kind = "local", version = "", commit = "" })
		helpers.assert_eq(row, expected("menu.about.version_local", {
			["{commit}"] = require("infra.i18n").get("menu.about.commit_unknown"),
		}))
		local warned = lines_with(lines, "WARNING", "Build commit unknown")
		helpers.assert_eq(#warned, 1, "expected one WARNING naming the missing data; got:\n" .. table.concat(lines, "\n"))
		helpers.assert_true(warned[1]:find(SOURCE_DIR, 1, true) ~= nil, warned[1])
	end)

	helpers.it("a package whose stamp holds no version says its version is unknown", function()
		local identity, row
		capture_logs(function(Version)
			identity = Version.resolve_identity({
				source = Version.SOURCE_UNKNOWN, version = Version.UNKNOWN,
				commit_opts = {
					env = fixture_fs({ [PACKAGE_SHARED .. "/" .. Snapshot.BUILD_STAMP_FILE] = "commit=" .. SHA .. "\n" }),
					shared_root = PACKAGE_SHARED, source_dir = "/usr/lib/ergopti/linux",
				},
			})
			row = version_row(identity)
		end)
		helpers.assert_eq(identity, { kind = "unknown", version = "", commit = SHORT })
		helpers.assert_eq(row, expected("menu.about.version_unknown", { ["{commit}"] = SHORT }))
	end)

	helpers.it("a resolver that raises is logged as an ERROR and reads as an unknown commit", function()
		local identity
		local lines = capture_logs(function(Version)
			package.loaded["infra.diagnostic_snapshot"] = {
				resolve_commit = function() error("stamp read exploded", 0) end,
			}
			identity = Version.resolve_identity({ source = Version.SOURCE_BUILD, version = "1.2.3" })
		end)
		helpers.assert_eq(identity, { kind = "release", version = "1.2.3", commit = "" })
		helpers.assert_eq(#lines_with(lines, "ERROR", "stamp read exploded"), 1, table.concat(lines, "\n"))
	end)

	helpers.it("the identity is resolved once, then served to every rebuild", function()
		local calls = 0
		capture_logs(function(Version)
			package.loaded["infra.diagnostic_snapshot"] = {
				resolve_commit = function()
					calls = calls + 1
					return SHORT, Snapshot.COMMIT_SOURCE_GIT
				end,
			}
			local first = Version.identity()
			helpers.assert_true(Version.identity() == first, "the same identity is served again")
		end)
		helpers.assert_eq(calls, 1, "the commit is read once per daemon")
	end)
end)
