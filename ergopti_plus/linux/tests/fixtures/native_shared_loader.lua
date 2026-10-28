--- tests/fixtures/native_shared_loader.lua
--- ==============================================================================
--- MODULE: Installed Linux Shared Loader Child
--- DESCRIPTION:
--- Resolves the real child installation and exercises one actual loader. Only
--- an acknowledged native stream close is replaced for the refusal scenario.
--- ==============================================================================

local source, installed, module, target, mode, receipt = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]
package.path = installed .. '/?.lua;' .. source .. '/?.lua;' .. source .. '/?/init.lua;' .. source .. '/../_shared/lua/?.lua;' .. source .. '/../_shared/lua/?/init.lua;' .. package.path
require('compat.utf8').install()
local uv, Json = require('luv'), require('json')
local Paths = require('infra.paths')
assert(Paths.shared_root() == installed .. '/_shared', 'actual resolver must admit the installed child layout')
assert(Paths.shared('modules/llm/' .. target) == installed .. '/_shared/modules/llm/' .. target)
local target_path = Paths.shared('modules/llm/' .. target)
local open, closes = io.open, 0
if mode == 'close-refusal' then
 io.open = function(path, access)
  local file, detail, errno = open(path, access)
  if not file or uv.fs_realpath(path) ~= target_path then return file, detail, errno end
  return { read = function(_, ...) return file:read(...) end,
   close = function() closes = closes + 1; assert(file:close()); return nil, 'controlled close refusal' end }
 end
end
local result = { target = target, mode = mode, admitted_child_layout = true }
if module == 'local' then
 local order, servers, published = require('modules.llm.local_server_catalogue').load({})
 result.order, result.published = order, published
 result.optional_auth_allowed = require('llm.local_server_auth').entry_token_allowed('llamacpp', '', servers.llamacpp and servers.llamacpp.base_url or '', servers)
elseif module == 'environment' then
 local rows, reason = require('modules.llm.managed_ollama_environment').load()
 result.rows, result.reason = rows or false, reason
elseif module == 'profile' then
 result.profile = require('modules.llm.model_profile').recommend('unlisted:999b')
else error('unknown loader') end
io.open = open
result.close_calls = closes
local file = assert(open(receipt, 'wb')); assert(file:write(Json.encode(result))); assert(file:close())
