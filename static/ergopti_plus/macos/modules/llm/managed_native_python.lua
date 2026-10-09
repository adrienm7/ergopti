--- modules/llm/managed_native_python.lua

--- ==============================================================================
--- MODULE: Managed Native Python Resolver
--- DESCRIPTION:
--- Reuses the native system interpreter or the exact private uv installation
--- selected by the canonical pinned Python catalogue, without executing a probe.
--- ==============================================================================

local M = {}
local Interpreter = require("adapters.python_interpreter")
local FileSystem = require("adapters.file_system")
local Json = require("json")
local hs = hs
local Logger = require("infra.logger")

local function integer(value)
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

--- Resolve one actually native interpreter; absence never triggers a download.
--- @return string|nil executable Existing native interpreter.
function M.resolve()
	local system = Interpreter.resolve()
	if system then return system end
	local home = os.getenv("HOME")
	local arch = hs and hs.processInfo and hs.processInfo.arch
	local family = arch == "arm64" and "aarch64" or arch == "x86_64" and "x86_64" or nil
	if type(home) ~= "string" or home:sub(1, 1) ~= "/" or not family then return nil end
	local source = debug.getinfo(1, "S").source:sub(2)
	local driver = source:match("^(.*)/modules/llm/managed_native_python%.lua$")
	if not driver then return nil end
	local function refused() Logger.error("managed_native_python", "Pinned native Python catalogue admission refused.") end
	local read_ok, bytes, status = pcall(FileSystem.read_with_status,
		driver .. "/../_shared/modules/llm/managed_python_release.json", refused)
	if not read_ok or status ~= "ok" or type(bytes) ~= "string" then return nil end
	local decoded, catalogue = pcall(Json.decode, bytes)
	if not decoded or type(catalogue) ~= "table" or catalogue.schema_version ~= 1
		or type(catalogue.downloads) ~= "table" then return nil end
	local selected = nil
	for _, row in pairs(catalogue.downloads) do
		if type(row) == "table" and row.name == "cpython" and row.os == "darwin" and row.libc == "none"
			and row.prerelease == "" and type(row.arch) == "table" and row.arch.family == family then
			if selected or not integer(row.major) or not integer(row.minor) or not integer(row.patch) then return nil end
			selected = row
		end
	end
	if not selected then return nil end
	local root = home:gsub("/+$", "") .. "/Library/Application Support/Ergopti/native-bootstrap/python/"
	local version = string.format("%.0f.%.0f.%.0f", selected.major, selected.minor, selected.patch)
	local path = root .. "cpython-" .. version .. "-macos-" .. family .. "-none/bin/python"
		.. string.format("%.0f.%.0f", selected.major, selected.minor)
	local absolute_ok, absolute = pcall(hs.fs.pathToAbsolute, path)
	if not absolute_ok or type(absolute) ~= "string" or absolute:sub(1, #root) ~= root then return nil end
	local attributes_ok, attributes = pcall(hs.fs.attributes, absolute)
	if not attributes_ok or type(attributes) ~= "table" or attributes.mode ~= "file"
		or type(attributes.permissions) ~= "string" or not attributes.permissions:find("x", 1, true) then return nil end
	local opened, file = pcall(io.open, absolute, "rb")
	if not opened or not file then return nil end
	local read, head = pcall(file.read, file, 4096)
	local close_ok, closed = pcall(file.close, file)
	if not read or not close_ok or closed ~= true then return nil end
	local slices = Interpreter.parse_header(head)
	if type(slices) ~= "table" then return nil end
	for _, slice in ipairs(slices) do if slice == arch then return absolute end end
	return nil
end

return M
