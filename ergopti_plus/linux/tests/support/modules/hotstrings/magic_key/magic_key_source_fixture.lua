--- tests/support/modules/hotstrings/magic_key/magic_key_source_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_magic_key_source
--- DESCRIPTION:
--- Prelude shared by the test_magic_key_source_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local Json = require("json")

local Shared = require("keymap.magic_key_source")

local PATH = "hotstrings.magic_key_source"

local KEY_J = 36

local KEY_C = 46

local function registry()
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/data/keycodes/physical_keys.json", "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

require("test.magic_key_source_contract")(helpers, Shared, {
	entry = require("infra.manifest_reader").find_entry_by_path(PATH),
	registry = registry(),
	field = "evdev",
})

--- Runs body against fresh owners whose config.toml is a private file.
--- @param content string|nil Initial config.toml; nil is an absent file.
--- @param body function body(Source, Preferences, path)
local function with_source(content, body)
	local saved = {
		preferences = package.loaded["infra.hotstring_preferences"],
		source = package.loaded["modules.hotstrings.magic_key_source"],
	}
	local path = string.format("%s/ergopti_magic_key_source_%d_%d.toml",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	if content then
		local handle = assert(io.open(path, "w"))
		handle:write(content)
		handle:close()
	end
	local ok, err = pcall(function()
		package.loaded["modules.hotstrings.magic_key_source"] = nil
		local Preferences = helpers.load_module("infra.hotstring_preferences")
		assert(Preferences._set_file_for_test(path))
		body(require("modules.hotstrings.magic_key_source"), Preferences, path)
	end)
	package.loaded["infra.hotstring_preferences"] = saved.preferences
	package.loaded["modules.hotstrings.magic_key_source"] = saved.source
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

--- Wires the owner to recording collaborators.
--- @param Source table
--- @param state table { active, replace, typed_ok, grab, typable } switches the test flips.
--- @param end_selection function|nil The selection window's end; counted when nil.
--- @return table calls { typed = {}, dispatched = {}, deferred = {}, ended = 0 }
local function wire(Source, state, end_selection)
	local calls = { typed = {}, dispatched = {}, deferred = {}, ended = 0 }
	Source.init({
		end_selection = end_selection or function() calls.ended = calls.ended + 1 end,
		is_active = function() return state.active end,
		replace_on = function() return state.replace end,
		magic_key = function() return state.magic or "★" end,
		can_type = function(text) return text == (state.magic or "★") and state.typable ~= false end,
		typing_plan = function() return state.plan end,
		input_source_receipt = function() return state.origin or { generation = 1, ready = true } end,
		direct_source_admitted = function(code) return state.blocked_code ~= code end,
		type_text = function(text)
			calls.typed[#calls.typed + 1] = text
			return state.typed_ok
		end,
		dispatch_char = function(char, code)
			calls.dispatched[#calls.dispatched + 1] = { char = char, code = code }
		end,
		can_capture = function() return state.grab ~= false end,
		key_text = function(code) return code == KEY_J and "j" or nil end,
		defer = function(fn, delay_ms)
			calls.deferred[#calls.deferred + 1] = { fn = fn, delay_ms = delay_ms }
			if delay_ms == 0 then
				if state.answer == "throw" then error("Controlled answer queue refusal") end
				if state.answer == "premature" then fn() end
				if state.answer == "refuse" then return false end
				if state.answer_pause then state.answer_pause() end
			end
			return true
		end,
	})
	return calls
end

--- Runs the deferred work queued with no delay, as the next loop tick would.
local function run_due(calls)
	for _, entry in ipairs(calls.deferred) do
		if entry.delay_ms == 0 and not entry.ran then
			entry.ran = true
			entry.fn()
		end
	end
end

--- Runs actual Capture and Layout owners through the caller's later callbacks.
--- The native protocol is controlled and supplies no physical delivery authority.
--- @param body function
local function caller_cohort(body)
	local saved_capture = package.loaded["adapters.xkb_capture"]
	local saved_layout = package.loaded["adapters.keyboard_layout"]
	local capture = helpers.load_module("adapters.xkb_capture")
	local state = { group = 0, native_epoch = 7, observed = true, origin = { generation = 1, ready = true } }
	local backend = {
		create = function() return { identity = "caller-source-map", groups = 2 } end,
		destroy = function() end,
		capture_group = function()
			if state.on_group then local fn = state.on_group; state.on_group = nil; fn() end
			return state.group
		end,
		source_group = function()
			if state.on_source then local fn = state.on_source; state.on_source = nil; fn() end
			local group, epoch = state.group, state.native_epoch
			return group, epoch, function() return state.observed and state.group == group and state.native_epoch == epoch end
		end,
		direct_sources = function(_, _, group)
			return { { code = 39, text = group == 0 and ";" or "ù", mods = {}, plain = true, direct = true, dead = false } }
		end,
		inverse = function()
			local rows = {}
			for code = 32, 126 do rows[string.char(code)] = { keycode = code, level = 1, mods = {} } end
			rows[";"] = { keycode = 39, level = 1, mods = {} }
			return rows
		end,
	}
	capture._set_backend(backend)
	local path = os.tmpname()
	local file = assert(io.open(path, "w")); file:write("caller-source-map"); file:close()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local called, detail = pcall(function()
		helpers.assert_true(layout.refresh(path))
		with_source(nil, function(Source, Preferences)
			local deps = {
				is_active = function() return true end, replace_on = function() return true end,
				magic_key = function() return ";" end,
				can_type = function(text) return layout.resolve(text) ~= nil end,
				typing_plan = function(text)
					if state.on_plan then state.on_plan(Source, Preferences, layout, path) end
					return layout.resolve(text)
				end,
				input_source_receipt = function() return state.origin end,
				direct_source_admitted = function()
					if state.on_admit then state.on_admit(Source, Preferences) end
					return true
				end,
				type_text = function() error("read-only source must not emit") end,
				dispatch_char = function() error("read-only source must not dispatch") end,
				end_selection = function() end, can_capture = function() return true end,
				key_text = function() return ";" end, defer = function() return false end,
			}
			Source.init(deps)
			body(Source, Preferences, capture, layout, state, path, deps)
		end)
	end)
	capture._reset_backend(); os.remove(path)
	package.loaded["adapters.xkb_capture"] = saved_capture
	package.loaded["adapters.keyboard_layout"] = saved_layout
	if not called then error(detail, 0) end
end

-- Native notice title policy does not own the physical source or its body.
local native_caption_file = assert(io.open(helpers.driver_root()
	.. "/../_shared/tests/corpus/native_presentations/original_captions.json", "rb"))

local native_caption_read, native_caption_bytes = pcall(function() return native_caption_file:read("*a") end)

local native_caption_closed, native_caption_close = pcall(function() return native_caption_file:close() end)

if not native_caption_read then error(native_caption_bytes, 0) end

assert(native_caption_closed and native_caption_close ~= nil and native_caption_close ~= false)

local native_caption_corpus = assert(Json.decode(native_caption_bytes))

local magic_notice_module_names = { "ui.menu.menu_builder", "infra.native_presentation", "adapters.application_notifier",
	"infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }

-- A caller catching an expected primary must also consume cleanup_failures.
-- Normal positive subjects fail on any cleanup refusal after all attempts finish.
local function with_magic_notice(body, cleanup_failures)
	cleanup_failures = cleanup_failures or {}
	local cache, saved = package.loaded, {}
	for _, name in ipairs(magic_notice_module_names) do saved[name] = rawget(cache, name) end
	local Locale, I18n, previous_locale, locale_captured, policy, lookup_owner, lookup_captured
	local function restore(operation, fn)
		local restored, failure = pcall(fn)
		if not restored then cleanup_failures[#cleanup_failures + 1] = { operation = operation, failure = failure } end
	end
	-- Protection starts before the first owned cache edit, including setup imports.
	local ok, failure = pcall(function()
		for _, name in ipairs(magic_notice_module_names) do rawset(cache, name, nil) end
		Locale, I18n = require("infra.locale"), require("infra.i18n")
		previous_locale = Locale.current_locale()
		locale_captured = true
		policy = require("window_titles")
		lookup_owner, lookup_captured = policy.native_presentation, true
		local notices = {}
		rawset(cache, "adapters.application_notifier", { send = function(message, options)
			notices[#notices + 1] = { message = message, title = options.title, level = options.level }
			return true
		end })
		with_source(nil, function(Source)
			local settled, primary = pcall(function()
				local calls = wire(Source, { active = true, replace = true, typed_ok = true })
				local Builder = require("ui.menu.menu_builder")
				local changed = 0
				local items = Builder.build({ on_quit = function() end, magic_key_source = Source,
					on_menu_changed = function() changed = changed + 1 end })
				local capture
				local function find(rows)
					for _, row in ipairs(rows or {}) do
						if row.title == I18n.get("menu.layout.magic_key_source.capture") then capture = row.fn end
						find(row.menu)
					end
				end
				find(items)
				helpers.assert_type(capture, "function", "actual physical capture command must exist")
				body({ source = Source, calls = calls, capture = capture, notices = notices,
					locale = Locale, i18n = I18n, changed = function() return changed end,
					policy = policy, native = require("infra.native_presentation") })
			end)
			-- The genuine reset returns nil; only a thrown failure is refusal here.
			restore("physical_source_reset", function() Source._reset_for_test() end)
			if not settled then error(primary, 0) end
		end)
	end)
	if lookup_captured then
		restore("native_policy_lookup", function()
			policy.native_presentation = lookup_owner
			assert(rawequal(policy.native_presentation, lookup_owner), "native policy lookup was not restored")
		end)
	end
	if locale_captured then
		restore("locale_selection", function()
			Locale.set_locale(previous_locale)
			assert(Locale.current_locale() == previous_locale, "fixture locale was not restored")
		end)
	end
	for _, name in ipairs(magic_notice_module_names) do
		restore("package.loaded:" .. name, function()
			rawset(cache, name, saved[name])
			assert(rawequal(rawget(cache, name), saved[name]), "fixture module cache was not restored")
		end)
	end
	if not ok then error(failure, 0) end
	if #cleanup_failures > 0 then error(cleanup_failures[1].failure, 0) end
end

local function magic_notice_cache_snapshot()
	local saved = {}
	for _, name in ipairs(magic_notice_module_names) do saved[name] = rawget(package.loaded, name) end
	return saved
end

local function assert_magic_notice_cache_restored(saved)
	for _, name in ipairs(magic_notice_module_names) do
		helpers.assert_true(rawequal(rawget(package.loaded, name), saved[name]), "exact original module restored: " .. name)
	end
end

--- Compiles the genuine daemon pause callback over explicit non-input ports.
--- The ScriptActions owner still executes its real toggle/notification path.
--- @param Source table Actual initialized magic-key owner.
--- @param state table Live activity observed by the recording input ports.
--- @return table controller Actual script-actions controller.
local function capture_pause_controller(Source, state)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = file:read("*a"); assert(file:close())
	local marker = "on_pause_change = function(paused)"
	local first, last = source:find(marker, 1, true)
	assert(first and last, "The genuine daemon pause callback must exist")
	local finish = assert(source:find("\n\t\tend,\n\t})", last + 1, true))
	local body = source:sub(last + 1, finish - 1)
	local callback = assert(load("return function(paused)" .. body .. "\nend", "genuine-daemon-pause", "t", {
		MagicKeySource = Source,
		keylogger = require("modules.keylogger.keylogger"),
		TapHold = { set_paused = function() end },
		package = { loaded = {} },
	}))()
	return require("modules.shortcuts.script_actions").new({
		reset = function() end, reload = function() end, quit = function() end,
		on_pause_change = function(paused)
			state.active = not paused
			callback(paused)
		end,
	})
end

--- Keeps the real cached preference owner and exact source route in one fixture.
local function with_collision_source(content, body)
	local saved = package.loaded["infra.config_paths"]
	local routed
	package.loaded["infra.config_paths"] = { config = function() return routed end }
	local ok, why = pcall(function()
		with_source(content, function(Source, Preferences, path)
			routed = path
			body(Source, Preferences, path)
		end)
	end)
	package.loaded["infra.config_paths"] = saved
	if not ok then error(why, 0) end
end

return {
	helpers = helpers,
	Json = Json,
	Shared = Shared,
	PATH = PATH,
	KEY_J = KEY_J,
	KEY_C = KEY_C,
	registry = registry,
	with_source = with_source,
	wire = wire,
	run_due = run_due,
	caller_cohort = caller_cohort,
	native_caption_file = native_caption_file,
	native_caption_read = native_caption_read,
	native_caption_bytes = native_caption_bytes,
	native_caption_closed = native_caption_closed,
	native_caption_close = native_caption_close,
	native_caption_corpus = native_caption_corpus,
	magic_notice_module_names = magic_notice_module_names,
	with_magic_notice = with_magic_notice,
	magic_notice_cache_snapshot = magic_notice_cache_snapshot,
	assert_magic_notice_cache_restored = assert_magic_notice_cache_restored,
	capture_pause_controller = capture_pause_controller,
	with_collision_source = with_collision_source,
}
