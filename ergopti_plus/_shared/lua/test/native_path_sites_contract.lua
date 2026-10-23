--- _shared/lua/test/native_path_sites_contract.lua

--- ==============================================================================
--- MODULE: Shared Native Path Sites Contract
--- DESCRIPTION:
--- The shared modules both POSIX drivers load keep a backslash as filename data
--- on a modelled POSIX host (posix-backslash-separator-owner).
---
--- ROOT CAUSE ENCODED:
--- Each site trimmed or split with its own [/\\] class, so a backslash ending a
--- folder name was dropped, a backslash inside a file name cut it, and a home
--- folder "/home/a" redacted the different folder "/home/a\b" as "~\b". Every
--- vector below failed before the sites went through _shared/lua/native_path.lua.
--- ==============================================================================

local M = {}

local POSIX_CONFIG = "/\n;\n?\n!\n-\n"

--- Runs body with package.config modelling a POSIX host, restoring it afterwards.
--- @param body function
local function on_posix(body)
	local saved = package.config
	package.config = POSIX_CONFIG
	local ok, failure = xpcall(body, debug.traceback)
	package.config = saved
	if not ok then error(failure, 0) end
end

--- Registers the vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	helpers.describe("shared path sites keep POSIX backslash bytes (posix-backslash-separator-owner)", function()
		helpers.it("posix-backslash-separator-owner: a reload names the whole file", function()
			on_posix(function()
				local text = require("diagnostics.runtime_log").describe_paths({ "/home/a/back\\slash.toml" })
				helpers.assert_true(text:find("back\\slash.toml", 1, true) ~= nil, "whole file name kept: " .. text)
			end)
		end)

		helpers.it("posix-backslash-separator-owner: home redaction stops at a real separator", function()
			on_posix(function()
				local Snapshot = require("diagnostics.snapshot")
				helpers.assert_eq(Snapshot.redact_home("/home/a\\b/x", "/home/a"), "/home/a\\b/x",
					"/home/a\\b is another folder, not inside /home/a")
				helpers.assert_eq(Snapshot.redact_home("/home/a\\/x", "/home/a\\"), "~/x",
					"a home ending in a backslash keeps that byte")
			end)
		end)

		helpers.it("posix-backslash-separator-owner: trailing backslashes stay in folder names", function()
			on_posix(function()
				local read = {}
				require("diagnostics.snapshot").build_commit({ read = function(path) read[#read + 1] = path end }, "/s\\")
				helpers.assert_eq(read[1]:sub(1, 4), "/s\\/", "the build stamp is read inside /s\\: " .. read[1])

				local ctx = { vocabulary = { _meta = { user_file = "layers.toml" } } }
				helpers.assert_eq(require("keymap.layers").user_file_path("/cfg\\", ctx), "/cfg\\/layers.toml")

				local spec = { folders = { linux = { base = "BASE", segments = { "{app}" } } } }
				local folder = require("control.driver_control").folder(spec, "linux",
					function() return "/run\\" end, "app", "/")
				helpers.assert_eq(folder, "/run\\/app")

				local probes = {}
				local fs = { exists = function(path) probes[#probes + 1] = path; return path == "/r/w\\/.git/HEAD" end }
				helpers.assert_eq(require("reload_gate").git_dir(fs, "/r/w\\"), "/r/w\\/.git",
					"the checkout folder keeps its trailing backslash")
			end)
		end)
	end)
end

return M
