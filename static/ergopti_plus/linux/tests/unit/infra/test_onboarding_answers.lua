--- tests/unit/infra/test_onboarding_answers.lua

--- ==============================================================================
--- MODULE: Onboarding Answers (Linux)
--- DESCRIPTION:
--- Runs the shared onboarding answers contract against the Linux manifest under
--- the Linux runner (LuaJIT in CI): the wizard catalogue names only paths this
--- driver declares, the finish payload becomes sparse manifest rows or is
--- refused whole, and the commit publishes one versioned batch.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.onboarding_answers_contract").register(helpers, { driver = "linux" })

require("test.onboarding_publication_contract").register(helpers)


helpers.describe("Linux wizard retained native publication phases", function()
	helpers.it("defers and retains exact scalar rollback after native cleanup, without replaying accepted phases", function()
		local saved = package.loaded["ui.onboarding.bridge"]
		package.loaded["ui.onboarding.bridge"] = nil
		local settled, cleanup_calls, forward_calls = false, 0, 0
		local locale, directory, path_rollbacks, locale_rollbacks = "en", "/before", 0, 0
		local refuse_locale_inverse = true
		local state = {
			manifest = require("infra.manifest_reader"),
			file_system = { read_with_status = function() return nil, "absent" end },
			i18n = {
				get_locale = function() return locale end,
				list_locales = function() return { "en", "fr" } end,
				get = function(key) return key end,
				persist_locale = function(value) locale = value; return true end,
				set_locale = function(value)
					locale_rollbacks = locale_rollbacks + 1
					if refuse_locale_inverse then return false end
					locale = value; return true
				end,
			},
			config_paths = {
				get_config_dir = function() return directory end,
				default_config_dir = function() return "/before" end,
				set_config_dir = function(value)
					if value == "/before" then path_rollbacks = path_rollbacks + 1 end
					directory = value; return true
				end,
			},
			prepare_destination = function() return true end,
			writer = { batch_write = function()
				forward_calls = forward_calls + 1
				return false, "release pending", nil, function()
					cleanup_calls = cleanup_calls + 1
					return settled, nil, false
				end, "[gestures]\nenabled = true\n"
			end },
			notify_error = function() end,
		}
		local ok, detail = xpcall(function()
			local bridge = require("ui.onboarding.bridge")
			local answers = { locale = "fr", config_dir = "/after",
				operations = { { path = "gestures.enabled", value = true } } }
			helpers.assert_eq(bridge.on_message({ action = "finish", answers = answers }, state), { done = false })
			helpers.assert_eq(forward_calls, 1)
			helpers.assert_eq(cleanup_calls, 1)
			helpers.assert_eq(path_rollbacks, 0, "no scalar inverse precedes refused native release")
			helpers.assert_eq(locale_rollbacks, 0)
			settled = true
			helpers.assert_eq(bridge.on_message({ action = "finish", answers = answers }, state), { done = false })
			helpers.assert_eq(path_rollbacks, 1)
			helpers.assert_eq(locale_rollbacks, 1)
			helpers.assert_eq(forward_calls, 1)
			helpers.assert_eq(bridge.on_message({ action = "ready" }, state), { pushed = false })
			helpers.assert_eq(path_rollbacks, 1, "an acknowledged directory inverse must not repeat")
			helpers.assert_eq(locale_rollbacks, 2)
			helpers.assert_eq(cleanup_calls, 2, "an acknowledged native release must not repeat")
			refuse_locale_inverse = false
			state.writer.batch_write = function() forward_calls = forward_calls + 1; return true end
			helpers.assert_eq(bridge.on_message({ action = "finish", answers = answers }, state), { done = false },
				"replacing the held native writer cannot acquire the previous inverse")
			helpers.assert_eq(forward_calls, 1)
		end, debug.traceback)
		package.loaded["ui.onboarding.bridge"] = saved
		if not ok then error(detail, 0) end
	end)
end)


--- Drives the actual native Finish entry with a controlled no-effect publisher.
local function with_receiving_boundary(scenario)
	local saved = package.loaded["ui.onboarding.bridge"]
	package.loaded["ui.onboarding.bridge"] = nil
	local f = { locale = "en", directory = "/before", writes = 0, cleanups = 0,
		path_rollbacks = 0, locale_rollbacks = 0, settled = false }
	local answers = { locale = "fr", config_dir = "/after",
		operations = { { path = "gestures.enabled", value = true } } }
	local state = {
		manifest = require("infra.manifest_reader"), layout = "qwerty",
		file_system = { read_with_status = function() return nil, "absent" end },
		i18n = {
			get_locale = function() if f.getter_failure then error("locale observer refused") end; return f.locale end,
			list_locales = function()
				if f.validation_callback then f.validation_callback() end
				return { "en", "fr" }
			end,
			get = function(key) return key end,
			persist_locale = function(value) f.locale = value; return true end,
			set_locale = function(value) f.locale_rollbacks = f.locale_rollbacks + 1; f.locale = value; return true end,
		},
		config_paths = {
			get_config_dir = function() if f.getter_failure then error("path observer refused") end; return f.directory end,
			default_config_dir = function() return "/before" end,
			config = function(rel) return f.directory .. "/" .. rel end,
			data = function(rel) return "/virtual/data/" .. rel end,
			metrics_path = function() return "/virtual/data/metrics.sqlite" end,
			set_config_dir = function(value)
				if value == "/before" then f.path_rollbacks = f.path_rollbacks + 1 end
				f.directory = value
				if value == "/before" and f.path_inverse_reply ~= nil then return f.path_inverse_reply end
				return true
			end,
		},
		prepare_destination = function() return true end,
		writer = { batch_write = function(_, _, _, source)
			f.writes = f.writes + 1
			helpers.assert_eq(source, { status = "absent" })
			if f.writes > 1 then return true end
			if f.write_callback then f.write_callback() end
			return false, "release pending", nil, function()
				f.cleanups = f.cleanups + 1
				return f.settled, nil, false
			end, "[gestures]\nenabled = true\n"
		end },
		webview_manager = { hide = function() return true end },
		restart = function() return true end,
		notify_error = function() end,
	}
	local called, detail = xpcall(function()
		f.bridge, f.state, f.answers = require("ui.onboarding.bridge"), state, answers
		f.finish = function() return f.bridge.on_message({ action = "finish", answers = answers }, state) end
		return scenario(f)
	end, debug.traceback)
	package.loaded["ui.onboarding.bridge"] = saved
	if not called then error(detail, 0) end
end

helpers.describe("Linux wizard validation and scalar successor authority", function()
	helpers.it("retains a scalar inverse whose host returns a nonliteral acknowledgment", function()
		with_receiving_boundary(function(f)
			helpers.assert_eq(f.finish(), { done = false })
			f.settled, f.path_inverse_reply = true, "confirmed"
			helpers.assert_eq(f.finish(), { done = false })
			helpers.assert_eq(f.writes, 1, "a textual acknowledgment cannot authorize a fresh transaction")
			helpers.assert_eq(f.path_rollbacks, 1)
			helpers.assert_eq(f.locale_rollbacks, 1)
			f.path_inverse_reply = nil
			helpers.assert_eq(f.finish(), { done = true, restarted = true })
			helpers.assert_eq(f.path_rollbacks, 2, "only the unacknowledged inverse retries")
			helpers.assert_eq(f.locale_rollbacks, 1, "an acknowledged sibling phase must not repeat")
			helpers.assert_eq(f.cleanups, 2)
		end)
	end)

	helpers.it("claims the initial validation stack before locale discovery can publish a nested request", function()
		with_receiving_boundary(function(f)
			local once, nested, ready = false, nil, nil
			f.validation_callback = function()
				if once then return end
				once = true
				nested = f.finish()
				ready = f.bridge.on_message({ action = "ready" }, f.state)
			end
			helpers.assert_eq(f.finish(), { done = false })
			helpers.assert_eq(nested, { done = false })
			helpers.assert_eq(ready, { pushed = false })
			helpers.assert_eq(f.writes, 1, "a nested validation callback cannot replace a publication owner")
			helpers.assert_eq(f.cleanups, 1)
			helpers.assert_eq(f.path_rollbacks, 0)
		end)
	end)

	helpers.it("does not adopt a native writer's foreign scalar successor as rollback authority", function()
		with_receiving_boundary(function(f)
			f.write_callback = function() f.directory, f.locale = "/foreign", "de" end
			helpers.assert_eq(f.finish(), { done = false })
			f.settled = true
			helpers.assert_eq(f.finish(), { done = false })
			helpers.assert_eq(f.directory, "/foreign")
			helpers.assert_eq(f.locale, "de")
			helpers.assert_eq(f.path_rollbacks, 0)
			helpers.assert_eq(f.locale_rollbacks, 0)
			helpers.assert_eq(f.writes, 1)
			f.directory, f.locale = "/after", "fr"
			helpers.assert_eq(f.finish(), { done = true, restarted = true })
			helpers.assert_eq(f.path_rollbacks, 1)
			helpers.assert_eq(f.locale_rollbacks, 1)
			helpers.assert_eq(f.cleanups, 2, "recovery does not repeat acknowledged native release")
		end)
	end)

	helpers.it("retains scalar compensation when its native getters throw after publication refuses", function()
		with_receiving_boundary(function(f)
			f.write_callback = function() f.getter_failure = true end
			helpers.assert_eq(f.finish(), { done = false })
			f.settled = true
			helpers.assert_eq(f.finish(), { done = false })
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.path_rollbacks, 0)
			helpers.assert_eq(f.locale_rollbacks, 0)
			f.getter_failure = false
			helpers.assert_eq(f.finish(), { done = true, restarted = true })
			helpers.assert_eq(f.path_rollbacks, 1)
			helpers.assert_eq(f.locale_rollbacks, 1)
			helpers.assert_eq(f.cleanups, 2)
		end)
	end)
end)

helpers.describe("Linux wizard unchanged forward refusal", function()
	helpers.it("does not invent scalar debt when a refusing forward folder owner left its snapshot unchanged", function()
		with_receiving_boundary(function(f)
			local original = f.state.config_paths.set_config_dir
			local refused_calls = 0
			f.state.config_paths.set_config_dir = function()
				refused_calls = refused_calls + 1
				return false
			end
			helpers.assert_eq(f.finish(), { done = false })
			helpers.assert_eq(refused_calls, 1, "an unchanged directory requires no second refused mutation")
			helpers.assert_eq(f.directory, "/before")
			helpers.assert_eq(f.locale, "en", "the changed locale still receives its actual inverse")
			helpers.assert_eq(f.locale_rollbacks, 1)
			helpers.assert_eq(f.writes, 0)
			f.state.config_paths.set_config_dir = original
			helpers.assert_eq(f.finish(), { done = false }, "the fresh transaction reaches its genuine retained release")
			helpers.assert_eq(f.writes, 1)
			helpers.assert_eq(f.cleanups, 1)
		end)
	end)
end)
