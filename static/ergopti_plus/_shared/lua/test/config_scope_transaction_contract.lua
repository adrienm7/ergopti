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
			delete = function(path)
				if controls.refuse == path then return false end
				files[path] = nil
				writes[#writes + 1] = "-" .. path
				return true
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
			-- A clear routes no row for the switch (gestures-clear-keeps-switch).
			helpers.assert_eq(decoded.gestures.enabled, true)
			helpers.assert_eq(decoded.gestures.swipe_3_down, nil)
			helpers.assert_eq(decoded.gestures.future, 42)
			helpers.assert_eq(decoded.gestures.expert.value, "preserve")
			helpers.assert_eq(decoded.llm.enabled, true)
			helpers.assert_eq(files.backup, original)
			helpers.assert_eq(#writes, 2)
			helpers.assert_eq(runtime.marker, true)
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

	--- A preset owner over a separate file, routing the manifest's tap_holds rows.
	--- Its runtime marker follows the preset candidate's master flag.
	local function preset_fixture(preset_source)
		local options, files, writes, runtime, controls, original = fixture()
		files.taps = preset_source
		options.presets = { tap_hold = {
			path = "taps", backup_path = "taps-backup", prefixes = { "tap_holds" },
			render = function(mode, document, rows)
				helpers.assert_true(mode == "recommended" or mode == "clear")
				local tap_hold = document.tap_hold or {}
				for _, row in ipairs(rows) do
					helpers.assert_eq(row.section .. "." .. row.key, "tap_holds.enabled")
					tap_hold.enabled = not row.delete and row.value or nil
				end
				tap_hold.keys = mode == "recommended" and { caps_lock = { tap_action = "escape" } } or nil
				document.tap_hold = tap_hold
				return Codec.encode(document)
			end,
		} }
		options.capture = function() return { marker = runtime.marker } end
		options.apply = function(decoded, updates, _, _, presets)
			helpers.assert_eq(decoded, nil, "a preset-only scope has no configuration candidate")
			helpers.assert_eq(#updates, 0)
			runtime.marker = presets.tap_hold.decoded.tap_hold.enabled
			if controls.external_edit then files[controls.external_edit.path] = controls.external_edit.content end
			return controls.apply_result ~= false
		end
		return options, files, writes, runtime, controls, original
	end

	helpers.describe("preset scope publication", function()
		helpers.it("publishes the preset file with a verified backup and leaves config.toml untouched", function()
			for _, mode in ipairs({ "recommended", "clear" }) do
				local source = '[tap_hold]\nenabled = false\nfuture = "keep"\n[other]\nvalue = 17\n'
				local options, files, writes, runtime, _, original = preset_fixture(source)
				local owner = require("config_scope_transaction").new(options)
				local ok, detail = owner.apply("tap_holds", mode)
				helpers.assert_eq(ok, true, detail)
				local stored = Codec.decode(files.taps)
				helpers.assert_eq(stored.tap_hold.future, "keep")
				helpers.assert_eq(stored.other.value, 17)
				-- A clear routes no switch row: the stored one stays (tap-hold-clear-keeps-switch).
				local expected = false
				if mode == "recommended" then expected = Manifest.recommended_for("tap_holds.enabled") end
				helpers.assert_eq(stored.tap_hold.enabled, expected)
				helpers.assert_eq(files["taps-backup"], source)
				helpers.assert_eq(files.config, original)
				helpers.assert_eq(files.backup, nil)
				helpers.assert_eq(writes, { "taps-backup", "taps" })
				helpers.assert_eq(runtime.marker, stored.tap_hold.enabled)
				helpers.assert_eq(owner.pending(), false)
			end
		end)

		helpers.it("creates an absent preset file without creating config.toml", function()
			local options, files, writes = preset_fixture(nil)
			files.config = nil
			local ok, detail = require("config_scope_transaction").new(options).apply("tap_holds", "recommended")
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(files.config, nil)
			helpers.assert_eq(files["taps-backup"], nil, "an absent source has nothing to back up")
			helpers.assert_eq(writes, { "taps" })
		end)

		helpers.it("keeps an external preset edit made during runtime application", function()
			local source = '[tap_hold]\nenabled = false\n'
			local options, files, _, runtime, controls = preset_fixture(source)
			controls.external_edit = { path = "taps", content = '[tap_hold]\nfuture = "external"\n' }
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("tap_holds", "recommended"), false)
			helpers.assert_eq(files.taps, controls.external_edit.content)
			helpers.assert_eq(runtime.marker, "original")
			helpers.assert_eq(owner.pending(), false)
		end)

		helpers.it("restores a published preset when the configuration publication is refused", function()
			local source = '[tap_hold]\nenabled = false\n'
			local options, files, _, runtime, controls, original = preset_fixture(source)
			options.apply = function() runtime.marker = "candidate"; return true end
			options.owned_paths = function() return { "gestures.action_parameters.tap_hold__caps_lock__open_url" } end
			options.owners = { action_parameter_domain = function(path)
				if path == "gestures.action_parameters.tap_hold__caps_lock__open_url" then return "tap_hold" end
			end }
			controls.refuse = "config"
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("tap_holds", "clear"), false)
			helpers.assert_eq(files.taps, source, "the preset bytes are put back exactly")
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(runtime.marker, "original")
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	helpers.describe("committed scope revert", function()
		helpers.it("reverts runtime and every published file, removing a file it created", function()
			local options, files, writes, runtime = preset_fixture(nil)
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("tap_holds", "recommended"), true)
			helpers.assert_eq(owner.committed(), true)
			helpers.assert_eq(runtime.marker, true)
			local reverted, detail = owner.revert()
			helpers.assert_eq(reverted, true, detail)
			helpers.assert_eq(files.taps, nil, "the created preset file is removed again")
			helpers.assert_eq(runtime.marker, "original")
			helpers.assert_eq(writes[#writes], "-taps")
			helpers.assert_eq(owner.committed(), false)
			helpers.assert_eq(owner.revert(), false, "one commit reverts once")
		end)

		helpers.it("puts the exact configuration bytes back after a committed single-file scope", function()
			local options, files, _, runtime, _, original = fixture()
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("gestures", "clear"), true)
			helpers.assert_true(files.config ~= original)
			helpers.assert_eq(owner.revert(), true)
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(runtime.marker, "original")
		end)

		helpers.it("retains a revert refused by a later edit until the edit is undone", function()
			local options, files, _, runtime, controls, original = fixture()
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("gestures", "clear"), true)
			local candidate = files.config
			files.config = candidate .. "# external edit\n"
			helpers.assert_eq(owner.revert(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(files.config, candidate .. "# external edit\n", "the later edit is never overwritten")
			helpers.assert_eq(runtime.marker, "original", "the runtime inverse is settled first")
			helpers.assert_eq(owner.apply("gestures", "clear"), false, "debt refuses another transaction")
			controls.restore_result = false
			files.config = candidate
			helpers.assert_eq(owner.retry_restore(), true, "a settled runtime step is not repeated")
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(owner.pending(), false)
		end)

		helpers.it("release forgets the inverse so a composed commit cannot be reverted", function()
			local options = fixture()
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("gestures", "clear"), true)
			owner.release()
			helpers.assert_eq(owner.committed(), false)
			local reverted, detail = owner.revert()
			helpers.assert_eq(reverted, false)
			helpers.assert_true(detail:find("no committed", 1, true) ~= nil, detail)
		end)
	end)

	helpers.describe("scope conditional unlink cleanup debt", function()
		for _, unlinked in ipairs({ true, false }) do
			for _, refusal in ipairs({ "false", "truthy", "throw" }) do
				helpers.it("retains " .. tostring(unlinked) .. " unlink debt across " .. refusal .. " release", function()
					local options, files, _, _, controls = preset_fixture(nil)
					local owner = require("config_scope_transaction").new(options)
					local cleanup_calls, removals, restores = 0, 0, 0
					local restore = options.restore
					options.restore = function(snapshot) restores = restores + 1; return restore(snapshot) end
					helpers.assert_eq(owner.apply("tap_holds", "recommended"), true)
					local candidate = files.taps
					local release_allowed = false
					options.files.remove_if_unchanged = function(path, expected)
						helpers.assert_eq(path, "taps"); helpers.assert_eq(expected.content, candidate)
						removals = removals + 1
						if removals > 1 then files.taps = nil; return true end
						if unlinked then files.taps = nil end
						return false, "release retained", function()
							cleanup_calls = cleanup_calls + 1
							if release_allowed then return true, nil, unlinked end
							if refusal == "throw" then error("release threw") end
							return refusal == "truthy" and "true" or false
						end
					end
					helpers.assert_eq(owner.revert(), false)
					helpers.assert_eq(owner.pending(), true)
					helpers.assert_eq(owner.retry_restore(), false, "only literal release acknowledgement settles debt")
					helpers.assert_eq(owner.apply("tap_holds", "clear"), false)
					if unlinked then files.taps = "later foreign record" end
					release_allowed = true
					helpers.assert_eq(owner.retry_restore(), true)
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(cleanup_calls, 2)
					helpers.assert_eq(restores, 1, "the runtime inverse must settle once")
					helpers.assert_eq(removals, unlinked and 1 or 2)
					if unlinked then helpers.assert_eq(files.taps, "later foreign record") end
				end)
			end
		end
	end)

	helpers.describe("scope refused partial unlink", function()
		helpers.it("proves absence only after the retained removal lease releases", function()
			local options, files = preset_fixture(nil)
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("tap_holds", "recommended"), true)
			local release_allowed, cleanup_calls, removals = false, 0, 0
			options.files.remove_if_unchanged = function(path)
				removals = removals + 1; files[path] = nil
				return false, "unlink refused after effect", function()
					cleanup_calls = cleanup_calls + 1
					return release_allowed, nil, false
				end
			end
			helpers.assert_eq(owner.revert(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(owner.retry_restore(), false)
			release_allowed = true
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(cleanup_calls, 2)
			helpers.assert_eq(removals, 1)
		end)
	end)

end
