--- tests/support/key_combination_declaration_fixture.lua

--- Explicit predecessor declaration premise for the unchanged ordered/runtime
--- controls. Every other feature delegates to the real generated Features owner;
--- the new public cohorts use that owner unchanged instead.
local M = {}
function M.install_unavailable()
	local original=require("infra.manifest_reader")
	local unavailable={}
	local function absent(path)
		return path=="mod_combos.simultaneous_threshold_ms" or path=="mod_combos.symmetric"
	end
	for name,value in pairs(original) do unavailable[name]=value end
	unavailable.find_entry_by_path=function(path)
		if absent(path) then return nil end
		return original.find_entry_by_path(path)
	end
	unavailable.default_for=function(path)
		assert(not absent(path),"Linux chord declaration unavailable in this predecessor fixture")
		return original.default_for(path)
	end
	package.loaded["infra.manifest_reader"]=unavailable
	return original
end
return M
