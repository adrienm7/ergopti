#pragma once

// Fixed source policy only. Native signed-role acquisition is separate.
#include <cstdint>
#include <string_view>

namespace ergoptiplus::remap::identity {

enum class role : std::uint8_t { unavailable, core, console, cli };

[[nodiscard]] constexpr std::string_view identifier(role value) noexcept {
  switch (value) {
    case role::core: return "com.ergoptiplus.remap.core";
    case role::console: return "com.ergoptiplus.remap.console";
    case role::cli: return "com.ergoptiplus.remap.cli";
    default: return {};
  }
}

[[nodiscard]] constexpr role classify(std::string_view value) noexcept {
  if (value == identifier(role::core)) { return role::core; }
  if (value == identifier(role::console)) { return role::console; }
  if (value == identifier(role::cli)) { return role::cli; }
  return role::unavailable;
}

} // namespace ergoptiplus::remap::identity
