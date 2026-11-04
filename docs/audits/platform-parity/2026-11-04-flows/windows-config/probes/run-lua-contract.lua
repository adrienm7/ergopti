-- Comparator only: real shared Lua migration engine, not Windows AHK execution.
local root = '/workspace/ergopti/static/ergopti_plus'
package.path = root .. '/_shared/lua/?.lua;' .. root .. '/_shared/lua/?/init.lua;' .. root .. '/linux/?.lua;' .. root .. '/linux/?/init.lua;' .. package.path
local passed, failed = 0, 0
local function same(a,b,seen)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    seen = seen or {}; if seen[a] == b then return true end; seen[a] = b
    for k,v in pairs(a) do if not same(v,b[k],seen) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local helpers = {
    describe = function(_, body) body() end,
    it = function(name, body)
        local ok, err = pcall(body)
        if ok then passed=passed+1 else failed=failed+1; print('FAIL '..name..': '..tostring(err)) end
    end,
    assert_true = function(v, why) assert(v, why) end,
    assert_nil = function(v, why) assert(v == nil, why or 'expected nil') end,
    assert_eq = function(a,b,why) assert(same(a,b),why or ('values differ: '..tostring(a)..' ~= '..tostring(b))) end,
}
require('test.config_migrate_contract').register(helpers, {driver='ahk'})
print(string.format('Shared Lua migration comparator driver=ahk passed=%d failed=%d; NOT native Windows replay',passed,failed))
os.exit(failed==0 and 0 or 1)
