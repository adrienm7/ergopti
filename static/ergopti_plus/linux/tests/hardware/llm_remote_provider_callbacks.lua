--- tests/hardware/llm_remote_provider_callbacks.lua

--- ==============================================================================
--- MODULE: Native Remote Provider Callback Diagnostic Receipts
--- DESCRIPTION:
--- Public Remote.chat and VisionRequest.send settle actual native HTTP over owned
--- verified TLS. Deliberate caller exceptions pin diagnostic and ownership policy;
--- complete requests and native handle settlement do not imply hardware coverage.
--- ==============================================================================

-- Read-only native callback contract audit. Caller exceptions are deliberate;
-- all HTTP, curl, timers, pipes, TLS and event-loop settlement are real.
local uv = require('luv')
local Remote = require('modules.llm.api_remote')
local VisionRequest = require('modules.llm.vision_request')
local Vision = require('llm.vision')
local Http = require('adapters.http_client')
local origin = assert(os.getenv('LLM_CALLBACK_ORIGIN'))

-- Capture the actual callback arity and values before protected caller assertions.
-- All verdicts below are checked again outside callbacks after native settlement.
local observed_tuples = {}
local function tuple_key(owner, format, case, phase, role)
    return table.concat({owner, format, case, phase, role}, '/')
end
local function capture_tuple(owner, format, case, phase, role, callback)
    if callback == nil then return nil end
    local key = tuple_key(owner, format, case, phase, role)
    return function(...)
        local args = {n = select('#', ...), ...}
        observed_tuples[key] = observed_tuples[key] or {}
        observed_tuples[key][#observed_tuples[key] + 1] = {
            args = args, remote_active = Remote.is_active(),
        }
        return callback(...)
    end
end
local function check_observed_tuple(owner, format, case, phase, role)
    local tuples = observed_tuples[tuple_key(owner, format, case, phase, role)]
    assert(tuples and #tuples == 1, 'outside callback: exact observed callback count')
    local tuple, args = tuples[1], tuples[1].args
    assert(args.n == (role == 'chunk' and 1 or 2), 'outside callback: exact callback arity')
    assert(args[1] == 'valid reply' and (role == 'chunk' or args[2] == nil),
        'outside callback: exact completion/chunk tuple')
    if owner == 'remote' then
        assert(tuple.remote_active == (role == 'chunk'), 'outside callback: captured remote ownership')
    end
end
local function check_absent_tuple(owner, format, case, phase, role)
    assert(observed_tuples[tuple_key(owner, format, case, phase, role)] == nil,
        'outside callback: no unexpected callback')
end
local native_post, receipts = Http.post, {}
Http.post = function(url, headers, body, callback, options)
    return native_post(url, headers, body, function(result)
        assert(not receipts[url], 'one native receipt per unique URL')
        receipts[url] = result
        callback(result)
    end, options)
end
local native_spawn, exits = uv.spawn, {}
uv.spawn = function(command, options, callback)
    assert(command == 'curl')
    for _, arg in ipairs(options.args) do assert(arg ~= '-k' and arg ~= '--insecure') end
    return native_spawn(command, options, function(code, signal)
        exits[#exits + 1] = {code = code, signal = signal}
        callback(code, signal)
    end)
end
local formats = {'openai', 'anthropic', 'gemini'}
local responses = {
    openai = '{"choices":[{"message":{"content":"valid reply"}}]}',
    anthropic = '{"content":[{"type":"text","text":"valid reply"}]}',
    gemini = '{"candidates":[{"content":{"parts":[{"text":"valid reply"}]}}]}',
}
local function endpoint(owner, format, case, phase)
    local entry = {provider = format == 'openai' and 'openai_compat' or format,
        token = 'owned-fixture-token', model = 'fixture-model',
        base_url = origin .. '/' .. owner .. '/' .. format .. '/' .. case .. '/' .. phase}
    return entry, assert(Remote.endpoint(entry, 'fixture-model'))
end
local failures, scenarios, requests = 0, 0, 0
local function settled()
    uv.run()
    assert(not uv.loop_alive())
    local handles = 0
    uv.walk(function() handles = handles + 1 end)
    assert(handles == 0, 'no retained native handles')
    assert(not Remote.is_active(), 'remote owner settled')
end
local function receipt(target, format)
    local result = assert(receipts[target.url], 'actual native HTTP receipt')
    assert(result.ok == true and result.status == 200 and result.body == responses[format])
    requests = requests + 1
end
local function remote_start(format, case, phase, chunk, done)
    chunk = capture_tuple('remote', format, case, phase, 'chunk', chunk)
    done = capture_tuple('remote', format, case, phase, 'done', done)
    local entry, target = endpoint('remote', format, case, phase)
    assert(Remote.chat(entry, nil, {{role = 'user', content = 'fixture prompt'}},
        {temperature = 0.25, max_tokens = 40}, chunk, done))
    return target
end
local function vision_start(format, case, phase, done)
    done = capture_tuple('vision', format, case, phase, 'done', done)
    local _, target = endpoint('vision', format, case, phase)
    local body = Vision.build_request(format, {model = 'fixture-model', system = 'fixture system',
        text = 'fixture prompt', max_tokens = 40})
    assert(VisionRequest.send(target, body, done))
    return target
end
local cases = {'healthy', 'chunk-string', 'chunk-object', 'terminal-string',
    'terminal-object', 'terminal-throwing-object', 'reentry-object', 'reentry-throwing-object'}
for _, format in ipairs(formats) do
    for _, case in ipairs(cases) do
        scenarios = scenarios + 1
        local chunks, calls, formatter_calls, successor_calls = 0, 0, 0, 0
        local successor
        local failure = setmetatable({}, {__tostring = function()
            formatter_calls = formatter_calls + 1
            if case == 'chunk-object' or case:find('throwing', 1, true) then
                error('owned formatter failure', 0)
            end
            return 'owned error description'
        end})
        local target = remote_start(format, case, 'primary', function(text)
            chunks = chunks + 1
            assert(text == 'valid reply')
            if case == 'chunk-string' then error('owned chunk failure', 0) end
            if case == 'chunk-object' then error(failure, 0) end
        end, function(text, err)
            calls = calls + 1
            assert(text == 'valid reply' and err == nil)
            assert(not Remote.is_active(), 'terminal owner cleared before caller')
            if case:find('reentry', 1, true) then
                successor = remote_start(format, case, 'successor', nil, function(next_text, next_err)
                    successor_calls = successor_calls + 1
                    assert(next_text == 'valid reply' and next_err == nil)
                    assert(not Remote.is_active())
                end)
                assert(Remote.is_active(), 'successor owns exchange')
            end
            if case == 'terminal-string' then error('owned terminal failure', 0) end
            if case:find('object', 1, true) and case ~= 'chunk-object' then error(failure, 0) end
        end)
        settled()
        assert(chunks == 1 and calls == 1)
        check_observed_tuple('remote', format, case, 'primary', 'chunk')
        check_observed_tuple('remote', format, case, 'primary', 'done')
        if case:find('reentry', 1, true) then
            check_observed_tuple('remote', format, case, 'successor', 'done')
        else check_absent_tuple('remote', format, case, 'successor', 'done') end
        check_absent_tuple('remote', format, case, 'successor', 'chunk')
        receipt(target, format)
        if successor then assert(successor_calls == 1); receipt(successor, format)
        else assert(successor_calls == 0) end
        local retry_calls = 0
        local retry = remote_start(format, case, 'retry', nil, function(text, err)
            retry_calls = retry_calls + 1
            assert(text == 'valid reply' and err == nil and not Remote.is_active())
        end)
        settled()
        assert(retry_calls == 1)
        check_observed_tuple('remote', format, case, 'retry', 'done')
        check_absent_tuple('remote', format, case, 'retry', 'chunk')
        receipt(retry, format)
        local good = formatter_calls == 0
        if not good then failures = failures + 1 end
        print((good and 'PASS ' or 'FAIL ') .. 'remote ' .. format .. ' ' .. case
            .. ' formatter_calls=' .. formatter_calls .. ' terminal_calls=' .. calls
            .. ' successor_calls=' .. successor_calls .. ' healthy_retry=' .. retry_calls)
    end
end
for _, format in ipairs(formats) do
    for _, case in ipairs({'healthy', 'terminal-string', 'reentry-string'}) do
        scenarios = scenarios + 1
        local calls, successor_calls, successor = 0, 0, nil
        local target = vision_start(format, case, 'primary', function(text, err)
            calls = calls + 1
            assert(text == 'valid reply' and err == nil)
            if case == 'reentry-string' then
                successor = vision_start(format, case, 'successor', function(next_text, next_err)
                    successor_calls = successor_calls + 1
                    assert(next_text == 'valid reply' and next_err == nil)
                end)
            end
            if case ~= 'healthy' then error('owned vision callback failure', 0) end
        end)
        settled()
        assert(calls == 1)
        check_observed_tuple('vision', format, case, 'primary', 'done')
        if case == 'reentry-string' then
            check_observed_tuple('vision', format, case, 'successor', 'done')
        else check_absent_tuple('vision', format, case, 'successor', 'done') end
        receipt(target, format)
        if successor then assert(successor_calls == 1); receipt(successor, format)
        else assert(successor_calls == 0) end
        local retry_calls = 0
        local retry = vision_start(format, case, 'retry', function(text, err)
            retry_calls = retry_calls + 1
            assert(text == 'valid reply' and err == nil)
        end)
        settled(); assert(retry_calls == 1); receipt(retry, format)
        check_observed_tuple('vision', format, case, 'retry', 'done')
        print('PASS vision ' .. format .. ' ' .. case .. ' terminal_calls=' .. calls
            .. ' successor_calls=' .. successor_calls .. ' healthy_retry=' .. retry_calls)
    end
end
assert(scenarios == 33 and requests == 75 and #exits == 75)
for _, exit in ipairs(exits) do assert(exit.code == 0 and exit.signal == 0) end
print('Native callback audit: ' .. scenarios .. ' scenarios, ' .. requests .. ' complete requests, '
    .. failures .. ' formatter-policy failures; all owners settled and retries completed')
os.exit(failures == 0 and 0 or 1)
