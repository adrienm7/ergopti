--- tests/fakes/clipboard_stage.lua

--- Models the prepared clipboard lifetime without native tools or elapsed time.
local M = {}

--- Adds reversible staging to the canonical in-memory clipboard.
--- The ordinary read/write ports remain observable so tests can refuse or reenter
--- a phase; the owner must retain restoration debt until that phase returns.
--- @param fake table In-memory clipboard ports and observations.
--- @param opts table Modeled availability and optional layout paste key.
function M.install(fake, opts)
	function fake.paste_keycode() return opts.paste_keycode or 47 end
	function fake.new_paste_stage(text, sleep_ms, key_v, admission)
		assert(type(text) == "string" and text ~= "" and type(key_v) == "number", "invalid clipboard preparation")
		local stage, saved = {}, nil
		local busy, revoked, dirty, prepared = false, false, false, false
		local function current()
			if revoked then return false end
			if admission == nil then return true end
			if type(admission) ~= "function" then return false end
			local ok, allowed = pcall(admission)
			return ok and allowed == true and not revoked
		end
		local function restore()
			if busy then return false end
			if not dirty then return true end
			busy = true
			local ok, restored = pcall(fake.write, saved)
			busy = false
			if ok and restored == true then dirty, saved = false, nil end
			return not dirty
		end
		function stage.close()
			revoked = true
			return not busy and restore()
		end
		function stage.prepare()
			if busy or revoked or prepared then return false end
			busy = true
			local ok, ready = pcall(function()
				if not current() or not fake.is_available() or not current() then return false end
				local read_ok, bytes = fake.read_checked()
				if read_ok ~= true then return false end
				saved = bytes
				if not current() then return false end
				dirty = true
				if fake.write(text) ~= true or not current() then return false end
				if sleep_ms(30) == false then return false end
				return current()
			end)
			busy = false
			prepared = ok and ready == true and not revoked
			if not prepared then stage.close() end
			return prepared
		end
		function stage.paste(channel)
			if busy or revoked or not prepared then return false end
			busy = true
			local ok, issued = pcall(function()
				if not current() then return false end
				if channel.emit(29, 1) ~= true or not current() then return false end
				if channel.emit(key_v, 1) ~= true then return false end
				fake.pastes, fake.last_pasted = fake.pastes + 1, fake.contents
				if channel.emit(key_v, 0) ~= true then return false end
				if channel.emit(29, 0) ~= true then return false end
				return sleep_ms(120) ~= false
			end)
			busy = false
			return ok and issued == true
		end
		return stage
	end
end

return M
