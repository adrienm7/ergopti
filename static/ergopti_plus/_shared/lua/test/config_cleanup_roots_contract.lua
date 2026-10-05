--- _shared/lua/test/config_cleanup_roots_contract.lua
--- Handwritten complete images exercise the driver's real readers and private-file CAS.
local M = {}
local Engine = require("config_unused_keys")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local sequence = 0
local function write(path, source)
	local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
end
local function read(path)
	local file = assert(io.open(path, "rb")); local source = assert(file:read("*a")); assert(file:close()); return source
end
local kept = '"ahk.literal" = {keep="literal", empty=[]}\nAHK={keep="case",flag=false}\n\n'
local tail = '[_meta]\nschema_version=11\n\n[_future]\nflag=false\nzero=0\nempty=[]\nvalues=[1,2]\nstamp=2026-10-05T10:20:30Z\n"literal.dot"="keep"\n'
local retired = {
	dotted = '# obsolete\nahk.layout.flag=true\nahk.layout.label="old"\n\n',
	inline = '# obsolete\nahk={layout={flag=true},items=[{id="a"},{id="b"}]}\n\n',
	array = '# obsolete\n[[ahk.items]]\nflag=true\nid="a"\n[[ahk.items]]\nflag=0\nid="b"\n\n',
}
local expected = kept .. '# obsolete\n\n' .. tail
local function only_root(scan, root)
	local rows = {}; for _, row in ipairs(scan.keys) do if row.key == "" and row.path[1] == root then rows[#rows + 1] = row end end; return rows
end
function M.register(h, ports)
	local function sandbox(kind, callback)
		sequence = sequence + 1
		local path = (os.getenv("TMPDIR") or "/tmp") .. "/ergopti_root_cleanup_" .. ports.driver .. "_" .. os.time() .. "_" .. sequence .. ".toml"
		local source = kept .. retired[kind] .. tail
		write(path, source)
		local backups = {}
		local function remove(rows, extra)
			local options = { path=path,keys=rows,file_adapter=ports.file_adapter,stamp="20991005-" .. string.format("%06d",#backups+1) }
			for key,value in pairs(extra or {}) do options[key]=value end
			local result=Engine.remove(options); backups[#backups+1]=result.backup; return result
		end
		local ok, detail = pcall(callback, path, source, remove)
		os.remove(path); os.remove(path..".tmp")
		for _, backup in ipairs(backups) do os.remove(backup); os.remove(backup..".tmp") end
		if not ok then error(detail,0) end
	end
	for _, kind in ipairs({"dotted","inline","array"}) do
		h.it("whole unread root: actual "..ports.driver.." "..kind.." collector and exact native-file publication",function()
			sandbox(kind,function(path,source,remove)
				local rows=only_root(ports.find(path),"ahk"); h.assert_eq(#rows,1); if #rows~=1 then return end
				h.assert_eq(read(path),source)
				local result=remove(rows,{expected_source=source}); h.assert_eq(result.status,"removed"); h.assert_eq(result.removed,1)
				h.assert_eq(read(result.backup),source); h.assert_eq(read(path),expected)
				local model,shapes=Codec.decode_with_shapes(read(path)); h.assert_nil(model.ahk)
				h.assert_eq(model['ahk.literal'],{keep='literal',empty={}}); h.assert_true(shapes.arrays[model['ahk.literal'].empty])
				h.assert_eq(model.AHK,{keep='case',flag=false}); h.assert_eq(model._future.flag,false); h.assert_eq(model._future.zero,0)
				h.assert_true(shapes.arrays[model._future.empty]); h.assert_eq(model._future['literal.dot'],'keep')
				h.assert_eq(#only_root(ports.find(path),'ahk'),0)
			end)
		end)
	end
	for _, mode in ipairs({'clone','forged_key','field','path','extra','foreign','unbound','duplicate'}) do
		h.it("whole unread root: "..mode.." capability refuses before backup",function()
			sandbox('inline',function(path,source,remove)
				local rows
				if mode=='unbound' then rows={{section='ahk',key='',kind='section',value='{}',path={'ahk'}}}
				else rows=only_root(ports.find(path),'ahk'); h.assert_eq(#rows,1); if #rows~=1 then return end end
				if mode=='clone' or mode=='forged_key' then local copy={};for k,v in pairs(rows[1]) do copy[k]=v end;rows={copy};if mode=='forged_key' then rows[1].key='layout' end
				elseif mode=='field' then rows[1].value='{}'
				elseif mode=='path' then rows[1].path[1]='AHK'
				elseif mode=='extra' then rows[1].authority=true
				elseif mode=='duplicate' then rows[2]=rows[1]
				elseif mode=='unbound' then -- The forged record has no producer dependency.
				else
					local foreign=path..'.foreign';write(foreign,source);local ok,found=pcall(ports.find,foreign);os.remove(foreign);assert(ok,found);rows=only_root(found,'ahk')
				end
				local result=remove(rows);h.assert_eq(result.status,'write_failed');h.assert_eq(result.removed,0);h.assert_eq(read(path),source)
				h.assert_nil(io.open(result.backup,'rb'),'refusal precedes backup')
			end)
		end)
	end
	h.it('whole unread root: stale neighbor refuses and fresh scan preserves later source',function()
		sandbox('dotted',function(path,source,remove)
			local rows=only_root(ports.find(path),'ahk');h.assert_eq(#rows,1);if #rows~=1 then return end
			local later=source:gsub('"literal.dot"="keep"','"literal.dot"="later"');write(path,later)
			local result=remove(rows);h.assert_eq(result.status,'write_failed');h.assert_eq(read(path),later);h.assert_nil(io.open(result.backup,'rb'))
			result=remove(only_root(ports.find(path),'ahk'));h.assert_eq(result.status,'removed');h.assert_eq(read(result.backup),later)
			h.assert_eq(read(path),expected:gsub('"literal.dot"="keep"','"literal.dot"="later"'))
		end)
	end)
	h.it('whole unread root: consumed authority cannot revive after exact external restoration',function()
		sandbox('inline',function(path,source,remove)
			local rows=only_root(ports.find(path),'ahk');h.assert_eq(#rows,1);if #rows~=1 then return end
			h.assert_eq(remove(rows).status,'removed');write(path,source)
			local result=remove(rows);h.assert_eq(result.status,'write_failed');h.assert_eq(read(path),source);h.assert_nil(io.open(result.backup,'rb'))
			h.assert_eq(remove(only_root(ports.find(path),'ahk')).status,'removed')
		end)
	end)
	for _, mode in ipairs({'field','collection','source','live_read'}) do
		h.it('whole unread root: backup-time '..mode..' changes refuse publication',function()
			sandbox('array',function(path,source,remove)
				local live=false
				local collector=function(decoded,mark,shapes) ports.collect(decoded,mark,shapes);if live then mark('ahk','items') end end
				local scan=Engine.find({path=path,collect=collector,file_adapter=ports.file_adapter,whole_unread_roots=true})
				local rows=only_root(scan,'ahk');h.assert_eq(#rows,1);if #rows~=1 then return end
				local later=source:gsub('"literal.dot"="keep"','"literal.dot"="later"')
				local result=remove(rows,{create_backup=function(target,content)
					local ok,detail=Writer.publish_if_unchanged(target,content,ports.file_adapter,{status='absent'})
					if mode=='field' then rows[1].kind='leaf' elseif mode=='collection' then rows[1]=nil
					elseif mode=='source' then write(path,later) else live=true end
					return ok,detail
				end})
				h.assert_eq(result.status,'write_failed');h.assert_eq(result.removed,0);h.assert_eq(read(result.backup),source)
				h.assert_eq(read(path),mode=='source' and later or source)
			end)
		end)
	end
	h.it('whole unread root: protected and partially consumed roots cannot obtain whole-root preview',function()
		local source='hotstrings={trigger_char="@",future=1}\nupdater={future=true}\n_meta={schema_version=11}\n'
		local path=(os.getenv('TMPDIR') or '/tmp')..'/ergopti_root_protected_'..ports.driver..'.toml';write(path,source)
		local ok,detail=pcall(function()
			local scan=ports.find(path);h.assert_eq(#only_root(scan,'hotstrings'),0);h.assert_eq(#only_root(scan,'updater'),0);h.assert_eq(#only_root(scan,'_meta'),0)
			h.assert_eq(read(path),source)
		end);os.remove(path);if not ok then error(detail,0) end
	end)
	h.it('whole unread root: explicit mode never changes historical source-only addressing',function()
		local source='root=1\n[t]\n"quoted key"=1\n[[list]]\nk=1\n[list.sub]\nj=2\n'
		local scan=Engine.find_in_source(source,function() end)
		h.assert_eq(scan.keys,{})
	end)
	h.it('whole unread root: proven quoted equals identity permits exact unrelated root cleanup',function()
		local source='"other=x"=1\nahk={flag=true}\n'
		local path=(os.getenv('TMPDIR') or '/tmp')..'/ergopti_root_ambiguous_'..ports.driver..'.toml';write(path,source)
		local backup
		local ok,detail=pcall(function()
			local rows=only_root(ports.find(path),'ahk')
			h.assert_eq(#rows,1);h.assert_eq(read(path),source)
			if #rows~=1 then return end
			h.assert_eq(rows[1].path,{'ahk'})
			local result=Engine.remove({path=path,keys=rows,file_adapter=ports.file_adapter,stamp='20991005-666666'})
			backup=result.backup;h.assert_eq(result.status,'removed');h.assert_eq(result.removed,1)
			h.assert_eq(read(backup),source);h.assert_eq(read(path),'"other=x"=1\n')
		end);os.remove(path);if backup then os.remove(backup) end;if not ok then error(detail,0) end
	end)
	h.it('whole unread root: a current marked descendant refuses a forged whole root before backup',function()
		local source='hotstrings={trigger_char="@",future=1}\n'
		local path=(os.getenv('TMPDIR') or '/tmp')..'/ergopti_root_partial_'..ports.driver..'.toml';write(path,source)
		local backup
		local ok,detail=pcall(function()
			local row={section='hotstrings',key='',kind='section',value='{}',path={'hotstrings'}}
			local result=Engine.remove({path=path,keys={row},file_adapter=ports.file_adapter,stamp='20991005-888888'})
			backup=result.backup;h.assert_eq(result.status,'write_failed');h.assert_eq(result.removed,0)
			h.assert_nil(io.open(backup,'rb'));h.assert_eq(read(path),source)
		end);os.remove(path);if backup then os.remove(backup) end;if not ok then error(detail,0) end
	end)
	h.it('whole unread root: ordinary leaf removal and the selected root compose without deleting a live sibling',function()
		sandbox('dotted',function(path,source,remove)
			local live='[hotstrings]\ntrigger_char="@"\nfuture=false\n'
			write(path,source..live)
			local scan=ports.find(path);local rows=only_root(scan,'ahk')
			h.assert_eq(#rows,1);if #rows~=1 then return end
			for _,row in ipairs(scan.keys) do if row.section=='hotstrings' and row.key=='future' then rows[#rows+1]=row end end
			h.assert_eq(#rows,2)
			local result=remove(rows);h.assert_eq(result.status,'removed');h.assert_eq(result.removed,2)
			h.assert_eq(read(result.backup),source..live)
			h.assert_eq(read(path),expected..'[hotstrings]\ntrigger_char="@"\n')
		end)
	end)

	h.it('whole unread root: removing the first physical assignment preserves BOM CRLF and final-line spelling',function()
		local bom=string.char(0xEF,0xBB,0xBF)
		local source=bom..'ahk=false\r\n[_future]\r\nflag=false\r\nzero=0'
		local wanted=bom..'[_future]\r\nflag=false\r\nzero=0'
		local path=(os.getenv('TMPDIR') or '/tmp')..'/ergopti_root_bom_'..ports.driver..'.toml';write(path,source)
		local backup
		local ok,detail=pcall(function()
			local rows=only_root(ports.find(path),'ahk');h.assert_eq(#rows,1);if #rows~=1 then return end
			local result=Engine.remove({path=path,keys=rows,file_adapter=ports.file_adapter,stamp='20991005-777777'})
			backup=result.backup;h.assert_eq(result.status,'removed');h.assert_eq(result.removed,1)
			h.assert_eq(read(backup),source);h.assert_eq(read(path),wanted)
		end);os.remove(path);if backup then os.remove(backup) end;if not ok then error(detail,0) end
	end)

	for _, mode in ipairs({"row_identity", "selection_metatable"}) do
		h.it("whole unread root: backup-time " .. mode .. " cannot substitute captured identity", function()
			sandbox("inline", function(path, source, remove)
				local rows = only_root(ports.find(path), "ahk")
				h.assert_eq(#rows, 1); if #rows ~= 1 then return end
				local equality_calls, length_calls = 0, 0
				local original_row = rows[1]
				local result = remove(rows, { create_backup = function(target, content)
					local written, detail = Writer.publish_if_unchanged(target, content, ports.file_adapter, { status = "absent" })
					if mode == "row_identity" then
						rows[1] = setmetatable({}, { __eq = function() equality_calls = equality_calls + 1; return true end })
					else
						setmetatable(rows, { __len = function() length_calls = length_calls + 1; return 1 end })
					end
					return written, detail
				end })
				h.assert_eq(result.status, "write_failed"); h.assert_eq(result.removed, 0)
				h.assert_eq(read(path), source); h.assert_eq(read(result.backup), source)
				h.assert_eq(equality_calls, 0); h.assert_eq(length_calls, 0)
				-- Identity assertions stay outside native protected callbacks.
				if mode == "row_identity" then h.assert_eq(rawequal(rows[1], original_row), false)
				else h.assert_true(rawequal(rows[1], original_row)) end
			end)
		end)
	end


	-- New independent complete images exercise physical key/value boundaries;
	-- source tokens and survivor bytes are authored here, never serialized.
	local equal_vectors = {
		{ id = "basic neighbor", source = '"other=x"=1\nahk={flag=true}\n', expected = '"other=x"=1\n' },
		{ id = "literal neighbor", source = "'other=x'=false\nahk={flag=true}\n", expected = "'other=x'=false\n" },
		{ id = "escaped quote", source = '"other\\\"=x"={empty=[],kind={}}\nahk={flag=true}\n', expected = '"other\\\"=x"={empty=[],kind={}}\n' },
		{ id = "escaped equals", source = '"other\\u003dx"=[0.1,9223372036854775807]\nahk={flag=true}\n', expected = '"other\\u003dx"=[0.1,9223372036854775807]\n' },
		{ id = "dotted quoted parent", source = '"other=x".value=[\n  "[ahk.not-a-header]",\n]\nahk={flag=true}\n', expected = '"other=x".value=[\n  "[ahk.not-a-header]",\n]\n' },
		{ id = "multiline value", source = '"other=x"="""line\n[ahk.not-a-header]\nvalue=inside\n"""\nahk={flag=true}\n', expected = '"other=x"="""line\n[ahk.not-a-header]\nvalue=inside\n"""\n' },
		{ id = "quoted retired child", source = 'ahk."legacy=x"=[\n {flag=false},\n]\n"other=x"={empty=[],kind={}}\n', expected = '"other=x"={empty=[],kind={}}\n' },
		{ id = "header child and case sibling", source = '"other=x"={keep=true}\nahk.flag=true\n[ahk.child]\n"legacy=x"={flag=true}\n[AHK]\n"legacy=x"=false\n', expected = '"other=x"={keep=true}\n[AHK]\n"legacy=x"=false\n' },
	}
	for _, vector in ipairs(equal_vectors) do
		h.it("physical equals boundary: native cleanup and backup " .. vector.id, function()
			sequence = sequence + 1
			local path = (os.getenv('TMPDIR') or '/tmp') .. '/ergopti_root_equals_' .. ports.driver .. '_' .. sequence .. '.toml'
			write(path, vector.source)
			local backup
			local okay, detail = pcall(function()
				local rows = only_root(ports.find(path), 'ahk')
				h.assert_eq(#rows, 1); h.assert_eq(read(path), vector.source)
				if #rows ~= 1 then return end
				local result = Engine.remove({ path = path, keys = rows, file_adapter = ports.file_adapter, stamp = '20991005-555555' })
				backup = result.backup
				h.assert_eq(result.status, 'removed'); h.assert_eq(result.removed, 1)
				h.assert_eq(read(backup), vector.source); h.assert_eq(read(path), vector.expected)
				local after, shapes = Codec.decode_with_shapes(read(path))
				h.assert_nil(after.ahk)
				if vector.id == 'escaped quote' then
					h.assert_eq(shapes.arrays[after['other"=x'].empty], true)
					h.assert_eq(shapes.arrays[after['other"=x'].kind], nil)
				end
			end)
			os.remove(path); if backup then os.remove(backup) end
			if not okay then error(detail, 0) end
		end)
	end
	h.it('physical equals boundary: changed source refuses before backup and a fresh preview preserves the successor', function()
		local source = '"other=x"=0.1\nahk={flag=true}\n'
		local path = (os.getenv('TMPDIR') or '/tmp') .. '/ergopti_root_equals_changed_' .. ports.driver .. '.toml'
		local successor = '"other=x"=0.10000000000000000001\nahk={flag=true}\n'
		write(path, source)
		local backup
		local okay, detail = pcall(function()
			local rows = only_root(ports.find(path), 'ahk'); h.assert_eq(#rows, 1)
			if #rows ~= 1 then return end
			write(path, successor)
			local result = Engine.remove({ path = path, keys = rows, file_adapter = ports.file_adapter, stamp = '20991005-444444' })
			backup = result.backup; h.assert_eq(result.status, 'write_failed'); h.assert_eq(result.removed, 0)
			h.assert_nil(io.open(backup, 'rb')); h.assert_eq(read(path), successor)
			rows = only_root(ports.find(path), 'ahk'); h.assert_eq(#rows, 1)
			result = Engine.remove({ path = path, keys = rows, file_adapter = ports.file_adapter, stamp = '20991005-444444' })
			backup = result.backup; h.assert_eq(result.status, 'removed')
			h.assert_eq(read(backup), successor); h.assert_eq(read(path), '"other=x"=0.10000000000000000001\n')
		end)
		os.remove(path); if backup then os.remove(backup) end
		if not okay then error(detail, 0) end
	end)
	for _, source in ipairs({ '"other=x"=1\n\'other=x\'=2\nahk={flag=true}\n', '"open=x=1\nahk={flag=true}\n' }) do
		h.it('physical equals boundary: malformed or duplicate key still refuses actual native scan', function()
			sequence = sequence + 1
			local path = (os.getenv('TMPDIR') or '/tmp') .. '/ergopti_root_equals_invalid_' .. ports.driver .. '_' .. sequence .. '.toml'
			write(path, source)
			local okay, detail = pcall(function()
				local scan = ports.find(path)
				if source:sub(1, 6) == '"open=' then
					-- The existing decoder ignores a line with no external separator;
					-- physical root admission still refuses its unproven record.
					h.assert_eq(scan.status, 'ok')
				else h.assert_eq(scan.status, 'malformed') end
				h.assert_eq(scan.keys, {})
				h.assert_eq(read(path), source)
			end)
			os.remove(path); if not okay then error(detail, 0) end
		end)
	end
end
return M
