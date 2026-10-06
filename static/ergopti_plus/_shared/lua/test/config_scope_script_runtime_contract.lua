--- _shared/lua/test/config_scope_script_runtime_contract.lua

--- Actual native scalar ownership retains exact inverses across compositions.
return function(helpers, driver)
	local name = driver == "linux" and "infra.script_settings" or "infra.logger"
	local function with_native(callback)
		local previous = package.loaded[name]
		local storage = package.loaded["adapters.storage"]
		local writes = 0
		if driver == "linux" then
			package.loaded["adapters.storage"] = {
				get = function(_, default) return default end,
				set = function() writes = writes + 1; return true end,
			}
		end
		package.loaded[name] = nil
		local ok, err = pcall(function()
			local native = require(name)
			local logger = driver == "linux" and require("logger.shim") or native
			local function level() return driver == "linux" and logger.get_level() or logger.current_level end
			if driver == "linux" then helpers.assert_eq(native.apply("INFO"), true)
			else logger.set_level("INFO") end
			callback(native, logger, level, function() return writes end)
		end)
		package.loaded[name], package.loaded["adapters.storage"] = previous, storage
		if not ok then error(err) end
	end
	helpers.describe("script log runtime owned scalar", function()
		helpers.it("retains a real native inverse across release and composition reacquisition", function()
			with_native(function(native, _, level, writes)
				local token = { pending = function() return false end }
				helpers.assert_eq(native.scope_acquire(token), true)
				local receipt = native.scope_capture(token)
				helpers.assert_type(receipt, "table")
				helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), true)
				helpers.assert_eq(level(), 40)
				helpers.assert_eq(native.scope_release(token), true)
				helpers.assert_eq(native.scope_acquire(token), true)
				helpers.assert_eq(native.scope_restore(token, receipt), true)
				helpers.assert_eq(level(), 20)
				helpers.assert_eq(native.scope_release(token), true)
				helpers.assert_eq(writes(), 0, "runtime port must not call public persistence setters")
			end)
		end)
		helpers.it("refuses forged receipts, wrong owners and noncanonical values without changing state", function()
			with_native(function(native, _, level)
				local token = { pending = function() return false end }
				helpers.assert_eq(native.scope_acquire(token), true)
				local receipt = native.scope_capture(token)
				for _, value in ipairs({ "error", "foreign", 40, false, {} }) do
					helpers.assert_eq(native.scope_apply(token, receipt, value), false)
					helpers.assert_eq(level(), 20)
				end
				helpers.assert_eq(native.scope_apply({}, receipt, "ERROR"), false)
				helpers.assert_eq(native.scope_apply(token, {}, "ERROR"), false)
				helpers.assert_eq(native.scope_release({}), false)
				helpers.assert_eq(native.scope_release(token), true)
			end)
		end)
		helpers.it("refuses ordinary setter reentry throughout the actual field claim", function()
			with_native(function(native, _, level, writes)
				local token = { pending = function() return false end }
				helpers.assert_eq(native.scope_acquire(token), true)
				local receipt = native.scope_capture(token)
				if driver == "linux" then
					helpers.assert_eq(native.set("ERROR"), false)
					helpers.assert_eq(native.apply("ERROR"), false)
				else helpers.assert_eq(native.set_level("ERROR"), false) end
				helpers.assert_eq(level(), 20)
				helpers.assert_eq(writes(), 0)
				helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), true)
				helpers.assert_eq(native.scope_restore(token, receipt), true)
				helpers.assert_eq(native.scope_release(token), true)
			end)
		end)
		helpers.it("preserves a foreign successor even when its value matches the prior publication", function()
			with_native(function(native, _, level)
				local token = { pending = function() return false end }
				helpers.assert_eq(native.scope_acquire(token), true)
				local receipt = native.scope_capture(token)
				helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), true)
				helpers.assert_eq(native.scope_release(token), true)
				if driver == "linux" then helpers.assert_eq(native.apply("ERROR"), true)
				else native.set_level("ERROR") end
				helpers.assert_eq(native.scope_acquire(token), true)
				helpers.assert_eq(native.scope_restore(token, receipt), false)
				helpers.assert_eq(level(), 40)
				helpers.assert_eq(native.scope_release(token), true)
			end)
		end)
		helpers.it("refuses a replaced live module with the same scalar without touching either owner", function()
			with_native(function(native, _, level)
				local token = { pending = function() return false end }
				helpers.assert_eq(native.scope_acquire(token), true)
				local receipt = native.scope_capture(token)
				package.loaded[name] = { current_level = 20 }
				helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), false)
				helpers.assert_eq(native.scope_restore(token, receipt), false)
				helpers.assert_eq(level(), 20)
				package.loaded[name] = native
				helpers.assert_eq(native.scope_release(token), true)
			end)
		end)
		if driver == "linux" then
			helpers.it("restores an actual native setter that mutates before its terminal refusal", function()
				with_native(function(native, logger, level)
					local original, calls = logger.set_level, 0
					logger.set_level = function(value)
						calls = calls + 1
						original(value)
						if calls == 1 then return false end
					end
					local ok, err = pcall(function()
						local token = { pending = function() return false end }
						helpers.assert_eq(native.scope_acquire(token), true)
						local receipt = native.scope_capture(token)
						helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), false)
						helpers.assert_eq(level(), 40)
						helpers.assert_eq(native.current(), "INFO", "refused setter has not published the active token")
						helpers.assert_eq(native.scope_restore(token, receipt), true)
						helpers.assert_eq(level(), 20)
						helpers.assert_eq(calls, 2, "one refused application and one exact native inverse")
						helpers.assert_eq(native.scope_release(token), true)
					end)
					logger.set_level = original
					if not ok then error(err) end
				end)
			end)
			helpers.it("keeps the native gate through real setter callback reentry", function()
				with_native(function(native, logger)
					local original, calls, token, receipt = logger.set_level, 0
					token = { pending = function() return false end }
					logger.set_level = function(value)
						calls = calls + 1
						helpers.assert_eq(native.scope_release(token), false)
						helpers.assert_eq(native.scope_restore(token, receipt), false)
						helpers.assert_eq(native.scope_capture(token), nil)
						original(value)
					end
					local ok, err = pcall(function()
						helpers.assert_eq(native.scope_acquire(token), true)
						receipt = native.scope_capture(token)
						helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), true)
						helpers.assert_eq(native.scope_restore(token, receipt), true)
						helpers.assert_eq(calls, 2, "real native callback ran during publication and exact inverse")
						helpers.assert_eq(native.scope_release(token), true)
					end)
					logger.set_level = original
					if not ok then error(err) end
				end)
			end)
			helpers.it("fences a same-value live successor after the publication getter", function()
				with_native(function(native, logger, level)
					local original, armed = logger.get_level, true
					logger.get_level = function()
						local observed = original()
						if armed and observed == 40 then
							armed = false
							package.loaded[name] = { current_level = 40 }
						end
						return observed
					end
					local ok, err = pcall(function()
						local token = { pending = function() return false end }
						helpers.assert_eq(native.scope_acquire(token), true)
						local receipt = native.scope_capture(token)
						helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), false)
						helpers.assert_eq(armed, false, "actual publication getter interposed the successor")
						helpers.assert_eq(native.scope_restore(token, receipt), false)
						helpers.assert_eq(level(), 40)
						package.loaded[name] = native
						helpers.assert_eq(native.scope_restore(token, receipt), true)
						helpers.assert_eq(level(), 20)
						helpers.assert_eq(native.scope_release(token), true)
					end)
					logger.get_level = original
					if not ok then error(err) end
				end)
			end)
			helpers.it("refuses a same-value successor created during the actual final getter", function()
				with_native(function(native, logger)
					local original = logger.get_level
					logger.get_level = function()
						package.loaded[name] = { current_level = 20 }
						return original()
					end
					local ok, err = pcall(function()
						local token = { pending = function() return false end }
						helpers.assert_eq(native.scope_acquire(token), true)
						helpers.assert_eq(native.scope_capture(token), nil)
						package.loaded[name] = native
						helpers.assert_eq(native.scope_release(token), true)
					end)
					logger.get_level = original
					if not ok then error(err) end
				end)
			end)
		end
		if driver == "linux" then
			local function successor(logger, level)
				local native = {}
				for name, value in pairs(logger) do native[name] = value end
				native.get_level = function() return level end
				native.set_level = function(value) level = value end
				return native
			end
			local function with_parents(logger, callback)
				local shim, core = package.loaded["logger.shim"], package.loaded["logger"]
				local called, failure = pcall(callback)
				package.loaded["logger.shim"], package.loaded["logger"] = shim, core
				if not called then error(failure) end
			end
			helpers.it("refuses a live log backend successor before acquiring its native field", function()
				with_native(function(native, logger, level)
					with_parents(logger, function()
						local replacement = successor(logger, level())
						package.loaded["logger.shim"], package.loaded["logger"] = replacement, replacement
						helpers.assert_eq(native.scope_acquire({ pending = function() return false end }), false)
						helpers.assert_eq(logger.get_level(), 20)
						helpers.assert_eq(replacement.get_level(), 20)
					end)
				end)
			end)
			helpers.it("refuses a same-threshold live backend replacement without changing its retired receiver", function()
				with_native(function(native, logger, level)
					with_parents(logger, function()
						local owner = { pending = function() return false end }
						helpers.assert_eq(native.scope_acquire(owner), true)
						local receipt = native.scope_capture(owner)
						local replacement = successor(logger, level())
						package.loaded["logger.shim"], package.loaded["logger"] = replacement, replacement
						helpers.assert_eq(native.scope_apply(owner, receipt, "ERROR"), false)
						helpers.assert_eq(logger.get_level(), 20)
						helpers.assert_eq(replacement.get_level(), 20)
						helpers.assert_eq(native.scope_restore(owner, receipt), false)
						package.loaded["logger.shim"], package.loaded["logger"] = logger, logger
						helpers.assert_eq(native.scope_restore(owner, receipt), true)
						helpers.assert_eq(native.scope_release(owner), true)
					end)
				end)
			end)
			for _, stage in ipairs({ "capture", "publication" }) do
				helpers.it("refuses a same-threshold backend interposed by its actual " .. stage .. " getter", function()
					with_native(function(native, logger)
						with_parents(logger, function()
							local original = logger.get_level
							local armed, replacement = false, nil
							logger.get_level = function()
								local observed = original()
								if armed and observed == (stage == "capture" and 20 or 40) then
									armed = false
									replacement = successor(logger, observed)
									package.loaded["logger.shim"], package.loaded["logger"] = replacement, replacement
								end
								return observed
							end
							local called, failure = pcall(function()
								local owner = { pending = function() return false end }
								helpers.assert_eq(native.scope_acquire(owner), true)
								armed = stage == "capture"
								local receipt = native.scope_capture(owner)
								if stage == "capture" then helpers.assert_eq(receipt, nil)
								else
									helpers.assert_type(receipt, "table")
									armed = true
									helpers.assert_eq(native.scope_apply(owner, receipt, "ERROR"), false)
									helpers.assert_eq(native.scope_restore(owner, receipt), false)
								end
								helpers.assert_eq(armed, false, "the real getter must interpose its successor")
								helpers.assert_type(replacement, "table")
								helpers.assert_eq(replacement.get_level(), stage == "capture" and 20 or 40)
								package.loaded["logger.shim"], package.loaded["logger"] = logger, logger
								if receipt then helpers.assert_eq(native.scope_restore(owner, receipt), true) end
								helpers.assert_eq(native.scope_release(owner), true)
							end)
							logger.get_level = original
							if not called then error(failure) end
						end)
					end)
				end)
			end
		end
		helpers.it("rejects equal-valued owner impostors by raw identity", function()
			with_native(function(native)
				local equality = { __eq = function() return true end }
				local token = setmetatable({ pending = function() return false end }, equality)
				local foreign = setmetatable({ pending = function() return false end }, equality)
				helpers.assert_eq(token == foreign, true)
				helpers.assert_eq(native.scope_acquire(token), true)
				local receipt = native.scope_capture(token)
				helpers.assert_eq(native.scope_capture(foreign), nil)
				helpers.assert_eq(native.scope_apply(foreign, receipt, "ERROR"), false)
				helpers.assert_eq(native.scope_release(foreign), false)
				helpers.assert_eq(native.scope_restore(token, receipt), true)
				helpers.assert_eq(native.scope_release(token), true)
			end)
		end)
		helpers.it("forgets its inverse only after primary finalization and gate release", function()
			with_native(function(native)
				local pending = false
				local token = { pending = function() return pending end }
				helpers.assert_eq(native.scope_acquire(token), true)
				local receipt = native.scope_capture(token)
				helpers.assert_eq(native.scope_forget(token, receipt), false)
				helpers.assert_eq(native.scope_apply(token, receipt, "ERROR"), true)
				helpers.assert_eq(native.scope_release(token), true)
				pending = true
				helpers.assert_eq(native.scope_forget(token, receipt), false)
				pending = false
				helpers.assert_eq(native.scope_forget(token, receipt), true)
				helpers.assert_eq(native.scope_forget(token, receipt), true)
				helpers.assert_eq(native.scope_acquire(token), true)
				helpers.assert_eq(native.scope_restore(token, receipt), false)
				helpers.assert_eq(native.scope_release(token), true)
			end)
		end)
		helpers.it("keeps the gate until literal primary compensation acknowledgement", function()
			with_native(function(native)
				local pending = true
				local token = { pending = function() return pending end }
				helpers.assert_eq(native.scope_acquire(token), true)
				helpers.assert_eq(native.scope_release(token), false)
				pending = false
				helpers.assert_eq(native.scope_release(token), true)
			end)
		end)
	end)
end
