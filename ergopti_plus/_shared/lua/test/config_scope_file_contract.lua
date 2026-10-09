--- _shared/lua/test/config_scope_file_contract.lua

--- Shared behavior proves the second file of a scope keeps an exact inverse.
return function(helpers)
	local ScopeFile = require("config_scope_file")

	local function fixture(original)
		local files, removed = { overrides = original }, {}
		local controls = {}
		local fs = {
			write = function() error("publication must retain its source precondition") end,
			read_with_status = function(path)
				return files[path], files[path] and "ok" or "absent"
			end,
			write_if_unchanged = function(path, content, expected)
				if controls.refuse == path then return false end
				if expected.status == "absent" and files[path] ~= nil then return false end
				if expected.status == "ok" and files[path] ~= expected.content then return false end
				files[path] = content
				return true
			end,
		}
		local participant = ScopeFile.new({ path = "overrides", backup_path = "backup", files = fs,
			remove = function(path)
				removed[#removed + 1] = path
				files[path] = nil
				return true
			end })
		return participant, files, controls, removed
	end

	local DELETE = { { section = "rolls", key = "delay", delete = true } }

	helpers.describe("scope secondary file", function()
		helpers.it("publishes after a verified backup and restores the exact bytes", function()
			local original = "# kept\n[rolls]\ndelay = 0.3\ncolor = \"#abc\"\n"
			local participant, files = fixture(original)
			helpers.assert_eq(participant.prepare(DELETE), true)
			helpers.assert_eq(participant.backup(), true)
			helpers.assert_eq(files.backup, original)
			helpers.assert_eq(participant.publish(), true)
			helpers.assert_eq(files.overrides:find("delay", 1, true), nil)
			helpers.assert_eq(files.overrides:find("#abc", 1, true) ~= nil, true)
			helpers.assert_eq(participant.target().content, files.overrides)
			helpers.assert_eq(participant.restore(), true)
			helpers.assert_eq(files.overrides, original)
		end)
		helpers.it("refuses to publish over bytes another writer changed after preparation", function()
			local participant, files = fixture("[rolls]\ndelay = 0.3\n")
			helpers.assert_eq(participant.prepare(DELETE), true)
			files.overrides = "[rolls]\ndelay = 0.9\n"
			helpers.assert_eq(participant.publish(), false)
			helpers.assert_eq(files.overrides, "[rolls]\ndelay = 0.9\n")
			helpers.assert_eq(participant.restore(), true, "nothing was published, so nothing is owed")
		end)
		helpers.it("keeps a refused restoration owed until the published bytes are back", function()
			local participant, files, controls = fixture("[rolls]\ndelay = 0.3\n")
			helpers.assert_eq(participant.prepare(DELETE), true)
			helpers.assert_eq(participant.backup(), true)
			helpers.assert_eq(participant.publish(), true)
			local candidate = files.overrides
			controls.refuse = "overrides"
			helpers.assert_eq(participant.restore(), false)
			helpers.assert_eq(files.overrides, candidate)
			controls.refuse = nil
			helpers.assert_eq(participant.restore(), true)
			helpers.assert_eq(files.overrides, "[rolls]\ndelay = 0.3\n")
		end)
		helpers.it("creates an absent file and removes only its own candidate on restore", function()
			local participant, files, _, removed = fixture(nil)
			helpers.assert_eq(participant.prepare({ { section = "rolls", key = "delay", value = 0.5 } }), true)
			helpers.assert_eq(participant.backup(), true)
			helpers.assert_eq(files.backup, nil, "an absent source has no bytes to back up")
			helpers.assert_eq(participant.publish(), true)
			helpers.assert_eq(participant.target().status, "ok")
			files.overrides = files.overrides .. "[user]\ndelay = 1\n"
			helpers.assert_eq(participant.restore(), false, "another writer's bytes are never removed")
			helpers.assert_eq(#removed, 0)
		end)
		helpers.it("touches nothing when the plan leaves the bytes unchanged", function()
			local participant, files = fixture("[other]\ndelay = 2\n")
			helpers.assert_eq(participant.prepare(DELETE), true)
			helpers.assert_eq(participant.backup(), true)
			helpers.assert_eq(files.backup, nil)
			helpers.assert_eq(participant.publish(), true)
			helpers.assert_eq(participant.target().content, "[other]\ndelay = 2\n")
			helpers.assert_eq(participant.restore(), true)
		end)
	end)
	helpers.describe("secondary conditional publication terminal", function()
		for _, published in ipairs({ true, false }) do
			helpers.it("retains cleanup after a refused publication effect=" .. tostring(published), function()
				local source, blocked = "[rolls]\ndelay = 0.3\n", true
				local disk = { overrides = source }
				local first, calls = true, 0
				local fs = { read_with_status = function(path) return disk[path], disk[path] and "ok" or "absent" end,
					write = function() error("conditional writer required") end,
					write_if_unchanged = function(path, candidate, expected)
						if disk[path] ~= expected.content then return false end
						if first then
							first = false
							if published then disk[path] = candidate end
							return false, "release refused", function()
								calls = calls + 1
								return not blocked, "native owner pending", published
							end
						end
						disk[path] = candidate; return true
					end }
				local file = ScopeFile.new({ path = "overrides", backup_path = "backup", files = fs,
					remove = function() error("present source must not be removed") end })
				helpers.assert_eq(file.prepare(DELETE), true)
				helpers.assert_eq(file.publish(), false)
				helpers.assert_eq(file.restore(), false)
				helpers.assert_eq(file.pending(), true)
				local candidate = disk.overrides
				disk.overrides = "external successor"
				blocked = false
				helpers.assert_eq(file.restore(), not published)
				helpers.assert_eq(disk.overrides, "external successor")
				if published then
					helpers.assert_eq(file.pending(), true, "the source inverse outlives native release")
					disk.overrides = candidate
					helpers.assert_eq(file.restore(), true)
					helpers.assert_eq(disk.overrides, source)
				end
				helpers.assert_eq(file.pending(), false)
				helpers.assert_eq(calls, 2, "completed native cleanup is not repeated")
			end)
		end
	end)
end
