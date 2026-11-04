--- tests/support/content_digest.lua

--- ==============================================================================
--- MODULE: Content-Exact Native Hash Double
--- DESCRIPTION:
--- Models incremental native hash ownership with a collision-free, per-fixture
--- content registry. It proves byte identity and API ordering; real SHA-256
--- vectors and the physical SQLite replay independently cover native hashing.
--- ==============================================================================

local M = {}

--- Create one independent content oracle and native-style hash constructor.
--- @return table oracle Exposes new and for_bytes.
function M.create()
	local seen, next_id = {}, 0
	local oracle = {}
	function oracle.for_bytes(bytes)
		if not seen[bytes] then
			next_id = next_id + 1
			seen[bytes] = string.format("%064x", next_id)
		end
		return seen[bytes]
	end
	function oracle.new(algorithm)
		assert(algorithm == "SHA256", "unexpected native hash algorithm")
		local context = { chunks = {}, finished = false }
		function context:append(bytes)
			if self.finished then return nil end
			self.chunks[#self.chunks + 1] = bytes
			return self
		end
		function context:finish()
			self.finished = true
			return self
		end
		function context:value()
			return self.finished and oracle.for_bytes(table.concat(self.chunks)) or nil
		end
		return context
	end
	return oracle
end

return M
