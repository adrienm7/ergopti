// tools/diagnostics/hs274-stream-inventory.hpp
// Bounded keyboard-leaf observations; readable does not mean an atomic snapshot.
#pragma once

#include "hs274-key-element.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>

namespace hs274_stream_protocol {
template <std::size_t Limit>
class key_inventory final {
  static_assert(Limit > 0);
public:
  struct sample {
    std::uint32_t usage, cookie;
    key_element element;
    std::int32_t status;
    bool returned_value;
    std::uint32_t value_cookie;
    std::int64_t value;
    std::uint64_t timestamp, started, finished;
  };

  bool full() const noexcept { return count_ == Limit; }

  void append(const sample& input) {
    if (finished_) throw std::logic_error("Keyboard inventory already finalized");
    if (full()) {
      readable_ = false;
      throw std::overflow_error("Keyboard inventory bound exceeded");
    }
    bool valid = input.usage >= 1 && input.usage <= 255 && binary_key(input.element) &&
                 input.status == 0 && input.returned_value && input.cookie == input.value_cookie &&
                 (input.value == 0 || input.value == 1) && input.timestamp <= input.finished &&
                 previous_finish_ <= input.started && input.started <= input.finished;
    if (input.usage <= 3 && input.value != 0) valid = false;
    for (std::size_t i = 0; i < count_; ++i) {
      if (entries_[i].cookie == input.cookie || entries_[i].usage == input.usage) valid = false;
    }
    entries_[count_++] = input;
    previous_finish_ = input.finished;
    readable_ = readable_ && valid;
    found_key_ = found_key_ || (input.usage >= 4 && input.usage <= 255);
  }

  bool finish(bool enumerated, bool exhausted) {
    if (finished_) throw std::logic_error("Keyboard inventory already finalized");
    finished_ = true;
    return enumerated && !exhausted && readable_ && found_key_;
  }

private:
  std::array<sample, Limit> entries_{};
  std::size_t count_ = 0;
  std::uint64_t previous_finish_ = 0;
  bool finished_ = false, readable_ = true, found_key_ = false;
};
} // namespace hs274_stream_protocol
