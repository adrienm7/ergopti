-- Characterize actual shared policy ownership after real magic-key mutation.
local root = assert(arg[1], "Pass repository root")
package.path = root .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local Json = require("json")
local Policy = require("caps_word.auto_off")
local Terminators = require("keymap.terminators")
local function compile(owner)
	return assert(owner.compile({ idle_timeout_seconds = 0, terminators = { "star" },
		pointer = { pointer_motion = false } }, { "pointer_motion" }))
end
assert(Policy.ends_on_text(compile(Policy), "★"))
assert(not Policy.ends_on_text(compile(Policy), "§"))
assert(Terminators.update_magic_key("§"))
local old = compile(Policy)
assert(Terminators.is_terminator("§"))
assert(not Terminators.is_terminator("★"))
assert(Policy.ends_on_text(old, "★"))
assert(not Policy.ends_on_text(old, "§"))
package.loaded["caps_word.auto_off"] = nil
local LoadedAfterRename = require("caps_word.auto_off")
local renamed = compile(LoadedAfterRename)
assert(LoadedAfterRename.ends_on_text(renamed, "§"))
assert(not LoadedAfterRename.ends_on_text(renamed, "★"))
assert(Terminators.update_magic_key("★"))
package.loaded["caps_word.auto_off"] = Policy
print(Json.encode({ after_real_magic_key_rename = "§", hotstring_magic = { star = false, section = true },
	caps_policy_loaded_before_rename = { star = true, section = false },
	caps_policy_loaded_after_rename = { star = false, section = true },
	qualification = "Actual shared mutation and real policy module loads; not full boot order, menu label, keymap admission or native receiving." }))
