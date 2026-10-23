--- tests/fixtures/native_layout_registry_record.lua
--- ==============================================================================
--- MODULE: Native Layout Registry Record Fixture
--- DESCRIPTION:
--- Calls the production uninstall route on private files. Only the Python
--- process collaborator is scripted; all registry IO uses real native streams.
--- The caller owns five private XDG roots, the directory and the child deadline.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_layout_registry_record%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local folder, kind = assert(arg[1]), assert(arg[2])
for _, key in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR" }) do
	assert(assert(os.getenv(key)):sub(1, #folder + 1) == folder .. "/", "each worker requires its own XDG roots")
end
local Shell, Json, uv = require("adapters.shell_runner"), require("json"), require("luv")
local ConfigPaths = require("infra.config_paths")
local Registry, Runner = require("modules.keymap.layout_registry"), require("adapters.process_runner")
local Reader, Native = require("infra.regular_file_reader"), require("infra.regular_file_writer")
local open, rename, reader_open, native_open = io.open, os.rename, Reader.open, Native.open
local settings = assert(Registry.settings())
local local_dir = ConfigPaths.config(settings.local_folder) .. "/"
assert(local_dir:sub(1, #folder + 1) == folder .. "/", "the actual production locator must stay private")
assert(Shell.run("mkdir -p -- " .. Shell.quote(local_dir)))
local path, target = local_dir .. settings.installed_file, folder .. "/target"
local stage = path .. ".tmp"
local function write(candidate, bytes)
	local file = assert(open(candidate, "wb")); assert(file:write(bytes)); assert(file:close())
end
local function read(candidate)
	local file = assert(open(candidate, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end
local index = assert(Json.decode_lossless(read(root .. "/../../layouts/registry/index.json")))
local first, remaining = assert(index.layouts[1]), assert(index.layouts[2])
assert(first.id ~= remaining.id)
local before = assert(Json.encode({ schema_version = 1, layouts = { [first.id] = first, [remaining.id] = remaining },
	future = { marker = "preserve the other installed layout", opaque = { false, "unchanged" } } }))
local foreign = "private borrowed staging\0\r\n"
write(path, before); write(target, foreign)
write(local_dir .. first.id .. ".keylayout", "private first layout")
write(local_dir .. remaining.id .. ".keylayout", "private remaining layout")
local stage_kind = kind:match("^stage_(.+)$")
if stage_kind == "fifo" then assert(Shell.run("mkfifo -- " .. Shell.quote(stage)))
elseif stage_kind == "symlink" then assert(uv.fs_symlink(target, stage))
elseif stage_kind == "hardlink" then assert(uv.fs_link(target, stage))
elseif stage_kind == "regular" then write(stage, foreign)
elseif stage_kind == "directory" then assert(uv.fs_mkdir(stage, 448))
elseif stage_kind ~= nil then error("unknown staging kind") end
local fault, runs, read_opened, read_closed, write_opened, write_closed = true, 0, 0, 0, 0, 0
local modes, rename_attempts = {}, 0
local function refuse()
	if kind:match("_throw$") then error("controlled registry receipt exception") end
	if kind:match("_false$") then return false, "controlled registry receipt" end
	return nil, "controlled registry receipt"
end
Reader.open = function(candidate)
	local stream, detail, errno = reader_open(candidate)
	if candidate ~= path or not stream then return stream, detail, errno end
	read_opened = read_opened + 1
	return {
		read = function(_, mode)
			local bytes = stream:read(mode)
			if fault and kind:match("^read_[^_]+$") then return refuse() end
			return bytes
		end,
		close = function()
			assert(stream:close()); read_closed = read_closed + 1
			if fault and kind:match("^read_close_") then return refuse() end
			return true
		end,
	}, detail, errno
end
Native.open = function(candidate, mode)
	local stream, detail, errno, cleanup, current = native_open(candidate, mode)
	if candidate ~= path and candidate ~= stage or not stream then return stream, detail, errno, cleanup, current end
	write_opened = write_opened + 1; modes[#modes + 1] = mode
	return {
		write = function(_, bytes)
			assert(stream:write(fault and kind:match("^write_") and bytes:sub(1, 13) or bytes))
			if fault and kind:match("^write_") then return refuse() end
			return stream
		end,
		close = function()
			assert(stream:close()); write_closed = write_closed + 1
			if fault and kind:match("^close_") then return refuse() end
			return true
		end,
	}, detail, errno, cleanup, current
end
os.rename = function(from, to)
	if from == stage and to == path then
		rename_attempts = rename_attempts + 1
		if fault and kind:match("^rename_") then return refuse() end
	end
	return rename(from, to)
end
Runner.run = function(program, args, _, done)
	runs = runs + 1
	assert(program == "python3", "no desktop or network command may run")
	if args[1] == "-c" then done({ exit_code = 0, stdout = "", stderr = "" })
	else
		assert(args[1]:match("user_layout_installer%.py$") and args[2] == "uninstall")
		done({ exit_code = 0, stdout = '{"ok":true,"verified":true,"detail":"fixture uninstall"}\n', stderr = "" })
	end
	return true
end
local function uninstall()
	local result = { calls = 0 }
	result.dispatched = Registry.uninstall(first.id, function(ok, detail)
		result.calls = result.calls + 1; result.ok, result.detail = ok, detail
	end)
	return result
end
local result = uninstall()
local after = read(path)
local initial_reads_closed, initial_writes_closed, initial_runs = read_opened == read_closed, write_opened == write_closed, runs
local metadata, staging_bytes = uv.fs_lstat(stage), nil
if metadata and (metadata.type == "file" or metadata.type == "link") then staging_bytes = read(stage) end
fault = false
local snapshot = Registry.snapshot()
local retry
if result.ok == false and after == before then
	if stage_kind then assert(os.remove(stage)) end
	retry = uninstall()
end
local parsed, final = pcall(Json.decode_lossless, read(path))
if not parsed or type(final) ~= "table" or type(final.layouts) ~= "table" then final = { layouts = {} } end
local receipt = { kind = kind, callback_calls = result.calls, committed = result.ok, failure = result.detail,
	before_bytes = before, after_first_bytes = after, source_preserved = before == after,
	initial_reads_closed = initial_reads_closed, initial_writes_closed = initial_writes_closed,
	initial_process_callbacks = initial_runs, native_write_modes = modes, rename_attempts = rename_attempts,
	staging_type_after_first = metadata and metadata.type, staging_bytes_after_first = staging_bytes,
	foreign_target_preserved = read(target) == foreign, snapshot_remaining = snapshot.installed[remaining.id] ~= nil,
	snapshot_record_error = snapshot.record_error, retry_committed = retry and retry.ok,
	final_removed_first = final.layouts[first.id] == nil, final_kept_remaining = final.layouts[remaining.id] ~= nil,
	final_kept_future = final.future and final.future.marker == "preserve the other installed layout",
	physical_commands_started = 0, five_private_XDG = true, default_production_deps = true }
write(folder .. "/receipt.json", assert(Json.encode(receipt)))
assert(result.calls == 1, "one terminal callback is required")
assert(initial_reads_closed and initial_writes_closed, "every acquired native registry stream must close")
assert(receipt.foreign_target_preserved, "a borrowed staging target must stay exact")
if kind == "healthy" then assert(result.ok == true)
else
	assert(result.ok == false and result.detail == Registry.FAILURE_RECORD, "a native receipt refusal must fail the registry operation")
	assert(after == before, "a failed installed-record publication must retain the exact original registry")
	assert(receipt.snapshot_remaining and snapshot.record_error == nil, "another installed layout remains visible after failure")
	assert(retry and retry.calls == 1 and retry.ok == true, "the same public operation must succeed after repairing the refusal")
	if kind:match("^read_") then assert(initial_runs == 0, "a read refusal cannot dispatch the installer") end
	if stage_kind then
		assert(metadata, "a pre-existing staging endpoint must stay present")
		if stage_kind ~= "fifo" and stage_kind ~= "directory" then assert(staging_bytes == foreign) end
	end
end
assert(final.layouts[first.id] == nil and final.layouts[remaining.id] ~= nil, "healthy publication removes only the requested layout")
assert(receipt.final_kept_future, "future registry fields remain source data")
assert(uv.fs_lstat(stage) == nil, "a successful retry consumes only its own staging")
write(folder .. "/complete", "complete")
