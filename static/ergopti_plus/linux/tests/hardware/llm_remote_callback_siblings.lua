--- tests/hardware/llm_remote_callback_siblings.lua

--- ==============================================================================
--- MODULE: Native Remote Models And Probe Callback Diagnostic Receipts
--- DESCRIPTION:
--- Public model-list and connectivity callbacks share the protected terminal
--- owner. Actual native TLS settlement pins safe diagnostic text, callback tuples,
--- successor ownership and healthy retries; no hardware coverage is claimed.
--- ==============================================================================

local uv = require('luv')
local Remote = require('modules.llm.api_remote')
local Http = require('adapters.http_client')
local Logger = require('logger.shim')
local origin = assert(os.getenv('LLM_WRAPPER_ORIGIN'))

-- Snapshot actual public callback tuples before their protected caller assertions.
-- Model IDs are copied so later caller mutation cannot rewrite the observed list.
local observed_tuples = {}
local function tuple_key(owner, provider, case, phase)
    return table.concat({owner, provider, case, phase}, '/')
end
local function capture_tuple(owner, provider, case, phase, callback)
    local key = tuple_key(owner, provider, case, phase)
    return function(...)
        local args = {n = select('#', ...), ...}
        if type(args[1]) == 'table' then
            local ids = {}
            for id, value in pairs(args[1]) do ids[id] = value end
            args[1] = ids
        end
        observed_tuples[key] = observed_tuples[key] or {}
        observed_tuples[key][#observed_tuples[key] + 1] = {
            args = args, remote_active = Remote.is_active(),
        }
        return callback(...)
    end
end
local function check_observed_tuple(owner, provider, case, phase)
    local tuples = observed_tuples[tuple_key(owner, provider, case, phase)]
    assert(tuples and #tuples == 1, 'outside callback: exact observed callback count')
    local tuple, args = tuples[1], tuples[1].args
    assert(tuple.remote_active == false, 'outside callback: captured cleared remote ownership')
    if owner == 'models' then
        assert(args.n == 2 and type(args[1]) == 'table' and #args[1] == 1
            and args[1][1] == 'fixture-model' and args[2] == nil,
            'outside callback: exact models tuple')
        local keys = 0
        for id in pairs(args[1]) do assert(id == 1, 'outside callback: exact model list keys'); keys = keys + 1 end
        assert(keys == 1, 'outside callback: exact model list length')
    else
        assert(args.n == 3 and args[1] == true and args[2] == 'valid reply'
            and type(args[3]) == 'number' and args[3] >= 0 and args[3] < math.huge,
            'outside callback: exact probe tuple')
    end
end
local function check_absent_tuple(owner, provider, case, phase)
    assert(observed_tuples[tuple_key(owner, provider, case, phase)] == nil,
        'outside callback: no unexpected successor callback')
end
local native_error, diagnostics = Logger.error, {}
Logger.error = function(owner, message, detail, ...)
    diagnostics[#diagnostics + 1] = {owner=owner, message=message, detail=detail}
    return native_error(owner, message, detail, ...)
end
local receipts = {}
local function observe(url, callback)
    return function(result)
        assert(not receipts[url]); receipts[url] = result; callback(result)
    end
end
local native_get, native_post = Http.get, Http.post
Http.get = function(url, headers, options, callback)
    assert(options.follow_redirects == false)
    return native_get(url, headers, options, observe(url, callback))
end
Http.post = function(url, headers, body, callback, options)
    return native_post(url, headers, body, observe(url, callback), options)
end
local native_spawn, exits = uv.spawn, {}
uv.spawn = function(command, options, callback)
    assert(command == 'curl')
    for _, arg in ipairs(options.args) do assert(arg ~= '-k' and arg ~= '--insecure') end
    return native_spawn(command, options, function(code, signal)
        exits[#exits+1]={code=code,signal=signal}; callback(code,signal)
    end)
end
local cases={'healthy','string','object','throwing-object','reentry-object','reentry-throwing-object'}
local responses={openai='{"choices":[{"message":{"content":"valid reply"}}]}',
    anthropic='{"content":[{"type":"text","text":"valid reply"}]}',
    gemini='{"candidates":[{"content":{"parts":[{"text":"valid reply"}]}}]}'}
local function settled()
    uv.run(); assert(not Remote.is_active() and not uv.loop_alive())
    local handles=0; uv.walk(function() handles=handles+1 end); assert(handles==0)
end
local requests, scenarios, failures=0,0,0
local function start(owner, provider, format, token, case, phase, callback)
    callback = capture_tuple(owner, provider, case, phase, callback)
    local entry={id='owned-callback-wrapper', provider=provider, token=token, model='fixture-model',
        base_url=origin..'/'..owner..'/'..provider..'/'..case..'/'..phase}
    local target=assert(Remote.endpoint(entry,'fixture-model'))
    if owner=='models' then
        target.url=target.url:gsub('/chat/completions$','/models')
        assert(Remote.models(entry,callback))
    else assert(Remote.test(entry,callback)) end
    return target
end
local function check_callback(owner, a, b, c)
    assert(not Remote.is_active(), 'owner cleared before user callback')
    if owner=='models' then assert(type(a)=='table' and #a==1 and a[1]=='fixture-model' and b==nil and c==nil)
    else assert(a==true and b=='valid reply' and type(c)=='number' and c>=0) end
end
local function receipt(owner, format, target)
    local result=assert(receipts[target.url])
    local body=owner=='models' and '{"data":[{"id":"fixture-model"}]}' or responses[format]
    assert(result.ok==true and result.status==200 and result.body==body)
    requests=requests+1
end
for _, spec in ipairs({{'models','lmstudio','openai',''}, {'models','openai_compat','openai','owned-fixture-token'},
    {'test','openai_compat','openai','owned-fixture-token'}, {'test','anthropic','anthropic','owned-fixture-token'},
    {'test','gemini','gemini','owned-fixture-token'}}) do
    local owner,provider,format,token=spec[1],spec[2],spec[3],spec[4]
    for _, case in ipairs(cases) do
        scenarios=scenarios+1
        local count,formatter_calls,successor_count,successor=0,0,0,nil
        local old_logs=#diagnostics
        local failure=setmetatable({}, {__tostring=function()
            formatter_calls=formatter_calls+1
            if case:find('throwing',1,true) then error('owned formatter failure',0) end
            return 'owned formatter result'
        end})
        local target=start(owner,provider,format,token,case,'primary',function(a,b,c)
            count=count+1; check_callback(owner,a,b,c)
            if case:find('reentry',1,true) then
                successor=start(owner,provider,format,token,case,'successor',function(x,y,z)
                    successor_count=successor_count+1; check_callback(owner,x,y,z)
                end)
                assert(Remote.is_active())
            end
            if case=='string' then error('owned ordinary wrapper failure',0) end
            if case:find('object',1,true) then error(failure,0) end
        end)
        settled(); assert(count==1); receipt(owner,format,target)
        check_observed_tuple(owner, provider, case, 'primary')
        if case:find('reentry', 1, true) then
            check_observed_tuple(owner, provider, case, 'successor')
        else check_absent_tuple(owner, provider, case, 'successor') end
        local good = formatter_calls == 0
        if successor then assert(successor_count==1); receipt(owner,format,successor)
        else assert(successor_count==0) end
        if case=='healthy' then good = good and #diagnostics==old_logs
        else
            local log=diagnostics[#diagnostics]
            good = good and #diagnostics==old_logs+1 and log ~= nil
                and log.owner=='modules.llm.api_remote' and log.message=='Terminal callback raised — %s'
                and log.detail==(case=='string' and 'owned ordinary wrapper failure' or 'error object (table)')
        end
        local retry_count=0
        local retry=start(owner,provider,format,token,case,'retry',function(a,b,c)
            retry_count=retry_count+1; check_callback(owner,a,b,c)
        end)
        settled(); assert(retry_count==1); receipt(owner,format,retry)
        check_observed_tuple(owner, provider, case, 'retry')
        if not good then failures = failures + 1 end
        print((good and 'PASS ' or 'FAIL ')..owner..' '..provider..' '..case..' formatter_calls='..formatter_calls..' callbacks='..count
            ..' successors='..successor_count..' retry='..retry_count)
    end
end
assert(scenarios==30 and requests==70 and #exits==70)
for _, exit in ipairs(exits) do assert(exit.code==0 and exit.signal==0) end
print('Native protected callback siblings: 30 scenarios, 70 complete requests, '..failures..' policy failures; all owners/retries settled')
os.exit(failures == 0 and 0 or 1)
