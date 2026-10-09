--- tests/unit/infra/test_dynamic_hotstrings_scope.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstring Bulk Transaction Regression (Linux)
--- DESCRIPTION:
--- Exercises real preference, dynamic and ordinary-matcher owners against real
--- files. Refusals are injected only at runtime acknowledgement or conditional
--- publication; assertions observe the completed transaction outside callbacks.
--- ==============================================================================

local helpers = require("tests.helpers")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

-- Independent expected inventory; never derive this oracle from the planner.
local FAMILIES = { "date", "date_fr", "date_long_fr", "phone_prefixes", "ssn_prefixes",
	"iban_prefixes", "text_expansion_personal_information" }
local SOURCE = '[hotstrings]\nenabled = false\npreview_star_enabled = "outdated"\n'
	.. 'groups = { rolls = false, foreign = true }\n'
	.. '[hotstrings.dynamic]\nenabled = true\nprivate_note = "keep"\n'
	.. '[hotstrings.dynamic.future_family]\nenabled = true\n'
for index, id in ipairs(FAMILIES) do
	SOURCE = SOURCE .. '[hotstrings.dynamic.' .. id .. ']\nenabled = ' .. tostring(index % 2 == 1) .. '\n'
	if id == "date" then SOURCE = SOURCE .. 'time_activation_seconds = 0.75\n' end
end
local OVERRIDES = '[rolls]\ndelay = 7\n[unknown]\nprivate_note = "keep"\n'
local PERSONAL = '[info]\nphone_number = "0750123456"\nsocial_security_number = "1234567890123"\n'
	.. 'iban = "FR7612345678901234567890123"\nfirst_name = "Test"\n[letters]\np = "first_name"\n'

local function read(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end
local function write(path, content)
	local handle = assert(io.open(path, "w"))
	handle:write(content)
	handle:close()
end
local function fires(engine)
	engine:reset()
	local result
	for char in ("0750"):gmatch(".") do result = engine:on_char(char) end
	return result ~= nil and result.replacement == "0750123456"
end

--- Fresh real owners in a private folder, with acknowledgement fault controls.
local function with_scope(body, initial)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local directory = string.format("%s/ergopti_dynamic_scope_%d_%d",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	assert(os.execute("mkdir -p '" .. directory .. "'"))
	local ok, err = pcall(function()
		for _, name in ipairs({ "infra.hotstring_preferences", "infra.dynamic_hotstrings_scope",
			"modules.hotstrings.hotstrings_config", "modules.dynamic_hotstrings.manager",
			"modules.dynamic_hotstrings.prefix_rules", "dynamic_hotstrings" }) do package.loaded[name] = nil end
		local paths = {}
		for key, value in pairs(require("infra.config_paths")) do paths[key] = value end
		paths.config = function(rel) return rel and (directory .. "/" .. rel) or directory end
		paths.home = function() return directory end
		package.loaded["infra.config_paths"] = paths
		package.loaded["modules.hotstrings.loader"] = {
			find_toml_files = require("modules.hotstrings.loader").find_toml_files,
			list_subdirs = function() return {} end,
			read_file = function() return nil end,
			load_catalogue = function()
				return { committed = true, errors = 0, mappings = {}, categories = {
					rolls = { id = "rolls", sections_order = { "hc" }, sections = { hc = { count = 0 } } },
				} }
			end,
		}
		local c = { path = directory .. "/config.toml", backup = directory .. "/config.toml.dynamic.bak",
			overrides = directory .. "/hotstrings_overrides.toml", personal = directory .. "/personal_info.toml",
			published = {}, source = initial or SOURCE }
		write(c.path, c.source)
		write(c.overrides, OVERRIDES)
		write(c.personal, PERSONAL)
		c.Preferences = require("infra.hotstring_preferences")
		assert(c.Preferences.refresh())
		c.Dynamic = require("modules.dynamic_hotstrings.manager")
		assert(c.Dynamic.init({ trigger_char = "\\", personal_info_path = c.personal }))
		c.Config = require("modules.hotstrings.hotstrings_config")
		c.engine = require("hotstring_engine").new()
		assert(c.Config.init(c.engine, "virtual.toml"))
		c.Config.set_extra_mappings_provider(function() return c.Dynamic.prefix_mappings() end)
		local _, committed = c.Config.load_all()
		assert(committed, "fixture catalogue must be acknowledged")
		c.files = {
			read_with_status = function(path) return Writer.read_classified(path) end,
			write = function() error("unconditional publication is forbidden") end,
			write_if_unchanged = function(path, content, expected)
				c.published[#c.published + 1] = path
				if c.before_publish then c.before_publish(path, content, expected) end
				if c.refuse == path then return false, "injected refusal" end
				return Writer.publish_if_unchanged(path, content, nil, expected)
			end,
		}
		function c.new_scope(backup)
			return require("infra.dynamic_hotstrings_scope").new({ path = c.path, backup_path = backup or c.backup,
				files = c.files, config = c.Config, preferences = c.Preferences, dynamic = c.Dynamic })
		end
		c.scope = c.new_scope()
		body(c)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	os.execute("rm -rf '" .. directory .. "'")
	if not ok then error(err, 0) end
end

local function assert_neighbors(c)
	local document = Codec.decode(read(c.path))
	helpers.assert_eq(document.hotstrings.enabled, false, "global hotstring master is independent")
	helpers.assert_eq(document.hotstrings.groups, { rolls = false, foreign = true })
	helpers.assert_eq(document.hotstrings.preview_star_enabled, "outdated", "unrelated outdated leaf survives")
	helpers.assert_eq(document.hotstrings.dynamic.future_family.enabled, true)
	helpers.assert_eq(document.hotstrings.dynamic.private_note, "keep")
	helpers.assert_eq(document.hotstrings.dynamic.date.time_activation_seconds, 0.75)
	helpers.assert_eq(read(c.overrides), OVERRIDES, "override source is outside this scope")
	helpers.assert_eq(read(c.personal), PERSONAL, "personal data is outside this scope")
end

local function assert_restored(c)
	helpers.assert_eq(read(c.path), c.source, "exact source bytes survive refusal")
	helpers.assert_eq(read(c.backup), c.source, "exact verified backup")
	helpers.assert_eq(c.Dynamic.is_enabled(), true)
	helpers.assert_not_nil(c.Dynamic.preview("td\\", true), "previous date family still expands")
	helpers.assert_nil(c.Dynamic.preview("dt\\", true), "previous disabled sibling stays disabled")
	helpers.assert_eq(fires(c.engine), false, "previous disabled prefix family stays disabled")
	helpers.assert_eq(c.scope.pending(), false)
	helpers.assert_eq(c.Preferences.is_acquired(), false, "preference lease is released")
end

helpers.describe("dynamic hotstring bulk transaction", function()
	for _, enabled in ipairs({ true, false }) do
		helpers.it("dynamic bulk: commits all seven families and master " .. tostring(enabled), function()
			with_scope(function(c)
				local publications = {}
				c.before_publish = function(path)
					if path == c.path then
						publications[#publications + 1] = { source = read(c.path), enabled = c.Dynamic.is_enabled(),
							prefix = fires(c.engine), ordinary_write = c.Config.enable_group("rolls"),
							preference_write = c.Preferences.set("hotstrings.dynamic.date.enabled", not enabled) }
					end
				end
				local committed, detail = c.scope.apply(enabled)
				helpers.assert_true(committed, tostring(detail))
				helpers.assert_eq(#publications, 1, "one conditional source publication")
				helpers.assert_eq(publications[1], { source = c.source, enabled = enabled, prefix = enabled,
					ordinary_write = false, preference_write = false }, "runtime acknowledges before publication under both leases")
				for _, id in ipairs(FAMILIES) do
					helpers.assert_eq(c.Preferences.get("hotstrings.dynamic." .. id .. ".enabled"), enabled, id)
					helpers.assert_eq(Codec.decode(read(c.path)).hotstrings.dynamic[id].enabled,
						enabled and true or nil, "neutral family selection stays sparse: " .. id)
				end
				helpers.assert_eq(c.Preferences.get("hotstrings.dynamic.enabled"), enabled)
				helpers.assert_eq(c.Dynamic.is_enabled(), enabled)
				helpers.assert_eq(fires(c.engine), enabled, "ordinary prefix matcher adopts the same cohort")
				for _, trigger in ipairs({ "td\\", "dt\\", "date\\", "@p\\" }) do
					helpers.assert_eq(c.Dynamic.preview(trigger, true) ~= nil, enabled, "dynamic guard " .. trigger)
				end
				helpers.assert_eq(read(c.backup), c.source)
				assert_neighbors(c)
				helpers.assert_eq(c.scope.pending(), false)
				helpers.assert_eq(c.Preferences.is_acquired(), false)
				-- Cold readers consume the committed cohort, rather than the menu cache.
				helpers.assert_true(c.Preferences.refresh())
				package.loaded["modules.dynamic_hotstrings.manager"] = nil
				c.Dynamic = require("modules.dynamic_hotstrings.manager")
				helpers.assert_true(c.Dynamic.init({ trigger_char = "\\", personal_info_path = c.personal }))
				local _, reloaded = c.Config.reload()
				helpers.assert_true(reloaded)
				helpers.assert_eq(c.Dynamic.is_enabled(), enabled)
				helpers.assert_eq(fires(c.engine), enabled)
			end)
		end)
	end

	for _, refusal in ipairs({ "false", "nil", "throw" }) do
		helpers.it("dynamic bulk: restores a mutated ordinary runtime after " .. refusal, function()
			with_scope(function(c)
				local reload = c.Config.reload
				c.Config.reload = function()
					reload()
					if refusal == "throw" then error("injected terminal acknowledgement error") end
					if refusal == "nil" then return 0, nil end
					return 0, false
				end
				helpers.assert_eq(c.scope.apply(true), false)
				assert_restored(c)
				helpers.assert_eq(c.published, { c.backup }, "refused runtime never publishes configuration")
			end)
		end)
	end

	helpers.it("dynamic bulk: compensates a refused publication and permits a subsequent setter", function()
		with_scope(function(c)
			c.refuse = c.path
			helpers.assert_eq(c.scope.apply(true), false)
			assert_restored(c)
			helpers.assert_true(c.Config.enable_group("rolls"), "ordinary owner resumes after compensation")
		end)
	end)

	helpers.it("dynamic bulk: retained inverse blocks both writers until restoration acknowledges", function()
		with_scope(function(c)
			local restore = c.Config.restore_configuration
			c.Config.restore_configuration = function() return false end
			c.refuse = c.path
			helpers.assert_eq(c.scope.apply(true), false)
			helpers.assert_true(c.scope.pending())
			helpers.assert_true(c.Preferences.is_acquired())
			helpers.assert_eq(c.Preferences.set("hotstrings.dynamic.date.enabled", true), false)
			helpers.assert_eq(c.Config.enable_group("rolls"), false)
			helpers.assert_eq(c.scope.apply(false), false, "a pending inverse cannot be superseded")
			helpers.assert_eq(c.scope.retry_restore(), false)
			c.Config.restore_configuration = restore
			helpers.assert_true(c.scope.retry_restore())
			assert_restored(c)
		end)
	end)

	helpers.it("dynamic bulk: conditional publication preserves a concurrent foreign edit", function()
		with_scope(function(c)
			local foreign = c.source .. '\n[concurrent]\nvalue = "new"\n'
			c.before_publish = function(path) if path == c.path then write(c.path, foreign) end end
			helpers.assert_eq(c.scope.apply(true), false)
			helpers.assert_eq(read(c.path), foreign, "never overwrite an external editor's new bytes")
			helpers.assert_eq(read(c.backup), c.source)
			helpers.assert_not_nil(c.Dynamic.preview("td\\", true))
			helpers.assert_nil(c.Dynamic.preview("dt\\", true))
			helpers.assert_eq(fires(c.engine), false)
			helpers.assert_eq(c.scope.pending(), false)
		end)
	end)

	helpers.it("dynamic bulk: backup refusal leaves every reader and source untouched", function()
		with_scope(function(c)
			c.refuse = c.backup
			helpers.assert_eq(c.scope.apply(false), false)
			helpers.assert_eq(read(c.path), c.source)
			helpers.assert_nil(read(c.backup))
			helpers.assert_not_nil(c.Dynamic.preview("td\\", true))
			helpers.assert_eq(c.scope.pending(), false)
			helpers.assert_eq(c.Preferences.is_acquired(), false)
		end)
	end)

	helpers.it("dynamic bulk: validates narrow outputs without weakening the complete preference owner", function()
		with_scope(function(c)
			local owner = {}
			helpers.assert_true(c.Preferences.acquire(owner))
			helpers.assert_eq(c.Preferences.adopt(owner, Codec.decode(c.source)), false, "whole owner still refuses outdated typed output")
			helpers.assert_eq(c.Preferences.adopt(owner, Codec.decode(c.source), { ["unknown.enabled"] = true }), false)
			helpers.assert_true(c.Preferences.release(owner))
			helpers.assert_true(c.scope.apply(true), "dynamic owner does not claim the unrelated preview leaf")
			assert_neighbors(c)
		end)
	end)

	helpers.it("dynamic bulk: invalid postures refuse before backup or runtime mutation", function()
		with_scope(function(c)
			for _, posture in ipairs({ "true", 1, {} }) do helpers.assert_eq(c.scope.apply(posture), false) end
			helpers.assert_eq(c.published, {})
			helpers.assert_eq(read(c.path), c.source)
			helpers.assert_eq(c.Preferences.is_acquired(), false)
		end)
	end)

	helpers.it("dynamic bulk: malformed source refuses before backup and preserves current guards", function()
		with_scope(function(c)
			local malformed = '[hotstrings.dynamic\nenabled = true\n'
			write(c.path, malformed)
			helpers.assert_eq(c.scope.apply(true), false)
			helpers.assert_eq(read(c.path), malformed)
			helpers.assert_nil(read(c.backup))
			helpers.assert_eq(c.published, {})
			helpers.assert_not_nil(c.Dynamic.preview("td\\", true))
			helpers.assert_nil(c.Dynamic.preview("dt\\", true))
			helpers.assert_eq(c.Preferences.is_acquired(), false)
		end)
	end)

	helpers.it("dynamic bulk: refuses a scalar parent instead of replacing unknown configuration", function()
		local legacy = '[hotstrings]\nenabled = false\ndynamic = true\n'
		with_scope(function(c)
			helpers.assert_eq(c.scope.apply(true), false)
			helpers.assert_eq(read(c.path), legacy)
			helpers.assert_eq(c.published, {})
			helpers.assert_nil(read(c.backup))
			helpers.assert_eq(c.Preferences.is_acquired(), false)
		end, legacy)
	end)

	helpers.it("dynamic bulk: unavailable rules refuse enable and restore the previously disabled runtime", function()
		with_scope(function(c)
			package.loaded["modules.dynamic_hotstrings.manager"] = nil
			c.Dynamic = require("modules.dynamic_hotstrings.manager") -- No native rules were initialized.
			local _, reloaded = c.Config.reload()
			helpers.assert_true(reloaded)
			helpers.assert_eq(c.Dynamic.is_enabled(), false)
			c.scope = c.new_scope()
			helpers.assert_eq(c.scope.apply(true), false, "a true stored preference is not an acknowledged runtime")
			helpers.assert_eq(read(c.path), c.source)
			helpers.assert_eq(c.Dynamic.is_enabled(), false, "restore the actual previous posture")
			helpers.assert_eq(c.scope.pending(), false, "a legitimate disabled inverse must settle")
			helpers.assert_eq(c.Preferences.is_acquired(), false)
		end)
	end)

	helpers.it("dynamic bulk: committed inverse restores both matcher and source under reacquired leases", function()
		with_scope(function(c)
			helpers.assert_true(c.scope.apply(true))
			helpers.assert_true(fires(c.engine))
			helpers.assert_true(c.scope.revert())
			assert_restored(c)
		end)
	end)
end)
