// tools/diagnostics/hs274-stream-protocol.hpp
// Experimental fixture-only request protocol; authentication belongs to receiver.
#pragma once

#include "hs274-raw-capture.hpp"
#include "hs274-stream-session.hpp"
#include <charconv>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>

namespace hs274_stream_protocol {
using value = hs274_raw_capture::record;
using json = nlohmann::json;

// JSON numbers cannot preserve every uint64 when the downstream reader is Lua.
inline std::uint64_t decimal(const json& field) {
  if (!field.is_string()) throw std::invalid_argument("Expected a decimal string");
  const auto& text = field.get_ref<const std::string&>();
  if (text.empty() || (text.size() > 1 && text.front() == '0')) {
    throw std::invalid_argument("Noncanonical decimal identifier");
  }
  for (auto c : text) if (c < '0' || c > '9') throw std::invalid_argument("Invalid decimal identifier");
  std::uint64_t result = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
    throw std::invalid_argument("Decimal identifier overflow");
  }
  return result;
}

// Receiver and monitor must invoke this object on the same dispatcher.
// Capacity/Limit are supplied by the integration; there is no hidden queue.
template <std::size_t Capacity, std::size_t Limit>
class controller final {
  using storage = hs274_stream::session<value, Capacity>;
  static_assert(Limit > 0 && Limit <= Capacity);

public:
  explicit controller(std::string incarnation) : incarnation_(std::move(incarnation)) {
    if (incarnation_.empty()) throw std::invalid_argument("Missing producer incarnation");
  }

  ~controller() { if (owner_) storage_.release(*owner_); }

  void append(const value& input) noexcept { storage_.append(input); }

  void peer_closed(std::uint64_t peer) {
    if (owner_ && owner_->peer == peer) {
      storage_.release(*owner_);
      owner_.reset();
    }
  }

  json request(std::uint64_t peer, const json& input) {
    if (!input.is_object() || !input.at("version").is_number_unsigned() || input.at("version") != 1u) {
      throw std::invalid_argument("Unsupported capture protocol");
    }
    const auto action = input.at("action").get<std::string>();
    if (action == "open") {
      if (input.size() != 2) throw std::invalid_argument("Unexpected open fields");
      owner_ = storage_.acquire(peer);
      return envelope("opened");
    }
    if (!owner_ || owner_->peer != peer || input.at("incarnation") != incarnation_ ||
        decimal(input.at("lease")) != owner_->lease) {
      throw std::invalid_argument("Capture request belongs to another session");
    }
    if (action == "close") {
      if (input.size() != 4) throw std::invalid_argument("Unexpected close fields");
      auto response = envelope("closed");
      peer_closed(peer);
      return response;
    }
    if (action != "pull" || input.size() != (input.contains("ack") ? 5u : 4u)) {
      throw std::invalid_argument("Unexpected capture action or fields");
    }
    auto failure = storage_.status(*owner_);
    if (failure != storage::fault::none) {
      auto response = envelope("lost");
      response["reason"] = failure == storage::fault::overflow ? "overflow" : "sequence_exhausted";
      return response;
    }
    if (input.contains("ack")) storage_.acknowledge(*owner_, decimal(input.at("ack")));
    const auto batch = storage_.template read<Limit>(*owner_);
    auto response = envelope("batch");
    response["records"] = json::array();
    for (std::size_t i = 0; i < batch.count; ++i) {
      const auto& entry = batch.records[i];
      const auto& r = entry.value;
      response["records"].push_back({
          {"sequence", std::to_string(entry.sequence)}, {"device", std::to_string(r.device)},
          {"timestamp", std::to_string(r.timestamp)}, {"value", std::to_string(r.value)},
          {"has_page", r.has_page}, {"has_usage", r.has_usage}, {"page", r.page}, {"usage", r.usage}});
    }
    return response;
  }

private:
  json envelope(const char* kind) const {
    return {{"version", 1u}, {"kind", kind}, {"coverage", "fixture_only"},
            {"incarnation", incarnation_}, {"lease", std::to_string(owner_->lease)}};
  }

  const std::string incarnation_;
  storage storage_;
  std::optional<typename storage::token> owner_;
};
} // namespace hs274_stream_protocol
