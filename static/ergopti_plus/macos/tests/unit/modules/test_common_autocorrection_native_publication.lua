--- tests/unit/modules/test_common_autocorrection_native_publication.lua
--- Actual adapter, Writer and override controller with real temporary I/O.
--- Native locking and close refusals are doubled; physical macOS remains separate.
local helpers = require("tests.helpers")
local with_files = require("tests.support.file_system_transaction_fixture").with_fixture
local Codec = require("toml_codec")

local function with_native(body)
	helpers.with_fresh_modules({ "modules.hotstrings.hotstrings_config",
		"hotstrings.common_autocorrection_migration", "hotstrings.publication_recovery", "toml_codec.writer" }, function()
		with_files(function(native)
			local f = { path = os.tmpname():gsub("\\", "/"), release = false, locks = 0,
				unlocks = 0, closes = 0, renames = 0, handles = {} }
			f.original = '# independent native migration preimage\n[autocorrection.caps]\ndelay = 0.3\n'
			local seed = assert(io.open(f.path, "wb")); assert(seed:write(f.original)); assert(seed:close())
			local saved_open, saved_rename = io.open, os.rename
			local files = native.make_adapter(nil, nil, nil, nil, function()
				f.locks = f.locks + 1
				if f.held then return nil, "independent busy native lock" end
				f.held = true; return true
			end, function()
				f.unlocks = f.unlocks + 1
				if not f.release then return nil, "independent native unlock refusal" end
				f.held = false; return true
			end)
			io.open = function(path, mode)
				local handle, detail = saved_open(path, mode)
				if not handle or path ~= f.path .. native.WRITE_LOCK_SUFFIX or mode ~= "a+" then return handle, detail end
				local wrapper = { close = function()
					f.closes = f.closes + 1
					if not f.release then return nil, "independent native close refusal" end
					return handle:close()
				end }
				f.handles[#f.handles + 1] = handle
				return wrapper
			end
			os.rename = function(source, destination)
				if destination == f.path then
					f.renames = f.renames + 1
					if f.refuse_rename then return nil, "independent prepublication refusal" end
				end
				local renamed, detail = saved_rename(source, destination)
				if renamed and destination == f.path and f.after_rename then f.after_rename() end
				return renamed, detail
			end
			f.files = files
			f.Config = require("modules.hotstrings.hotstrings_config")
			function f.read()
				local handle = assert(saved_open(f.path, "rb")); local bytes = handle:read("*a")
				assert(handle:close()); return bytes
			end
			function f.init()
				return f.Config.init({ override_path = f.path, toml_resolver = function() return nil end,
					current_override_path = function() return f.path end })
			end
			local ok, detail = xpcall(function() body(f) end, debug.traceback)
			-- Settle the exact retained owner before replacing module/IO bindings.
			f.release = true; f.refuse_rename = false; f.after_rename = nil
			local settled = f.Config.reload()
			io.open, os.rename = saved_open, saved_rename
			for _, handle in ipairs(f.handles) do pcall(function() handle:close() end) end
			os.remove(f.path); os.remove(f.path .. native.WRITE_LOCK_SUFFIX)
			if not ok then error(detail, 0) end
			helpers.assert_true(settled, "fixture must leave no retained native publication")
			helpers.assert_eq(f.held, false, "fixture must release the actual injected mutex")
		end)
	end)
end

helpers.describe("common autocorrection actual native publication", function()
	helpers.it("(common-autocorrection-native) retains post-rename unlock and close debt before owned inverse", function()
		with_native(function(f)
			helpers.assert_eq(f.init(), false)
			helpers.assert_eq(f.renames, 1); helpers.assert_true(f.held)
			helpers.assert_true(f.unlocks > 0 and f.closes > 0, "both physical release operations refused")
			helpers.assert_nil(Codec.decode(f.read()).autocorrection.caps)
			helpers.assert_true(f.Config.has_pending_publication())
			helpers.assert_eq(f.Config.common_autocorrection_admitted(), false)
			helpers.assert_eq(f.Config.reload(), false); helpers.assert_eq(f.renames, 1)
			helpers.assert_eq(f.Config.init({ override_path = "foreign", toml_resolver = function() return nil end }), false)
			helpers.assert_eq(f.Config.acquire({}), false)
			f.release = true
			helpers.assert_true(f.Config.reload())
			helpers.assert_eq(f.renames, 3, "actual retained release, exact source inverse and new migration")
			helpers.assert_eq(f.Config.has_pending_publication(), false)
			helpers.assert_true(f.Config.common_autocorrection_admitted())
			local decoded = Codec.decode(f.read())
			for _, family in ipairs({ "names", "abbreviations", "technical_terms" }) do
				helpers.assert_eq(decoded.autocorrection[family].delay, 0.3)
				helpers.assert_eq(f.Config.get_user_override("autocorrection", family).delay, 0.3)
			end
		end)
	end)
	helpers.it("(common-autocorrection-native) release-only receipt never publishes an inverse", function()
		with_native(function(f)
			f.refuse_rename = true
			helpers.assert_eq(f.init(), false); helpers.assert_eq(f.read(), f.original)
			helpers.assert_true(f.Config.has_pending_publication()); helpers.assert_true(f.held)
			helpers.assert_eq(f.Config.reload(), false); helpers.assert_eq(f.renames, 1)
			f.release = true; f.refuse_rename = false
			helpers.assert_true(f.Config.reload())
			helpers.assert_eq(f.renames, 2, "only a new migration renames after release-only settlement")
			helpers.assert_eq(f.Config.has_pending_publication(), false)
		end)
	end)
	helpers.it("(common-autocorrection-native) inverse post-rename release debt cannot admit its restored source", function()
		with_native(function(f)
			helpers.assert_eq(f.init(), false)
			f.release = true
			f.after_rename = function() if f.renames == 2 then f.release = false end end
			helpers.assert_eq(f.Config.reload(), false)
			helpers.assert_eq(f.read(), f.original)
			helpers.assert_eq(f.renames, 2); helpers.assert_true(f.held)
			helpers.assert_true(f.Config.has_pending_publication())
			helpers.assert_eq(f.Config.common_autocorrection_admitted(), false)
			helpers.assert_eq(f.Config.reload(), false); helpers.assert_eq(f.renames, 2)
			f.release = true; f.after_rename = nil
			helpers.assert_true(f.Config.reload()); helpers.assert_eq(f.renames, 3)
			helpers.assert_eq(f.Config.has_pending_publication(), false)
		end)
	end)

end)
