-- Actual shared timing/configuration owners; no native execution claim.
local root = assert(arg[1])
local shared = root .. "/static/ergopti_plus/_shared/"
package.path = root .. "/static/ergopti_plus/linux/?.lua;" .. shared .. "lua/?.lua;" .. shared .. "lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Codec, Core = require("toml_codec"), require("hotstring_engine")
local Resolver, Manifest = require("hotstrings.delay_resolver"), require("infra.manifest_reader")
local function decode(file)
    local f = assert(io.open(file, "rb")); local value = assert(Codec.decode(f:read("*a"))); f:close(); return value
end
local meta = decode(shared .. "modules/hotstrings/magickey.toml")._meta
local timing = decode(shared .. "modules/timings/constants.toml").hotstrings
local base = Manifest.default_for("hotstrings.expansion_delay")
local resolved = Resolver.resolve({meta_category = meta, default_delay = base})
assert(base == 0.75 and meta.delay == 2 and resolved.delay == 2)
assert(timing.complex_key_delay_multiplier == 2 and timing.complex_key_carry_ms == 300)
local controls = {
    { id = "plain", expander = false, reference = false, gap = 2500, factor = 1, allowed = false },
    { id = "complex-expander", expander = true, reference = false, gap = 2500, factor = 2, allowed = true },
    { id = "complex-reference-outside-carry", expander = false, reference = true, gap = 2500, factor = 1, allowed = false },
    { id = "complex-reference-at-carry", expander = false, reference = true, gap = 300, factor = 2, allowed = true },
    { id = "complex-reference-after-carry", expander = false, reference = true, gap = 301, factor = 1, allowed = true },
    { id = "plain-exact-deadline", expander = false, reference = false, gap = 2000, factor = 1, allowed = true },
    { id = "plain-after-deadline", expander = false, reference = false, gap = 2001, factor = 1, allowed = false },
    { id = "complex-exact-deadline", expander = true, reference = false, gap = 4000, factor = 2, allowed = true },
    { id = "complex-after-deadline", expander = true, reference = false, gap = 4001, factor = 2, allowed = false },
}
for _, row in ipairs(controls) do
    local factor = Core.complex_delay_multiplier(row.expander, row.reference, row.gap,
        timing.complex_key_delay_multiplier, timing.complex_key_carry_ms, true)
    assert(factor == row.factor, row.id .. " factor")
    assert(Core.within_expansion_delay({expander_gap_ms = row.gap}, resolved.delay, 0, factor) == row.allowed,
        row.id .. " registered shared gate")
end
assert(Core.within_expansion_delay({expander_gap_ms = 999999}, 0, 0, 1) == true)
print(require("json").encode({base_delay = base, shipped_category_delay = resolved.delay,
    multiplier = timing.complex_key_delay_multiplier, carry_ms = timing.complex_key_carry_ms,
    controls = controls, assertions = 21,
    qualification = "Actual shared resolver/multiplier/registered gate only; public macOS repeat uses separate seconds comparison; Windows AHK unexecuted."}))
