// tools/diagnostics/hs274-stream-baseline-pages.hpp
// Immutable bounded baseline pages; session identity and acknowledgement belong to the caller.
#pragma once

#include "hs274-key-state.hpp"
#include <nlohmann/json.hpp>
#include <unordered_set>

namespace hs274_stream_protocol {
template <std::size_t PageSize, std::size_t Devices, std::size_t Elements>
class baseline_pages final {
  static_assert(PageSize > 0 && Devices > 0 && Elements > 0);
public:
  using element = typename key_state<Elements>::frozen_element;
  struct device_state {
    std::uint64_t device;
    bool keyboard;
    std::vector<element> keys;
  };

  baseline_pages(std::uint64_t boundary, std::vector<device_state> devices)
      : boundary_(boundary), devices_(std::move(devices)) {
    if (devices_.empty() || devices_.size() > Devices) {
      throw std::invalid_argument("Invalid baseline device count");
    }
    std::unordered_set<std::uint64_t> identities;
    for (const auto& device : devices_) {
      if (!device.device || !identities.insert(device.device).second || device.keys.size() > Elements ||
          (device.keyboard ? device.keys.empty() : !device.keys.empty())) {
        throw std::invalid_argument("Invalid baseline device inventory");
      }
      std::unordered_set<std::uint32_t> cookies;
      for (const auto& key : device.keys) {
        if (!key.usage || key.usage > 255 || (key.usage <= 3 && key.down) ||
            key.timestamp > boundary_ || !cookies.insert(key.cookie).second) {
          throw std::invalid_argument("Invalid baseline element");
        }
      }
      total_ += 1 + device.keys.size();
    }
  }

  std::size_t size() const noexcept { return total_; }

  // Device markers preserve empty consumer interfaces. A page boundary may
  // split a device's elements, so each key retains its exact device identity.
  nlohmann::json read(std::size_t offset) const {
    if (offset >= total_) throw std::out_of_range("Baseline cursor is outside the snapshot");
    auto rows = nlohmann::json::array();
    std::size_t index = 0;
    for (const auto& device : devices_) {
      if (index++ >= offset && rows.size() < PageSize) {
        rows.push_back({{"kind", "device"}, {"device", std::to_string(device.device)},
                        {"keyboard", device.keyboard}, {"elements", device.keys.size()}});
      }
      const auto first = offset > index ? offset - index : 0;
      for (auto i = first; i < device.keys.size() && rows.size() < PageSize; ++i) {
        const auto& key = device.keys[i];
        rows.push_back({{"kind", "key"}, {"device", std::to_string(device.device)},
                        {"usage", key.usage}, {"cookie", key.cookie},
                        {"timestamp", std::to_string(key.timestamp)}, {"down", key.down}});
      }
      index += device.keys.size();
      if (rows.size() == PageSize) break;
    }
    const auto next = offset + rows.size();
    return {{"boundary", std::to_string(boundary_)}, {"offset", offset},
            {"next", next}, {"total", total_}, {"complete", next == total_}, {"rows", std::move(rows)}};
  }

private:
  const std::uint64_t boundary_;
  std::vector<device_state> devices_;
  std::size_t total_ = 0;
};
} // namespace hs274_stream_protocol
