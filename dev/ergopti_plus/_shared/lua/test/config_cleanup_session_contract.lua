--- _shared/lua/test/config_cleanup_session_contract.lua

--- Exercises the real cleanup engine through the shared page-session contract.
local M = {}

function M.register(helpers)
	local Session = require("config_cleanup_session")
	local Engine = require("config_unused_keys")
	local Codec = require("toml_codec")
	local function fixture(count)
		local lines = { '[script]', 'locale = "en"', '[obsolete]' }
		for index = 1, count do lines[#lines + 1] = "setting_" .. index .. ' = "old"' end
		local path, source = "/trusted/config.toml", table.concat(lines, "\n") .. "\n"
		local context = { files = { [path] = source }, backups = 0, writes = 0, reads = 0 }
		local options = {
			path = path, stamp = "20260928_120000",
			collect = function(_, mark) mark("script", "locale") end,
			read = function(target)
				context.reads = context.reads + 1
				return context.files[target], context.files[target] and "ok" or "absent"
			end,
			create_backup = function(target, content)
				context.backups = context.backups + 1
				if context.on_backup then context.on_backup() end
				if context.refuse_backup or context.files[target] then return false, "backup refused" end
				context.files[target] = content
				return true
			end,
			publish = function(target, content, expected)
				helpers.assert_eq(target, path)
				helpers.assert_eq(expected.content, context.files[path])
				context.writes = context.writes + 1
				context.files[target] = content
				return true
			end,
		}
		return Session.new(options), context, options, source
	end

	helpers.describe("shared configuration cleanup session", function()
		helpers.it("opens without scanning and cancellation makes every later request inert", function()
			local session, context, options, source = fixture(3)
			helpers.assert_eq(context.reads, 0)
			local preview = session:handle("ready")
			session:handle({ action = "close", session = preview.session })
			helpers.assert_eq(session:handle("ready"), nil)
			helpers.assert_eq(session:handle({ action = "clean", session = preview.session }), nil)
			helpers.assert_eq(context.files[options.path], source)
			helpers.assert_eq(context.backups, 0)
			helpers.assert_eq(context.writes, 0)
		end)
		helpers.it("exposes all eighty rows and refuses a changed source before creating any backup", function()
			local session, context, options, source = fixture(80)
			local preview = session:handle("ready")
			helpers.assert_eq(preview.status, "ready")
			helpers.assert_eq(#preview.keys, 80)
			context.files[options.path] = source .. 'added_later = true\n'
			local result = session:handle({ action = "clean", session = preview.session })
			helpers.assert_eq(result.status, "changed")
			helpers.assert_eq(context.backups, 0)
			helpers.assert_eq(context.writes, 0)
		end)
		helpers.it("requires refresh after a change, then publishes one cleanup and an exact backup", function()
			local session, context, options, source = fixture(80)
			local token = session:handle("ready").session
			context.files[options.path] = source .. 'added_later = true\n'
			local changed_source = context.files[options.path]
			session:handle({ action = "clean", session = token })
			helpers.assert_eq(session:handle({ action = "clean", session = token }), nil)
			helpers.assert_eq(#session:handle({ action = "refresh", session = token }).keys, 81)
			local result = session:handle({ action = "clean", session = token })
			helpers.assert_eq(result.status, "removed")
			helpers.assert_eq(result.removed, 81)
			helpers.assert_eq(#result.keys, 0)
			helpers.assert_eq(context.files[result.backup], changed_source)
			helpers.assert_eq(Codec.decode(context.files[options.path]).script.locale, "en")
			helpers.assert_eq(session:handle({ action = "clean", session = token }), nil)
			helpers.assert_eq(context.writes, 1)
			helpers.assert_eq(context.backups, 1)
		end)
		helpers.it("ignores a stale token and never adopts browser supplied paths or deletion targets", function()
			local session, context, options = fixture(3)
			local token = session:handle("ready").session
			helpers.assert_eq(session:handle({ action = "clean", session = token .. "old" }), nil)
			helpers.assert_eq(context.writes, 0)
			local result = session:handle({ action = "clean", session = token, path = "/forged/config.toml",
				keys = { { section = "script", key = "locale" } } })
			helpers.assert_eq(result.removed, 3)
			helpers.assert_eq(context.files["/forged/config.toml"], nil)
			helpers.assert_eq(Codec.decode(context.files[options.path]).script.locale, "en")
		end)
		helpers.it("reports a failed backup and leaves the exact original source unchanged", function()
			local session, context, options, source = fixture(3)
			context.refuse_backup = true
			local token = session:handle("ready").session
			local result = session:handle({ action = "clean", session = token })
			helpers.assert_eq(result.status, "failed")
			helpers.assert_eq(result.reason_key, "dialog.unused_keys.reason.backup")
			helpers.assert_eq(context.files[options.path], source)
			helpers.assert_eq(context.writes, 0)
		end)
		helpers.it("refuses a reentrant clean while the first transaction owns publication", function()
			local session, context = fixture(3)
			local token = session:handle("ready").session
			local attempted = false
			context.on_backup = function()
				attempted = true
				helpers.assert_eq(session:handle({ action = "clean", session = token }), nil)
			end
			helpers.assert_eq(session:handle({ action = "clean", session = token }).status, "removed")
			helpers.assert_eq(attempted, true)
			helpers.assert_eq(context.writes, 1)
		end)
		helpers.it("returns a failed page state when scanning raises", function()
			local session, _, options = fixture(3)
			options.collect = function() error("reader unavailable") end
			local ok, state = pcall(session.handle, session, "ready")
			helpers.assert_eq(ok, true)
			helpers.assert_eq(state.status, "failed")
		end)
		helpers.it("returns a failed page state when the cleanup engine raises", function()
			local session = fixture(3)
			local token, original = session:handle("ready").session, Engine.remove
			Engine.remove = function() error("unexpected removal failure") end
			local ok, state = pcall(session.handle, session, { action = "clean", session = token })
			Engine.remove = original
			helpers.assert_eq(ok, true)
			helpers.assert_eq(state.status, "failed")
		end)
		helpers.it("keeps the published result truthful when preference adoption raises", function()
			local session, context, options, source = fixture(3)
			options.on_removed = function() error("baseline adoption unavailable") end
			local token = session:handle("ready").session
			local result = session:handle({ action = "clean", session = token })
			helpers.assert_eq(result.status, "removed", "publication succeeded before adoption failed")
			helpers.assert_eq(context.writes, 1)
			helpers.assert_eq(context.files[result.backup], source)
			helpers.assert_eq(Codec.decode(context.files[options.path]).obsolete, nil)
		end)
	end)
end

return M
