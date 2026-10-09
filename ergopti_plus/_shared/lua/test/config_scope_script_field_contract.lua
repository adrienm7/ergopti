--- _shared/lua/test/config_scope_script_field_contract.lua

--- Declared locale and error-flag native owners preserve their actual consumers.
return function(helpers, driver)
	local function with_native(kind, callback)
		local name = kind == "locale" and "infra.i18n"
			or (driver == "macos" and "ui.error_dialog" or "ui.error_dialog.bridge")
		local saved, names = {}, { name, "infra.locale", "locale.core", "adapters.storage" }
		for _, module in ipairs(names) do saved[module] = package.loaded[module]; package.loaded[module] = nil end
		local writes = 0
		package.loaded["adapters.storage"] = {
			get = function(alias, default)
				if alias == "locale" or alias == "i18n_locale" then return "fr" end
				if alias == "script.show_error_dialog" then return true end
				return default
			end,
			set = function() writes = writes + 1; return true end,
		}
		local called, failure = pcall(function()
			local native = require(name)
			local backend
			if kind == "locale" then
				backend = require("infra.locale")
				if driver == "macos" then native.set_locale_injector(backend.set_locale) end
				native.init()
			end
			callback(native, backend, function() return writes end)
		end)
		for _, module in ipairs(names) do package.loaded[module] = saved[module] end
		if not called then error(failure) end
	end
	local function token() return { pending = function() return false end } end
	for _, kind in ipairs({ "locale", "error" }) do
		helpers.describe("script " .. kind .. " source-bound native field", function()
			helpers.it("publishes its actual consumer and restores the opaque inverse after reacquisition", function()
				with_native(kind, function(native, backend, writes)
					local owner = token()
					helpers.assert_eq(native.scope_acquire(owner), true)
					local receipt = native.scope_capture(owner)
					helpers.assert_type(receipt, "table")
					local desired = kind == "locale" and "en" or false
					helpers.assert_eq(native.scope_apply(owner, receipt, desired), true)
					if kind == "locale" then
						helpers.assert_eq(native.get_locale(), "en")
						helpers.assert_eq(backend.current_locale(), "en")
						helpers.assert_true(next(backend.all()) ~= nil)
					else helpers.assert_eq(native.is_enabled(), false) end
					helpers.assert_eq(native.scope_release(owner), true)
					helpers.assert_eq(native.scope_acquire(owner), true)
					helpers.assert_eq(native.scope_restore(owner, receipt), true)
					if kind == "locale" then
						helpers.assert_eq(native.get_locale(), "fr")
						helpers.assert_eq(backend.current_locale(), "fr")
					else helpers.assert_eq(native.is_enabled(), true) end
					helpers.assert_eq(native.scope_release(owner), true)
					helpers.assert_eq(writes(), 0, "native scalar owner must not use persistence setters")
				end)
			end)
			helpers.it("refuses wrong field kinds, foreign receipts and callback setter reentry", function()
				with_native(kind, function(native, _, writes)
					local owner = token()
					helpers.assert_eq(native.scope_acquire(owner), true)
					local receipt = native.scope_capture(owner)
					local invalid = kind == "locale" and { false, 1, {}, "foreign_locale" } or { 0, "false", {} }
					for _, value in ipairs(invalid) do helpers.assert_eq(native.scope_apply(owner, receipt, value), false) end
					helpers.assert_eq(native.scope_apply(owner, {}, kind == "locale" and "en" or false), false)
					if kind == "locale" then
						helpers.assert_eq(native.set_locale("en"), false)
						helpers.assert_eq(native.persist_locale("en"), false)
						if driver == "macos" then helpers.assert_eq(native.set_locale_no_reload("en"), false) end
					else
						helpers.assert_eq(native.set_enabled(false), false)
						helpers.assert_eq(native.on_error("scope", "reentrant", "reentrant"), false)
					end
					helpers.assert_eq(writes(), 0)
					helpers.assert_eq(native.scope_restore(owner, receipt), true)
					helpers.assert_eq(native.scope_release(owner), true)
				end)
			end)
			helpers.it("keeps exact live-parent admission through an equal-valued module replacement", function()
				with_native(kind, function(native)
					local name = kind == "locale" and "infra.i18n"
						or (driver == "macos" and "ui.error_dialog" or "ui.error_dialog.bridge")
					local owner = token()
					helpers.assert_eq(native.scope_acquire(owner), true)
					local receipt = native.scope_capture(owner)
					package.loaded[name] = { enabled = true, locale = "fr" }
					helpers.assert_eq(native.scope_apply(owner, receipt, kind == "locale" and "en" or false), false)
					helpers.assert_eq(native.scope_restore(owner, receipt), false)
					package.loaded[name] = native
					helpers.assert_eq(native.scope_restore(owner, receipt), true)
					helpers.assert_eq(native.scope_release(owner), true)
				end)
			end)
			helpers.it("refuses identity impostors whose equality metamethod claims the retained owner", function()
				with_native(kind, function(native)
					local equality = { __eq = function() return true end }
					local owner, foreign = setmetatable(token(), equality), setmetatable(token(), equality)
					helpers.assert_eq(owner == foreign, true, "the adversary must trigger semantic equality")
					helpers.assert_eq(native.scope_acquire(owner), true)
					local receipt = native.scope_capture(owner)
					helpers.assert_eq(native.scope_capture(foreign), nil)
					helpers.assert_eq(native.scope_apply(foreign, receipt, kind == "locale" and "en" or false), false)
					helpers.assert_eq(native.scope_restore(foreign, receipt), false)
					helpers.assert_eq(native.scope_release(foreign), false)
					helpers.assert_eq(native.scope_restore(owner, receipt), true)
					helpers.assert_eq(native.scope_release(owner), true)
					helpers.assert_eq(native.scope_forget(foreign, receipt), false)
					helpers.assert_eq(native.scope_forget(owner, receipt), true)
				end)
			end)
			if kind == "error" then
				helpers.it("refuses an actual already scheduled error without canceling its presentation", function()
					with_native(kind, function(native)
						local timers = driver == "macos" and hs.timer.__timers or nil
						local before = timers and #timers or 0
						local deferred = {}
						if driver == "linux" then
							native.clock = function() return 0 end
							native.defer = function(callback) deferred[#deferred + 1] = callback; return true end
						end
						helpers.assert_eq(native.init(), true)
						local scheduled_result = native.on_error("scope", "scheduled", "scheduled")
						if driver == "linux" then helpers.assert_eq(scheduled_result, nil)
						else helpers.assert_eq(scheduled_result, true) end
						local count = timers and #timers or #deferred
						helpers.assert_true(count > before, "the real native owner must schedule before acquisition")
						helpers.assert_eq(native.scope_acquire(token()), false)
						helpers.assert_eq(timers and #timers or #deferred, count)
						if timers then for index = #timers, before + 1, -1 do timers[index]:stop(); timers[index] = nil end end
						native._reset()
					end)
				end)
			elseif driver == "macos" then
				helpers.it("refuses the existing locale reload instead of cancelling or replaying it", function()
					with_native(kind, function(native, backend)
						local timers = hs.timer.__timers
						local before = #timers
						helpers.assert_eq(native.set_locale("en"), true)
						backend.set_locale("en")
						helpers.assert_eq(native.get_locale(), backend.current_locale())
						helpers.assert_true(#timers > before)
						local scheduled = timers[#timers]
						helpers.assert_eq(scheduled.running, true)
						helpers.assert_eq(native.scope_acquire(token()), false)
						helpers.assert_eq(scheduled.running, true)
						for index = #timers, before + 1, -1 do timers[index]:stop(); timers[index] = nil end
					end)
				end)
			end
			helpers.it("forgets only finalized native inverse data and acknowledges repeat cleanup", function()
				with_native(kind, function(native)
					local owner = token()
					helpers.assert_eq(native.scope_acquire(owner), true)
					local receipt = native.scope_capture(owner)
					helpers.assert_eq(native.scope_forget(owner, receipt), false, "held field cannot finalize its inverse")
					helpers.assert_eq(native.scope_apply(owner, receipt, kind == "locale" and "en" or false), true)
					helpers.assert_eq(native.scope_release(owner), true)
					helpers.assert_eq(native.scope_forget(owner, receipt), true)
					helpers.assert_eq(native.scope_forget(owner, receipt), true)
					helpers.assert_eq(native.scope_acquire(owner), true)
					helpers.assert_eq(native.scope_restore(owner, receipt), false)
					helpers.assert_eq(native.scope_release(owner), true)
				end)
			end)
		end)
	end
end
