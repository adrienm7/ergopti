--- tests/support/logger_fixture.lua

--- Fresh genuine logger cores are private to one instrumentation test case.
--- The core exposes no sink getter, so resetting its mutable state in place
--- cannot restore another consumer's sink. Restore the original module objects
--- instead, including the instrumentation module that captured the private core.
local M = {}

function M.with(module_names, body)
	local names = { "logger", "logger.shim" }
	for _, name in ipairs(module_names) do names[#names + 1] = name end
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, failure = xpcall(body, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
end

--- Keep the ordinary assertion and registration API without mutating its table.
function M.helpers(module_names)
	local helpers = require("tests.helpers")
	return setmetatable({ it = function(name, body)
		helpers.it(name, function() M.with(module_names, body) end)
	end }, { __index = helpers })
end

return M
