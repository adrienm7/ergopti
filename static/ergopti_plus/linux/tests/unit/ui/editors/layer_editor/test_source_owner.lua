--- tests/unit/ui/editors/layer_editor/test_source_owner.lua

--- ==============================================================================
--- MODULE: Layer Editor Opening Source Ownership (Linux)
--- DESCRIPTION:
--- A draft belongs to the exact folder and bytes offered by ready. Saving must
--- not adopt another selected folder or overwrite a later edit in the same file.
--- ==============================================================================

local helpers = require("tests.helpers")
local Writer = require("toml_codec.writer")
local Json = require("json")
local SHARED = helpers.driver_root() .. "/../_shared"

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a")); assert(file:close())
	return content
end

local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content)); assert(file:close())
end

--- Runs the real bridge, validator and writer against two owned layer files.
--- @param body function Receives the source and controlled native consumers.
local function with_editor(body)
	local root = os.tmpname(); assert(os.remove(root))
	local made = os.execute("mkdir -p -- " .. quote(root .. "/a") .. " " .. quote(root .. "/b"))
	assert(made == true or made == 0)
	local text = read(SHARED .. "/tests/corpus/layer_editor/edited_layers.toml")
	local previous = package.loaded["ui.layer_editor.bridge"]
	local original_publish = Writer.publish_if_unchanged
	local f = { selected = root .. "/a", dirs = { a = root .. "/a", b = root .. "/b" },
		text = text, reloads = 0, closes = 0, pushes = {}, epoch = 1, visible = true }
	f.path = function(which) return f.dirs[which] .. "/layers.toml" end
	f.read = function(which) return read(f.path(which)) end
	f.write = function(which, bytes) write(f.path(which), bytes) end
	f.write("a", "# source A\n" .. text); f.write("b", "# source B\n" .. text)
	f.context = function()
		return { app_name = "layer_editor", epoch = f.epoch,
			close_owned_window = function() f.closes = f.closes + 1; f.visible = false; return true end }
	end
	f.state = {
		paths = { shared_root = function() return SHARED end },
		config_paths = { get_config_dir = function() return f.selected end },
		keyboard_layout = { base_symbol = function() return nil end, is_ready = function() return false end },
		tap_hold = { keys = function() return {} end, reload = function()
			f.reloads = f.reloads + 1; return f.reload_result ~= false
		end },
		i18n = { get = function(key) return key end },
		webview_manager = {
			page_current = function(_, epoch) return epoch == f.epoch and f.visible end,
			eval_js = function(_, js)
				f.pushes[#f.pushes + 1] = js
				-- The real shared init ignores every payload after its first one.
				local encoded = js:match("window%.init%((.*)%)")
				if encoded and f.page_text == nil and (f.push_result ~= false or f.ambiguous_delivery) then
					local data = Json.decode(encoded)
					f.page_text = data.text or false
				end
				return f.push_result ~= false
			end,
			set_title = function() return true end,
		},
	}
	local called, detail = xpcall(function()
		f.bridge = helpers.load_module("ui.layer_editor.bridge")
		f.open = function(expected)
			local result = f.bridge.on_message("ready", f.state, f.context())
			if expected ~= "unchecked" then
				helpers.assert_eq(result.pushed, expected == nil and f.push_result ~= false or expected == true)
			end
			return result
		end
		f.new_page = function()
			f.epoch = f.epoch + 1; f.visible = true; f.page_text = nil
			return f.open()
		end
		f.save = function() return f.bridge.on_message({ action = "save", text = text }, f.state, f.context()) end
		body(f)
	end, debug.traceback)
	Writer.publish_if_unchanged = original_publish
	package.loaded["ui.layer_editor.bridge"] = previous
	local removed = os.execute("rm -rf -- " .. quote(root))
	assert(removed == true or removed == 0)
	if not called then error(detail, 0) end
end

--- No mutation or consumer acknowledgement is permitted for a stale draft.
local function assert_refused(f, result, a, b)
	helpers.assert_eq(result.saved, false)
	helpers.assert_eq(f.read("a"), a, "the original source is unchanged")
	helpers.assert_eq(f.read("b"), b, "the successor source is unchanged")
	helpers.assert_eq({ f.reloads, f.closes, f.visible }, { 0, 0, true })
	helpers.assert_true(f.pushes[#f.pushes]:find('"saved":false', 1, true) ~= nil,
		"the retained draft receives a refused save rather than a success")
end

helpers.describe("Layer editor source ownership (layer-editor-source-owner)", function()
	for _, identical in ipairs({ false, true }) do
		helpers.it("refuses an open draft after changing to a " .. (identical and "byte-identical" or "distinct") .. " folder", function()
			with_editor(function(f)
				if identical then f.write("b", f.read("a")) end
				local a, b = f.read("a"), f.read("b")
				helpers.assert_eq(f.open().data.text, a)
				f.selected = f.dirs.b
				assert_refused(f, f.save(), a, b)
				f.new_page()
				helpers.assert_eq(f.save().saved, true, "a new native page may save B")
				helpers.assert_eq(f.read("a"), a)
				helpers.assert_eq(f.read("b"), f.text)
				helpers.assert_eq({ f.reloads, f.closes }, { 1, 1 })
			end)
		end)
	end


	helpers.it("retains the first page source when ready repeats after selecting another folder", function()
		with_editor(function(f)
			local a, b = f.read("a"), f.read("b")
			f.open(); helpers.assert_eq(f.page_text, a)
			f.selected = f.dirs.b
			f.open("unchecked")
			helpers.assert_eq(f.page_text, a, "the real page ignores a second init payload")
			assert_refused(f, f.save(), a, b)
			f.new_page(); helpers.assert_eq(f.page_text, b)
			helpers.assert_eq(f.save().saved, true, "a genuinely new page can save its own B source")
			helpers.assert_eq({ f.read("a"), f.read("b"), f.reloads, f.closes }, { a, f.text, 1, 1 })
		end)
	end)


	helpers.it("does not treat a replacement state as a new native page", function()
		with_editor(function(f)
			local a, b = f.read("a"), f.read("b")
			f.open(); helpers.assert_eq(f.page_text, a)
			local successor = {}
			for key, value in pairs(f.state) do successor[key] = value end
			f.state = successor; f.selected = f.dirs.b
			f.open("unchecked"); helpers.assert_eq(f.page_text, a)
			local result = f.save()
			helpers.assert_eq({ f.read("a"), f.read("b") }, { a, b })
			helpers.assert_eq({ result.saved, f.reloads, f.closes, f.visible }, { false, 0, 0, true })
			f.new_page(); helpers.assert_eq(f.page_text, b)
			helpers.assert_eq(f.save().saved, true)
			helpers.assert_eq({ f.read("a"), f.read("b"), f.reloads, f.closes }, { a, f.text, 1, 1 })
		end)
	end)

	for _, ambiguous in ipairs({ false, true }) do
		helpers.it("retains an unacknowledged first source with ambiguous delivery=" .. tostring(ambiguous), function()
			with_editor(function(f)
				local a, b = f.read("a"), f.read("b")
				f.push_result = false; f.ambiguous_delivery = ambiguous; f.open()
				if ambiguous then helpers.assert_eq(f.page_text, a) else helpers.assert_nil(f.page_text) end
				f.push_result = true; f.selected = f.dirs.b
				f.open("unchecked")
				assert_refused(f, f.save(), a, b)
				f.new_page(); helpers.assert_eq(f.page_text, b)
				helpers.assert_eq(f.save().saved, true)
				helpers.assert_eq({ f.read("a"), f.read("b"), f.reloads, f.closes }, { a, f.text, 1, 1 })
			end)
		end)
	end

	helpers.it("requires a confirmed same-source offer before saving after an ambiguous push", function()
		with_editor(function(f)
			local a, b = f.read("a"), f.read("b")
			f.push_result = false; f.ambiguous_delivery = true; f.open()
			helpers.assert_eq(f.page_text, a)
			f.push_result = true
			assert_refused(f, f.save(), a, b)
			f.open(); helpers.assert_eq(f.page_text, a)
			helpers.assert_eq(f.save().saved, true, "a confirmed retry retains the original source")
			helpers.assert_eq({ f.read("a"), f.read("b"), f.reloads, f.closes }, { f.text, b, 1, 1 })
		end)
	end)

	helpers.it("refuses later bytes in the same folder without losing the draft", function()
		with_editor(function(f)
			f.open(); f.write("a", "# another writer owns these bytes\n" .. f.text)
			local a, b = f.read("a"), f.read("b")
			assert_refused(f, f.save(), a, b)
			f.new_page(); helpers.assert_eq(f.save().saved, true)
			helpers.assert_eq(f.read("a"), f.text)
		end)
	end)

	helpers.it("does not adopt a refreshed source during the save announcement", function()
		with_editor(function(f)
			local a, b = f.read("a"), f.read("b")
			f.open()
			local logger = require("logger.shim")
			local start = logger.start
			logger.start = function(...)
				logger.start = start
				f.selected = f.dirs.b; f.new_page()
				return start(...)
			end
			local called, result = pcall(f.save)
			logger.start = start
			if not called then error(result, 0) end
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq({ f.read("a"), f.read("b") }, { a, b })
			helpers.assert_eq({ f.reloads, f.closes, f.visible }, { 0, 0, true })
			helpers.assert_true(f.pushes[#f.pushes]:find("window.init(", 1, true) ~= nil,
				"the newer page image must not receive the older save result")
			helpers.assert_eq(f.save().saved, true, "the refreshed source remains usable")
		end)
	end)

	for _, no_op in ipairs({ false, true }) do
		helpers.it("checks the captured folder at final atomic publication with no-op=" .. tostring(no_op), function()
			with_editor(function(f)
				if no_op then f.write("a", f.text) end
				local a, b = f.read("a"), f.read("b")
				f.open()
				local publish, calls = Writer.publish_if_unchanged, 0
				Writer.publish_if_unchanged = function(path, content, adapter, expected, on_error, admission)
					if path == f.path("a") and type(admission) == "function" then
						local original = admission
						admission = function()
							calls = calls + 1; f.selected = f.dirs.b
							return original()
						end
					end
					return publish(path, content, adapter, expected, on_error, admission)
				end
				assert_refused(f, f.save(), a, b)
				helpers.assert_true(calls > 0, "the actual writer must call the captured final admission")
			end)
		end)
	end

	helpers.it("never refreshes captured bytes at the writer boundary", function()
		with_editor(function(f)
			f.open()
			local publish, changed = Writer.publish_if_unchanged, false
			Writer.publish_if_unchanged = function(path, content, adapter, expected, on_error, admission)
				if not changed and path == f.path("a") then
					changed = true; f.write("a", "# publication-time writer\n" .. f.text)
				end
				return publish(path, content, adapter, expected, on_error, admission)
			end
			local result = f.save()
			assert_refused(f, result, "# publication-time writer\n" .. f.text, "# source B\n" .. f.text)
			helpers.assert_true(changed)
		end)
	end)

	helpers.it("saves a healthy existing source with a fresh routed context table", function()
		with_editor(function(f)
			f.open()
			local b = f.read("b")
			local result = f.save()
			helpers.assert_eq({ result.saved, result.applied, result.closed }, { true, true, true })
			helpers.assert_eq(f.read("a"), f.text)
			helpers.assert_eq(f.read("b"), b)
			helpers.assert_eq({ f.reloads, f.closes }, { 1, 1 })
		end)
	end)

	helpers.it("creates an absent original file only after its ready source is offered", function()
		with_editor(function(f)
			assert(os.remove(f.path("a")))
			helpers.assert_nil(f.open().data.text)
			local result = f.save()
			helpers.assert_eq({ result.saved, result.applied, result.closed }, { true, true, true })
			helpers.assert_eq(f.read("a"), f.text)
		end)
	end)

	helpers.it("cannot save a source whose initial payload was refused", function()
		with_editor(function(f)
			local a, b = f.read("a"), f.read("b")
			f.push_result = false; f.open(); f.push_result = true
			assert_refused(f, f.save(), a, b)
			f.new_page(); helpers.assert_eq(f.save().saved, true)
		end)
	end)

	helpers.it("requires a fresh read after an unreadable opening source is repaired", function()
		with_editor(function(f)
			assert(os.remove(f.path("a")))
			local made = os.execute("mkdir -- " .. quote(f.path("a")))
			assert(made == true or made == 0)
			local opened = f.open()
			helpers.assert_eq(opened.data.errors[1].code, "file_unreadable")
			assert(os.remove(f.path("a")))
			f.write("a", "# repaired source A\n" .. f.text)
			assert_refused(f, f.save(), f.read("a"), f.read("b"))
			f.new_page(); helpers.assert_eq(f.save().saved, true)
		end)
	end)

	helpers.it("retains its own committed source while a failed apply is retried", function()
		with_editor(function(f)
			f.open(); f.reload_result = false
			local result = f.save()
			helpers.assert_eq({ result.saved, result.applied }, { true, false })
			helpers.assert_eq(f.read("a"), f.text)
			helpers.assert_eq({ f.reloads, f.closes }, { 1, 0 })
			f.reload_result = true; result = f.save()
			helpers.assert_eq({ result.saved, result.applied, result.closed }, { true, true, true })
			helpers.assert_eq({ f.reloads, f.closes }, { 2, 1 })
		end)
	end)
end)
