--- tests/support/hotstrings_config_window_fixture.lua

--- ==============================================================================
--- MODULE: Hotstrings Configuration Window Test Fixture
--- DESCRIPTION:
--- Loads an isolated real controller with observable native owners and failures.
--- No fixture state survives a call.
--- ==============================================================================

--- Runs an isolated controller with observable native owners.
--- @param test function Behavioral assertions.
local function with_window(test)
	local loaded, original_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local state = { callbacks = {}, views = {}, options = {}, writes = 0, errors = {} }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end,
			error = function(_, message, ...)
				state.errors[#state.errors + 1] = string.format(message, ...)
				if state.on_error then state.on_error() end
			end,
			callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		}
		package.loaded["infra.paths"] = { shared = function(path) return "/virtual/" .. path end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.fs_dir"] = { entries = function() return {} end }
		package.loaded["modules.keymap"] = {}
		package.loaded["infra.personal_hotstrings"] = { adoptions = function() return {} end }
		package.loaded["infra.personal_file_controls"] = {
			capture = function() return nil end, apply = function() return false end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			set_override = function() state.writes = state.writes + 1 return true end,
			resolve = function() return {} end, get_toml_defaults = function() return {} end,
			get_user_override = function() return {} end, get_sections = function() return {} end,
		}
		_G.hs = { json = { encode = function()
			if state.on_encode then state.on_encode() end
			if state.encode_mode == "throw" then error("private payload") end
			if state.encode_mode == "nil" then return nil end
			return "{}"
		end }, webview = {
			usercontent = { new = function()
				return { setCallback = function(self, callback)
					if callback then state.callbacks[#state.callbacks + 1] = callback end
					return self
				end }
			end },
		} }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 10, height = 10 } end,
			get_centered_frame = function() return {} end, force_focus = function() end,
			show_webview = function(options)
				if state.throw_before_create then error("injected factory entry failure") end
				local view = { deletes = 0, javascript = 0 }
				function view:delete()
					self.deletes = self.deletes + 1
					if state.refuse_delete then error("injected delete failure") end
				end
				function view:evaluateJavaScript(_, completion)
					self.javascript = self.javascript + 1
					state.completion = completion
					if state.eval_mode == "throw" then error("private payload") end
					if state.eval_mode == "nil" then return nil end
					if state.eval_mode == "false" then return false end
					if state.eval_mode == "sync_error" and completion then completion(nil, { message = "private payload" }) end
					if state.on_javascript then state.on_javascript() end
					return self
				end
				state.views[#state.views + 1] = view
				state.options[#state.options + 1] = options
				if options.on_webview_created then options.on_webview_created(view) end
				if state.throw_after_create then error("injected factory post-allocation failure") end
				if state.close_during_show then options.on_close() end
				return view
			end,
		}
		package.loaded["ui.hotstrings_config_window"] = nil
		test(require("ui.hotstrings_config_window"), state)
	end, debug.traceback)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	_G.hs = original_hs
	if not ok then error(err, 0) end
end

--- Explicit native catalogue/binding double for bridge routing only. The real
--- shared metadata planner and classified CAS writer remain the test subjects;
--- native physical admission, leases and runtime receipts have separate tests.
--- @param path string Exact native source path.
--- @param content string Boot-admitted bytes, independently provided by the test.
--- @return string root
--- @return string owner Canonical source identifier, never a display stem.
--- @return string native_path
--- @return table context Closed native fixture capability and observations.
local function install_personal_binding(path, content)
	local root, name = path:match("^(.*)[/\\]([^/\\]+)$")
	assert(root and name and name:match("%.toml$"))
	assert(type(content) == "string")
	local Files = require("hotstrings.personal_files")
	local source = Files.describe({ name })
	local native_path = root .. "/" .. name
	local record = { owner = source.id, source = source, path = native_path,
		content = content, admitted = true, exclusive = true }
	local binding = { record = record, root = root, native = {} }
	local context = { record = record, binding = binding, captures = 0, applications = 0,
		current = true, acknowledged = true }
	binding.native.current = function() return context.current == true end
	package.loaded["infra.fs_dir"] = { entries = function(candidate)
		return candidate == root and { name } or {}
	end }
	package.loaded["infra.personal_hotstrings"] = {
		adoptions = function() return { record } end,
	}
	package.loaded["infra.personal_file_controls"] = {
		capture = function(id)
			context.captures = context.captures + 1
			if id == record.owner and record.admitted == true and context.current == true then return binding end
			return nil
		end,
		apply = function(captured, section, field, value)
			assert(captured == binding, "a bridge category must use its captured native capability")
			assert(captured.record.owner == source.id and captured.record.path == native_path,
				"a retained native binding may not change source identity or route")
			context.applications = context.applications + 1
			if context.current ~= true or context.acknowledged ~= true or record.admitted ~= true then return false end
			local fs = package.loaded["adapters.file_system"]
			local ok, bytes, status = pcall(fs.read_with_status, native_path)
			if not ok or status ~= "ok" or type(bytes) ~= "string" or bytes ~= record.content then return false end
			local plan = require("hotstrings.personal_metadata").prepare(bytes, section, field, value)
			if not plan then return false end
			local wrote, committed = pcall(fs.write_if_unchanged, native_path, plan.content,
				{ status = "ok", content = bytes })
			if not wrote or committed ~= true then return false end
			record.content = plan.content
			return true
		end,
	}
	local Reader = require("toml_codec.reader")
	package.loaded["infra.toml.reader"] = {
		parse = function(candidate)
			if candidate == native_path then return Reader.parse_text(record.content) end
			return nil, false
		end,
	}
	return root, source.id, native_path, context
end

--- Finds the actual state builder retained by the native bridge closure.
local function find_build_state(fn, seen)
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	local index = 1
	while true do
		local name, value = debug.getupvalue(fn, index)
		if not name then return nil end
		if name == "build_state" then return value end
		if type(value) == "function" then
			local nested = find_build_state(value, seen)
			if nested then return nested end
		end
		index = index + 1
	end
end

--- Opens no WebView: render the real initial state to capture boot-owned bindings.
local function prepare_personal_window(window, root)
	window.setup({ personal_dir = root })
	local build = assert(find_build_state(window._on_message))
	return build()
end

return { with_window = with_window, install_personal_binding = install_personal_binding,
	prepare_personal_window = prepare_personal_window }
