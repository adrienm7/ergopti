--- tests/unit/modules/llm/settings/test_profile_preferences_canonical_ordered_child_template.lua

package.loaded["tests.support.modules.llm.settings.profile_preferences_canonical_fixture"] = nil
local Fixture = require("tests.support.modules.llm.settings.profile_preferences_canonical_fixture")
local helpers, Sandbox, Toml, Json, Base64, with_idle_live_owner, with_config, profile =
	Fixture.helpers, Fixture.Sandbox, Fixture.Toml, Fixture.Json, Fixture.Base64, Fixture.with_idle_live_owner, Fixture.with_config, Fixture.profile




helpers.describe("ordered child template native list and conditional include contract", function()
	local function with_frame(body)
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_template_api.json"
		local Menu = assert(require("menu.renderer").new({
			platform = "linux",
			manifest_path = function() return path end,
			json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end },
			logger = helpers.make_logger_stub(),
		}))
		local handle = assert(io.open(path, "rb"))
		local oracle = require("json").decode(handle:read("*a")); handle:close()
		local state = { ready = true, present = true, calls = 0, phases = {} }
		local function native_action() state.calls = state.calls + 1; return false end
		local builtin = { label = "Builtin native", checked = true, action = native_action }
		local custom = { label = "Custom native", items = { { label = "Native child", action = native_action } } }
		local getters = {
			ready = function() return state.ready end,
			custom_present = function() state.phases[#state.phases + 1] = "custom_present"; return state.present end,
		}
		local children = {
			builtins = function(...) helpers.assert_eq(select("#", ...), 0); state.phases[#state.phases + 1] = "builtins"; return { builtin } end,
			customs = function(...) helpers.assert_eq(select("#", ...), 0); state.phases[#state.phases + 1] = "customs"; return { custom } end,
		}
		body(Menu, { create = native_action, clone = native_action }, getters, children, state, oracle._expected, builtin, custom)
	end
	local function shape(rows)
		local labels = {}
		for _, row in ipairs(rows) do labels[#labels + 1] = row.separator and "---" or row.label end
		return table.concat(labels, "|")
	end
	helpers.it("splices real canonical data lazily at declaration positions and selects exact command order", function()
		with_frame(function(Menu, commands, getters, children, state, expected, builtin, custom)
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), table.concat(expected.present, "|"))
			helpers.assert_eq(table.concat(state.phases, "|"), table.concat(expected.phases, "|"))
			helpers.assert_true(rawequal(rows[2], builtin))
			helpers.assert_true(rawequal(rows[5], custom))
			helpers.assert_true(rawequal(rows[5].items, custom.items))
			local rendered = Menu.render_rows(rows, "frame")
			helpers.assert_eq(rendered[2].checked, true)
			helpers.assert_eq(rendered[5].menu[1].fn(), false)
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2)
			state.ready = false
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2, "existing command readiness remains live")
			state.ready = true
			Menu.get_array("commands")[2].id = "withdrawn"
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2, "selected command declaration withdrawal is effect free")
		end)
	end)
	helpers.it("a false presence getter skips the whole fragment without calling its native list", function()
		with_frame(function(Menu, commands, getters, children, state, expected)
			state.present = false
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), table.concat(expected.absent, "|"))
			helpers.assert_eq(table.concat(state.phases, "|"), "builtins|custom_present")
			helpers.assert_eq(state.calls, 0)
		end)
	end)
	helpers.it("empty native lists remain valid and legacy whole-section includes retain their order", function()
		with_frame(function(Menu, commands, getters, children)
			children.builtins, children.customs = function() return {} end, function() return {} end
			Menu.get_array("frame")[4].row_id = nil
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), "menu.profiles.header_default_profiles|---|menu.profiles.header_custom_profiles|menu.profiles.create_profile|menu.profiles.clone_builtin|---|menu.profiles.create_profile")
		end)
	end)
	helpers.it("platform filtering hides a selected original command without invoking another command", function()
		with_frame(function(Menu, commands, getters, children, state)
			Menu.get_array("commands")[2].platforms = { "hs" }
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(#rows, 7)
			helpers.assert_eq(rows[7].label, "menu.profiles.create_profile")
			helpers.assert_eq(state.calls, 0)
		end)
	end)
	helpers.it("lazy group children run after native lists and the actual check getter", function()
		with_frame(function(Menu, commands, getters, children, state)
			local declaration = Menu.get_array("frame")
			declaration[#declaration + 1] = { type = "check", id = "auto", i18n = "menu.profiles.auto_detect", checked_when = { "auto_checked" } }
			declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides" }
			commands.auto = function() return false end
			getters.auto_checked = function() state.phases[#state.phases + 1] = "autodetect"; return true end
			local native = { label = "Native application", action = function() state.calls = state.calls + 1; return false end }
			children.apps = function(...)
				helpers.assert_eq(select("#", ...), 0)
				state.phases[#state.phases + 1] = "perapp"
				return { native }
			end
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(table.concat(state.phases, "|"), "builtins|custom_present|customs|autodetect|perapp")
			helpers.assert_eq(rows[9].checked, true)
			helpers.assert_true(rawequal(rows[10].items[1], native))
			local rendered = Menu.render_rows(rows, "native_phase_frame")
			helpers.assert_eq(rendered[10].menu[1].fn(), false)
			helpers.assert_eq(state.calls, 1)
		end)
	end)
	helpers.it("existing eager Array group identity and policy stay unchanged", function()
		with_frame(function(Menu, commands, getters, children)
			local declaration = Menu.get_array("frame")
			declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides", disabled_when = { "group_ready" } }
			local native = { { label = "Existing application", action = function() return false end } }
			children.apps = native
			getters.group_ready = function() return false end
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_true(rawequal(rows[9].items, native))
			helpers.assert_eq(rows[9].disabled, true)
			helpers.assert_nil(rows[9].action)
		end)
	end)
	local group_refusals = {
		{ "missing", function() return nil end },
		{ "noncallable", function() return true end },
		{ "throw", function() return function() error("per-app native read refused") end end },
		{ "wrongtype", function() return function() return false end end },
		{ "sparse", function() return function() return { [2] = { label = "gap" } } end end },
		{ "scalar child", function() return function() return { false } end end },
		{ "driver dialect", function() return function() return { { title = "wrong", fn = function() end } } end end },
		{ "missing label", function() return function() return { { action = function() end } } end end },
		{ "empty label", function() return function() return { { label = "" } } end end },
		{ "wrong separator type", function() return function() return { { label = "Native", separator = "true" } } end end },
	}
	for _, refusal in ipairs(group_refusals) do
		helpers.it("refuses lazy group " .. refusal[1] .. " without returning a partial frame", function()
			with_frame(function(Menu, commands, getters, children, state)
				local declaration = Menu.get_array("frame")
				declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides" }
				children.apps = refusal[2]()
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
	local refusals = {
		{ "missing list provider", function(_, _, _, children) children.builtins = nil end },
		{ "noncallable list data", function(_, _, _, children) children.builtins = {} end },
		{ "throwing list provider", function(_, _, _, children) children.builtins = function() error("list refused") end end },
		{ "nil list result", function(_, _, _, children) children.builtins = function() end end },
		{ "nonarray list result", function(_, _, _, children) children.builtins = function() return false end end },
		{ "sparse list result", function(_, _, _, children) children.builtins = function() return { [2] = { label = "gap" } } end end },
		{ "metamethod forged dense array", function(_, _, _, children) children.builtins = function() return setmetatable({ [2] = { label = "gap" } }, { __len = function() return 1 end, __pairs = function() return ipairs({ { label = "forged" } }) end }) end end },
		{ "metamethod forged canonical label", function(_, _, _, children) children.builtins = function() return { setmetatable({}, { __index = { label = "forged" } }) } end end },
		{ "string keyed list result", function(_, _, _, children) children.builtins = function() return { bad = { label = "bad" } } end end },
		{ "scalar child", function(_, _, _, children) children.builtins = function() return { false } end end },
		{ "driver dialect child", function(_, _, _, children) children.builtins = function() return { { title = "wrong", fn = function() end } } end end },
		{ "missing canonical label", function(_, _, _, children) children.builtins = function() return { { action = function() end } } end end },
		{ "empty native label", function(_, _, _, children) children.builtins = function() return { { label = "" } } end end },
		{ "wrong native separator type", function(_, _, _, children) children.builtins = function() return { { label = "Native", separator = "true" } } end end },
		{ "missing presence getter", function(_, _, getters) getters.custom_present = nil end },
		{ "noncallable presence getter", function(_, _, getters) getters.custom_present = true end },
		{ "throwing presence getter", function(_, _, getters) getters.custom_present = function() error("presence refused") end end },
		{ "nil presence", function(_, _, getters) getters.custom_present = function() end end },
		{ "numeric presence", function(_, _, getters) getters.custom_present = function() return 1 end end },
		{ "string presence", function(_, _, getters) getters.custom_present = function() return "true" end end },
		{ "empty presence identity", function(Menu) Menu.get_array("frame")[3].present_when = "" end },
		{ "missing selected identity", function(Menu) Menu.get_array("frame")[4].row_id = "missing" end },
		{ "empty selected identity", function(Menu) Menu.get_array("frame")[4].row_id = "" end },
		{ "wrong type selected identity", function(Menu) Menu.get_array("frame")[4].row_id = false end },
		{ "duplicate selected identity", function(Menu) Menu.get_array("commands")[1].id = "clone" end },
		{ "missing include even when false", function(Menu, _, _, _, state) state.present = false; Menu.get_array("frame")[3].section = "missing" end },
		{ "unsupported include metadata", function(Menu) Menu.get_array("frame")[4].i18n = "native fallback" end },
		{ "fixed label disguised as list", function(Menu) Menu.get_array("frame")[2].i18n = "native fallback" end },
		{ "cyclic selected include", function(Menu) local row = Menu.get_array("commands")[2]; row.type, row.section = "include", "frame"; row.id = nil; Menu.get_array("frame")[4].row_id = nil end },
	}
	for _, refusal in ipairs(refusals) do
		helpers.it("refuses " .. refusal[1] .. " without a partial frame or a native command effect", function()
			with_frame(function(Menu, commands, getters, children, state)
				refusal[2](Menu, commands, getters, children, state)
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
end)




helpers.describe("explicit inert presentation omission preserves actual native data", function()
	local function with_presentation(body)
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local state = { calls = 0, getters = 0, errors = {}, phases = {} }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) state.errors[#state.errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({
			platform = "linux", manifest_path = function() return path end,
			json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger,
		}))
		local builtin = { label = "Builtin native", action = function() state.calls = state.calls + 1; return false end }
		local custom = { label = "Custom native", items = { { label = "Native child", action = function() state.calls = state.calls + 1 end } } }
		local children = {
			builtins = function() state.phases[#state.phases + 1] = "builtins"; return { builtin } end,
			customs = function() state.phases[#state.phases + 1] = "customs"; return { custom } end,
		}
		local getters = { forbidden = function() state.getters = state.getters + 1; return true end }
		body(Menu, { forbidden = builtin.action }, getters, children, state, builtin, custom)
	end
	local function labels(rows)
		local result = {}
		for _, row in ipairs(rows) do result[#result + 1] = row.separator and "---" or row.label end
		return table.concat(result, "|")
	end
	helpers.it("recursively composes valid inert presentation before unchanged native objects and callbacks", function()
		with_presentation(function(Menu, commands, getters, children, state, builtin, custom)
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(labels(rows), "menu.profiles.header_default_profiles|---|menu.profiles.header_custom_profiles|Builtin native|Custom native")
			helpers.assert_true(rawequal(rows[4], builtin))
			helpers.assert_true(rawequal(rows[5], custom))
			helpers.assert_eq(rows[4].action(), false)
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	helpers.it("valid hidden presentation preserves native data without logging a refusal", function()
		with_presentation(function(Menu, commands, getters, children, state)
			local rows = Menu.get_array("presentation")
			for i = #rows, 2, -1 do rows[i] = nil end
			rows[1].platforms, rows[1].unavailable = { "ahk" }, "hide"
			local actual = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(labels(actual), "Builtin native|Custom native")
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	local omissions = {
		{ "missing", function(Menu) Menu.get_array("frame")[1].section = "missing" end },
		{ "empty", function(Menu) local rows = Menu.get_array("presentation"); for i = #rows, 1, -1 do rows[i] = nil end end },
		{ "malformed caption", function(Menu) Menu.get_array("presentation")[1].i18n = "" end },
		{ "unknown row", function(Menu) Menu.get_array("presentation")[3].type = "unknown" end },
		{ "clicked command", function(Menu) local row = Menu.get_array("presentation")[3]; row.type, row.section, row.id, row.i18n = "command", nil, "forbidden", "caption"; row.disabled_when = { "forbidden" } end },
		{ "clicked child", function(Menu) local row = Menu.get_array("presentation")[3]; row.type, row.section, row.id, row.i18n = "group", nil, "customs", "caption" end },
		{ "label getter", function(Menu) Menu.get_array("nested")[1].caption_getter = "forbidden" end },
		{ "header callback", function(Menu) Menu.get_array("presentation")[1].action = function() error("must not execute") end end },
		{ "conditional nested include", function(Menu) Menu.get_array("presentation")[3].present_when = "forbidden" end },
		{ "nested cycle", function(Menu) Menu.get_array("presentation")[3].section = "presentation" end },
		{ "nested missing", function(Menu) Menu.get_array("presentation")[3].section = "missing" end },
		{ "sparse presentation", function(Menu) Menu.get_array("presentation")[2] = nil end },
		{ "malformed platforms", function(Menu) Menu.get_array("presentation")[1].platforms = "hs" end },
		{ "inherited target getter", function(Menu) setmetatable(Menu.get_array("presentation")[1], { __index = { caption_getter = "forbidden" } }) end },
		{ "forged target membership", function(Menu) setmetatable(Menu.get_array("presentation"), { __len = function() return 1 end }) end },
		{ "selected inert row with clicked sibling", function(Menu)
			Menu.get_array("frame")[1].row_id = "safe"
			Menu.get_array("presentation")[1].id = "safe"
			Menu.get_array("presentation")[3] = { type = "command", id = "forbidden", i18n = "caption", disabled_when = { "forbidden" } }
		end },
	}
	for _, omission in ipairs(omissions) do
		helpers.it("logs and omits " .. omission[1] .. " before any clicked/getter work, preserving native data", function()
			with_presentation(function(Menu, commands, getters, children, state, builtin, custom)
				omission[2](Menu)
				local rows = assert(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(labels(rows), "Builtin native|Custom native")
				helpers.assert_true(rawequal(rows[1], builtin))
				helpers.assert_true(rawequal(rows[2], custom))
				helpers.assert_eq(state.getters, 0)
				helpers.assert_eq(state.calls, 0)
				helpers.assert_eq(table.concat(state.phases, "|"), "builtins|customs")
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_true(state.errors[1]:find("presentation omitted", 1, true) ~= nil)
				helpers.assert_eq(rows[1].action(), false)
				helpers.assert_eq(state.calls, 1)
			end)
		end)
	end
	local strict = {
		{ "unknown enum", function(Menu) Menu.get_array("frame")[1].on_refusal = "ignore" end },
		{ "empty enum", function(Menu) Menu.get_array("frame")[1].on_refusal = "" end },
		{ "false enum", function(Menu) Menu.get_array("frame")[1].on_refusal = false end },
		{ "missing include identity", function(Menu) Menu.get_array("frame")[1].section = "" end },
		{ "bad selector", function(Menu) Menu.get_array("frame")[1].row_id = "missing" end },
		{ "missing presence getter", function(Menu) Menu.get_array("frame")[1].present_when = "missing" end },
		{ "throwing presence getter", function(Menu, getters) Menu.get_array("frame")[1].present_when = "forbidden"; getters.forbidden = function() error("owner refused") end end },
		{ "wrong presence type", function(Menu, getters) Menu.get_array("frame")[1].present_when = "forbidden"; getters.forbidden = function() return 1 end end },
		{ "native provider failure", function(_, _, children) children.customs = function() error("real native read failed") end end },
		{ "policy on a native list", function(Menu) Menu.get_array("frame")[2].on_refusal = "omit_presentation" end },
		{ "strict ordinary include", function(Menu) local row = Menu.get_array("frame")[1]; row.on_refusal = nil; row.section = "missing" end },
	}
	for _, refusal in ipairs(strict) do
		helpers.it("keeps " .. refusal[1] .. " a refusal rather than a generic success fallback", function()
			with_presentation(function(Menu, commands, getters, children, state)
				refusal[2](Menu, getters, children)
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
end)




helpers.describe("inert presentation platform membership cannot invoke implicit getters", function()
	helpers.it("omits a metatable-forged platform array before renderer iteration, retaining physical native data", function()
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local callbacks, errors = 0, {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({ platform = "linux",
			manifest_path = function() return path end, json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
		Menu.get_array("presentation")[1].platforms = setmetatable({ "ahk" }, {
			__index = function(_, index) callbacks = callbacks + 1; if index == 2 then return "linux" end end,
		})
		local builtin, custom = { label = "Builtin native" }, { label = "Custom native" }
		local rows = assert(Menu.template_rows("frame", {}, {}, {
			builtins = function() return { builtin } end, customs = function() return { custom } end,
		}))
		helpers.assert_eq(callbacks, 0, "raw platform proof cannot later execute an implicit callback")
		helpers.assert_eq(#rows, 2, "the malformed inert target is completely omitted on both Lua VMs")
		helpers.assert_true(rawequal(rows[1], builtin) and rawequal(rows[2], custom))
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(errors[1]:find("presentation omitted", 1, true) ~= nil)
	end)
end)




helpers.describe("selected inert include inspects only physical identities before whole-target proof", function()
	for _, mode in ipairs({ "scalar sibling", "inherited sibling identity", "inherited target membership" }) do
		helpers.it("omits " .. mode .. " without implicit work, retaining the native data after a valid exact selector", function()
			local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
			local callbacks, errors = 0, {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			local Menu = assert(require("menu.renderer").new({ platform = "linux",
				manifest_path = function() return path end, json_decode = require("json").decode,
				i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
			Menu.get_array("frame")[1].row_id = "safe"
			local target = Menu.get_array("presentation")
			target[1].id = "safe"
			if mode == "scalar sibling" then target[3] = false
			elseif mode == "inherited sibling identity" then
				target[3] = setmetatable({ type = "label", i18n = "caption" }, {
					__index = function() callbacks = callbacks + 1; return "inherited" end,
				})
			else
				setmetatable(target, { __index = function() callbacks = callbacks + 1 end })
			end
			local builtin, custom = { label = "Builtin native" }, { label = "Custom native" }
			local called, rows = pcall(Menu.template_rows, "frame", {}, {}, {
				builtins = function() return { builtin } end, customs = function() return { custom } end,
			})
			helpers.assert_true(called, "malformed presentation cannot throw before its opted-in preflight")
			helpers.assert_eq(callbacks, 0, "physical selector admission never invokes inherited identity/membership")
			helpers.assert_not_nil(rows)
			helpers.assert_eq(#rows, 2)
			helpers.assert_true(rawequal(rows[1], builtin) and rawequal(rows[2], custom))
			helpers.assert_eq(#errors, 1)
			helpers.assert_true(errors[1]:find("presentation omitted", 1, true) ~= nil)
		end)
	end
end)




helpers.describe("invalid inert selector refuses before identity comparison", function()
	helpers.it("does not invoke equality callbacks for a non-string selector", function()
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local callbacks, providers, errors = 0, 0, {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({ platform = "linux",
			manifest_path = function() return path end, json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
		local meta = { __eq = function() callbacks = callbacks + 1; return true end }
		Menu.get_array("frame")[1].row_id = setmetatable({}, meta)
		Menu.get_array("presentation")[1].id = setmetatable({}, meta)
		local function supplied() providers = providers + 1; return { { label = "Native" } } end
		local called, rows = pcall(Menu.template_rows, "frame", {}, {}, { builtins = supplied, customs = supplied })
		helpers.assert_true(called)
		helpers.assert_nil(rows, "bad selector is a strict identity refusal, not omitted presentation")
		helpers.assert_eq(callbacks, 0)
		helpers.assert_eq(providers, 0)
		helpers.assert_eq(#errors, 1)
		helpers.assert_nil(errors[1]:find("presentation omitted", 1, true))
	end)
end)




-- The complete shared frame reuses the actual canonical store and unchanged data/callback owners.
helpers.describe("complete ordered profile frame: actual Linux native owner", function()
	local function shared(relative) return helpers.driver_root():gsub("/linux$", "/_shared/") .. relative end
	local function read(relative)
		local handle = assert(io.open(shared(relative), "rb"))
		local value = Json.decode(handle:read("*a")); handle:close(); return value
	end
	local oracle = read("tests/corpus/menus/profile_ordered_frame.json")
	-- Handwritten policy amendment; the original independent frame corpus stays byte-exact.
	oracle.sections.llm_profile_lua_frame[5].on_refusal = "omit_presentation"
	oracle.sections.llm_profile_windows_frame[1].on_refusal = "omit_presentation"
	oracle.sections.llm_profile_custom_section[1].on_refusal = "omit_presentation"
	local function with_frame(options, body)
		options = options or {}
		local registry = options.custom and { profile() } or Json.array({})
		local initial = '[llm]\nfuture = "keep"\nuser_profiles = "v1:' .. Base64.encode(Json.encode(registry))
			.. '"\n[llm.profiles]\nactive = "' .. (options.active or "basic") .. '"\nauto_profile_for_model = false\n'
		with_config(initial, function(settings, path)
			with_idle_live_owner(settings, function(live_owner)
				local names = { "infra.manifest_menu", "infra.i18n", "ui.menu.menu_builder", "ui.prompt_editor.bridge" }
				local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
				local ok, err = xpcall(function()
					local document = read("modules/menu/menu_manifest.json")
					local header_captions = read("data/locales/en.json")
					local i18n = setmetatable({ get = function(key)
						if key == "menu.builder.active_brand" or key == "menu.builder.title_paused" then
							return header_captions[key]
						end
						return key
					end }, { __index = require("infra.i18n") })
					package.loaded["infra.i18n"] = i18n
					package.loaded["infra.manifest_menu"] = assert(require("menu.renderer").new({
						platform = "linux", manifest_path = function() return shared("modules/menu/menu_manifest.json") end,
						json_decode = function() return document end, i18n = i18n, logger = require("logger.shim"),
					}))
					local redraws, editors, opened = 0, 0, nil
					package.loaded["ui.prompt_editor.bridge"] = { open = function(existing, on_save, opts)
						editors = editors + 1; opened = { existing = existing, on_save = on_save, opts = opts }; return true
					end }
					local ctx = { paused = options.paused == true, is_paused = function() return options.paused == true end,
						llm = { is_enabled = function() return true end, get_models = function() return {} end,
							get_current_model = function() return "small" end, get_prediction_model = function() return "small" end,
							get_live = live_owner.get_live, set_live = live_owner.set_live },
						on_menu_changed = function() redraws = redraws + 1 end }
					local builder = helpers.load_module("ui.menu.menu_builder")
					local function find(rows)
						for _, row in ipairs(rows or {}) do
							if row.menu then
								for _, child in ipairs(row.menu) do if child.title == i18n.get(oracle.labels.auto_detect) then return row.menu end end
								local result = find(row.menu); if result then return result end
							end
						end
					end
					body({ document = document, i18n = i18n, settings = settings, path = path, initial = initial, ctx = ctx,
						rows = function() return find(builder.build(ctx)) end, opened = function() return opened end,
						counts = function() return { redraws, editors } end })
				end, debug.traceback)
				for _, name in ipairs(names) do package.loaded[name] = saved[name] end
				if not ok then error(err, 0) end
			end)
		end)
	end
	local function at(rows, title)
		for _, row in ipairs(rows or {}) do if row.title == title then return row end end
	end
	local function roles(f, rows)
		local native = {}
		for _, entry in ipairs(f.settings.list_built_in()) do native[f.settings.menu_label(entry, f.settings.get("num_predictions") or 1)] = true end
		local result, counted_native = {}, false
		for _, row in ipairs(rows) do
			local role
			if row.title == "-" then role = "---"
			elseif native[row.title] then
				if not counted_native then role, counted_native = "builtin_catalogue", true end
			elseif row.title == "Canonical" then role = "custom:user_canonical"
			else for id, key in pairs(oracle.labels) do if row.title == f.i18n.get(key) then role = id end end end
			helpers.assert_true(role ~= nil or native[row.title], "every physical native row belongs to the independent frame or original catalogue")
			if role then result[#result + 1] = role end
		end
		return result
	end
	helpers.it("pins the full frame around the unchanged canonical builtin catalogue and custom data", function()
		with_frame({ custom = true }, function(f)
			local rows = assert(f.rows())
			helpers.assert_eq(roles(f, rows), oracle.expected.linux_custom_builtin)
			local catalogue = f.settings.list_built_in()
			for index, entry in ipairs(catalogue) do
				helpers.assert_eq(rows[index + 3].title, f.settings.menu_label(entry, f.settings.get("num_predictions") or 1))
				helpers.assert_eq(rows[index + 3].checked == true, entry.id == "basic")
				helpers.assert_not_nil(rows[index + 3].fn)
			end
			helpers.assert_eq(Sandbox.read_bytes(f.path), f.initial)
			helpers.assert_eq(f.counts(), { 0, 0 })
		end)
	end)
	helpers.it("empty custom registry and custom active profile keep the original conditional boundaries", function()
		with_frame({}, function(f)
			local rows = assert(f.rows())
			helpers.assert_nil(at(rows, f.i18n.get(oracle.labels.custom_heading)))
			helpers.assert_not_nil(at(rows, f.i18n.get(oracle.labels.clone)))
		end)
		with_frame({ custom = true, active = "user_canonical" }, function(f)
			local rows = assert(f.rows())
			helpers.assert_nil(at(rows, f.i18n.get(oracle.labels.clone)))
			helpers.assert_true(at(rows, "Canonical").menu[1].checked)
		end)
	end)
	helpers.it("consumes the exact independent shared declarations and explicit inert omission policy", function()
		with_frame({}, function(f)
			for section, expected in pairs(oracle.sections) do helpers.assert_eq(f.document[section], expected, section) end
		end)
	end)
	helpers.it("actual declared checkbox persists the real canonical value and refreshes its native check", function()
		with_frame({}, function(f)
			local row = assert(at(f.rows(), f.i18n.get(oracle.labels.auto_detect)))
			helpers.assert_eq(row.checked, false)
			helpers.assert_true(row.fn())
			helpers.assert_eq(f.settings.get("auto_profile_for_model"), true)
			helpers.assert_true(at(f.rows(), f.i18n.get(oracle.labels.auto_detect)).checked)
			helpers.assert_eq(Toml.decode(Sandbox.read_bytes(f.path)).llm.future, "keep")
			helpers.assert_eq(f.counts(), { 1, 0 })
		end)
	end)
	for _, action in ipairs({ "auto_detect", "create", "clone" }) do
		helpers.it("retained " .. action .. " refuses declaration withdrawal before file/editor effects", function()
			with_frame({}, function(f)
				local row = assert(at(f.rows(), f.i18n.get(oracle.labels[action])))
				if action == "auto_detect" then f.document.llm_profile_auto_detect_control = nil
				else
					for _, declared in ipairs(f.document.llm_profile_commands) do
						if declared.id == "llm_profile_" .. action then declared.id = "withdrawn" end
					end
				end
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(Sandbox.read_bytes(f.path), f.initial)
				helpers.assert_eq(f.counts(), { 0, 0 })
			end)
		end)
	end
	helpers.it("retained controls keep original live pause refusal while builtin selection keeps its native nil receipt", function()
		with_frame({}, function(f)
			local rows = assert(f.rows())
			local auto, create, clone = at(rows, oracle.labels.auto_detect), at(rows, oracle.labels.create), at(rows, oracle.labels.clone)
			f.ctx.paused = true; f.ctx.is_paused = function() return true end
			helpers.assert_eq(auto.fn(), false); helpers.assert_eq(create.fn(), false); helpers.assert_eq(clone.fn(), false)
			helpers.assert_eq(Sandbox.read_bytes(f.path), f.initial); helpers.assert_eq(f.counts(), { 0, 0 })
			local catalogue = f.settings.list_built_in()
			local last = catalogue[#catalogue]
			helpers.assert_nil(assert(at(rows, f.settings.menu_label(last, f.settings.get("num_predictions") or 1))).fn())
			helpers.assert_eq(f.settings.get("active"), last.id)
			helpers.assert_eq(f.counts(), { 1, 0 })
		end)
	end)
	helpers.it("create and clone keep their real editor seeds and conditional-save callback", function()
		with_frame({}, function(f)
			helpers.assert_true(assert(at(f.rows(), oracle.labels.clone)).fn())
			helpers.assert_not_nil(f.opened().existing)
			helpers.assert_true(f.opened().opts.as_new)
			local candidate = profile(); candidate.id = f.opened().opts.profile_id; candidate.label = "Clone owned"
			helpers.assert_true(f.opened().on_save(candidate))
			helpers.assert_eq(f.settings.list_user()[1].label, "Clone owned")
			helpers.assert_eq(Toml.decode(Sandbox.read_bytes(f.path)).llm.future, "keep")
			helpers.assert_eq(f.counts(), { 1, 1 })
		end)
		with_frame({}, function(f)
			helpers.assert_true(assert(at(f.rows(), oracle.labels.create)).fn())
			helpers.assert_nil(f.opened().existing)
			helpers.assert_eq(f.counts(), { 0, 1 })
		end)
	end)
	helpers.it("materializes actual source order changes rather than a native fixed frame", function()
		with_frame({}, function(f)
			local frame = f.document.llm_profile_lua_frame
			frame[3], frame[10] = frame[10], frame[3]
			local rows = assert(f.rows())
			helpers.assert_eq(rows[1].title, oracle.labels.create)
			helpers.assert_eq(rows[#rows].title, oracle.labels.auto_detect)
		end)
	end)
	local faults = {
		{ "missing frame", function(f) f.document.llm_profile_lua_frame = nil end },
		{ "wrong list binding", function(f) f.document.llm_profile_lua_frame[6].id = "wrong_native_slot" end },
		{ "missing presence binding", function(f) f.document.llm_profile_lua_frame[7].present_when = "wrong_getter" end },
		{ "wrong command selector", function(f) f.document.llm_profile_lua_frame[10].row_id = "missing" end },
	}
	for _, fault in ipairs(faults) do
		helpers.it("refuses " .. fault[1] .. " without fabricating a parent or writing canonical files", function()
			with_frame({ custom = true }, function(f)
				fault[2](f)
				helpers.assert_nil(f.rows())
				helpers.assert_eq(Sandbox.read_bytes(f.path), f.initial)
				helpers.assert_eq(f.counts(), { 0, 0 })
			end)
		end)
	end
	helpers.it("all 21 original fixed captions reach the actual complete Linux frame without ported Mac-only rows", function()
		with_frame({ custom = true }, function(f)
			local languages = read("data/locale_order.json").order
			helpers.assert_eq(#languages, 21)
			for _, language in ipairs(languages) do
				local values = read("data/locales/" .. language .. ".json")
				f.i18n.get = function(key) return values[key] or key end
				local rows = assert(f.rows())
				for _, id in ipairs({ "auto_detect", "builtin_heading", "custom_heading", "clone", "create" }) do
					local key = oracle.labels[id]
					helpers.assert_not_nil(values[key], language)
					helpers.assert_not_nil(at(rows, values[key]), language .. ": native shared-caption publication")
				end
				helpers.assert_eq(roles(f, rows), oracle.expected.linux_custom_builtin)
				helpers.assert_eq(Sandbox.read_bytes(f.path), f.initial)
				helpers.assert_eq(f.counts(), { 0, 0 })
			end
		end)
	end)

end)

