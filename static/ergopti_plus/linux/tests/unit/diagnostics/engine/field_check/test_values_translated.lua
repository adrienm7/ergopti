--- static/ergopti_plus/linux/tests/unit/diagnostics/engine/field_check/test_values_translated.lua

--- The field check reports show each step value in the user's language. The
--- field report of 2026-11-25 read « Composition installée : kept » and
--- « Réglages proxy : none »: the raw codes reached the window after French
--- labels. Every value the composer and network checks (all three drivers) and
--- the Linux setup check can emit must have a field_check.value.* key in every
--- locale, and the renderer must use it.

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Report = require("diagnostics.engine.field_check.report")

local SHARED = helpers.driver_root() .. "/../_shared/"
local ROOT = helpers.driver_root() .. "/../"

--- Reads a file of the repository.
local function read(path)
	local handle = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Every locale catalogue as a translate function.
local function catalogues()
	local list = {}
	local index = Json.decode(read(SHARED .. "core/i18n/data/locales/en.json"))
	assert(type(index) == "table")
	for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no",
		"pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		local catalogue = Json.decode(read(SHARED .. "core/i18n/data/locales/" .. code .. ".json"))
		list[#list + 1] = { code = code, translate = function(key) return catalogue[key] or key end }
	end
	return list
end

-- The producers of step values: the shared composer and network checks, their
-- Linux, macOS and Windows ports, and the Linux setup check.
local PRODUCERS = {
	"_shared/layouts/engine/composer/check_core.lua",
	"_shared/core/network/engine/field_check_network.lua",
	"linux/core/network/adapters/check_ports.lua",
	"linux/modules/keymap/composer_check.lua",
	"linux/diagnostics/engine/field_check/setup_check.lua",
	"linux/diagnostics/ui/field_check/window.lua",
	"macos/modules/keymap/composer_check.lua",
	"windows/ui/layout_manager/composer_check.ahk",
	"windows/diagnostics/ui/field_check/network_check.ahk",
}

-- A line that records or builds a step value.
local VALUE_CONTEXTS = { "step%(", "_Record%(", "_Step%(", "ready%(", "value = \"", "Push%(\"", "add%(\"",
	"return \"", "STATE_%u+, \"" }

-- Step states: a line whose value is computed ends with its state literal.
local STATES = { pass = true, fail = true, info = true, skip = true }

--- The literal values the producers can emit, plus the registry and managed
--- Python failure codes a composer install step carries.
local function emitted_values()
	local values, seen = {}, {}
	local function add(token)
		token = token:gsub(":$", "")
		-- A prefix the code completes ("http_" .. status) is a family the renderer spells.
		if token == "" or token:sub(-1) == "_" or seen[token] or STATES[token] then return end
		seen[token] = true
		values[#values + 1] = token
	end
	for _, relative in ipairs(PRODUCERS) do
		for line in (read(ROOT .. relative) .. "\n"):gmatch("([^\n]*)\n") do
			local code = line:gsub("%-%-.*$", ""):gsub("^%s*;.*$", "")
			for _, context in ipairs(VALUE_CONTEXTS) do
				if code:find(context) then
					local last
					-- A literal that indexes a map (Result["code"]) is a field name, not a value.
					-- A compared literal (mode == "selected") is an input, not a value.
					for before, literal, after in code:gmatch("()\"([%l][%w_%-:]*)\"()") do
						if code:sub(after, after) ~= "]" and not code:sub(1, before - 1):find("[=~]=%s*$") then
							last = literal
						end
					end
					if last then add(last) end
					break
				end
			end
		end
	end
	-- The Linux registry's failure codes live in the layout defaults (registry.failures).
	local defaults = Json.decode(read(SHARED .. "layouts/data/defaults.json"))
	for _, code in pairs(defaults.registry.failures) do add(code) end
	for code in read(ROOT .. "linux/modules/keymap/managed_python.lua"):gmatch("\"(python_[%l_]+)\"") do add(code) end
	-- The sanitizer puts this marker in place of any private value.
	add(Report.REDACTED)
	return values
end

--- Step ids and other words a scanned line can end with that are not values.
local function is_step_id(token, translate)
	return translate("field_check.step." .. token) ~= "field_check.step." .. token
end

helpers.describe("field check values: translated in every locale (field-check-values)", function()
	helpers.it("renders the field report of 2026-11-25 without a raw code (field-check-values)", function()
		local reported = { "existing", "kept", "unreadable", "not_installed", "no_copy", "none", "no_pac",
			"selected_direct", "trusted", "http_200", "get_only", "registry:direct+blob:direct", "direct" }
		for _, locale in ipairs(catalogues()) do
			for _, value in ipairs(reported) do
				local unknown = Report.unknown_tokens(value, locale.translate)
				helpers.assert_eq(#unknown, 0, locale.code .. ": " .. value .. " has no translation: "
					.. table.concat(unknown, ", "))
			end
		end
	end)

	helpers.it("has a translation of every value the checks emit (field-check-values)", function()
		local en = catalogues()[5]
		helpers.assert_eq(en.code, "en")
		local values = emitted_values()
		helpers.assert_true(#values > 40, "the scan found only " .. #values .. " values")
		local missing = {}
		for _, value in ipairs(values) do
			if not is_step_id(value, en.translate) then
				for _, token in ipairs(Report.unknown_tokens(value, en.translate)) do missing[#missing + 1] = token end
			end
		end
		helpers.assert_eq(#missing, 0, "emitted values without a field_check.value key: " .. table.concat(missing, " "))
		-- Every value key of the source catalogue is in every other one.
		local keys = {}
		for key in read(SHARED .. "core/i18n/data/locales/en.json"):gmatch("\"(field_check%.value%.[^\"]+)\":") do
			keys[#keys + 1] = key
		end
		for _, locale in ipairs(catalogues()) do
			for _, key in ipairs(keys) do
				helpers.assert_true(locale.translate(key) ~= key, locale.code .. " lacks " .. key)
			end
		end
	end)

	helpers.it("shows the translation in the window text, not the code (field-check-values)", function()
		local report = Report.new_report("composer")
		report.step("composer_install", Report.STATE_SKIP, "kept")
		report.step("route_plan", Report.STATE_INFO, "registry:direct+blob:direct")
		report.step("transfer", Report.STATE_PASS, "http_200")
		local fr
		for _, locale in ipairs(catalogues()) do if locale.code == "fr" then fr = locale.translate end end
		local text = Report.format_text(report.result(), fr)
		helpers.assert_contains(text, fr("field_check.value.kept"))
		helpers.assert_contains(text, "HTTP 200")
		helpers.assert_true(not text:find(": kept", 1, true) and not text:find("registry:", 1, true)
			and not text:find("http_200", 1, true), text)
	end)

	helpers.it("names an open code as a code instead of showing it bare (field-check-values)", function()
		local translate = function(key)
			if key == "field_check.value.other" then return "code {1}" end
			return key
		end
		helpers.assert_eq(Report.display_value("proxy-xyz-refused", translate), "code proxy-xyz-refused")
		helpers.assert_eq(Report.display_value("12", translate), "12", "a count is shown as it is")
	end)
end)
