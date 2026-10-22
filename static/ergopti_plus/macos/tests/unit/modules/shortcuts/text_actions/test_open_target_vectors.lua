--- tests/unit/modules/shortcuts/text_actions/test_open_target_vectors.lua

--- ==============================================================================
--- MODULE: copy_selected_path opens what the selection names (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/shortcuts/open_target_vectors.json, which the
--- Linux and Windows suites replay too, through _shared/lua/open_target with
--- the corpus's POSIX environment, then drives copy_or_open_path's
--- selection handler with recording URL, open(1), file and notice ports.
---
--- ROOT CAUSE ENCODED:
--- is_probable_url only accepted http(s)://, www. and a dot followed by two
--- letters, so a selected IP address (192.168.1.1, 10.0.0.1:8080/admin) or
--- localhost:3000 became a Google search, and a selected path was searched
--- instead of opened (open-target-ip-address).
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local OpenTarget = require("open_target")

local CORPUS = helpers.shared("tests/corpus/shortcuts/open_target_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the open-target corpus is not valid JSON")
end

--- The notice a report shows: the locale template with the target in it.
--- @param key string
--- @param target string
--- @return string
local function notice(key, target)
	return (tostring(require("infra.i18n").get(key)):gsub("%%s", function() return target end))
end

--- The modules a fixture replaces; with_fresh_modules restores each one, so a
--- recording port never reaches the next test file the runner loads.
local OWNED_MODULES = {
	"modules.shortcuts.actions.apps", "adapters.window_info", "adapters.shell_runner",
	"adapters.file_system", "infra.notifications", "infra.logger",
}

--- Runs a case against the apps actions with recording ports.
--- @param existing table|nil Paths that exist.
--- @param body function Receives world { apps, urls, opened, notices }.
local function with_apps(existing, body)
	helpers.with_fresh_modules(OWNED_MODULES, function()
		local world = { urls = {}, opened = {}, notices = {} }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.window_info"] = { getFocused = function() return { appId = "TextEdit" } end }
		package.loaded["infra.notifications"] = {
			notify = function(message) world.notices[#world.notices + 1] = message; return true end,
		}
		package.loaded["adapters.file_system"] = {
			exists = function(path) return (existing or {})[path] == true end,
		}
		package.loaded["adapters.shell_runner"] = {
			open = function(target, on_done)
				world.opened[#world.opened + 1] = target
				on_done(true)
				return true, {
					isSettled = function() return true end,
					onSettled = function(observer) observer(); return true end,
					terminate = function() return true, "settled" end,
				}
			end,
			applescript = function() return false end,
		}
		world.apps = helpers.load_with_stubs("modules.shortcuts.actions.apps", {
			urlevent = { openURL = function(url) world.urls[#world.urls + 1] = url; return true end },
			http = { encodeForQuery = function(value) return (value:gsub(" ", "+")) end },
		})
		body(world)
	end)
end

helpers.describe("copy_selected_path replays the shared open-target corpus", function()
	local corpus = read_corpus()
	local env = corpus.env.posix

	helpers.it("open-target: the corpus is loaded", function()
		helpers.assert_true(#corpus.vectors >= 60, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("open-target vector '" .. vector.id .. "'", function()
			local want = vector.macos or vector.posix or vector.expect
			local got = OpenTarget.classify(vector.text, function(name) return env[name] end)
			helpers.assert_eq(got.kind, want.kind, vector.id .. ": kind")
			helpers.assert_eq(got.target, want.target, vector.id .. ": target")
			helpers.assert_eq(got.reason, want.reason, vector.id .. ": reason")
		end)
	end
end)

helpers.describe("copy_or_open_path opens the selection (open-target-ip-address)", function()
	for _, case in ipairs({
		{ "192.168.1.1", "http://192.168.1.1" },
		{ "10.0.0.1:8080/admin", "http://10.0.0.1:8080/admin" },
		{ "localhost:3000", "http://localhost:3000" },
		{ "[::1]:8080", "http://[::1]:8080" },
		{ "ada@example.com", "mailto:ada@example.com" },
	}) do
		helpers.it("open-target: opens '" .. case[1] .. "' as " .. case[2] .. ", not a web search", function()
			with_apps(nil, function(world)
				helpers.assert_eq(world.apps._open_or_search(case[1]), true)
				helpers.assert_eq(world.urls, { case[2] })
				helpers.assert_eq(#world.notices, 0)
			end)
		end)
	end

	helpers.it("open-target: an existing file or folder goes to open(1) as one argument", function()
		with_apps({ ["/Users/ada/Mes documents/a b.pdf"] = true }, function(world)
			helpers.assert_eq(world.apps._open_or_search("\"/Users/ada/Mes documents/a b.pdf\""), true)
			helpers.assert_eq(world.opened, { "/Users/ada/Mes documents/a b.pdf" })
			helpers.assert_eq(#world.urls, 0, "a path is not searched")
		end)
	end)

	helpers.it("open-target: a missing path is reported, never searched (open-target-missing-path-reported)", function()
		with_apps(nil, function(world)
			helpers.assert_eq(world.apps._open_or_search("/Users/ada/nowhere.txt"), false)
			helpers.assert_eq(#world.urls + #world.opened, 0, "nothing must open, not even a search")
			helpers.assert_eq(world.notices, { notice("open_target.missing_path", "/Users/ada/nowhere.txt") })
		end)
	end)

	helpers.it("open-target: a registry key and a bare file name are reported, not searched", function()
		with_apps(nil, function(world)
			world.apps._open_or_search("HKCU\\Software")
			world.apps._open_or_search("notes.txt")
			helpers.assert_eq(#world.urls + #world.opened, 0)
			helpers.assert_eq(world.notices, {
				notice("open_target.windows_only", "HKEY_CURRENT_USER\\Software"),
				notice("open_target.bare_file_name", "notes.txt"),
			})
		end)
	end)

	helpers.it("open-target: plain text is searched with the shared default engine", function()
		with_apps(nil, function(world)
			world.apps._open_or_search("bonjour le monde")
			helpers.assert_eq(world.urls, { OpenTarget.DEFAULT_SEARCH_URL .. "bonjour+le+monde" })
		end)
	end)
end)
