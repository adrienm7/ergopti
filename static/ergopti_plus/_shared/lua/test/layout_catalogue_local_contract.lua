--- _shared/lua/test/layout_catalogue_local_contract.lua

--- Replays local-source catalogue refreshes without a published remote index.
return function(helpers, Catalogue, Json, settings, bundled)
	local request_settings = {
		owner = "test", repo = "registry", branch = "main", folder = "layouts",
		index_file = "index.json", timeout_ms = 30000, max_file_bytes = settings.max_file_bytes,
		url_template = "https://example.invalid/{owner}/{repo}/{branch}/{folder}/{path}",
	}
	helpers.describe("local layout catalogue refresh", function()
		for _, valid in ipairs({ true, false }) do
			helpers.it(valid and "uses the local index without network or cache (layout-catalogue-local)"
				or "refuses a missing local index without network (layout-catalogue-local)", function()
				local reads, writes, requests, callbacks = 0, 0, 0, 0
				local outcome
				Catalogue.refresh(request_settings, {
					local_source = true,
					bundled_index = valid and bundled or nil,
					decode_json = Json.decode,
					read_cache = function()
						reads = reads + 1
						return { text = '{"layouts":[]}', etag = '"old"' }
					end,
					write_cache = function() writes = writes + 1; return true end,
					transport = { get = function(_, _, _, callback)
						requests = requests + 1
						callback(404, "Not Found", nil, {})
					end },
				}, function(result) callbacks = callbacks + 1; outcome = result end)
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(requests, 0, "unpublished checkout data must not trigger a remote request")
				helpers.assert_eq(reads, 0, "a remote cache cannot replace the checkout catalogue")
				helpers.assert_eq(writes, 0)
				if valid then
					helpers.assert_eq(outcome.source, Catalogue.SOURCE_BUNDLED)
					helpers.assert_eq(outcome.index, bundled)
					helpers.assert_nil(outcome.error)
				else
					helpers.assert_eq(outcome.source, Catalogue.SOURCE_NONE)
					helpers.assert_eq(outcome.error.code, Catalogue.ERROR_INVALID_INDEX)
				end
			end)
		end
	end)
end
