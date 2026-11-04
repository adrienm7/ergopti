-- Executes the production shared backup owner, not the Windows native copy port.
local repo = '/workspace/ergopti'
package.path = repo .. '/static/ergopti_plus/_shared/lua/?.lua;' .. package.path
local json = require('json')
local handle = assert(io.open(repo .. '/static/ergopti_plus/_shared/modules/updater/defaults.json', 'rb'))
local defaults = assert(json.decode(handle:read('*a'))); handle:close()
local count = 0
require('test.config_backup_contract').register({
    describe = function(_, body) body() end,
    it = function(name, body) body(); count = count + 1; print('PASS ' .. name) end,
    assert_true = function(value, why) assert(value, why) end,
    assert_eq = function(actual, expected, why) assert(actual == expected, (why or 'different values') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected)) end,
}, { defaults = defaults })
print('Shared owner contract: ' .. count .. ' passed')

-- Characterize overlay semantics without asserting that deletion is desired.
local files, dirs = { ['/cfg/config.toml'] = 'old' }, { ['/cfg'] = true }
local function adddir(path)
    if path == '' or path == '/' or dirs[path] then return end
    adddir(path:match('^(.*)/[^/]+$') or '/')
    dirs[path] = true
end
local ports = {
    list = function(dir)
        if not dirs[dir] then return nil, 'absent' end
        local out = {}
        for path in pairs(files) do
            if path:sub(1, #dir + 1) == dir .. '/' then
                local name = path:sub(#dir + 2)
                if not name:find('/', 1, true) then out[#out + 1] = { name = name, kind = 'file' } end
            end
        end
        for path in pairs(dirs) do
            if path:sub(1, #dir + 1) == dir .. '/' then
                local name = path:sub(#dir + 2)
                if name ~= '' and not name:find('/', 1, true) then out[#out + 1] = { name = name, kind = 'dir' } end
            end
        end
        return out
    end,
    read = function(path) return files[path], files[path] == nil and 'absent' or nil end,
    make_dir = function(path) adddir(path); return true end,
    create = function(path, body) if files[path] then return nil, 'exists' end; files[path] = body; return true end,
    replace = function(path, body) files[path] = body; return true end,
}
local logger = setmetatable({}, { __index = function() return function() end end })
local Backup = require('updater.config_backup')
local owner = Backup.new({ rules = assert(Backup.rules(defaults)), roots = { { id = 'config', dir = '/cfg' } },
    io = ports, json = json, logger = logger, clock = function() return { stamp = '20261104-120000', iso = '2026-11-04T12:00:00Z' } end })
local snapshot = assert(owner.create('pre_install', {}))
files['/cfg/config.toml'] = 'new'
files['/cfg/tap_hold.toml'] = 'created after backup'
assert(owner.restore(snapshot.id))
assert(files['/cfg/config.toml'] == 'old')
assert(files['/cfg/tap_hold.toml'] == 'created after backup')
print('CHARACTERIZATION: saved file restored; later file retained. Deletion policy not inferred.')
