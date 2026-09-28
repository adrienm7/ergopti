--- tests/unit/infra/test_config_scope_transaction.lua

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")

local function fixture()
	local original = '[gestures]\nenabled = true\nswipe_3_down = "copy"\nfuture = 42\n[gestures.expert]\nvalue = "preserve"\n[llm]\nenabled = true\n'
	local files = { config = original }
	local writes, runtime = {}, { marker = "original" }
	local controls = {}
	local fs = {
		write = function() error("publication must retain its source precondition") end,
		read_with_status = function(path)
			return files[path], files[path] and "ok" or "absent"
		end,
		write_if_unchanged = function(path, content, expected)
			if controls.refuse == path then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			if expected.status == "ok" and files[path] ~= expected.content then return false end
			files[path] = content
			writes[#writes + 1] = path
			return true
		end,
	}
	local options = {
		path = "config", backup_path = "backup", files = fs, manifest = Manifest,
		capture = function() return { marker = runtime.marker } end,
		apply = function(decoded)
			runtime.marker = decoded.gestures.enabled
			if controls.external_edit then files.config = controls.external_edit end
			if controls.throw_apply then error("native acquisition refused") end
			return controls.apply_result ~= false
		end,
		restore = function(snapshot)
			runtime.marker = snapshot.marker
			return controls.restore_result ~= false
		end,
	}
	return options, files, writes, runtime, controls, original
end

helpers.describe("scoped configuration transaction", function()
	helpers.it("makes ordinary registered configuration writes sparse without touching unrelated files", function()
		helpers.with_fresh_modules({ "toml_codec.writer" }, function()
		local options, files = fixture()
		local writer = require("toml_codec.writer")
		writer.set_sparse_defaults("config", Manifest)
		local updates = { { section = "gestures", key = "enabled", value = false } }
		helpers.assert_eq(writer.batch_write("config", updates, options.files), true)
		helpers.assert_eq(Codec.decode(files.config).gestures.enabled, nil)
		helpers.assert_eq(updates[1].value, false, "caller-owned operations must not be mutated")
		helpers.assert_eq(writer.batch_write("other", updates, options.files), true)
		helpers.assert_eq(Codec.decode(files.other).gestures.enabled, false)
		end)
	end)

	helpers.it("clears owned leaves while preserving unknown nested keys and unrelated consent", function()
		local options, files, writes, runtime, _, original = fixture()
		local owner = require("config_scope_transaction").new(options)
		local committed, detail = owner.apply("gestures", "clear")
		helpers.assert_eq(committed, true, detail)
		local decoded = Codec.decode(files.config)
		helpers.assert_eq(decoded.gestures.enabled, nil)
		helpers.assert_eq(decoded.gestures.swipe_3_down, nil)
		helpers.assert_eq(decoded.gestures.future, 42)
		helpers.assert_eq(decoded.gestures.expert.value, "preserve")
		helpers.assert_eq(decoded.llm.enabled, true)
		helpers.assert_eq(files.backup, original)
		helpers.assert_eq(#writes, 2)
		helpers.assert_eq(runtime.marker, nil)
	end)

	helpers.it("restores recommendations without acquiring absent AI or metrics consent", function()
		local options, files = fixture()
		files.config = ""
		helpers.assert_eq(require("config_scope_transaction").new(options).apply("global", "recommended"), true)
		local decoded = Codec.decode(files.config)
		helpers.assert_eq(decoded.gestures.enabled, true)
		helpers.assert_eq((decoded.llm or {}).enabled, nil)
		helpers.assert_eq((decoded.metrics or {}).enabled, nil)
		helpers.assert_eq((decoded.hotstrings or {}).preview_ai_enabled, nil)
	end)

	helpers.it("refuses a failed backup before touching runtime or the destination", function()
		local options, files, writes, runtime, controls, original = fixture()
		controls.refuse = "backup"
		helpers.assert_eq(require("config_scope_transaction").new(options).apply("gestures", "clear"), false)
		helpers.assert_eq(runtime.marker, "original")
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(#writes, 0)
	end)

	helpers.it("compensates a throwing native application without publishing the candidate", function()
		local options, files, _, runtime, controls, original = fixture()
		controls.throw_apply = true
		helpers.assert_eq(require("config_scope_transaction").new(options).apply("gestures", "clear"), false)
		helpers.assert_eq(runtime.marker, "original")
		helpers.assert_eq(files.config, original)
	end)

	helpers.it("compensates a refused publication without losing unknown bytes", function()
		local options, files, _, runtime, controls, original = fixture()
		controls.refuse = "config"
		helpers.assert_eq(require("config_scope_transaction").new(options).apply("gestures", "clear"), false)
		helpers.assert_eq(runtime.marker, "original")
		helpers.assert_eq(files.config, original)
	end)

	helpers.it("retains failed rollback debt and refuses another transaction until restored", function()
		local options, _, _, _, controls = fixture()
		controls.apply_result, controls.restore_result = false, false
		local owner = require("config_scope_transaction").new(options)
		helpers.assert_eq(owner.apply("gestures", "clear"), false)
		helpers.assert_eq(owner.pending(), true)
		helpers.assert_eq(owner.apply("gestures", "recommended"), false)
		controls.restore_result = true
		helpers.assert_eq(owner.retry_restore(), true)
		helpers.assert_eq(owner.pending(), false)
	end)

	helpers.it("preserves an external edit arriving during runtime application", function()
		local options, files, _, runtime, controls = fixture()
		controls.external_edit = '[future]\nvalue = "external"\n'
		helpers.assert_eq(require("config_scope_transaction").new(options).apply("gestures", "clear"), false)
		helpers.assert_eq(files.config, controls.external_edit)
		helpers.assert_eq(runtime.marker, "original")
	end)

	helpers.it("never overwrites an existing backup", function()
		local options, files, _, runtime, _, original = fixture()
		files.backup = "previous recovery bytes"
		helpers.assert_eq(require("config_scope_transaction").new(options).apply("gestures", "clear"), false)
		helpers.assert_eq(files.backup, "previous recovery bytes")
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(runtime.marker, "original")
	end)
end)
