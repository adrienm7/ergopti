--- platform/remap/token_reuse.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Token Reuse Decision
--- DESCRIPTION:
--- Decides, and names, whether a replacement lease generation may keep the token
--- of the generation it replaces. Reusing a token would leave karabiner.json
--- byte-identical (the token only appears in variable names) and so spare the
--- 743 KB rewrite and reload that a recovery otherwise causes while the user
--- types. The decision is always a refusal today; this module states why, so
--- the log shows it and a future native change has one place to lift it.
---
--- FEATURES & RATIONALE:
--- 1. Writers first: a token is never reusable while any writer of the previous
---    generation is unaccounted (a failed generation whose exact fence is not
---    proven, an exhausted fallback). A late writer would act on the new rules.
--- 2. Monotone tombstone: every generation that was started or stopped ended
---    with `ergopti_revoked_<token>=1`, which the launcher never lowers inside
---    a Core Service epoch (RemapLeaseWorker.swift, "Monotone Tombstone"). The
---    replacement's rules require that variable to be 0, so the same token
---    cannot become READY. Lifting this needs a native, acknowledged "rearm"
---    that only a Mac can verify; until then every reuse is refused.
--- 3. Pure: no host API, no state; the caller supplies the facts and logs.
--- ==============================================================================

local M = {}

M.FRESH_FIRST = "first-generation"
M.REFUSED_WRITERS = "writers-unaccounted"
M.REFUSED_TOMBSTONE = "tombstone-monotone"

--- Decides one allocation.
--- @param facts table `previous_token` string|nil (generation being replaced),
---   `unaccounted_writers` integer (retiring generations without a proven fence).
--- @return string verdict Always `fresh`: no reuse is permitted yet.
--- @return string reason Stable reason name.
function M.decide(facts)
	if type(facts) ~= "table" or type(facts.unaccounted_writers) ~= "number" then
		error("token_reuse.decide needs the unaccounted writer count", 2)
	end
	if facts.previous_token == nil then return "fresh", M.FRESH_FIRST end
	if facts.unaccounted_writers > 0 then return "fresh", M.REFUSED_WRITERS end
	return "fresh", M.REFUSED_TOMBSTONE
end

return M
