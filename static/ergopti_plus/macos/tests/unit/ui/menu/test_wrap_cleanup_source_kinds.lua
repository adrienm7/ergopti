-- static/ergopti_plus/macos/tests/unit/ui/menu/test_wrap_cleanup_source_kinds.lua

--- Explicit cleanup retains admitted Wrap source kinds through the real file writer.
local helpers = require("tests.helpers")
local output = require("tests.support.toml_output_fixture")
local function read(path)
	local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end
local function write(path, bytes)
	local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
end
local function with_source(source, callback)
	return helpers.with_stub_scope({ "infra.preferences", "ui.menu.unused_keys_cleanup", "menu.wrap_preferences",
		"adapters.file_system", "infra.fs_dir", "infra.logger" }, function()
		helpers.load_with_stubs("infra.logger")
		local preferences = helpers.load_with_stubs("infra.preferences")
		local cleanup = helpers.load_with_stubs("ui.menu.unused_keys_cleanup")
		local engine = require("config_unused_keys")
		return output.with_output(function(path)
			write(path, source)
			local backup = engine.backup_path(path, "wrap-source-kinds")
			local receipt = table.pack(pcall(callback, path, backup, preferences, cleanup, engine, require("adapters.file_system")))
			for _, owned in ipairs({ backup, backup .. ".ergoptiplus-write-lock-v1" }) do
				local removed, reason, code = os.remove(owned)
				assert(removed or code == 2, "owned backup cleanup failed: " .. tostring(reason))
			end
			if not receipt[1] then error(receipt[2], 0) end
			return table.unpack(receipt, 2, receipt.n)
		end)
	end)
end
local SOURCE = '[shortcuts]\nwrap_symbols={states={"("=false,"."=true,old="obsolete"},custom=[{left="🙂",right="é",future=[],dictionary={},scientific=1e2,date=2026-10-05,"literal.dot"=[]}],future=[]}\n'
helpers.describe("actual-file explicit Wrap cleanup source kinds", function()
	helpers.it("removes only the two offered entries while retaining pair kinds, scalar tokens and literal identities", function()
		with_source(SOURCE, function(path, backup, preferences, cleanup, engine, files)
			local projection, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			local found = engine.find_in_source(SOURCE, cleanup.collect)
			helpers.assert_eq(#found.keys, 2)
			local result = engine.remove({ path = path, keys = found.keys, stamp = "wrap-source-kinds", file_adapter = files, expected_source = SOURCE })
			helpers.assert_eq(result.status, "removed")
			helpers.assert_eq(result.removed, 2)
			helpers.assert_eq(read(backup), SOURCE, "backup contains exact pre-publication bytes")
			helpers.assert_eq(read(path), result.content)
			local document, shapes = require("toml_codec").decode_with_shapes(read(path))
			local wrap = document.shortcuts.wrap_symbols
			helpers.assert_nil(wrap.states.old)
			helpers.assert_nil(wrap.future)
			helpers.assert_eq(wrap.states["("], false)
			helpers.assert_eq(wrap.states["."], true)
			helpers.assert_eq(#wrap.custom, 1)
			helpers.assert_eq(wrap.custom[1].left, "🙂")
			helpers.assert_eq(wrap.custom[1].right, "é")
			helpers.assert_eq(shapes.arrays[wrap.custom[1].future], true)
			helpers.assert_nil(shapes.arrays[wrap.custom[1].dictionary])
			helpers.assert_eq(shapes.arrays[wrap.custom[1]["literal.dot"]], true)
			helpers.assert_true(result.content:find("scientific = 1e2", 1, true) ~= nil)
			helpers.assert_true(result.content:find("date = 2026-10-05", 1, true) ~= nil)
			helpers.assert_eq(preferences.adopt_cleanup(path, result.previous, result.content), true)
			helpers.assert_eq(engine.find_in_source(read(path), cleanup.collect).keys, {})
			projection.wrap_symbol_states["("] = true
			helpers.assert_eq(preferences.save(path, projection, {}, {}), true, "actual native source owner admits the next ordinary change")
			local saved, saved_shapes = require("toml_codec").decode_with_shapes(read(path))
			helpers.assert_eq(saved.shortcuts.wrap_symbols.states["("], true)
			helpers.assert_eq(saved_shapes.arrays[saved.shortcuts.wrap_symbols.custom[1].future], true)
		end)
	end)
	helpers.it("refuses a physical successor after preview without creating a backup or replacing it", function()
		with_source(SOURCE, function(path, backup, _, cleanup, engine, files)
			local found = engine.find_in_source(SOURCE, cleanup.collect)
			local successor = SOURCE .. '\n[external]\ntoken="retain"\n'
			write(path, successor)
			local result = engine.remove({ path = path, keys = found.keys, stamp = "wrap-source-kinds", file_adapter = files, expected_source = SOURCE })
			helpers.assert_eq(result.status, "changed")
			helpers.assert_eq(read(path), successor)
			helpers.assert_nil(io.open(backup, "rb"))
		end)
	end)
end)
