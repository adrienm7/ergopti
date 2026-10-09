--- tests/unit/adapters/file_system/test_classified_read_and_create.lua

--- ==============================================================================
--- MODULE: FileSystem Classified Read and Create Regression
--- DESCRIPTION:
--- Preserves the filesystem transaction contract at its owning boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("adapters.file_system: classified reads and create-only publication", function()
	helpers.it("distinguishes a proven absent file from unsafe lookups", function()
		with_fixture(function(fixture)
			local root = os.tmpname():gsub("\\", "/") .. "_classified"
			local absent = root .. "/absent.toml"
			local dangling = root .. "/dangling.toml"
			local target = root .. "/missing-target.toml"
			local inaccessible = root .. "/locked.toml"
			local missing_parent = root .. "/missing/config.toml"
			local directory = root .. "/directory"
			fixture.HOST_MKDIR(root)
			fixture.HOST_MKDIR(directory)

			local adapter = fixture.make_adapter({
				[dangling] = target,
			}, {
				[inaccessible] = true,
			}, {
				[absent] = true,
				[target] = true,
				[root .. "/missing"] = true,
			})

			local content, status = adapter.read_with_status(absent)
			helpers.assert_nil(content)
			helpers.assert_eq(status, "absent", "only a listed final-name absence may be classified absent")

			content, status = adapter.read_with_status(dangling)
			helpers.assert_nil(content)
			helpers.assert_eq(status, "error", "a dangling symlink must never be classified absent")

			content, status = adapter.read_with_status(directory)
			helpers.assert_nil(content)
			helpers.assert_eq(status, "error", "a directory at the requested pathname is not absence")

			content, status = adapter.read_with_status(inaccessible)
			helpers.assert_nil(content)
			helpers.assert_eq(status, "error", "an lstat/EACCES-style failure is not absence")

			content, status = adapter.read_with_status(missing_parent)
			helpers.assert_nil(content)
			helpers.assert_eq(status, "error", "a missing path prefix is not a creatable final-name absence")

			fixture.HOST_RMDIR(directory)
			fixture.HOST_RMDIR(root)
		end)
	end)

	helpers.it("resolves dot-dot after an intermediate symlink before a classified read", function()
		with_fixture(function(fixture)
			local request_root = os.tmpname():gsub("\\", "/") .. "_read_request"
			local target_root = os.tmpname():gsub("\\", "/") .. "_read_target"
			local target_subdirectory = target_root .. "/sub"
			local link_path = request_root .. "/link"
			local requested_path = link_path .. "/../preferences.toml"
			local kernel_target = target_root .. "/preferences.toml"
			local lexically_collapsed_target = request_root .. "/preferences.toml"
			local content, status
			local call_ok, call_err = xpcall(function()
				os.remove(request_root)
				os.remove(target_root)
				assert(fixture.HOST_MKDIR(request_root))
				assert(fixture.HOST_MKDIR(target_root))
				assert(fixture.HOST_MKDIR(target_subdirectory))

				local kernel_file = assert(io.open(kernel_target, "w"))
				assert(kernel_file:write("kernel target")); assert(kernel_file:close())
				local collapsed_file = assert(io.open(lexically_collapsed_target, "w"))
				assert(collapsed_file:write("lexically collapsed target")); assert(collapsed_file:close())

				local adapter = fixture.make_adapter({ [link_path] = target_subdirectory })
				content, status = adapter.read_with_status(requested_path)
			end, debug.traceback)
			os.remove(kernel_target)
			os.remove(lexically_collapsed_target)
			fixture.HOST_RMDIR(target_subdirectory)
			fixture.HOST_RMDIR(target_root)
			fixture.HOST_RMDIR(request_root)
			if not call_ok then error(call_err) end

			helpers.assert_eq(status, "ok")
			helpers.assert_eq(content, "kernel target",
				"classified reads must apply dot-dot to the symlink target, not the link's parent")
		end)
	end)

	helpers.it("resolves dot-dot after an intermediate symlink before create-only publication", function()
		with_fixture(function(fixture)
			local request_root = os.tmpname():gsub("\\", "/") .. "_create_request"
			local target_root = os.tmpname():gsub("\\", "/") .. "_create_target"
			local target_subdirectory = target_root .. "/sub"
			local link_path = request_root .. "/link"
			local requested_path = link_path .. "/../personal_shortcuts.toml"
			local kernel_target = target_root .. "/personal_shortcuts.toml"
			local lexically_collapsed_target = request_root .. "/personal_shortcuts.toml"
			local staging_locks = {}
			local created, status, kernel_content, collapsed_content, published_path
			local call_ok, call_err = xpcall(function()
				os.remove(request_root)
				os.remove(target_root)
				assert(fixture.HOST_MKDIR(request_root))
				assert(fixture.HOST_MKDIR(target_root))
				assert(fixture.HOST_MKDIR(target_subdirectory))

				local collapsed_file = assert(io.open(lexically_collapsed_target, "w"))
				assert(collapsed_file:write("foreign collapsed file")); assert(collapsed_file:close())

				local adapter = nil
				adapter, staging_locks = fixture.make_adapter(
					{ [link_path] = target_subdirectory },
					nil,
					nil,
					function(source, destination, is_symlink)
						helpers.assert_eq(is_symlink, false)
						published_path = destination
						local source_file = assert(io.open(source, "r"))
						local payload = source_file:read("*a"); assert(source_file:close())
						local destination_file = assert(io.open(destination, "w"))
						assert(destination_file:write(payload)); assert(destination_file:close())
						return true
					end
				)
				created, status = adapter.create_if_absent(requested_path, "our defaults")

				local kernel_file = io.open(kernel_target, "r")
				if kernel_file then kernel_content = kernel_file:read("*a"); kernel_file:close() end
				local collapsed_read = assert(io.open(lexically_collapsed_target, "r"))
				collapsed_content = collapsed_read:read("*a"); collapsed_read:close()
			end, debug.traceback)
			os.remove(kernel_target)
			os.remove(lexically_collapsed_target)
			for lock_path in pairs(staging_locks) do
				os.remove(lock_path .. "/payload")
				fixture.HOST_RMDIR(lock_path)
			end
			fixture.HOST_RMDIR(target_subdirectory)
			fixture.HOST_RMDIR(target_root)
			fixture.HOST_RMDIR(request_root)
			if not call_ok then error(call_err) end

			helpers.assert_eq(created, true, "the POSIX destination is absent and must be creatable")
			helpers.assert_eq(status, "created")
			helpers.assert_eq(published_path, kernel_target,
				"create-only publication must target the symlink target's parent")
			helpers.assert_eq(kernel_content, "our defaults")
			helpers.assert_eq(collapsed_content, "foreign collapsed file",
				"the lexically collapsed sibling belongs to another pathname and must remain untouched")
		end)
	end)

	helpers.it("requires read and close to commit before returning ok", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local seed = assert(io.open(path, "w")); seed:write("seed"); seed:close()
			local adapter = fixture.make_adapter({ [path] = { mode = "file" } })
			local original_open = io.open
			local close_calls = 0

			io.open = function(open_path, mode)
				if open_path == path and mode == "r" then
					return {
						read = function() return "complete" end,
						close = function() close_calls = close_calls + 1; return nil, "flush failed" end,
					}
				end
				return original_open(open_path, mode)
			end
			local call_ok, content, status = pcall(adapter.read_with_status, path)
			io.open = original_open
			os.remove(path)
			if not call_ok then error(content) end

			helpers.assert_nil(content)
			helpers.assert_eq(status, "error", "a failed close must not publish read content")
			helpers.assert_eq(close_calls, 1, "the read handle must be closed exactly once")
		end)
	end)

	helpers.it("rejects a regular file replaced after its bytes were read", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local seed = assert(io.open(path, "w")); seed:write("old bytes"); seed:close()
			local probes = 0
			local adapter = fixture.make_adapter({
				[path] = function()
					probes = probes + 1
					if probes == 1 then return { mode = "file", dev = 7, ino = 11 } end
					return { mode = "file", dev = 7, ino = 12 }
				end,
			})

			local content, status, detail = adapter.read_with_status(path)
			helpers.assert_nil(content, "bytes from a replaced file must never be committed")
			helpers.assert_eq(status, "error")
			helpers.assert_true(type(detail) == "string" and detail:find("identity changed", 1, true) ~= nil,
				"the failure must identify the ordinary-file replacement race")
			os.remove(path)
		end)
	end)

	helpers.it("rejects a same-inode file whose attributes change while it is read", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local seed = assert(io.open(path, "w")); seed:write("old bytes"); seed:close()
			local probes = 0
			local adapter = fixture.make_adapter({
				[path] = function()
					probes = probes + 1
					if probes == 1 then
						return {
							mode = "file",
							dev = 7,
							ino = 11,
							size = 9,
							modification = 100,
							change = 200,
						}
					end
					return {
						mode = "file",
						dev = 7,
						ino = 11,
						size = 4,
						modification = 101,
						change = 201,
					}
				end,
			})

			local content, status, detail = adapter.read_with_status(path)
			helpers.assert_nil(content, "bytes observed during an in-place rewrite must not commit")
			helpers.assert_eq(status, "error")
			helpers.assert_true(type(detail) == "string" and detail:find("size changed", 1, true) ~= nil,
				"the refusal must identify the changed attribute")
			helpers.assert_true(probes >= 2,
				"the same ordinary file must be inspected before and after reading")
			os.remove(path)
		end)
	end)

	helpers.it("rejects same-size in-place mutation timestamps", function()
		with_fixture(function(fixture)
			for _, changed_field in ipairs({ "modification", "change" }) do
				local path = os.tmpname():gsub("\\", "/")
				local seed = assert(io.open(path, "w")); seed:write("same"); seed:close()
				local probes = 0
				local adapter = fixture.make_adapter({
					[path] = function()
						probes = probes + 1
						local attributes = {
							mode = "file",
							dev = 7,
							ino = 11,
							size = 4,
							modification = 100,
							change = 200,
						}
						if probes > 1 then attributes[changed_field] = attributes[changed_field] + 1 end
						return attributes
					end,
				})

				local content, status, detail = adapter.read_with_status(path)
				helpers.assert_nil(content,
					"same-size in-place mutation must not commit when " .. changed_field .. " changed")
				helpers.assert_eq(status, "error")
				helpers.assert_true(type(detail) == "string"
					and detail:find(changed_field .. " changed", 1, true) ~= nil,
					"the refusal must identify the changed " .. changed_field .. " time")
				os.remove(path)
			end
		end)
	end)

	helpers.it("rejects content whose byte length disagrees with the captured size", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local seed = assert(io.open(path, "w")); seed:write("nine-byte"); seed:close()
			local adapter = fixture.make_adapter({
				[path] = {
					mode = "file",
					dev = 7,
					ino = 11,
					size = 9,
					modification = 100,
					change = 200,
				},
			})
			local original_open = io.open
			io.open = function(open_path, mode)
				if open_path == path and mode == "r" then
					return {
						read = function() return "torn" end,
						close = function() return true end,
					}
				end
				return original_open(open_path, mode)
			end
			local call_ok, content, status, detail = pcall(adapter.read_with_status, path)
			io.open = original_open
			os.remove(path)
			if not call_ok then error(content) end

			helpers.assert_nil(content, "a partial stream must not commit as an exact snapshot")
			helpers.assert_eq(status, "error")
			helpers.assert_true(type(detail) == "string" and detail:find("byte length", 1, true) ~= nil,
				"the refusal must identify the stream-size mismatch")
		end)
	end)

	helpers.it("rejects removal of the ordinary target behind a stable symlink", function()
		with_fixture(function(fixture)
			local link_path = os.tmpname():gsub("\\", "/")
			local target_path = link_path .. ".target"
			local seed = assert(io.open(target_path, "w")); seed:write("target bytes"); seed:close()
			local target_probes = 0
			local adapter = fixture.make_adapter({
				[link_path] = { mode = "link", target = target_path, dev = 3, ino = 5 },
				[target_path] = function()
					target_probes = target_probes + 1
					if target_probes == 1 then return { mode = "file", dev = 7, ino = 11 } end
					os.remove(target_path)
					return nil
				end,
			}, nil, { [target_path] = function() return target_probes > 1 end })

			local content, status = adapter.read_with_status(link_path)
			helpers.assert_nil(content, "a removed symlink target must not commit stale handle bytes")
			helpers.assert_eq(status, "error", "target removal is not absence of the requested symlink")
			os.remove(target_path)
		end)
	end)

	helpers.it("does not overwrite a target created between absence proof and publication", function()
		with_fixture(function(fixture)
			local target = os.tmpname():gsub("\\", "/")
			os.remove(target)
			local confirmed_absences = { [target] = true }
			local link_calls = 0
			local adapter = fixture.make_adapter(nil, nil, confirmed_absences, function(_, destination, is_symlink)
				link_calls = link_calls + 1
				helpers.assert_eq(destination, target)
				helpers.assert_eq(is_symlink, false)
				confirmed_absences[target] = nil
				local foreign = assert(io.open(target, "w"))
				foreign:write("foreign winner")
				foreign:close()
				return nil, "File exists"
			end)

			local created, status = adapter.create_if_absent(target, "our defaults")
			helpers.assert_eq(created, false, "the losing creator must report that it did not publish")
			helpers.assert_eq(status, "exists", "a readable concurrent winner is an idempotent exists result")
			helpers.assert_eq(link_calls, 1, "publication must use one create-only hard-link operation")
			local fh = assert(io.open(target, "r"))
			local content = fh:read("*a"); fh:close()
			helpers.assert_eq(content, "foreign winner", "the concurrent winner must never be overwritten")
			os.remove(target)
		end)
	end)

	helpers.it("prepares multiple missing parent levels before classifying the final file absent", function()
		with_fixture(function(fixture)
			local root = os.tmpname():gsub("\\", "/") .. "_prepared_parent"
			local first = root .. "/.config"
			local second = first .. "/karabiner"
			local destination = second .. "/karabiner.json"
			local prepared, detail, content, status
			local call_ok, call_err = xpcall(function()
				os.remove(root)
				assert(fixture.HOST_MKDIR(root))
				local adapter = fixture.make_adapter()
				prepared, detail = adapter.prepare_parent_for_create(destination)
				content, status = adapter.read_with_status(destination)
			end, debug.traceback)
			fixture.HOST_RMDIR(second)
			fixture.HOST_RMDIR(first)
			fixture.HOST_RMDIR(root)
			if not call_ok then error(call_err) end

			helpers.assert_eq(prepared, true, tostring(detail))
			helpers.assert_nil(content)
			helpers.assert_eq(status, "absent",
				"only the final name may remain absent after parent preparation")
		end)
	end)

	helpers.it("fails closed when mkdir cannot create a missing parent", function()
		with_fixture(function(fixture)
			local root = os.tmpname():gsub("\\", "/") .. "_denied_parent"
			local denied_parent = root .. "/karabiner"
			local destination = denied_parent .. "/karabiner.json"
			os.remove(root)
			assert(fixture.HOST_MKDIR(root))
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, nil, function(path)
				if path == denied_parent then return nil, "Permission denied" end
				return fixture.HOST_MKDIR(path)
			end)

			local prepared, detail = adapter.prepare_parent_for_create(destination)

			helpers.assert_eq(prepared, false)
			helpers.assert_true(type(detail) == "string" and detail:find("Permission denied", 1, true) ~= nil,
				"the exact mkdir refusal must remain visible")
			helpers.assert_nil(fixture.HOST_ATTRIBUTES(denied_parent),
				"a refused parent must not be reported or modelled as created")
			fixture.HOST_RMDIR(root)
		end)
	end)

	helpers.it("accepts a concurrent directory winner after mkdir reports File exists", function()
		with_fixture(function(fixture)
			local root = os.tmpname():gsub("\\", "/") .. "_parent_winner"
			local won_parent = root .. "/karabiner"
			local destination = won_parent .. "/karabiner.json"
			local mkdir_calls = 0
			local prepared, detail, content, status
			local call_ok, call_err = xpcall(function()
				os.remove(root)
				assert(fixture.HOST_MKDIR(root))
				local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, nil, function(path)
					mkdir_calls = mkdir_calls + 1
					if path == won_parent then
						assert(fixture.HOST_MKDIR(path))
						return nil, "File exists"
					end
					return fixture.HOST_MKDIR(path)
				end)
				prepared, detail = adapter.prepare_parent_for_create(destination)
				content, status = adapter.read_with_status(destination)
			end, debug.traceback)
			fixture.HOST_RMDIR(won_parent)
			fixture.HOST_RMDIR(root)
			if not call_ok then error(call_err) end

			helpers.assert_eq(prepared, true, tostring(detail))
			helpers.assert_eq(mkdir_calls, 1,
				"the concurrent winner must be accepted without a second mkdir attempt")
			helpers.assert_nil(content)
			helpers.assert_eq(status, "absent",
				"the winner authorizes only the final classified-absence read")
		end)
	end)

	helpers.it("rejects a concurrent non-directory winner after mkdir reports File exists", function()
		with_fixture(function(fixture)
			local root = os.tmpname():gsub("\\", "/") .. "_parent_file_winner"
			local won_path = root .. "/karabiner"
			local destination = won_path .. "/karabiner.json"
			local prepared, detail
			local call_ok, call_err = xpcall(function()
				os.remove(root)
				assert(fixture.HOST_MKDIR(root))
				local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, nil, function(path)
					if path == won_path then
						local winner = assert(io.open(path, "w"))
						assert(winner:write("foreign winner")); assert(winner:close())
						return nil, "File exists"
					end
					return fixture.HOST_MKDIR(path)
				end)
				prepared, detail = adapter.prepare_parent_for_create(destination)
			end, debug.traceback)
			os.remove(won_path)
			fixture.HOST_RMDIR(root)
			if not call_ok then error(call_err) end

			helpers.assert_eq(prepared, false)
			helpers.assert_true(type(detail) == "string" and detail:find("not a directory", 1, true) ~= nil,
				"a file or symlink winner must never authorize descendant creation")
		end)
	end)

	helpers.it("rejects a parent symlink retargeted during directory creation", function()
		with_fixture(function(fixture)
			local request_root = os.tmpname():gsub("\\", "/") .. "_prepare_request"
			local target_a = os.tmpname():gsub("\\", "/") .. "_prepare_target_a"
			local target_b = os.tmpname():gsub("\\", "/") .. "_prepare_target_b"
			local link_path = request_root .. "/karabiner-link"
			local created_parent_a = target_a .. "/karabiner"
			local untouched_parent_b = target_b .. "/karabiner"
			local destination = link_path .. "/karabiner/karabiner.json"
			local current_target = target_a
			local prepared, detail
			local call_ok, call_err = xpcall(function()
				os.remove(request_root)
				os.remove(target_a)
				os.remove(target_b)
				assert(fixture.HOST_MKDIR(request_root))
				assert(fixture.HOST_MKDIR(target_a))
				assert(fixture.HOST_MKDIR(target_b))
				local adapter = fixture.make_adapter({
					[link_path] = function()
						return { mode = "link", target = current_target, dev = 7, ino = 11 }
					end,
				}, nil, nil, nil, nil, nil, function(path)
					local created, create_err = fixture.HOST_MKDIR(path)
					if path == created_parent_a and created == true then current_target = target_b end
					return created, create_err
				end)
				prepared, detail = adapter.prepare_parent_for_create(destination)
			end, debug.traceback)
			fixture.HOST_RMDIR(created_parent_a)
			fixture.HOST_RMDIR(untouched_parent_b)
			fixture.HOST_RMDIR(target_a)
			fixture.HOST_RMDIR(target_b)
			fixture.HOST_RMDIR(request_root)
			if not call_ok then error(call_err) end

			helpers.assert_eq(prepared, false)
			helpers.assert_true(type(detail) == "string" and detail:find("symlink target changed", 1, true) ~= nil,
				"retargeting must invalidate the observed route")
			helpers.assert_nil(fixture.HOST_ATTRIBUTES(untouched_parent_b),
				"preparation must never follow the replacement target after the race")
		end)
	end)
end)
