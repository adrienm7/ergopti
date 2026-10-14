// tools/diagnostics/hs274-installed-baseline-client.hpp
// Installed pages keep the original lease and a private Core-derived cut cursor.
#pragma once

#include "hs274-stream-baseline-client.hpp"

namespace hs274_stream_protocol {
// Parsing an authenticated response does not mint a native owner or a terminal
// receipt. The original Core socket/participant owns those admission obligations.
inline std::uint64_t validate_installed_opened(const json& opened) {
  if (!opened.is_object() || opened.size() != 7 ||
      !opened.at("version").is_number_unsigned() || opened.at("version") != 1u ||
      opened.at("kind") != "opened" || opened.at("coverage") != "complete" ||
      !opened.at("incarnation").is_string() || opened.at("incarnation").get_ref<const std::string&>().empty() ||
      !decimal(opened.at("lease"))) throw std::invalid_argument("Invalid installed opened envelope");
  return decimal(opened.at("baseline_sequence"));
}

template <std::size_t Limit, typename Request, typename Publish, typename Acknowledge>
void transfer_installed_baseline(const json& opened, Request request, Publish publish, Acknowledge acknowledge) {
  static_assert(Limit > 0);
  validate_installed_opened(opened);
  const auto& descriptor = opened.at("baseline");
  if (!descriptor.is_object() || descriptor.size() != 3 ||
      !descriptor.at("version").is_number_unsigned() || descriptor.at("version") != 2u ||
      !descriptor.at("rows").is_number_unsigned()) {
    throw std::invalid_argument("Invalid capture baseline descriptor");
  }
  decimal(descriptor.at("boundary"));
  const auto total = descriptor.at("rows").get<std::size_t>();
  if (!total) throw std::invalid_argument("Capture baseline is empty");
  json query{{"version", 1u}, {"action", "baseline"}, {"incarnation", opened.at("incarnation")},
             {"lease", opened.at("lease")}};
  std::size_t cursor = 0;
  for (;;) {
    const json response = request(query);
    for (const auto* field : {"version", "coverage", "incarnation", "lease", "baseline_sequence"}) {
      if (response.at(field).type() != opened.at(field).type() || response.at(field) != opened.at(field)) {
        throw std::runtime_error("Baseline response changed session identity");
      }
    }
    if (response.at("kind") == "lost") {
      if (response.size() != 7 || !response.at("reason").is_string())
        throw std::invalid_argument("Invalid installed baseline loss envelope");
      publish(response);
      throw std::runtime_error("Physical capture coverage lost during baseline transfer");
    }
    if (response.at("kind") == "baseline_ready") {
      if (response.size() != 6 || cursor != total) throw std::runtime_error("Premature baseline completion");
      // Its preceding page was acknowledged already. Ordered output places this
      // marker before any raw batch; a second identical receipt would be stale.
      publish(response);
      return;
    }
    if (response.at("kind") != "baseline" || response.size() != 12 ||
        response.at("boundary") != descriptor.at("boundary") ||
        !response.at("offset").is_number_unsigned() || response.at("offset") != cursor ||
        !response.at("next").is_number_unsigned() ||
        !response.at("total").is_number_unsigned() || response.at("total") != total ||
        !response.at("complete").is_boolean() || !response.at("rows").is_array()) {
      throw std::runtime_error("Invalid baseline page envelope");
    }
    const auto next = response.at("next").get<std::size_t>();
    if (next <= cursor || next > total || next - cursor > Limit ||
        response.at("rows").size() != next - cursor || response.at("complete") != (next == total)) {
      throw std::runtime_error("Baseline page skipped or repeated rows");
    }
    publish(response);
    acknowledge(baseline_acknowledgement(opened, next));
    cursor = next;
    query["baseline_ack"] = std::to_string(cursor);
  }
}
} // namespace hs274_stream_protocol
