--- tests/unit/lib/test_config_overrides_log_level.lua

--- ==============================================================================
--- MODULE: Regression — config.toml [script] log_level override is honored
--- DESCRIPTION:
--- Audit finding F-M4. The documented expert override `[script] log_level = "..."`
--- (and the AHK-parity LogLevel) silently no-opped: config_overrides wrote it to a
--- BARE settings key ("log_level"), but the logger restore reads only the canonical
--- "ergopti.log_level" — and even if the key matched, Logger.set_level ran at boot
--- BEFORE config_overrides, so nothing re-applied it.
---
--- Fix: config_overrides maps log_level/LogLevel onto "ergopti.log_level", and
--- init.lua re-applies the level AFTER overrides. This test pins the key mapping
--- behaviorally and the re-apply step at source.
--- ==============================================================================

local helpers = require("tests.helpers")

local stored = {}
_G.hs = _G.hs or {}
local _ORIGINAL_SETTINGS = _G.hs.settings
local test_settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

package.loaded["adapters.storage"] = nil
local Overrides = helpers.load_with_stubs("infra.config_overrides", {settings = test_settings})

local function write_tmp(contents)
	local path = helpers.temp_dir()
		.. "/ergopti_config_overrides_loglevel.toml"
	local fh = assert(io.open(path, "w"))
	fh:write(contents); fh:close()
	return path
end

helpers.describe("config_overrides maps [script] log_level onto the canonical logger key", function()
	helpers.it("a [script] log_level override lands under ergopti.log_level", function()
		for k in pairs(stored) do stored[k] = nil end
		local path = write_tmp('[script]\nlog_level = "ERROR"\nsome_other = 7\n')
		Overrides.apply(path)
		-- The canonical key the logger restore actually reads.
		helpers.assert_eq(stored["ergopti.log_level"], "ERROR")
		-- A non-log [script] key still routes to its bare name (unchanged behavior).
		helpers.assert_eq(stored["ergopti.some_other"], 7)
		-- And it must NOT also leak under the bare "log_level" key (no dead writer).
		helpers.assert_nil(stored["log_level"])
		os.remove(path)
	end)

	helpers.it("the AHK-parity LogLevel spelling is also mapped", function()
		for k in pairs(stored) do stored[k] = nil end
		local path = write_tmp('[script]\nLogLevel = "DEBUG"\n')
		Overrides.apply(path)
		helpers.assert_eq(stored["ergopti.log_level"], "DEBUG")
		os.remove(path)
	end)
end)

helpers.describe("init re-applies the log level after config overrides", function()
	helpers.it("source: Logger.set_level is re-derived from ergopti.log_level after apply", function()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")
		local apply_idx = src:find("config_overrides.apply", 1, true)
		helpers.assert_true(apply_idx ~= nil, "config_overrides.apply must be called at boot")
		-- A set_level reading ergopti.log_level must appear AFTER the overrides apply.
		local reapply = src:find('Logger.set_level', apply_idx, true)
		helpers.assert_true(reapply ~= nil and reapply > apply_idx,
			"the log level must be re-applied AFTER config_overrides.apply")
		helpers.assert_true(src:find('Storage.get("log_level")', apply_idx, true) ~= nil,
			"the re-apply must read the canonical ergopti.log_level key")
	end)
end)

package.loaded["adapters.storage"] = nil
package.loaded["infra.config_overrides"] = nil
if _ORIGINAL_SETTINGS then _G.hs.settings = _ORIGINAL_SETTINGS end


helpers.describe("Expert known-value admission", function()
	local function with_file(source, body)
		helpers.with_stub_scope({ "infra.config_overrides", "adapters.storage", "infra.logger", "logger.shim", "infra.manifest_reader" }, function()
			local observed, warnings, errors, writes = {}, {}, {}, {}
			local logger = helpers.make_logger_stub()
			logger.LEVELS = require("logger").LEVELS
			logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			local controls = {}
			local native = {
				set = function(key, value)
					writes[#writes + 1] = { key = key, value = value }
					if controls.refuse then return false end
					observed[key] = value
				end,
				get = function(key) return observed[key] end,
			}
			local owner = helpers.load_with_stubs("infra.config_overrides", { settings = native })
			_G.hs.settings = native
			local outdated = require("config_outdated")
			outdated.reset_for_tests()
			local path = os.tmpname()
			local function write(content)
				local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
			end
			local function read()
				local file = assert(io.open(path, "rb")); local content = assert(file:read("*a")); assert(file:close()); return content
			end
			write(source)
			local codec = require("infra.toml.codec")
			local ok, detail = xpcall(function()
				body({ owner = owner, path = path, read = read, write = write, codec = codec,
					observed = observed, warnings = warnings, errors = errors, writes = writes,
					controls = controls, logger = logger })
			end, debug.traceback)
			os.remove(path)
			if not ok then error(detail, 0) end
		end)
	end
	local function test(name, body) helpers.it(name .. " (expert-known-value)", body) end
	local VECTORS = {
		{ key = "log_level", literal = "true", value = true },
		{ key = "LogLevel", literal = "17", value = 17 },
		{ key = "LOG_LEVEL", literal = '"TRACE"', value = "TRACE" },
		{ key = "loglevel", literal = '"gone"', value = "gone" },
		{ key = "log_level", literal = '["INFO"]', value = { "INFO" } },
		{ key = "log_level", literal = '{ old = "INFO" }', value = { old = "INFO" } },
	}
	for _, vector in ipairs(VECTORS) do
		test("ignores and preserves obsolete threshold " .. vector.key .. vector.literal, function()
			local source = '[script]\n' .. vector.key .. ' = ' .. vector.literal .. '\nKeptKey = 7\n'
				.. '[future]\nkeep = "independent"\n'
			with_file(source, function(f)
				helpers.assert_eq(f.owner.apply(f.path), 1)
				helpers.assert_eq(f.observed, { ["ergopti.KeptKey"] = 7 })
				local marks = {}
				f.owner.mark_config_reads(f.codec.decode(source), function(...) marks[#marks + 1] = { ... } end)
				helpers.assert_eq(marks, { { "script", "KeptKey" } })
				helpers.assert_eq(f.owner.apply(f.path), 1)
				helpers.assert_eq(#f.warnings, 1, "boot, marks and repeated read share one exact rejection")
				helpers.assert_contains(f.warnings[1], require("toml_codec.key_path").render({ "script", vector.key }))
				helpers.assert_eq(f.errors, {})
				helpers.assert_eq(f.read(), source)
				helpers.assert_eq(f.codec.decode(f.read()), { script = { [vector.key] = vector.value, KeptKey = 7 }, future = { keep = "independent" } })
			end)
		end)
	end
	for _, vector in ipairs({
		{ literal = '"false"', value = "false" },
		{ literal = "17", value = 17 },
		{ literal = '[false]', value = { false } },
		{ literal = '{ old = false }', value = { old = false } },
	}) do
		for _, spelling in ipairs({ 'llm.enabled', '"llm.enabled"' }) do
			test("ignores obsolete native consent " .. spelling .. vector.literal, function()
				local source = '[features]\n' .. spelling .. ' = ' .. vector.literal .. '\nfree = "kept"\n[future]\nkeep = 7\n'
				with_file(source, function(f)
					helpers.assert_eq(f.owner.apply(f.path), 1)
					helpers.assert_eq(f.observed, { ["ergopti.free"] = "kept" }, "invalid consent never reaches native truthiness")
					local marks = {}
					f.owner.mark_config_reads(f.codec.decode(source), function(...) marks[#marks + 1] = { ... } end)
					helpers.assert_eq(marks, { { "features", "free" } })
					helpers.assert_eq(#f.warnings, 1)
					local expected_path = spelling == 'llm.enabled' and { "features", "llm", "enabled" } or { "features", "llm.enabled" }
					helpers.assert_contains(f.warnings[1], require("toml_codec.key_path").render(expected_path))
					local expected = spelling == 'llm.enabled' and { features = { llm = { enabled = vector.value }, free = "kept" }, future = { keep = 7 } }
						or { features = { ["llm.enabled"] = vector.value, free = "kept" }, future = { keep = 7 } }
					helpers.assert_eq(f.codec.decode(f.read()), expected)
					helpers.assert_eq(f.read(), source)
					helpers.assert_eq(f.errors, {})
				end)
			end)
		end
	end
	for _, threshold in ipairs({ "DEBUG", "info", "WARNING", "error" }) do
		test("retains published threshold " .. threshold, function()
			with_file('[script]\nLogLevel = "' .. threshold .. '"\n', function(f)
				helpers.assert_eq(f.owner.apply(f.path), 1)
				helpers.assert_eq(f.observed, { ["ergopti.log_level"] = threshold })
				local marks = {}
				f.owner.mark_config_reads(f.codec.decode(f.read()), function(...) marks[#marks + 1] = { ... } end)
				helpers.assert_eq(marks, { { "script", "LogLevel" } })
				helpers.assert_eq(f.warnings, {})
			end)
		end)
	end
	for _, enabled in ipairs({ true, false }) do
		test("retains Boolean native consent " .. tostring(enabled), function()
			with_file('[features]\nllm.enabled = ' .. tostring(enabled) .. '\n', function(f)
				helpers.assert_eq(f.owner.apply(f.path), 1)
				helpers.assert_eq(f.observed, { ["ergopti.llm.enabled"] = enabled })
				helpers.assert_eq(f.warnings, {})
			end)
		end)
	end
	test("reports a known manifest enum and preserves arbitrary expert compatibility", function()
		local source = '[features]\nui.menubar_icon = "removed"\n"MagicKey.Repeat.Enabled" = false\n[script]\nKeptKey = 1\n'
		with_file(source, function(f)
			helpers.assert_eq(f.owner.apply(f.path), 2)
			helpers.assert_eq(f.observed, { ["ergopti.MagicKey.Repeat.Enabled"] = false, ["ergopti.KeptKey"] = 1 })
			helpers.assert_eq(#f.warnings, 1)
			helpers.assert_contains(f.warnings[1], "features.ui.menubar_icon")
			helpers.assert_eq(f.read(), source)
		end)
	end)
	test("cleanup offers the exact rejected path even if another reader marks it", function()
		local source = '[script]\nlog_level = true\nKeptKey = 7\n'
		with_file(source, function(f)
			local cleanup = require("config_unused_keys")
			local scan = cleanup.find_in_source(source, function(document, mark)
				f.owner.mark_config_reads(document, mark)
				mark("script", "log_level")
			end)
			helpers.assert_eq(scan.status, "ok")
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].section, "script")
			helpers.assert_eq(scan.keys[1].key, "log_level")
			helpers.assert_eq(f.read(), source)
		end)
	end)
	test("keeps choices while the threshold catalogue is unavailable", function()
		with_file('[script]\nlog_level = "future"\n', function(f)
			f.logger.LEVELS = nil
			helpers.assert_eq(f.owner.apply(f.path), 1)
			helpers.assert_eq(f.observed, { ["ergopti.log_level"] = "future" })
			helpers.assert_eq(f.warnings, {})
			f.logger.LEVELS = {}
			helpers.assert_eq(f.owner.apply(f.path), 1, "an empty catalogue is not retirement proof")
			helpers.assert_eq(f.warnings, {})
			f.logger.LEVELS = require("logger").LEVELS
			helpers.assert_eq(f.owner.apply(f.path), 0)
			helpers.assert_eq(#f.warnings, 1)
		end)
	end)
	test("expert metadata admission does not resolve a hardware default", function()
		with_file('[features]\nllm.models.selected = "ollama"\nllm.enabled = false\n', function(f)
			helpers.with_stub_scope({ "modules.llm.backend_detector" }, function()
				package.loaded["modules.llm.backend_detector"] = { auto_default = function()
					error("expert type admission attempted to resolve hardware")
				end }
				helpers.assert_eq(f.owner.apply(f.path), 2)
				helpers.assert_eq(f.observed, { ["ergopti.llm.models.selected"] = "ollama", ["ergopti.llm.enabled"] = false })
				local marks = {}
				f.owner.mark_config_reads(f.codec.decode(f.read()), function(...) marks[#marks + 1] = { ... } end)
				helpers.assert_eq(marks, { { "features", "llm", "enabled" }, { "features", "llm", "models", "selected" } })
			end)
		end)
	end)
	test("retains unsupported section shapes without a new scalar-key crash", function()
		with_file('script = ["DEBUG"]\nfeatures = [true]\n', function(f)
			helpers.assert_eq(f.owner.apply(f.path), 0)
			helpers.assert_eq(f.observed, {})
			helpers.assert_eq(f.errors, {})
			helpers.assert_eq(f.read(), 'script = ["DEBUG"]\nfeatures = [true]\n')
		end)
	end)
	test("keeps malformed file and native write refusals strict", function()
		with_file('[features]\nllm.enabled = false\n', function(f)
			f.controls.refuse = true
			helpers.assert_eq(f.owner.apply(f.path), 0)
			helpers.assert_eq(f.observed, {})
			helpers.assert_eq(#f.errors, 2)
			f.write('[script\nlog_level = "DEBUG"\n')
			helpers.assert_eq(f.owner.apply(f.path), 0)
			helpers.assert_eq(#f.writes, 1, "malformed whole file publishes no further state")
			helpers.assert_eq(#f.errors, 3)
			helpers.assert_eq(f.warnings, {})
		end)
	end)
end)


helpers.describe("Expert classified source admission", function()
	local SOURCE = '[script]\nlog_level = "INFO"\n[future]\nkeep = "independent"\n'
	local function with_file(body)
		helpers.with_stub_scope({ "infra.config_overrides", "adapters.storage", "adapters.file_system", "infra.logger", "logger.shim", "infra.manifest_reader" }, function()
			local observed, warnings, errors, debug_messages = {}, {}, {}, {}
			local logger = helpers.make_logger_stub()
			logger.LEVELS = require("logger").LEVELS
			logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			logger.debug = function(_, fmt, ...) debug_messages[#debug_messages + 1] = string.format(fmt, ...) end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			local native = {
				set = function(key, value) observed[key] = value end,
				get = function(key) return observed[key] end,
			}
			local owner = helpers.load_with_stubs("infra.config_overrides", { settings = native })
			_G.hs.settings = native
			local files = require("adapters.file_system")
			local native_read, native_open = files.read_with_status, io.open
			local path = os.tmpname()
			local function write(content)
				local file = assert(native_open(path, "wb")); assert(file:write(content)); assert(file:close())
			end
			local function read()
				local file = assert(native_open(path, "rb")); local content = assert(file:read("*a")); assert(file:close()); return content
			end
			write(SOURCE)
			local ok, detail = xpcall(function()
				body({ owner = owner, files = files, path = path, read = read, write = write,
					observed = observed, warnings = warnings, errors = errors, debug = debug_messages,
					native_open = native_open, native_read = native_read })
			end, debug.traceback)
			files.read_with_status, io.open = native_read, native_open
			os.remove(path)
			if not ok then error(detail, 0) end
		end)
	end
	local function test(name, body) helpers.it(name .. " (expert-classified-read)", body) end
	test("admits actual regular source bytes and no source mutation", function()
		with_file(function(f)
			helpers.assert_eq(f.owner.apply(f.path), 1)
			helpers.assert_eq(f.observed, { ["ergopti.log_level"] = "INFO" })
			helpers.assert_eq(f.read(), SOURCE)
			helpers.assert_eq(f.errors, {})
		end)
	end)
	test("only proven native absence remains a no-op", function()
		with_file(function(f)
			helpers.assert_true(os.remove(f.path))
			local content, status = f.native_read(f.path)
			helpers.assert_nil(content)
			helpers.assert_eq(status, "absent")
			helpers.assert_eq(f.owner.apply(f.path), 0)
			helpers.assert_eq(f.observed, {})
			helpers.assert_eq(f.errors, {})
			helpers.assert_contains(table.concat(f.debug, "\n"), "not found")
		end)
	end)
	for _, receipt in ipairs({
		{ name = "native open refusal", result = function(_, diagnostic) diagnostic("open"); return nil, "error", "private source marker" end },
		{ name = "reader exception", result = function() error("private source marker") end },
		{ name = "reported failure with ok", result = function(_, diagnostic) diagnostic("open"); return SOURCE, "ok" end },
		{ name = "reported failure with absent", result = function(_, diagnostic) diagnostic("absent"); return nil, "absent" end },
		{ name = "nil status", result = function() return SOURCE, nil end },
		{ name = "truthy status", result = function() return SOURCE, true end },
		{ name = "wrong status", result = function() return SOURCE, "ready" end },
		{ name = "absent with bytes", result = function() return SOURCE, "absent" end },
		{ name = "ok without bytes", result = function() return nil, "ok" end },
		{ name = "ok with false", result = function() return false, "ok" end },
	}) do
		test("refuses " .. receipt.name .. " without native publication", function()
			with_file(function(f)
				f.files.read_with_status = receipt.result
				helpers.assert_eq(f.owner.apply(f.path), 0)
				helpers.assert_eq(f.observed, {})
				helpers.assert_eq(f.read(), SOURCE)
				helpers.assert_eq(#f.errors, 1)
				helpers.assert_contains(f.errors[1], f.path)
				helpers.assert_true(f.errors[1]:find("private source marker", 1, true) == nil, "source-bearing native details remain withheld")
				helpers.assert_eq(f.warnings, {})
			end)
		end)
	end
	for _, phase in ipairs({ "read", "close" }) do
		test("retains native " .. phase .. " refusal through the actual classified reader", function()
			with_file(function(f)
				io.open = function(path, mode)
					local handle, detail, errno = f.native_open(path, mode)
					if path ~= f.path or not handle then return handle, detail, errno end
					return {
						read = function()
							if phase == "read" then return nil, "controlled read refusal" end
							return handle:read("*a")
						end,
						close = function()
							assert(handle:close())
							if phase == "close" then return false, "controlled close refusal" end
							return true
						end,
					}
				end
				helpers.assert_eq(f.owner.apply(f.path), 0)
				helpers.assert_eq(f.observed, {})
				helpers.assert_eq(#f.errors, 1)
				helpers.assert_contains(f.errors[1], phase)
				helpers.assert_eq(f.read(), SOURCE)
			end)
		end)
	end
	test("empty regular source is admitted without fabrication", function()
		with_file(function(f)
			f.write("")
			helpers.assert_eq(f.owner.apply(f.path), 0)
			helpers.assert_eq(f.observed, {})
			helpers.assert_eq(f.errors, {})
			helpers.assert_eq(f.read(), "")
		end)
	end)
end)


helpers.describe("Persisted native consent admission", function()
	local function with_native(value, body)
		helpers.with_stub_scope({ "infra.config_overrides", "adapters.storage", "infra.logger", "logger.shim", "infra.manifest_reader" }, function()
			local stored = { ["ergopti.llm.enabled"] = value, ["ergopti.log_level"] = "ERROR",
				["foreign.future"] = { keep = false, values = { 1, "future" } } }
			local function detached(value)
				if type(value) ~= "table" then return value end
				local copy = {}
				for key, child in pairs(value) do copy[key] = detached(child) end
				return copy
			end
			local predecessor = detached(stored)
			local warnings, writes = {}, 0
			local logger = helpers.make_logger_stub()
			logger.LEVELS = require("logger").LEVELS
			logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			logger.callback = function(_, _, callback) callback() end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			local native = {
				set = function(key, replacement) writes = writes + 1; stored[key] = replacement end,
				clear = function(key) writes = writes + 1; stored[key] = nil end,
				get = function(key) return stored[key] end,
			}
			local owner = helpers.load_with_stubs("infra.config_overrides", { settings = native })
			_G.hs.settings = native
			local storage = require("adapters.storage")
			require("config_outdated").reset_for_tests()
			local manifest = require("infra.manifest_reader")
			local entry = assert(manifest.find_declared_entry_by_path("llm.enabled"))
			helpers.assert_eq(entry.type, "boolean", "the actual published declaration owns consent's type")
			local neutral = manifest.default_for("llm.enabled")
			helpers.assert_eq(neutral, false, "the actual published neutral consent remains opt-in")
			local source = assert(helpers.read_driver_source("local function has_common_hotstring_groups"))
			local cleanup = assert(source:match("(local mlx_cleanup_enabled = [^\n]+)"))
			local bootstrap = assert(source:match("(local boot_llm_enabled =.-)\nlocal function start_llm_bootstrap%(%)"))
			local gate = assert(source:match('(if boot_llm_enabled then.-)\n\nBoot.mark%("LLM backend bootstrap"%)'))
			local compiled = assert(load("return function(config_overrides, Storage, boot_saved_prefs, neutral, Logger)\n"
				.. "local ok_core_llm, core_llm = true, { DEFAULT_STATE = { llm_enabled = neutral } }\n"
				.. cleanup .. "\nlocal mlx_cleanup_settled = not mlx_cleanup_enabled\nlocal pending_llm_bootstrap\n"
				.. bootstrap .. "\nlocal started = 0\nlocal function start_llm_bootstrap() started = started + 1 end\n"
				.. gate .. "\nreturn mlx_cleanup_enabled, boot_llm_enabled, started, pending_llm_bootstrap ~= nil\nend",
				"@native-consent-actual-init-slices"))()
			body({ owner = owner, storage = storage, stored = stored, warnings = warnings,
				manifest = manifest, entry = entry, neutral = neutral,
				writes = function() return writes end,
				boot = function(prefs) return compiled(owner, storage, prefs or {}, neutral, logger) end })
			helpers.assert_eq(stored, predecessor, "native defaults retain an independent complete predecessor model")
			helpers.assert_eq(storage.get("log_level"), "ERROR", "a valid retained logger threshold keeps its meaning")
			helpers.assert_eq(writes, 0, "read admission never clears or rewrites native defaults")
		end)
	end
	for _, vector in ipairs({
		{ name = "text true", value = "true" }, { name = "text false", value = "false" },
		{ name = "integer", value = 17 }, { name = "zero", value = 0 },
		{ name = "empty object", value = {} }, { name = "object", value = { old = true } },
		{ name = "array", value = { false } },
	}) do
		helpers.it("legacy " .. vector.name .. " cannot enter the actual immediate or delayed bootstrap", function()
			with_native(vector.value, function(f)
				local _, enabled, started, pending = f.boot({ llm_enabled = f.neutral })
				helpers.assert_eq(started, 0, "obsolete consent cannot invoke a runtime bootstrap")
				helpers.assert_eq(pending, false, "obsolete consent cannot retain a future runtime bootstrap")
				helpers.assert_eq(enabled, false)
			end)
		end)
		helpers.it("refuses legacy " .. vector.name .. " through the actual boot consent gates", function()
			with_native(vector.value, function(f)
				local cleanup, enabled, started, pending = f.boot({ llm_enabled = f.neutral })
				helpers.assert_eq(cleanup, false, "obsolete native consent cannot admit MLX cleanup")
				helpers.assert_eq(enabled, false, "obsolete native consent reads as absent before the neutral fallback")
				helpers.assert_eq(started, 0)
				helpers.assert_eq(pending, false, "obsolete consent cannot queue a delayed activation")
				f.boot({ llm_enabled = f.neutral })
				helpers.assert_eq(#f.warnings, 1, "both gates and repeated boot reads share one warning identity")
				helpers.assert_contains(f.warnings[1], "hs.settings")
				helpers.assert_contains(f.warnings[1], "llm.enabled")
				helpers.assert_contains(f.warnings[1], "the value is not a boolean")
			end)
		end)
	end
	for _, value in ipairs({ false, true }) do
		helpers.it("retains acknowledged Boolean native consent " .. tostring(value), function()
			with_native(value, function(f)
				local cleanup, enabled, started, pending = f.boot({ llm_enabled = not value })
				helpers.assert_eq(cleanup, value)
				helpers.assert_eq(enabled, value, "valid native consent retains its existing precedence")
				helpers.assert_eq(started, 0)
				helpers.assert_eq(pending, value)
				helpers.assert_eq(f.owner.read_native_value("llm.enabled"), value)
				helpers.assert_eq(f.warnings, {})
			end)
		end)
	end
	helpers.it("absence uses the actual neutral opt-in default without native materialization", function()
		with_native(nil, function(f)
			local cleanup, enabled, started, pending = f.boot()
			helpers.assert_eq(cleanup, false)
			helpers.assert_eq(enabled, false)
			helpers.assert_eq(started, 0)
			helpers.assert_eq(pending, false)
			helpers.assert_nil(f.owner.read_native_value("llm.enabled"))
			helpers.assert_eq(f.warnings, {})
		end)
	end)
	for _, value in ipairs({ "false", 17, {} }) do
		helpers.it("obsolete residue cannot veto independently acknowledged canonical consent " .. type(value), function()
			with_native(value, function(f)
				local cleanup, enabled, started, pending = f.boot({ llm_enabled = true })
				helpers.assert_eq(cleanup, false)
				helpers.assert_eq(enabled, true)
				helpers.assert_eq(started, 1)
				helpers.assert_eq(pending, false)
				helpers.assert_eq(#f.warnings, 1)
			end)
		end)
	end
	helpers.it("obsolete source and native residue preserve actual source bytes and the logger's valid value", function()
		with_native("false", function(f)
			local source = '[script]\nlog_level = "gone"\n[features]\nllm.enabled = "false"\n[future]\nkeep = [1, "future"]\n'
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local okay, detail = xpcall(function()
				helpers.assert_eq(f.owner.apply(path), 0)
				local cleanup, enabled, started, pending = f.boot()
				helpers.assert_eq(cleanup, false)
				helpers.assert_eq(enabled, false)
				helpers.assert_eq(started, 0)
				helpers.assert_eq(pending, false)
				helpers.assert_eq(f.owner.apply(path), 0)
				f.boot()
				helpers.assert_eq(#f.warnings, 3, "source and native domains retain their independent once-only warnings")
				local current = assert(io.open(path, "rb"))
				local bytes = assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes, source, "source refusal and boot admission never rewrite TOML")
			end, debug.traceback)
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end)
	helpers.it("admission uses the published owner rather than a duplicated Boolean allowlist", function()
		with_native(17, function(f)
			local old = f.entry.type
			local okay, detail = xpcall(function()
				f.entry.type = "number"
				helpers.assert_eq(f.owner.read_native_value("llm.enabled"), 17)
				helpers.assert_eq(f.warnings, {})
			end, debug.traceback)
			f.entry.type = old
			if not okay then error(detail, 0) end
		end)
	end)
	helpers.it("a missing published declaration stays fail-closed without probing hardware", function()
		with_native(true, function(f)
			helpers.assert_eq(type(f.owner.read_native_value), "function", "the refusal control needs the actual admission owner")
			local find = f.manifest.find_declared_entry_by_path
			f.manifest.find_declared_entry_by_path = function() return nil end
			local called = pcall(f.owner.read_native_value, "llm.enabled")
			f.manifest.find_declared_entry_by_path = find
			helpers.assert_eq(called, false)
			helpers.assert_eq(f.warnings, {})
		end)
	end)
end)
