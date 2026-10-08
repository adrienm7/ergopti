--- tests/unit/infra/test_ollama_pinned_artifact.lua

--- ==============================================================================
--- MODULE: Pinned Ollama Native Artifact Admission
--- DESCRIPTION:
--- Receives the actual registry through controlled ports. Literal pin, completion,
--- hash, original bound and cleanup assertions are independent of producer data.
--- These models do not qualify the native C backend, zstd process or kernel.
--- ==============================================================================

local helpers = require("tests.helpers")
local Output = require("infra.archive_output")
local make_fixture = require("tests.support.ollama_pinned_artifact_fixture")
local DIGEST = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

local function controlled(options, body)
	local names = { "ffi", "luv", "infra.paths", "infra.monotonic", "infra.managed_http_deadline", "infra.fd_sha256", "adapters.owned_process" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, reason = xpcall(function() body(make_fixture(options)) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(reason, 0) end
end

local function verified(f)
	f:reserve(); f:complete(); assert(f:adopt())
	f:hash_ack(DIGEST); f:timer_ack()
	assert(f.commits == 1 and f.operation:is_settled() and f.factory.transfer_settled(f.brand))
end

local function retire(f)
	f.factory.cancel_transfer(f.brand); f:timer_ack()
	assert(f.factory.transfer_settled(f.brand))
end

helpers.describe("Pinned Ollama native artifact", function()
	helpers.it("fixed pinned constructor refuses updater-shaped admission", function()
		controlled({}, function(f)
			assert(f.factory.reserve_transfer({ tag = "0.24.0", download_url = f.asset.url, checksum_url = f.asset.url }, {}, function() return true end, function() return true end, 100.5) == nil)
			assert(f.creates == 0 and f.opens == 0)
		end)
	end)
	helpers.it("digest commitment precedes any output and rejects a second commitment", function()
		controlled({}, function(f)
			f:reserve()
			assert(f.factory.bind_checksum(f.brand, string.rep("0", 64)) == false)
			f:complete(); f:adopt(); f:hash_ack(DIGEST); f:timer_ack()
			assert(f.stages == 1 and f.commits == 1)
			retire(f)
		end)
	end)
	helpers.it("mutable caller asset cannot substitute admitted size hash or name", function()
		controlled({}, function(f)
			f.asset.bytes, f.asset.sha256, f.asset.name, f.asset.url = 999, string.rep("0", 64), "foreign.tar.zst", "https://foreign/archive"
			verified(f); retire(f)
		end)
	end)
	helpers.it("wrong complete same-FD digest refuses native stage", function()
		controlled({}, function(f)
			f:reserve(); f:complete(); f:adopt(); f:hash_ack(string.rep("0", 64)); f:timer_ack()
			assert(f.stages == 0 and f.commits == 0 and f.operation:is_settled())
			assert(f.callbacks[1].path == nil)
		end)
	end)
	helpers.it("matching digest over wrong pinned byte count cannot stage", function()
		controlled({}, function(f)
			f.asset.bytes = 4
			f.factory = assert(Output.native_ollama_artifact(f.asset))
			f:reserve(); f:complete(); f:adopt(); f:hash_ack(DIGEST); f:timer_ack()
			assert(f.hashes == 1 and f.stages == 0 and f.commits == 0 and f.operation:is_settled())
			assert(f.callbacks[1].path == nil)
		end)
	end)
	helpers.it("refused master subscription acquires no native directory", function()
		controlled({ subscribe_refused = true }, function(f)
			f:reserve()
			assert(f.target == nil and f.creates == 0 and f.opens == 0)
			assert(f.factory.transfer_settled(f.brand))
		end)
	end)
	helpers.it("captured master methods cannot be replaced by caller table mutation", function()
		controlled({}, function(f)
			f:reserve()
			f.budget.current = function() return true end
			f.budget.deadline_ms = function() return 999999 end
			f.master_current = false; f.master_cancel()
			assert(f.closes == 1 and not f.factory.transfer_settled(f.brand))
			f:timer_ack(); assert(f.factory.transfer_settled(f.brand) and f.commits == 0)
		end)
	end)
	helpers.it("changed original bound cannot borrow a reconstructed deadline", function()
		controlled({}, function(f)
			f:reserve(); f:complete(); f.master_deadline = 999999
			f:adopt(); f:timer_ack()
			assert(f.hashes == 0 and f.stages == 0 and f.commits == 0)
			assert(f.operation:is_settled() and f.callbacks[1].path == nil)
		end)
	end)
	helpers.it("pinned extraction admits original master without updater defaults", function()
		controlled({}, function(f)
			verified(f)
			assert(f.factory.begin_install(f.brand, f.transaction, {}, function() return true end, function() return true end) == nil)
			local token = assert(f.factory.begin_ollama_install(f.brand, f.transaction, function() return true end, function() return true end))
			assert(f.factory.install_current(token))
			assert(f.factory.install_feed(token, "names", nil, function() end) == nil and (f.readers or 0) == 0)
			local finished = false
			local operation = assert(f.factory.finish_install(token, false, function(result) finished = result.ok end))
			assert(finished and operation:is_settled() and f.factory.artifact_settled(f.brand))
			assert(f.master_current ~= false, "consumer cleanup does not retire parent budget")
		end)
	end)
	helpers.it("master withdrawal without cancellation callback refuses retained output write", function()
		controlled({}, function(f)
			f:reserve(); local sink = f:begin_delivery()
			f.master_current = false
			assert(sink:consume("abc") == false and #f.writes == 0 and f.aborted)
			assert(f.closes == 0, "refusal must retain the actual unclosed producer")
			f.factory.cancel_transfer(f.brand)
			f.input.closed = true; f.reader_ack()
			f.producer.settled = true; f.producer_ack()
			f:timer_ack()
			assert(f.closes == 1 and f.commits == 0 and f.factory.transfer_settled(f.brand))
		end)
	end)
	helpers.it("foreign install transaction cannot acquire a retained reader", function()
		controlled({}, function(f)
			verified(f)
			assert(f.factory.begin_ollama_install(f.brand, {}, function() return true end, function() return true end) == nil)
			assert((f.readers or 0) == 0); retire(f)
		end)
	end)
	helpers.it("original master withdrawal refuses later reader reservation", function()
		controlled({}, function(f)
			verified(f); f.master_current = false; f.master_cancel()
			assert(f.factory.begin_ollama_install(f.brand, f.transaction, function() return true end, function() return true end) == nil)
			assert((f.readers or 0) == 0 and f.commits == 1 and f.factory.artifact_settled(f.brand))
		end)
	end)
	for _, change in ipairs({
		{ name = "key", value = "linux-other" },
		{ name = "name", value = "ollama-linux-amd64.tar.gz" },
		{ name = "url", value = "https://foreign/archive" },
		{ name = "bytes", value = 0 },
		{ name = "sha256", value = "not-a-digest" },
	}) do
		helpers.it("invalid pinned " .. change.name .. " refuses before native lookup", function()
			controlled({}, function(f)
				f.asset[change.name] = change.value
				local factory, refusal = Output.native_ollama_artifact(f.asset)
				assert(factory == nil and refusal.cause == "unknown" and f.creates == 0 and f.opens == 0)
			end)
		end)
	end
end)
