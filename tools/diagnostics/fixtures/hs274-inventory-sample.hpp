// tools/diagnostics/fixtures/hs274-inventory-sample.hpp
// Shared decoding of retained native inventory samples for portable tests.
#pragma once

#include <nlohmann/json.hpp>
#include <cstdint>
#include <string>

namespace hs274_test {
template <typename Sample>
Sample inventory_sample(const nlohmann::json& element) {
  const auto& sample = element.at("sample");
  return {element.at("usage").get<std::uint32_t>(), element.at("cookie").get<std::uint32_t>(),
      {true, element.at("relative").get<bool>(), element.at("array").get<bool>(),
       element.at("bits").get<std::uint32_t>(), element.at("count").get<std::uint32_t>(),
       element.at("minimum").get<std::int64_t>(), element.at("maximum").get<std::int64_t>()},
      sample.at("status").get<std::int32_t>(), sample.at("returned_value").get<bool>(),
      sample.at("value_cookie").get<std::uint32_t>(), std::stoll(sample.at("value").get<std::string>()),
      std::stoull(sample.at("timestamp").get<std::string>()),
      std::stoull(sample.at("started").get<std::string>()), std::stoull(sample.at("finished").get<std::string>())};
}
} // namespace hs274_test
