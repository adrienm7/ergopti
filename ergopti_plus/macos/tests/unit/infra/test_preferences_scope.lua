--- tests/unit/infra/test_preferences_scope.lua

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local function fixture(source)
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["modules.gestures.conflicts"] = nil
	local Actions = helpers.load_with_stubs("modules.gestures.actions")
	local Gestures = helpers.load_with_stubs("modules.gestures")
	Actions.set_action_parameter("tap_4", "open_url", "https://apple.com")
	Actions.set_action_parameter("keyboard__cmd_k", "open_url", "https://example.com")
	local original = source or '[gestures]\nenabled = true\naction_parameters = { tap_4__open_url = "https://apple.com", keyboard__cmd_k__open_url = "https://example.com", unknown = { value = 7 } }\n[future]\nvalue = "preserve"\n'
	local files, writes, runtime, controls = { config = original }, {}, { marker = "original" }, {}
	local options = {
		path = "config", backup_path = "backup", gestures = Gestures,
		files = {
			read_with_status = function(path)
				if controls.unreadable and path == "config" then return nil, "error", "permission denied" end
				return files[path], files[path] and "ok" or "absent"
			end,
			write = function() error("conditional publication required") end,
			write_if_unchanged = function(path, content, expected)
				if controls.refuse == path then return false end
				if expected.status == "absent" and files[path] ~= nil then return false end
				if expected.status == "ok" and files[path] ~= expected.content then return false end
				files[path] = content
				writes[#writes + 1] = path
				return true
			end,
		},
		capture = function() return { marker = runtime.marker } end,
		owned_paths = function()
			if controls.before_prepare then files.config = controls.before_prepare end
			return {}
		end,
		apply = function()
			runtime.marker = "candidate"
			if controls.external_edit then files.config = controls.external_edit end
			if controls.reenter then controls.reentered = controls.owner.apply("shortcuts", "clear") end
			if controls.throw_apply then error("native apply refused after mutation") end
			return controls.apply_result == nil and true or controls.apply_result
		end,
		restore = function(snapshot)
			if controls.refuse_restore then return false end
			runtime.marker = snapshot.marker
			return true
		end,
	}
	local owner = require("infra.preferences_scope").new(options)
	controls.owner = owner
	return owner, files, writes, runtime, controls, original, Actions, Gestures, options
end

helpers.describe("macOS scoped preference table owner", function()
	helpers.it("restores and clears the exact inline parameter table without dropping other domains or unknown data", function()
		for _, mode in ipairs({ "clear", "recommended" }) do
			local owner, files, writes, _, _, original, Actions = fixture()
			local ok, detail = owner.apply("gestures", mode)
			helpers.assert_eq(ok, true, detail)
			local decoded = Codec.decode(files.config)
			helpers.assert_eq(decoded.gestures.action_parameters.tap_4__open_url, nil)
			helpers.assert_eq(decoded.gestures.action_parameters.keyboard__cmd_k__open_url, "https://example.com")
			helpers.assert_eq(decoded.gestures.action_parameters.unknown.value, 7)
			helpers.assert_eq(decoded.future.value, "preserve")
			helpers.assert_eq(files.backup, original)
			helpers.assert_eq(#writes, 2)
			helpers.assert_eq(Actions.get_action_parameter("tap_4", "open_url"), "")
			helpers.assert_eq(Actions.get_action_parameter("keyboard__cmd_k", "open_url"), "https://example.com")
		end
	end)
	helpers.it("handles the equivalent nested parameter table without rewriting its unknown siblings", function()
		local original = '[gestures.action_parameters]\ntap_4__open_url = "https://apple.com"\nunknown = "preserve"\n'
		local owner, files = fixture(original)
		local ok, detail = owner.apply("gestures", "clear")
		helpers.assert_eq(ok, true, detail)
		helpers.assert_eq(files.config, '[gestures.action_parameters]\nunknown = "preserve"\n')
	end)
	helpers.it("removes an exhausted inline table instead of writing an empty placeholder", function()
		local owner, files = fixture('[gestures]\naction_parameters = { tap_4__open_url = "https://apple.com" }\n')
		helpers.assert_eq(owner.apply("gestures", "clear"), true)
		helpers.assert_eq(Codec.decode(files.config).gestures.action_parameters, nil)
	end)
	helpers.it("refuses unreadable or malformed parameter tables before backup and native mutation", function()
		for _, source in ipairs({ '[gestures]\naction_parameters = 7\n', '[gestures]\naction_parameters = ["invalid"]\n' }) do
			local owner, files, writes, runtime, _, original = fixture(source)
			helpers.assert_eq(owner.apply("gestures", "clear"), false)
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(#writes, 0)
			helpers.assert_eq(runtime.marker, "original")
		end
	end)
	helpers.it("compensates both runtime owners after a refused conditional publication", function()
		local owner, files, _, runtime, controls, original, Actions = fixture()
		controls.refuse = "config"
		helpers.assert_eq(owner.apply("gestures", "clear"), false)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(runtime.marker, "original")
		helpers.assert_eq(Actions.get_action_parameter("tap_4", "open_url"), "https://apple.com")
		helpers.assert_eq(owner.pending(), false)
	end)
	helpers.it("refuses a stale preparation snapshot, unreadable source and unavailable runtime inventory", function()
		for _, failure in ipairs({ "before_prepare", "unreadable", "inventory" }) do
			local owner, files, writes, runtime, controls, original, _, Gestures = fixture()
			if failure == "inventory" then Gestures.get_all_action_parameters = function() return nil end
			elseif failure == "before_prepare" then controls.before_prepare = '[future]\nvalue = "external"\n'
			else controls.unreadable = true end
			helpers.assert_eq(owner.apply("gestures", "clear"), false)
			helpers.assert_eq(files.config, controls.before_prepare or original)
			helpers.assert_eq(#writes, 0)
			helpers.assert_eq(runtime.marker, "original")
			helpers.assert_eq(owner.pending(), false)
		end
	end)
	helpers.it("the shared preparation port requires a terminal result and an exact valid candidate", function()
		for _, result in ipairs({ "accepted", true }) do
			local _, files, writes, runtime, _, original, _, _, options = fixture()
			options.manifest = require("infra.manifest_reader")
			local candidate = result == true and "[invalid" or '[gestures]\nfuture = "preserve"\n'
			options.prepare_batch = function() return result, nil, candidate, { status = "ok", content = original } end
			local owner = require("config_scope_transaction").new(options)
			helpers.assert_eq(owner.apply("gestures", "clear"), false)
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(#writes, 0)
			helpers.assert_eq(runtime.marker, "original")
		end
	end)
	helpers.it("retains compensation debt and rejects another operation until terminal restoration", function()
		local owner, files, _, runtime, controls, original = fixture()
		controls.throw_apply, controls.refuse_restore = true, true
		helpers.assert_eq(owner.apply("gestures", "clear"), false)
		helpers.assert_eq(owner.pending(), true)
		helpers.assert_eq(owner.apply("shortcuts", "clear"), false)
		helpers.assert_eq(files.config, original)
		controls.refuse_restore = false
		helpers.assert_eq(owner.retry_restore(), true)
		helpers.assert_eq(runtime.marker, "original")
		helpers.assert_eq(owner.pending(), false)
	end)
	helpers.it("preserves an external edit and refuses truthy nonterminal runtime acknowledgement", function()
		local owner, files, _, runtime, controls, _, Actions = fixture()
		controls.external_edit = '[future]\nvalue = "external"\n'
		helpers.assert_eq(owner.apply("gestures", "clear"), false)
		helpers.assert_eq(files.config, controls.external_edit)
		helpers.assert_eq(runtime.marker, "original")
		helpers.assert_eq(Actions.get_action_parameter("tap_4", "open_url"), "https://apple.com")
		local second, source, writes, _, control, original = fixture()
		control.apply_result = "accepted"
		helpers.assert_eq(second.apply("gestures", "clear"), false)
		helpers.assert_eq(source.config, original)
		helpers.assert_eq(#writes, 1)
	end)
	helpers.it("refuses reentrancy without changing the selected domain and refuses preset scopes", function()
		local owner, files, _, _, controls, _, Actions = fixture()
		controls.reenter = true
		helpers.assert_eq(owner.apply("gestures", "clear"), true)
		helpers.assert_eq(controls.reentered, false)
		helpers.assert_eq(Actions.get_action_parameter("keyboard__cmd_k", "open_url"), "https://example.com")
		local second, _, writes = fixture()
		helpers.assert_eq(second.apply("global", "clear"), false)
		helpers.assert_eq(#writes, 0)
		helpers.assert_not_nil(Codec.decode(files.config).gestures.action_parameters.unknown)
	end)
	helpers.it("the live gesture facade exposes the exact parameter snapshot and replacement owner", function()
		local _, _, _, _, _, _, Actions, Gestures = fixture()
		helpers.assert_eq(Gestures.split_action_parameter_key, Actions.split_action_parameter_key)
		helpers.assert_eq(Gestures.replace_action_parameters, Actions.replace_action_parameters)
		local snapshot = Actions.get_all_action_parameters()
		helpers.assert_eq(Actions.replace_action_parameters({ tap_4__open_url = false }), false)
		helpers.assert_eq(Actions.get_all_action_parameters(), snapshot)
		helpers.assert_eq(Actions.replace_action_parameters(snapshot), true)
		snapshot.tap_4__open_url = "mutated"
		helpers.assert_eq(Actions.get_action_parameter("tap_4", "open_url"), "https://apple.com")
	end)
end)
