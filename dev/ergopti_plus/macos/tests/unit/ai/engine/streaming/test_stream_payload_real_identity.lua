--- tests/unit/ai/engine/streaming/test_stream_payload_real_identity.lua

--- Verifies retirement through the real FileSystem adapter and actual path replacement.
local helpers = require("tests.helpers")
local fixture = require("tests.support.file_system_transaction_fixture")
local uv = require("luv")
local function attrs(path)
 local value = uv.fs_lstat(path)
 if value then value.mode = value.type end
 return value
end
local function followed(path)
 local value = uv.fs_stat(path)
 if value then value.mode = value.type end
 return value
end

helpers.describe("stream payload allocation identity", function()
 helpers.it("returns the native temporary file identity without changing the error return", function()
  fixture.with_fixture(function(native)
   local files = native.make_adapter()
   local path, detail, identity = files.create_secure_temp_file()
   helpers.assert_type(path, "string")
   helpers.assert_nil(detail)
   local actual = assert(attrs(path))
   helpers.assert_eq(identity, { dev = actual.dev, ino = actual.ino })
   assert(os.remove(path))
  end, { fs = { attributes = followed, symlinkAttributes = attrs,
   mkdir = function(path) return uv.fs_mkdir(path, 448) end, rmdir = uv.fs_rmdir } })
 end)
end)

helpers.describe("stream payload exact-file retirement", function()
 for _, scenario in ipairs({ "healthy", "same bytes", "symlink" }) do
  helpers.it("handles " .. scenario .. " after the child settles", function()
   fixture.with_fixture(function(native)
    local files = native.make_adapter()
    package.loaded["core.fs.adapters.file_system"] = files
    package.loaded["ai.engine.api.stream_payload_cleanup"] = nil
    local cleanup = require("ai.engine.api.stream_payload_cleanup")
    local path = assert(os.tmpname())
    local original, target = path .. ".original", path .. ".target"
    local function write(name)
     local stream = assert(io.open(name, "wb")); assert(stream:write("request body")); assert(stream:close())
    end
    local ok, err = xpcall(function()
     write(path)
     local attributes = assert(attrs(path))
     local settled = false
     local owner = cleanup.new({ error = function() end, debug = function() end }, "test")
     local retire = owner.capture(path, function() return { isSettled = function() return settled end } end,
      { dev = attributes.dev, ino = attributes.ino }, "request body")
     helpers.assert_eq(retire(), false)
     if scenario ~= "healthy" then
      assert(os.rename(path, original))
      if scenario == "symlink" then write(target); assert(uv.fs_symlink(target, path)) else write(path) end
     end
     settled = true
     if scenario == "healthy" then
      helpers.assert_eq(owner.settle_pending(), true)
      helpers.assert_nil(attrs(path))
     else
      helpers.assert_eq(owner.settle_pending(), false)
      local attrs = assert(attrs(path))
      helpers.assert_eq(attrs.mode, scenario == "symlink" and "link" or "file")
      local stream = assert(io.open(path, "rb")); helpers.assert_eq(stream:read("*a"), "request body"); assert(stream:close())
     end
    end, debug.traceback)
    os.remove(path); os.remove(original); os.remove(target)
    if not ok then error(err, 0) end
   end, { fs = { attributes = followed, symlinkAttributes = attrs,
    mkdir = function(path) return uv.fs_mkdir(path, 448) end, rmdir = uv.fs_rmdir } })
  end)
 end
end)
