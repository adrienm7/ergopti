local root = "/tmp/ergopti-group1-todo33-domains/static/ergopti_plus/linux"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Logger = require("logger.shim")
local warnings, errors = {}, {}
Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
local Loader = require("platform.remap.tap_hold_loader")
local Writer = require("platform.remap.tap_hold_writer")
local Codec = require("toml_codec")
local Defaults = root .. "/../_shared/tap_hold/defaults.toml"
local function write(path, text)
 local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
end
local function read(path)
 local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
end
for _, vector in ipairs({
 { id="wrong-global-enabled-leaf", source='[tap_hold]\nenabled="old"\n[tap_hold.keys.caps_lock]\ntap_action="enter"\n' },
 { id="scalar-root-parent", source='tap_hold="opaque"\n[future]\nkeep="unchanged"\n' },
 { id="scalar-keys-parent", source='[tap_hold]\nkeys="opaque"\n[future]\nkeep="unchanged"\n' },
 { id="array-binding-false-ack", source='[tap_hold.keys]\ncaps_lock=[1,2]\n[future]\nkeep="unchanged"\n' },
 { id="scalar-binding-replacement", source='[tap_hold.keys]\ncaps_lock="opaque"\n[future]\nkeep="unchanged"\n' },
}) do
 local path=os.tmpname(); write(path,vector.source)
 warnings,errors={},{}
 require("config_outdated").reset_for_tests()
 local before=Loader.load(Defaults,path)
 local reloads=0
 Writer._reset_for_test()
 Writer.init({path=path,reload=function() reloads=reloads+1; return true end,
  is_tap_action=function(id)return id=="copy"end,canonical_hold=function()return ""end})
 local called,receipt=pcall(Writer.set_tap,"caps_lock","copy")
 local after=Codec.decode(read(path));local loaded=Loader.load(Defaults,path)
 print(vector.id, "called="..tostring(called),"receipt="..tostring(receipt),"warnings="..#warnings,"errors="..#errors,
  "reloads="..reloads,"enabled="..tostring(before.enabled),
  "projected_tap="..tostring(loaded.keys.caps_lock and loaded.keys.caps_lock.tap_action))
 print("published="..read(path):gsub("\n"," | "))
 assert(os.remove(path))
end
