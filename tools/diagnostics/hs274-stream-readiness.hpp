// tools/diagnostics/hs274-stream-readiness.hpp
// Strict startup observation under one deadline, without acquiring a lease.
#pragma once

#include "hs274-stream-protocol.hpp"
#include <algorithm>
#include <chrono>
#include <set>

namespace hs274_stream_protocol {
class readiness final {
public:
  bool observe(const json& response) {
    if (!response.is_object() || response.size() != 7 ||
        !response.at("version").is_number_unsigned() || response.at("version") != 1u ||
        response.at("kind") != "status" || response.at("coverage") != "fixture_only" ||
        !response.at("incarnation").is_string() || response.at("incarnation").get_ref<const std::string&>().empty() ||
        !response.at("ready").is_boolean() || !response.at("exhausted").is_boolean() ||
        !response.at("monitors").is_array()) {
      throw std::invalid_argument("Invalid capture readiness response");
    }
    const auto identity = response.at("incarnation").get<std::string>();
    if (!incarnation_.empty() && incarnation_ != identity) throw std::runtime_error("Capture readiness changed producer");
    incarnation_ = identity;
    if (response.at("exhausted").get<bool>()) throw std::runtime_error("Capture monitor inventory exhausted");
    std::set<std::uint64_t> devices;
    bool expected = !response.at("monitors").empty();
    for (const auto& monitor : response.at("monitors")) {
      if (!monitor.is_object() || monitor.size() != 2 || !monitor.at("started").is_boolean()) {
        throw std::invalid_argument("Invalid capture monitor readiness");
      }
      const auto device = decimal(monitor.at("device"));
      if (!device || !devices.insert(device).second) throw std::invalid_argument("Invalid or duplicate capture device");
      expected = expected && monitor.at("started").get<bool>();
    }
    if (response.at("ready").get<bool>() != expected) throw std::invalid_argument("Capture readiness disagrees with inventory");
    return expected;
  }

  const std::string& incarnation() const { return incarnation_; }

private:
  std::string incarnation_;
};

template <typename Clock = std::chrono::steady_clock, typename Client>
std::string await_readiness(Client& client, std::chrono::milliseconds interval, typename Clock::time_point deadline) {
  if (interval.count() <= 0) throw std::invalid_argument("Capture readiness interval must be positive");
  readiness observation;
  for (;;) {
    if (Clock::now() >= deadline) throw std::runtime_error("Capture readiness timeout");
    const auto response = client.request({{"version", 1u}, {"action", "status"}}, deadline);
    const auto ready = observation.observe(response);
    if (Clock::now() >= deadline) throw std::runtime_error("Capture readiness timeout");
    if (ready) return observation.incarnation();
    client.pause(std::min(interval, std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now())));
  }
}
} // namespace hs274_stream_protocol
