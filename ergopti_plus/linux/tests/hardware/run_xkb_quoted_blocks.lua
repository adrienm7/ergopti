--- tests/hardware/run_xkb_quoted_blocks.lua

--- ==============================================================================
--- MODULE: Native XKB Quoted Block Metadata Regression
--- DESCRIPTION:
--- Compiles and canonically serializes real native keymaps, then exercises the
--- public parser and file-backed layout refresh without a display or device.
--- Quoted metadata must not select or truncate an outer structural block.
--- Per-key quoted type braces and symbols-looking strings remain separate bugs.
--- ==============================================================================

local ffi = require("ffi")
local Parser = require("infra.xkb_keymap")
local Rmlvo = require("infra.xkb_rmlvo")
local Shell = require("adapters.shell_runner")
local FileSystem = require("adapters.file_system")
local Layout = require("adapters.keyboard_layout")
local Capture = require("adapters.xkb_capture")

ffi.cdef([[
struct xkb_context *xkb_context_new(int);
void xkb_context_unref(struct xkb_context *);
struct xkb_keymap *xkb_keymap_new_from_string(struct xkb_context *, const char *, int, int);
void xkb_keymap_unref(struct xkb_keymap *);
char *xkb_keymap_get_as_string(struct xkb_keymap *, int);
struct xkb_state *xkb_state_new(struct xkb_keymap *);
void xkb_state_unref(struct xkb_state *);
int xkb_state_key_get_utf8(struct xkb_state *, unsigned int, char *, unsigned long);
void free(void *);
]])

local lib = ffi.load(require("_generated.native_runtime").xkbcommon)
local _checks, _failures = 0, 0
local paths = {}

--- Records one independently expected production-path result.
--- @param condition boolean
--- @param label string
local function check(condition, label)
	_checks = _checks + 1
	if condition then print("PASS " .. label)
	else _failures = _failures + 1; print("FAIL " .. label) end
end

--- Serializes a genuine native keymap after independently checking known keys.
--- @param text string
--- @return string
local function canonicalize(text)
	local context = lib.xkb_context_new(0)
	assert(context ~= nil, "native XKB context creation must succeed")
	local map = lib.xkb_keymap_new_from_string(context, text, 1, 0)
	if map == nil then
		lib.xkb_context_unref(context)
		error("the native compiler refused the test keymap")
	end
	local state = lib.xkb_state_new(map)
	if state == nil then
		lib.xkb_keymap_unref(map); lib.xkb_context_unref(context)
		error("native XKB state creation must succeed")
	end
	local bytes
	local ok, result = pcall(function()
		local buffer = ffi.new("char[16]")
		for _, hit in ipairs({ { 38, "a" }, { 24, "q" }, { 11, "2" } }) do
			local length = tonumber(lib.xkb_state_key_get_utf8(state, hit[1], buffer, 16))
			assert(ffi.string(buffer, length) == hit[2], "the actual native keys must retain their expected text")
		end
		bytes = lib.xkb_keymap_get_as_string(map, 1)
		assert(bytes ~= nil, "native canonical serialization must succeed")
		return ffi.string(bytes)
	end)
	if bytes ~= nil then ffi.C.free(bytes) end
	lib.xkb_state_unref(state); lib.xkb_keymap_unref(map); lib.xkb_context_unref(context)
	if not ok then error(result, 0) end
	return result
end

--- Adds a custom native type and explicitly assigns AC01 to it.
--- @param text string
--- @param name string
--- @return string
local function custom_type(text, name)
	local definition = assert(text:match('type "ALPHABETIC" %b{};'))
	local renamed = definition:gsub('"ALPHABETIC"', function() return '"' .. name .. '"' end, 1)
	local result, count = text:gsub('type "ALPHABETIC" %b{};', function() return definition .. "\n\t" .. renamed end, 1)
	assert(count == 1, "exactly one native type definition must be inserted")
	result, count = result:gsub("(key%s+<AC01>%s*{)%s*", function(prefix)
		return prefix .. '\n\t\ttype[Group1]="' .. name .. '",\n\t\t'
	end, 1)
	assert(count == 1, "exactly one native key must reference the custom type")
	return result
end

local original = assert(Shell.exec(Rmlvo.compile_command(assert(Rmlvo.parse_gnome("[('xkb', 'us')]")))))
local cases = {
	{ name = "healthy group metadata", group = "Readback plain metadata" },
	{ name = "group closing brace", group = "Readback } metadata" },
	{ name = "group opening brace", group = "Readback { metadata" },
	{ name = "group balanced braces", group = "Readback {balanced} metadata" },
	{ name = "group inverted braces", group = "Readback }{ metadata" },
	{ name = "healthy custom type", type_name = "Readback plain type" },
	{ name = "earlier quoted block keyword", type_name = "xkb_symbols" },
	{ name = "earlier quoted level keyword", level_name = "xkb_symbols" },
}
local ok, err = pcall(function()
	for _, spec in ipairs(cases) do
		local text, count = original, 0
		if spec.group then
			text, count = text:gsub('name%[Group1%]%s*=%s*"[^"]*"', function() return 'name[Group1]="' .. spec.group .. '"' end, 1)
			assert(count == 1, "the native input must carry the intended group name")
		elseif spec.type_name then
			text = custom_type(text, spec.type_name)
		else
			text, count = text:gsub('level_name%[1%]%s*=%s*"[^"]*"', function() return 'level_name[1]="' .. spec.level_name .. '"' end, 1)
			assert(count == 1, "the native input must carry the intended level name")
		end
		local canonical = canonicalize(text)
		local section = assert(canonical:find('\nxkb_symbols "', 1, true), "the actual symbols section must be retained")
		if spec.group then
			local retained = assert(canonical:find('name[Group1]="' .. spec.group .. '"', 1, true), "the exact group literal must survive native serialization")
			assert(retained > section, "the group literal must remain in the symbols section")
		elseif spec.type_name then
			local literal = '"' .. spec.type_name .. '"'
			local retained = assert(canonical:find("type " .. literal, 1, true), "the exact custom type literal must survive native serialization")
			assert(retained < section, "the quoted type literal must precede the actual symbols section")
			local key = assert(canonical:find("key <AC01>", section, true))
			local ending = assert(canonical:find("\n\t};", key, true))
			assert(canonical:sub(key, ending):find(literal, 1, true), "the exact type literal must remain in the canonical key definition")
		else
			local retained = assert(canonical:find('level_name[1]= "' .. spec.level_name .. '"', 1, true), "the exact level literal must survive native serialization")
			assert(retained < section, "the quoted level literal must precede the actual symbols section")
		end
		-- Native serialization places symbols last. This independent framing
		-- oracle compares original bytes rather than balancing the same braces.
		local expected_body = assert(canonical:match('\nxkb_symbols "[^"]*" {(.*)};%s*};%s*$'))
		assert(expected_body:find("key <AC01>", 1, true) and expected_body:find("key <AC02>", 1, true))
		check(Parser.block(canonical, "xkb_symbols") == expected_body, spec.name .. ": exact raw block body")
		check(Parser.parse_keycodes(canonical).AC01 == 30, spec.name .. ": native keycode projection")
		local symbols = Parser.parse_symbols(canonical).AC01
		check(symbols ~= nil and symbols[1] == "a" and symbols[2] == "A", spec.name .. ": known native symbols")
		check(#Parser.parse(canonical) >= 200, spec.name .. ": complete keymap entry floor")
		local path = os.tmpname()
		paths[#paths + 1] = path
		assert(FileSystem.write(path, canonical), "checked file publication must succeed")
		check(Layout.refresh(path) == true, spec.name .. ": public native refresh")
		for _, hit in ipairs({ { 30, "a" }, { 16, "q" }, { 3, "2" } }) do
			local label = Layout.base_symbol(hit[1])
			check(label ~= nil and label.text == hit[2], spec.name .. ": public native base " .. hit[2])
		end
		Capture.clear()
	end
end)
Capture.clear()
for _, path in ipairs(paths) do assert(os.remove(path)) end
if not ok then error(err, 0) end
assert(_checks == 64, "all eight native cases must execute eight production checks")
print(string.format("Native XKB quoted blocks: %d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
