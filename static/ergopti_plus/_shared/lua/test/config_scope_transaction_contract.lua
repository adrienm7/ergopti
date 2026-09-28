--- _shared/lua/test/config_scope_transaction_contract.lua

--- Shared behavior proves both hosts keep backups, consent and rollback debt.
return function(helpers)
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
				runtime.marker = decoded.gestures and decoded.gestures.enabled
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

	local function with_writer(run)
		local previous = package.loaded["toml_codec.writer"]
		package.loaded["toml_codec.writer"] = nil
		local ok, detail = pcall(run)
		package.loaded["toml_codec.writer"] = previous
		assert(ok, detail)
	end

	helpers.describe("scoped configuration transaction", function()
		helpers.it("makes ordinary registered configuration writes sparse without touching unrelated files", function()
			with_writer(function()
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
			for _, scope in ipairs({ "gestures", "llm", "metrics", "hotstrings" }) do
				local options, files = fixture()
				files.config = ""
				helpers.assert_eq(require("config_scope_transaction").new(options).apply(scope, "recommended"), true)
				local decoded = Codec.decode(files.config)
				helpers.assert_eq((decoded.llm or {}).enabled, nil)
				helpers.assert_eq((decoded.metrics or {}).enabled, nil)
				helpers.assert_eq((decoded.hotstrings or {}).preview_ai_enabled, nil)
			end
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

	helpers.describe("dynamic scope publication", function()
		helpers.it("removes only runtime-owned ordinary leaves and backs up the exact unknown neighbors", function()
			local options, files = fixture()
			local original = '[hotstrings.modules.french_probe]\ncustom = true\nunowned = false\nnote = "preserve"\n'
			files.config = original
			options.owned_paths = function()
				return Manifest.scope_inventory("hotstrings", { extension = function()
					return { "hotstrings.modules.french_probe.custom" }
				end })
			end
			local ok, detail = require("config_scope_transaction").new(options).apply("hotstrings", "clear")
			helpers.assert_eq(ok, true, detail)
			local group = Codec.decode(files.config).hotstrings.modules.french_probe
			helpers.assert_eq(group.custom, nil)
			helpers.assert_eq(group.unowned, false)
			helpers.assert_eq(group.note, "preserve")
			helpers.assert_eq(files.backup, original)
		end)
	end)

	helpers.describe("quoted dynamic scope publication", function()
		helpers.it("clears a quoted extension leaf with exact backup and neighbor preservation", function()
			local options, files, writes, runtime = fixture()
			local original = '[hotstrings.modules."ext:ergopti:rolls"]\ncustom = true\nunowned = false\n'
			files.config = original
			options.owned_paths = function()
				return Manifest.scope_inventory("hotstrings", { extension = function()
					return { "hotstrings.modules.ext:ergopti:rolls.custom" }
				end })
			end
			local ok, detail = require("config_scope_transaction").new(options).apply("hotstrings", "clear")
			helpers.assert_eq(ok, true, detail)
			local group = Codec.decode(files.config).hotstrings.modules["ext:ergopti:rolls"]
			helpers.assert_eq(group.custom, nil)
			helpers.assert_eq(group.unowned, false)
			helpers.assert_eq(files.backup, original)
			helpers.assert_eq(#writes, 2)
			helpers.assert_eq(runtime.marker, nil)
		end)
	end)

	helpers.describe("single-file scope admission", function()
		helpers.it("removes only validated binding parameters while preserving other domains and unknown neighbors", function()
			for _, profile in ipairs({ { "action_parameters", "gesture__tap_4__open_url" },
				{ "gesture_parameters", "tap_4__open_url" } }) do
				for _, mode in ipairs({ "clear", "recommended" }) do
					local options, files, writes = fixture()
					local original = '[' .. profile[1] .. ']\n' .. profile[2] .. ' = "https://apple.com"\n'
						.. 'keyboard__ctrl_k__open_url = "https://example.com"\nfuture = "preserve"\n'
					files.config = original
					options.owned_paths = function() return { profile[1] .. "." .. profile[2],
						profile[1] .. ".keyboard__ctrl_k__open_url" } end
					options.owners = { action_parameter_domain = function(path)
						if path == profile[1] .. "." .. profile[2] then return "gesture" end
						if path == profile[1] .. ".keyboard__ctrl_k__open_url" then return "keyboard" end
					end }
					local ok, detail = require("config_scope_transaction").new(options).apply("gestures", mode)
					helpers.assert_eq(ok, true, detail)
					local parameters = Codec.decode(files.config)[profile[1]]
					helpers.assert_eq(parameters[profile[2]], nil)
					helpers.assert_eq(parameters.keyboard__ctrl_k__open_url, "https://example.com")
					helpers.assert_eq(parameters.future, "preserve")
					helpers.assert_eq(files.backup, original)
					helpers.assert_eq(#writes, 2)
				end
			end
		end)
		helpers.it("refuses the inline macOS parameter table before backup or runtime publication", function()
			local options, files, writes, runtime = fixture()
			local original = '[gestures]\naction_parameters = { tap_4__open_url = "https://apple.com", unknown = "preserve" }\n'
			files.config = original
			options.owned_paths = function() return { "gestures.action_parameters.tap_4__open_url" } end
			options.owners = { action_parameter_domain = function(path)
				if path == "gestures.action_parameters.tap_4__open_url" then return "gesture" end
			end }
			local ok = require("config_scope_transaction").new(options).apply("gestures", "clear")
			helpers.assert_eq(ok, false)
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(files.backup, nil)
			helpers.assert_eq(#writes, 0)
			helpers.assert_eq(runtime.marker, "original")
		end)
		helpers.it("refuses preset scopes before reading, backing up or touching runtime", function()
			for _, scope in ipairs({ "global", "tap_holds" }) do
				for _, mode in ipairs({ "recommended", "clear" }) do
					local options, files, writes, runtime, _, original = fixture()
					local reads = 0
					local read = options.files.read_with_status
					options.files.read_with_status = function(path) reads = reads + 1; return read(path) end
					local owner = require("config_scope_transaction").new(options)
					local ok, detail = owner.apply(scope, mode)
					helpers.assert_eq(ok, false)
					helpers.assert_true(detail:find("preset", 1, true) ~= nil, detail)
					helpers.assert_eq(reads, 0)
					helpers.assert_eq(#writes, 0)
					helpers.assert_eq(files.config, original)
					helpers.assert_eq(files.backup, nil)
					helpers.assert_eq(runtime.marker, "original")
					helpers.assert_eq(owner.pending(), false)
				end
			end
		end)
	end)

end
