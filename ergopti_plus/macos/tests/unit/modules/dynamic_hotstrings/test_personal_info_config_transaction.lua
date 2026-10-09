--- tests/unit/modules/dynamic_hotstrings/test_personal_info_config_transaction.lua

--- ==============================================================================
--- MODULE: Personal Information Configuration Transaction Regressions
--- DESCRIPTION:
--- Exercises real startup and save paths with scoped filesystem boundaries.
--- Invalid declared data must never become defaults authorized for publication.
--- ==============================================================================

local helpers = require('tests.helpers')
local modules = {
	'modules.dynamic_hotstrings.personal_info', 'adapters.file_system',
	'infra.logger', 'adapters.synthetic_input', 'ui.personal_info_editor',
	'modules.keylogger',
	'infra.manifest_reader', 'infra.personal_info_fields',
}
local function with_subject(content, run)
	helpers.with_fresh_modules(modules, function()
		local state = { content = content, writes = 0, registrations = 0, logs = {}, refreshes = 0 }
		package.loaded['adapters.file_system'] = {
			read_with_status = function() return state.content, 'ok' end,
			write_if_unchanged = function(_, value, expected)
				if expected.content ~= state.content then return false end
				state.writes = state.writes + 1
				state.content = value
				return true
			end,
		}
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ 'debug', 'info', 'warn', 'error', 'start', 'success' }) do
			logger[level] = function(_, format, ...)
				state.logs[#state.logs + 1] = string.format(format, ...)
			end
		end
		package.loaded['infra.logger'] = logger
		package.loaded['adapters.synthetic_input'] = {}
		package.loaded['ui.personal_info_editor'] = {}
		package.loaded['modules.keylogger'] = {}
		local subject = require('modules.dynamic_hotstrings.personal_info')
		local keymap = {
			get_trigger_char = function() return '@' end,
			register_interceptor = function() state.registrations = state.registrations + 1 end,
			register_preview_provider = function() state.registrations = state.registrations + 1 end,
			invalidate_hotstring_preview = function() return true end,
		}
		local function start()
			return subject.start('', keymap, '/virtual/personal_info.toml', function(_, publish)
				state.refreshes = state.refreshes + 1
				return publish()
			end)
		end
		local ok, err = xpcall(function() run(subject, state, start) end, debug.traceback)
		subject.stop()
		if not ok then error(err, 0) end
	end)
end
helpers.describe('personal-info configuration transactions', function()
	helpers.it('(personal-config-conflict) refuses an invalid external winner without adopting defaults', function()
		with_subject('[info]\nfirst_name = "Original"\nlast_name = "Unchanged"', function(subject, state, start)
			helpers.assert_eq(start(), true)
			local live = subject.get_info()
			local malformed = '[info]\nfirst_name = "PRIVATE-Alice\\q"'
			state.content = malformed
			helpers.assert_eq(subject.save_info({ last_name = 'Attempt' }), false)
			helpers.assert_eq(state.refreshes, 1)
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(state.content, malformed)
			helpers.assert_true(subject.get_info() == live)
			helpers.assert_eq(live.first_name, 'Original')
			helpers.assert_eq(live.last_name, 'Unchanged')
			helpers.assert_true(not table.concat(state.logs, '\n'):find('PRIVATE-Alice', 1, true))
			state.content = '[info]\nfirst_name = "Repaired"\nlast_name = "External"'
			helpers.assert_eq(subject.save_info({ last_name = 'Attempt' }), false)
			helpers.assert_eq(state.refreshes, 3)
			helpers.assert_eq(state.writes, 0)
			helpers.assert_true(subject.get_info() == live)
			helpers.assert_eq(live.first_name, 'Repaired')
			helpers.assert_eq(live.last_name, 'External')
			helpers.assert_eq(subject.save_info({ last_name = 'Retried' }), true)
			helpers.assert_eq(state.writes, 1)
		end)
	end)
	for index, case in ipairs({
		{ [[first_name = 'PRIVATE-Alice']], 'PRIVATE-Alice' },
		{ [[first_name = "PRIVATE-Alice" # comment]], 'PRIVATE-Alice' },
		{ [[first_name = "PRIVATE-Alice\"B"]], 'PRIVATE-Alice"B' },
		{ 'first_name = """PRIVATE-Alice\nB"""', 'PRIVATE-Alice\nB' },
		{ [[first_name = ""]], '' },
	}) do
		helpers.it('(personal-config-value) preserves known field syntax ' .. index, function()
			with_subject('[info]\n' .. case[1], function(subject, state, start)
				helpers.assert_eq(start(), true)
				helpers.assert_eq(subject.get_info().first_name, case[2])
				helpers.assert_eq(subject.save_info({ last_name = 'Updated' }), true)
				helpers.assert_eq(state.writes, 1)
				local decoded = require('toml_codec.codec').decode(state.content)
				helpers.assert_eq(decoded.info.first_name, case[2])
				helpers.assert_eq(decoded.info.last_name, 'Updated')
			end)
		end)
	end
	for index, content in ipairs({
		'[info]\nfirst_name = "PRIVATE-Alice\\q"',
		'[info]\nfirst_name = "PRIVATE-Alice',
		'[info]\nfirst_name = "PRIVATE-Alice"\nfirst_name = "Duplicate"',
		'[info]\nfirst_name = false',
		'info = false',
		'info = [1]',
		'[letters]\np = 42',
	}) do
		helpers.it('(personal-config-refusal) rejects invalid declared data ' .. index, function()
			with_subject(content, function(subject, state, start)
				helpers.assert_eq(start(), false)
				helpers.assert_eq(state.registrations, 0)
				helpers.assert_eq(subject.save_info({ last_name = 'Updated' }), false)
				helpers.assert_eq(state.writes, 0)
				helpers.assert_eq(state.content, content)
				helpers.assert_true(not table.concat(state.logs, '\n'):find('PRIVATE-Alice', 1, true))
				state.content = '[info]\nfirst_name = "Repaired"'
				helpers.assert_eq(start(), true)
				helpers.assert_eq(subject.get_info().first_name, 'Repaired')
			end)
		end)
	end
end)
