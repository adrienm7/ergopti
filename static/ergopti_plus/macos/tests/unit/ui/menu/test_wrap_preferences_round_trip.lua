-- static/ergopti_plus/macos/tests/unit/ui/menu/test_wrap_preferences_round_trip.lua

--- Actual-file Wrap publication and typed-source preservation regressions.
local helpers = require("tests.helpers")
local output = require("tests.support.toml_output_fixture")
local roundtrip = require("tests.support.preferences_roundtrip_fixture")
local function read(path)
	local handle = assert(io.open(path, "rb"))
	local bytes = assert(handle:read("*a"))
	assert(handle:close())
	return bytes
end
local function write(path, bytes)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(bytes))
	assert(handle:close())
end
local function with_source(source, callback)
	return helpers.with_stub_scope({ "infra.preferences", "infra.logger", "adapters.file_system", "infra.fs_dir",
		"menu.wrap_preferences", "menu.wrap_mutation", "compat.utf8" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local preferences = helpers.load_with_stubs("infra.preferences")
		return output.with_output(function(path)
			write(path, source)
			local flat, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			return callback(preferences, path, flat)
		end)
	end)
end

helpers.describe("actual-file Wrap preference roundtrip", function()
	helpers.it("restores independently authored symbols, pair order and future metadata", function()
		local expected = {
			wrap_symbol_states = { ["("] = false, ["."] = false, ["é"] = true, ["\""] = false },
			custom_wrap_symbols = { { left = "🙂", right = "é", future = { note = "retain", flags = { true, false } } },
				{ left = "a", right = "b" } },
		}
		roundtrip.with_roundtrip(expected, function(saved, preferences, path)
			helpers.assert_eq(saved.wrap_symbol_states, expected.wrap_symbol_states)
			helpers.assert_eq(saved.custom_wrap_symbols, expected.custom_wrap_symbols)
			local state = { wrap_symbol_states = {}, custom_wrap_symbols = {} }
			preferences.merge_saved_data(state, saved)
			helpers.assert_eq(state, expected, "boot overlay must restore exact saved projection")
			local text = helpers.load_with_stubs("modules.shortcuts.actions.text")
			local active = text.build_active_wrap_pairs(state.wrap_symbol_states, state.custom_wrap_symbols)
			helpers.assert_nil(active["("], "first input must respect persisted disabled built-in")
			helpers.assert_eq(active["🙂"], { left = "🙂", right = "é" })
			helpers.assert_eq(active.b, { left = "a", right = "b" })
			local receipt = preferences.publication_receipt(path)
			helpers.assert_eq(receipt.id, 1)
			helpers.assert_eq(receipt.source.content, read(path), "ACK belongs to actual physical bytes")
		end)
	end)
	helpers.it("clear removes acknowledged pairs without erasing future or obsolete neighbors", function()
		local source = '[shortcuts.wrap_symbols]\ncustom = [{left="a",right="b",future={note="retain"}}]\nfuture = { token="keep" }\n[shortcuts.wrap_symbols.states]\n"(" = false\nold = "obsolete"\n'
		with_source(source, function(preferences, path)
			helpers.assert_eq(preferences.save(path, { wrap_symbol_states = {}, custom_wrap_symbols = {} }, {}, {}), true)
			local document = require("toml_codec").decode(read(path))
			helpers.assert_nil(document.shortcuts.wrap_symbols.custom)
			helpers.assert_eq(document.shortcuts.wrap_symbols.future, { token = "keep" })
			helpers.assert_eq(document.shortcuts.wrap_symbols.states.old, "obsolete")
			helpers.assert_nil(document.shortcuts.wrap_symbols.states["("])
		end)
	end)
	for _, form in ipairs({ '[]', '{}' }) do
		helpers.it("retains source-bound states kind " .. form, function()
			local source = '[shortcuts.wrap_symbols]\nstates = ' .. form .. '\n'
			with_source(source, function(preferences, path, flat)
				if form == '[]' then helpers.assert_nil(flat.wrap_symbol_states)
				else helpers.assert_eq(flat.wrap_symbol_states, {}) end
				helpers.assert_eq(preferences.save(path, { wrap_symbol_states = {}, custom_wrap_symbols = {} }, {}, {}), true)
				local doc, shapes = require("toml_codec").decode_with_shapes(read(path))
				helpers.assert_eq(shapes.arrays[doc.shortcuts.wrap_symbols.states] == true, form == '[]')
			end)
		end)
		helpers.it("interprets source-bound custom kind " .. form, function()
			local source = '[shortcuts.wrap_symbols]\ncustom = ' .. form .. '\n'
			with_source(source, function(preferences, path, flat)
				if form == '{}' then helpers.assert_nil(flat.custom_wrap_symbols)
				else helpers.assert_eq(flat.custom_wrap_symbols, {}) end
				helpers.assert_eq(preferences.save(path, { custom_wrap_symbols = {} }, {}, {}), true)
				if form == '{}' then
					local doc, shapes = require("toml_codec").decode_with_shapes(read(path))
					helpers.assert_eq(doc.shortcuts.wrap_symbols.custom, {})
					helpers.assert_nil(shapes.arrays[doc.shortcuts.wrap_symbols.custom])
				end
			end)
		end)
	end
	local collisions = {
		{ source = '[shortcuts]\nwrap_symbols = "old"\n', desired = { wrap_symbol_states = { ["("] = false } } },
		{ source = '[shortcuts.wrap_symbols]\nstates = []\n', desired = { wrap_symbol_states = { ["("] = false } } },
		{ source = '[shortcuts.wrap_symbols.states]\n"(" = "old"\n', desired = { wrap_symbol_states = { ["("] = false } } },
		{ source = '[shortcuts.wrap_symbols]\ncustom = {}\n', desired = { custom_wrap_symbols = { { left = "a", right = "b" } } } },
		{ source = '[shortcuts.wrap_symbols]\ncustom = [{left="future",right="shape",private="keep"}]\n', desired = { custom_wrap_symbols = { { left = "a", right = "b" } } } },
	}
	for index, case in ipairs(collisions) do
		helpers.it("refuses obsolete source collision " .. index .. " without issuing ACK", function()
			with_source(case.source, function(preferences, path)
				local receipt = preferences.publication_receipt(path)
				helpers.assert_eq(preferences.save(path, case.desired, {}, {}), false)
				helpers.assert_eq(read(path), case.source, "ordinary save cannot erase obsolete source")
				helpers.assert_eq(preferences.publication_receipt(path), receipt)
			end)
		end)
	end
	helpers.it("refuses an external physical successor then retries against adopted exact bytes", function()
		with_source('[shortcuts.wrap_symbols]\ncustom = [{left="a",right="b"}]\n', function(preferences, path, flat)
			local mutation = require("menu.wrap_mutation")
			local before = read(path)
			local successor = before .. '\n[future]\ntoken = "retain"\n'
			write(path, successor)
			local function remove(candidate) table.remove(candidate.custom_wrap_symbols, 1); return true end
			local function save() return preferences.save(path, flat, {}, {}) end
			helpers.assert_eq(mutation.commit(flat, remove, save), false)
			helpers.assert_eq(flat.custom_wrap_symbols, { { left = "a", right = "b" } })
			helpers.assert_eq(read(path), successor)
			helpers.assert_eq(preferences.publication_receipt(path).id, 0)
			helpers.assert_eq(mutation.commit(flat, remove, save), true)
			local persisted, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_nil(persisted.custom_wrap_symbols)
			helpers.assert_eq(require("toml_codec").decode(read(path)).future.token, "retain")
			helpers.assert_eq(preferences.publication_receipt(path).id, 1)
		end)
	end)
	for _, kinds in ipairs({ { "[]", "{}" }, { "{}", "[]" } }) do
		helpers.it("retains externally adopted future kind " .. kinds[1] .. " to " .. kinds[2] .. " despite equal Lua models", function()
			local function source(kind)
				return '[shortcuts]\nwrap_symbols={states={"("=false},custom=[{left="a",right="b",future=' .. kind .. '}],future=' .. kind .. '}\n'
			end
			with_source(source(kinds[1]), function(preferences, path, flat)
				local before_doc = require("toml_codec").decode(source(kinds[1]))
				local next_doc = require("toml_codec").decode(source(kinds[2]))
				helpers.assert_eq(before_doc, next_doc, "ordinary model equality cannot admit a kind change")
				local successor = source(kinds[2])
				write(path, successor)
				local function enable(candidate) candidate.wrap_symbol_states["("] = true; return true end
				local mutation = require("menu.wrap_mutation")
				local function save() return preferences.save(path, flat, {}, {}) end
				helpers.assert_eq(mutation.commit(flat, enable, save), false)
				helpers.assert_eq(read(path), successor)
				helpers.assert_eq(flat.wrap_symbol_states["("], false)
				helpers.assert_eq(mutation.commit(flat, enable, save), true)
				local doc, shapes = require("toml_codec").decode_with_shapes(read(path))
				local wrap = doc.shortcuts.wrap_symbols
				helpers.assert_eq(wrap.states["("], true)
				helpers.assert_eq(shapes.arrays[wrap.future] == true, kinds[2] == "[]")
				helpers.assert_eq(shapes.arrays[wrap.custom[1].future] == true, kinds[2] == "[]")
				helpers.assert_eq(preferences.publication_receipt(path).id, 1)
			end)
		end)
	end
	helpers.it("refuses adopted changes to source pair identities until the projection is reloaded", function()
		with_source('[shortcuts.wrap_symbols]\ncustom=[{left="a",right="b",future=[]}]\n', function(preferences, path, flat)
			local successor = '[shortcuts.wrap_symbols]\ncustom=[{left="c",right="d",future={}}]\n'
			write(path, successor)
			flat.wrap_symbol_states = { ["("] = false }
			helpers.assert_eq(preferences.save(path, flat, {}, {}), false)
			helpers.assert_eq(preferences.save(path, flat, {}, {}), false, "adoption alone cannot give a cached pair a new identity")
			helpers.assert_eq(read(path), successor)
			helpers.assert_eq(preferences.publication_receipt(path).id, 0)
			local current, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			current.wrap_symbol_states = { ["("] = false }
			helpers.assert_eq(preferences.save(path, current, {}, {}), true)
			local doc, shapes = require("toml_codec").decode_with_shapes(read(path))
			helpers.assert_eq(doc.shortcuts.wrap_symbols.custom[1].left, "c")
			helpers.assert_nil(shapes.arrays[doc.shortcuts.wrap_symbols.custom[1].future])
		end)
	end)
	helpers.it("deletes the actual duplicate record while retaining its sibling's metadata identity", function()
		with_source('[shortcuts.wrap_symbols]\ncustom=[{left="a",right="b",future=[]},{left="a",right="b",future={}}]\n', function(preferences, path, flat)
			local mutation = require("menu.wrap_mutation")
			helpers.assert_eq(mutation.commit(flat, function(candidate)
				table.remove(candidate.custom_wrap_symbols, 1); return true
			end, function() return preferences.save(path, flat, {}, {}) end), true)
			local doc, shapes = require("toml_codec").decode_with_shapes(read(path))
			helpers.assert_eq(#doc.shortcuts.wrap_symbols.custom, 1)
			helpers.assert_nil(shapes.arrays[doc.shortcuts.wrap_symbols.custom[1].future], "surviving second dictionary is not first record's array")
		end)
	end)

	helpers.it("retains adjacent native inline future kinds during an unrelated symbol toggle", function()
		local source = '[shortcuts]\nkeys={ctrl_d=false,future=[]}\nwrap_symbols={states={"("=false},custom=[{left="a",right="b",future=[]}],future=[]}\n'
		with_source(source, function(preferences, path, flat)
			local before = preferences.publication_receipt(path)
			local mutation = require("menu.wrap_mutation")
			helpers.assert_eq(mutation.commit(flat, function(candidate)
				candidate.wrap_symbol_states["("] = true; return true
			end, function() return preferences.save(path, flat, {}, {}) end), true)
			local document, shapes = require("toml_codec").decode_with_shapes(read(path))
			helpers.assert_eq(document.shortcuts.wrap_symbols.states["("], true)
			helpers.assert_eq(shapes.arrays[document.shortcuts.keys.future], true, "complete native snapshot cannot change another domain's unowned future kind")
			helpers.assert_eq(shapes.arrays[document.shortcuts.wrap_symbols.future], true)
			helpers.assert_eq(shapes.arrays[document.shortcuts.wrap_symbols.custom[1].future], true)
			helpers.assert_eq(preferences.publication_receipt(path).id, before.id + 1)
		end)
	end)
end)
