--- tests/unit/ui/editors/test_physical_editor_host.lua

--- Checks the actual native host through controlled constructor and cleanup ports.
local helpers = require("tests.helpers")
local Json = require("json")
helpers.describe("Physical shortcut native host ownership", function()
	helpers.it("(physical-editor-ui) refuses stale pages and retains failed native cleanup", function()
		local loaded, original_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local called, detail = pcall(function()
			require("test.physical_editor_host_contract")(helpers, Json,
				function(relative) return helpers.driver_root() .. "/../_shared/" .. relative end,
				function() package.loaded["ui.physical_shortcuts.bridge"] = nil; return require("ui.physical_shortcuts.bridge") end, "linux")
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		_G.hs = original_hs
		if not called then error(detail, 0) end
	end)
end)

helpers.describe("Physical editor position capture host epoch composition", function()
	helpers.it("uses genuine thin-host session guards through explicitly controlled native ports", function()
		local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "adapters.keyboard_hook",
			"modules.gestures.manager", "infra.paths", "infra.i18n", "logger.shim" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
		local host, epoch, callback, native_token, guard, cancel_refused, writes, sends = nil, 0, nil, nil, nil, false, 0, 0
		local receipt = {}
		local on_page = nil
		local manager = { native_available = function() return true end,
			current_epoch = function() return epoch > 0 and epoch or nil end,
			page_current = function(_, exact) local valid = epoch > 0 and epoch == exact; if on_page then on_page() end; return valid end,
			show = function() epoch = epoch + 1; return host.on_window_acquiring(epoch) end,
			hide = function(_, exact) if epoch ~= exact then return false end; local old = epoch; epoch = 0; host.on_window_closed(old); return true end,
			eval_js = function() sends = sends + 1; return true end }
		local hook = { position_capture_available = function() return true end,
			capture_position = function(current, receive) guard, callback, native_token = current, receive, {}; return native_token end,
			cancel_position = function(token) return not cancel_refused and rawequal(token, native_token) end }
		local scope = { physical_delivery_available = function() return true end,
			capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
			editor_source_current = function(exact) return rawequal(exact, receipt) end,
			edit = function() writes = writes + 1; return true end }
		local called, detail = pcall(function()
			package.loaded["ui.webview_manager"], package.loaded["adapters.keyboard_hook"] = manager, hook
			package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end, get_action_label = function(action) return action end }
			package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["logger.shim"] = helpers.make_logger_stub()
			host = helpers.load_module("ui.physical_shortcuts.bridge")
			helpers.assert_true(host.open({ scope = scope, is_paused = function() return false end }))
			local function send(message, exact) return host.on_message(message, {}, { app_name = "physical_shortcuts", epoch = exact or epoch }) end
			helpers.assert_true(send({ action = "ready" }))
			helpers.assert_true(send({ action = "capture_position", request = { request_id = 1 } }))
			helpers.assert_true(guard(), "actual shared/native host retains its Manager epoch and canonical receipt")
			helpers.assert_true(callback({ native_code = 36, mods = {} }), "controlled observation passes actual host and shared registry")
			helpers.assert_eq(writes, 0, "host observation is never a native Save or delivery capability")
			helpers.assert_true(not send({ action = "capture_position", request = { request_id = 2 } }, epoch + 1), "foreign page epoch cannot enroll")
			helpers.assert_true(send({ action = "capture_position", request = { request_id = 3 } }), "controlled new request has a separate host guard")
			local original = hook.capture_position
			local foreign = 0
			hook.capture_position = function() foreign = foreign + 1; return {} end
			helpers.assert_true(not guard(), "public Hook replacement cannot retain the host enrollment")
			helpers.assert_true(not callback({ native_code = 36, mods = {} }))
			helpers.assert_eq(foreign, 0, "captured host ports never execute replacement constructors")
			hook.capture_position = original
			local original_manager_epoch = manager.current_epoch
			manager.current_epoch = function() foreign = foreign + 1; return epoch end
			helpers.assert_true(not send({ action = "capture_position", request = { request_id = 4 } }), "message admission rejects a foreign Manager query")
			helpers.assert_eq(foreign, 0, "native page admission never invokes a replaced epoch callback")
			manager.current_epoch = original_manager_epoch
			local original_epoch = epoch
			on_page = function() epoch = epoch + 1; on_page = nil end
			helpers.assert_true(not guard(), "page query cannot change its epoch and still acknowledge the original page")
			epoch = original_epoch

			local previous = sends
			receipt = {}
			helpers.assert_true(not guard(), "canonical source replacement withdraws original request")
			helpers.assert_true(not callback({ native_code = 36, mods = {} }), "late source callback cannot fill current form")
			helpers.assert_eq(sends, previous, "no JavaScript send after stale-source refusal")
			cancel_refused = true
			helpers.assert_true(not host.close(), "controlled cancellation refusal retains exact page owner")
			cancel_refused = false
			helpers.assert_true(host.close(), "original observation and native page cleanup can retry")
			helpers.assert_true(not callback({ native_code = 36, mods = {} }), "closed original page callback cannot publish")
			on_page = function() epoch = epoch + 1; on_page = nil end
			helpers.assert_true(not host.open({ scope = scope, is_paused = function() return false end }),
				"constructor's last page getter cannot revoke its epoch and still report opened")
			epoch = 1
			helpers.assert_true(host.close(), "controlled exact Manager epoch recovery permits retained page cleanup")
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
		if not called then error(detail, 0) end
	end)
end)


helpers.describe("Physical editor exact native-closed debt retry", function()
	helpers.it("(physical-editor-close-debt) settles only the observed closed epoch before admitting a successor", function()
		local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "adapters.keyboard_hook",
			"modules.gestures.manager", "infra.paths", "infra.i18n", "logger.shim" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
		local host, epoch, serial, callback, token = nil, 0, 0, nil, nil
		local hide_refused, cancel_refused, hide_calls = false, false, 0
		local receipt = {}
		local manager = { native_available = function() return true end,
			current_epoch = function() return epoch > 0 and epoch or nil end,
			page_current = function(_, exact) return epoch > 0 and epoch == exact end,
			show = function() serial = serial + 1; epoch = serial; return host.on_window_acquiring(epoch) end,
			hide = function(_, exact)
				hide_calls = hide_calls + 1
				if hide_refused or epoch ~= exact then return false end
				local closed = epoch; epoch = 0
				host.on_window_closed(closed)
				return true
			end,
			eval_js = function() return true end }
		local hook = { position_capture_available = function() return true end,
			capture_position = function(_, receive) callback, token = receive, {}; return token end,
			cancel_position = function(exact) return not cancel_refused and rawequal(exact, token) end }
		local scope = { physical_delivery_available = function() return true end,
			capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
			editor_source_current = function(exact) return rawequal(exact, receipt) end,
			edit = function() error("Controlled observation retirement must never publish") end }
		local checked, failure = pcall(function()
			package.loaded["ui.webview_manager"], package.loaded["adapters.keyboard_hook"] = manager, hook
			package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end, get_action_label = function(action) return action end }
			package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["logger.shim"] = helpers.make_logger_stub()
			host = helpers.load_module("ui.physical_shortcuts.bridge")
			local options = { scope = scope, is_paused = function() return false end }
			helpers.assert_true(host.open(options))
			local first = epoch
			host.on_window_closed(first + 1)
			hide_refused = true
			helpers.assert_eq(host.close(), false, "A refused hide without exact closure cannot become an ACK")
			helpers.assert_eq(epoch, first, "The controlled native page remains owned")
			helpers.assert_eq(hide_calls, 1)
			hide_refused = false
			helpers.assert_true(host.close(), "The same still-owned page can close normally")
			helpers.assert_eq(epoch, 0)

			helpers.assert_true(host.open(options))
			local closed = epoch
			local function send(message) return host.on_message(message, {}, { app_name = "physical_shortcuts", epoch = closed }) end
			helpers.assert_true(send({ action = "ready" }))
			helpers.assert_true(send({ action = "capture_position", request = { request_id = 1 } }))
			cancel_refused = true
			helpers.assert_true(manager.hide("physical_shortcuts", closed), "Exact native owner closes before its notice")
			helpers.assert_eq(epoch, 0)
			local hides = hide_calls
			helpers.assert_eq(host.close(), false, "Native closure cannot settle refused original observation debt")
			helpers.assert_eq(hide_calls, hides, "Refused cancellation performs no second native close")
			helpers.assert_eq(callback({ native_code = 36, mods = {} }), false, "Closed original page cannot receive late facts")
			cancel_refused = false
			helpers.assert_true(host.close(), "Same observation and Window acknowledge retry after exact native closure")
			helpers.assert_eq(hide_calls, hides, "The observed dead page is never hidden twice")
			helpers.assert_true(host.open(options), "Only all settled original phases admit successor")
			local successor = epoch
			helpers.assert_true(successor ~= closed)
			host.on_window_closed(closed)
			helpers.assert_eq(epoch, successor, "Old exact notice cannot retire a newer page")
			helpers.assert_true(host.close())
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
		if not checked then error(failure, 0) end
	end)
end)


helpers.describe("Physical editor premature close notice refusal", function()
	helpers.it("(physical-editor-close-notice) premature same-epoch notice cannot settle cancellation retry without native ACK", function()
		local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "adapters.keyboard_hook",
			"modules.gestures.manager", "infra.paths", "infra.i18n", "logger.shim" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
		local host, epoch, serial, callback, token = nil, 0, 0, nil, nil
		local hide_refused, cancel_refused, hide_calls = false, false, 0
		local receipt = {}
		local manager = { native_available = function() return true end,
			current_epoch = function() return epoch > 0 and epoch or nil end,
			page_current = function(_, exact) return epoch > 0 and epoch == exact end,
			show = function() serial = serial + 1; epoch = serial; return host.on_window_acquiring(epoch) end,
			hide = function(_, exact)
				hide_calls = hide_calls + 1
				if hide_refused or epoch ~= exact then return false end
				local closed = epoch; epoch = 0
				host.on_window_closed(closed)
				return true
			end,
			eval_js = function() return true end }
		local hook = { position_capture_available = function() return true end,
			capture_position = function(_, receive) callback, token = receive, {}; return token end,
			cancel_position = function(exact) return not cancel_refused and rawequal(exact, token) end }
		local scope = { physical_delivery_available = function() return true end,
			capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
			editor_source_current = function(exact) return rawequal(exact, receipt) end,
			edit = function() error("Controlled observation retirement must never publish") end }
		local checked, failure = pcall(function()
			package.loaded["ui.webview_manager"], package.loaded["adapters.keyboard_hook"] = manager, hook
			package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end, get_action_label = function(action) return action end }
			package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["logger.shim"] = helpers.make_logger_stub()
			host = helpers.load_module("ui.physical_shortcuts.bridge")
			local options = { scope = scope, is_paused = function() return false end }
			helpers.assert_true(host.open(options))
			local original = epoch
			local function send(message) return host.on_message(message, {}, { app_name = "physical_shortcuts", epoch = original }) end
			helpers.assert_true(send({ action = "ready" }))
			helpers.assert_true(send({ action = "capture_position", request = { request_id = 1 } }))
			cancel_refused = true
			host.on_window_closed(original)
			helpers.assert_eq(epoch, original, "A premature notice leaves the native page owned")
			helpers.assert_eq(host.close(), false, "Refused cancellation keeps the exact observation debt")
			helpers.assert_eq(hide_calls, 0, "Cancellation refusal cannot reach native close")
			cancel_refused, hide_refused = false, true
			helpers.assert_eq(host.close(), false, "Cancellation retry cannot manufacture a native retirement ACK")
			helpers.assert_eq(hide_calls, 1, "The same live page still requires its exact native hide")
			helpers.assert_eq(epoch, original, "Refused native hide retains the original live page")
			helpers.assert_eq(callback({ native_code = 36, mods = {} }), false, "Cancelled original page cannot receive late facts")
			hide_refused = false
			helpers.assert_true(host.close(), "The actual native close can settle the retained original owner")
			helpers.assert_eq(hide_calls, 2)
			helpers.assert_eq(epoch, 0)
			helpers.assert_true(host.open(options), "Only acknowledged native retirement admits a successor")
			local successor = epoch
			host.on_window_closed(original)
			helpers.assert_eq(epoch, successor, "A stale notice cannot retire the successor")
			helpers.assert_true(host.close())
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
		if not checked then error(failure, 0) end
	end)
end)

helpers.describe("Physical editor pure constructor reservation rollback", function()
	for _, mode in ipairs({ "throw", "nil", "false" }) do
		helpers.it("(physical-editor-constructor) refuses before native acquisition and releases only the pure reservation: " .. mode, function()
			local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "adapters.keyboard_hook",
				"modules.gestures.manager", "infra.paths", "infra.i18n", "logger.shim", "shortcuts.physical_editor_window" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
			local host, epoch, serial, options, failing = nil, 0, 0, nil, true
			local shows, hides, captures, cancellations, source_reads = 0, 0, 0, 0, 0
			local nested_open, nested_close, original_failure = nil, nil, nil
			local receipt = {}
			local checked, failure = pcall(function()
				local actual_window = require("shortcuts.physical_editor_window")
				local original_new = actual_window.new
				local catalogue = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end }
				if mode ~= "throw" then catalogue.get_action_label = function(action) return action end end
				package.loaded["modules.gestures.manager"] = catalogue
				package.loaded["ui.webview_manager"] = { native_available = function() return true end,
					current_epoch = function() return epoch > 0 and epoch or nil end,
					page_current = function(_, exact) return epoch > 0 and epoch == exact end,
					show = function() shows = shows + 1; serial = serial + 1; epoch = serial; return host.on_window_acquiring(epoch) end,
					hide = function(_, exact)
						hides = hides + 1
						if epoch ~= exact then return false end
						local old = epoch; epoch = 0; host.on_window_closed(old); return true
					end,
					eval_js = function() return true end }
				package.loaded["adapters.keyboard_hook"] = { position_capture_available = function() return true end,
					capture_position = function() captures = captures + 1; return {} end,
					cancel_position = function() cancellations = cancellations + 1; return true end }
				package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["logger.shim"] = helpers.make_logger_stub()
				package.loaded["shortcuts.physical_editor_window"] = { new = function(ports)
					if not failing then return original_new(ports) end
					nested_open, nested_close = host.open(options), host.close()
					if mode == "nil" then return nil end
					if mode == "false" then return false end
					local called, result = pcall(original_new, ports)
					original_failure = not called and result or nil
					if not called then error(result, 0) end
					return result
				end }
				local scope = { physical_delivery_available = function() return true end,
					capture_editor_inventory = function() source_reads = source_reads + 1; return { assignments = {}, parameters = {} }, receipt end,
					editor_source_current = function(exact) return rawequal(exact, receipt) end,
					edit = function() error("Constructor-only refusal must never publish") end }
				options = { scope = scope, is_paused = function() return false end }
				host = helpers.load_module("ui.physical_shortcuts.bridge")
				local called, opened = pcall(host.open, options)
				helpers.assert_eq(called, true, "The constructor boundary returns a closed refusal rather than raising")
				helpers.assert_eq(opened, false, "An unreturned or invalid editor cannot acquire a native page")
				helpers.assert_eq(nested_open, false, "The original constructing reservation refuses a successor")
				helpers.assert_eq(nested_close, false, "No native retirement ACK exists before page acquisition")
				if mode == "throw" then
					helpers.assert_true(type(original_failure) == "string" and original_failure:find("physical editor port is incomplete", 1, true) ~= nil,
						"The real shared constructor rejects the genuine missing action-label port")
				end
				helpers.assert_eq(shows, 0, "Failed pure construction precedes Manager.show")
				helpers.assert_eq(hides, 0, "No invented native hide compensates pure construction")
				helpers.assert_eq(captures, 0)
				helpers.assert_eq(cancellations, 0)
				helpers.assert_eq(source_reads, 0, "The genuine constructor does not acquire a source inventory")
				failing = false
				catalogue.get_action_label = function(action) return action end
				helpers.assert_true(host.open(options), "The same host retries after only the failed pure reservation is released")
				helpers.assert_eq(shows, 1)
				helpers.assert_true(host.close(), "The actual returned shared Window acknowledges ordinary retirement")
				helpers.assert_eq(hides, 1)
			end)
			for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
			if not checked then error(failure, 0) end
		end)
	end
end)

helpers.describe("Physical editor returned Window retirement acknowledgement", function()
	helpers.it("(physical-editor-window-ack) retains false nil and throw retirement debt after acknowledged native close", function()
		local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "adapters.keyboard_hook",
			"modules.gestures.manager", "infra.paths", "infra.i18n", "logger.shim", "shortcuts.physical_editor_window" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
		local checked, failure = pcall(function()
			local actual_window = require("shortcuts.physical_editor_window")
			local original_new = actual_window.new
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				local host, epoch, serial, refuse, wrapped_owner = nil, 0, 0, true, nil
				local shows, hides, retire_calls, original_retire_calls = 0, 0, 0, 0
				local receipt = {}
				package.loaded["ui.webview_manager"] = { native_available = function() return true end,
					current_epoch = function() return epoch > 0 and epoch or nil end,
					page_current = function(_, exact) return epoch > 0 and epoch == exact end,
					show = function() shows = shows + 1; serial = serial + 1; epoch = serial; return host.on_window_acquiring(epoch) end,
					hide = function(_, exact)
						hides = hides + 1
						if epoch ~= exact then return false end
						local old = epoch; epoch = 0; host.on_window_closed(old); return true
					end,
					eval_js = function() return true end }
				package.loaded["adapters.keyboard_hook"] = { position_capture_available = function() return false end }
				package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end, get_action_label = function(action) return action end }
				package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["logger.shim"] = helpers.make_logger_stub()
				package.loaded["shortcuts.physical_editor_window"] = { new = function(ports)
					local owner = original_new(ports)
					local original_retire = owner.retire
					if wrapped_owner == nil then wrapped_owner = owner end
					owner.retire = function()
						retire_calls = retire_calls + 1
						if rawequal(owner, wrapped_owner) and refuse then
							if mode == "throw" then error("Controlled original Window retirement failure") end
							if mode == "nil" then return nil end
							return false
						end
						original_retire_calls = original_retire_calls + 1
						return original_retire()
					end
					return owner
				end }
				local scope = { physical_delivery_available = function() return true end,
					capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
					editor_source_current = function(exact) return rawequal(exact, receipt) end,
					edit = function() error("Window retirement receiver must never publish") end }
				local options = { scope = scope, is_paused = function() return false end }
				host = helpers.load_module("ui.physical_shortcuts.bridge")
				helpers.assert_true(host.open(options))
				local closed = epoch
				helpers.assert_true(package.loaded["ui.webview_manager"].hide("physical_shortcuts", closed), "Native owner acknowledges its exact page close")
				helpers.assert_eq(epoch, 0)
				helpers.assert_eq(retire_calls, 1, "The close notice invokes only the returned original Window")
				helpers.assert_eq(original_retire_calls, 0, "Controlled refusal is not an original Editor retirement ACK")
				helpers.assert_eq(host.close(), false, "Native closure does not settle refused Window retirement: " .. mode)
				helpers.assert_eq(host.open(options), false, "The exact Window debt refuses a successor: " .. mode)
				helpers.assert_eq(shows, 1)
				helpers.assert_eq(hides, 1, "Retry never hides the already acknowledged native page again")
				helpers.assert_eq(original_retire_calls, 0)
				refuse = false
				helpers.assert_true(host.close(), "The same retained real Window/Editor can acknowledge retirement")
				helpers.assert_eq(original_retire_calls, 1)
				helpers.assert_eq(hides, 1)
				helpers.assert_true(host.open(options), "Only the original retirement ACK admits a successor")
				local successor, previous_retire_calls = epoch, retire_calls
				host.on_window_closed(closed)
				helpers.assert_eq(epoch, successor)
				helpers.assert_eq(retire_calls, previous_retire_calls, "Stale original notice never retires successor Window")
				helpers.assert_true(host.close())
			end
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
		if not checked then error(failure, 0) end
	end)
end)
