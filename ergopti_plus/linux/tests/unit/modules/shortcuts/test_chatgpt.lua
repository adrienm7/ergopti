--- tests/unit/modules/shortcuts/test_chatgpt.lua

--- ==============================================================================
--- MODULE: Canonical ChatGPT Shortcut Preference Tests
--- DESCRIPTION:
--- Exercises the actual configuration writer and fresh reader, including sparse
--- scope operations, exact-source refusal and cleanup ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")
local SOURCE = '[shortcuts]\nchatgpt_url = "https://old.example/chat"\nunknown = "keep"\n[other]\nvalue = 42\n'

--- Runs a real canonical reader/writer over an exclusive temporary file.
--- @param source string|nil Initial configuration bytes.
--- @param body function Test body.
local function with_subject(source, body)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local batch = Writer.batch_write
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			local controls = { commands = {}, legacy_writes = 0, legacy_url = "https://legacy.example" }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = {
				get = function(_, default) return controls.legacy_url or default end,
				set = function() controls.legacy_writes = controls.legacy_writes + 1; return true end,
			}
			package.loaded["adapters.shell_runner"] = {
				has_command = function(binary) return binary == "xdg-open" end,
				quote = function(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end,
				run = function(command) controls.commands[#controls.commands + 1] = command; return true end,
			}
			Writer.batch_write = function(target, operations, files, expected)
				if controls.external then Sandbox.write_bytes(target, controls.external) end
				if controls.refuse then return false, "injected refusal" end
				return batch(target, operations, files, expected)
			end
			local function reload()
				package.loaded["modules.shortcuts.chatgpt"] = nil
				return require("modules.shortcuts.chatgpt")
			end
			body(reload(), controls, path, reload)
		end)
	end)
	Writer.batch_write = batch
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

helpers.describe("Canonical ChatGPT shortcut preference", function()
	helpers.it("uses the manifest default for absence without importing legacy storage", function()
		with_subject(nil, function(subject, _, path)
			helpers.assert_eq(subject.get_url(), Manifest.default_for("shortcuts.chatgpt_url"))
			helpers.assert_eq(Sandbox.read_bytes(path), nil)
		end)
	end)

	helpers.it("reads the actual canonical file before and after a fresh module load", function()
		with_subject(SOURCE, function(subject, _, _, reload)
			helpers.assert_eq(subject.get_url(), "https://old.example/chat")
			helpers.assert_eq(reload().get_url(), "https://old.example/chat")
		end)
	end)

	helpers.it("publishes a sparse URL and preserves unknown neighbors across restart", function()
		with_subject(SOURCE, function(subject, controls, path, reload)
			helpers.assert_true(subject.set_url("https://new.example/chat"))
			local config = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(config.shortcuts.chatgpt_url, "https://new.example/chat")
			helpers.assert_eq(config.shortcuts.unknown, "keep")
			helpers.assert_eq(config.other.value, 42)
			helpers.assert_eq(reload().get_url(), "https://new.example/chat")
			helpers.assert_eq(controls.legacy_writes, 0)
		end)
	end)

	helpers.it("removes an explicit neutral value rather than materializing the default", function()
		with_subject(SOURCE, function(subject, _, path, reload)
			helpers.assert_true(subject.set_url(subject.DEFAULT_URL))
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).shortcuts.chatgpt_url, nil)
			helpers.assert_eq(reload().get_url(), subject.DEFAULT_URL)
		end)
	end)

	helpers.it("refuses invalid setter values without changing the configuration", function()
		with_subject(SOURCE, function(subject, controls, path)
			for _, value in ipairs({ false, 4, "file:///etc/passwd", "javascript:alert(1)", "https://bad url" }) do
				helpers.assert_eq(subject.set_url(value), false)
			end
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(controls.legacy_writes, 0)
		end)
	end)

	helpers.it("never opens an old-shape URL and lets a new choice replace it (config-outdated-chatgpt)", function()
		-- A stored value that is not an HTTP(S) URL is outdated configuration:
		-- it used to make every read raise, so Ctrl+G, the menu and the cleanup
		-- all failed on it.
		with_subject('[shortcuts]\nchatgpt_url = false\n', function(subject, _, path)
			helpers.assert_eq(subject.get_url(), subject.DEFAULT_URL, "the value never reaches xdg-open")
			local marked = {}
			subject.mark_config_reads(Codec.decode(Sandbox.read_bytes(path)),
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(marked, {}, "left unmarked, so the cleanup offers it")
			helpers.assert_true(subject.set_url("https://new.example"))
			helpers.assert_eq(subject.get_url(), "https://new.example")
		end)
	end)

	helpers.it("publishes no new state when the actual writer refuses", function()
		with_subject(SOURCE, function(subject, controls, path, reload)
			controls.refuse = true
			helpers.assert_eq(subject.set_url("https://new.example"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(reload().get_url(), "https://old.example/chat")
		end)
	end)

	helpers.it("preserves an external edit arriving between validated read and publication", function()
		with_subject(SOURCE, function(subject, controls, path, reload)
			controls.external = '[shortcuts]\nchatgpt_url = "https://external.example"\n[foreign]\nvalue = 19\n'
			helpers.assert_eq(subject.set_url("https://new.example"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), controls.external)
			helpers.assert_eq(reload().get_url(), "https://external.example")
		end)
	end)

	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("consumes the actual " .. mode .. " scope candidate after publication", function()
			with_subject(SOURCE, function(subject, _, path, reload)
				local operations = Manifest.scope_operations("shortcuts", mode)
				helpers.assert_true(Writer.batch_write(path, operations))
				local expected = mode == "clear" and Manifest.default_for("shortcuts.chatgpt_url")
					or Manifest.recommended_for("shortcuts.chatgpt_url")
				helpers.assert_eq(reload().get_url(), expected)
				helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).shortcuts.unknown, "keep")
			end)
		end)
	end

	helpers.it("retains the consumed URL during actual unused-key detection", function()
		with_subject(SOURCE, function(_, _, path)
			package.loaded["ui.menu.unused_keys_cleanup"] = nil
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			local found = {}
			for _, entry in ipairs(scan.keys) do found[table.concat(entry.path, ".")] = true end
			helpers.assert_eq(found["shortcuts.chatgpt_url"], nil)
			helpers.assert_true(found["shortcuts.unknown"])
		end)
	end)

	helpers.it("opens the canonical URL as one inert shell argument", function()
		with_subject('[shortcuts]\nchatgpt_url = "https://example.invalid/a?value=$(touch%20no)"\n', function(subject, controls)
			helpers.assert_true(subject.open())
			helpers.assert_eq(#controls.commands, 1)
			helpers.assert_contains(controls.commands[1], "'https://example.invalid/a?value=$(touch%20no)'")
		end)
	end)
end)
