// tools/diagnostics/hs274-stream-readiness.hpp
// Strict startup observation under one deadline, without acquiring a lease.
#pragma once

#include "hs274-stream-protocol.hpp"
#include "hs274-stream-native-control.hpp"
#include "hs274-stream-native-fault.hpp"
#include <algorithm>
#include <chrono>
#include <set>

namespace hs274_stream_protocol {
class readiness final {
public:
  bool observe(const json& response) {
    if (!response.is_object() || response.size() != 8 ||
        !response.at("version").is_number_unsigned() || response.at("version") != 1u ||
        response.at("kind") != "status" || response.at("coverage") != "fixture_only" ||
        !response.at("incarnation").is_string() || response.at("incarnation").get_ref<const std::string&>().empty() ||
        !response.at("ready").is_boolean() || !response.at("exhausted").is_boolean() ||
        !response.at("monitors").is_array() || !response.at("native_fault").is_string()) {
      throw std::invalid_argument("Invalid capture readiness response");
    }
    const auto identity = response.at("incarnation").get<std::string>();
    if (!incarnation_.empty() && incarnation_ != identity) throw std::runtime_error("Capture readiness changed producer");
    incarnation_ = identity;
    const auto fault = response.at("native_fault").get<std::string>();
    bool known_fault = false;
    for (auto candidate : {native_fault::none, native_fault::registration_capacity_exhausted,
        native_fault::registration_serial_exhausted, native_fault::invalid_device_identity,
        native_fault::duplicate_device_identity, native_fault::invalid_device_type,
        native_fault::acquisition_resource_exhausted, native_fault::inventory_receipt_write_failed,
        native_fault::reference_receipt_write_failed}) known_fault = known_fault || fault == native_fault_name(candidate);
    if (!known_fault || (fault != "none" && (!response.at("exhausted").get<bool>() || response.at("ready").get<bool>())))
      throw std::invalid_argument("Invalid capture native fault");
    if (fault != "none") throw std::runtime_error("Capture native diagnostic refused: " + fault);
    if (response.at("exhausted").get<bool>()) throw std::runtime_error("Capture monitor inventory exhausted");
    std::set<std::uint64_t> devices;
    bool expected = !response.at("monitors").empty();
    for (const auto& monitor : response.at("monitors")) {
      if (!monitor.is_object() || monitor.size() != 3 || !monitor.at("started").is_boolean() || !monitor.at("refusal").is_string()) {
        throw std::invalid_argument("Invalid capture monitor readiness");
      }
      const auto device = decimal(monitor.at("device"));
      if (!device || !devices.insert(device).second) throw std::invalid_argument("Invalid or duplicate capture device");
      const auto reason = monitor.at("refusal").get<std::string>();
      bool known = false;
      for (auto candidate : {native_refusal::none, native_refusal::inventory_unavailable,
          native_refusal::identity_unavailable, native_refusal::identity_mismatch,
          native_refusal::keyboard_type_unavailable, native_refusal::changed_native_provenance})
        known = known || reason == refusal_name(candidate);
      if (!known || (reason != "none" && monitor.at("started").get<bool>()))
        throw std::invalid_argument("Invalid capture native refusal");
      if (reason != "none") throw std::runtime_error("Capture native provenance refused: " + reason);
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
