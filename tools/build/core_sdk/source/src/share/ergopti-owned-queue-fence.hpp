// Queue-cut bookkeeping. Native receipts and folded source snapshots own admission.
#pragma once
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <utility>
#include <vector>

namespace ergoptiplus::remap {
// Values are sampled by the original native monitor under its acquisition lock.
// This structure alone is neither a native receipt nor a coverage capability.
struct native_queue_conditions {
  bool requested, opened, values, raw_reports, queue;
  std::uint64_t generation, fault;
  bool admits(std::uint64_t captured) const noexcept {
    return captured && generation == captured && requested && opened && values &&
           !raw_reports && queue && !fault;
  }
};
template<std::size_t Limit> class queue_drain_budget final {
  static_assert(Limit > 0);
public:
  bool take() noexcept { if (count_ == Limit) { refused_ = true; return false; } ++count_; return true; }
  // At the bound, emptiness is unproved. Refuse conservatively without consuming
  // an extra native value solely to infer whether the queue has become empty.
  bool complete() const noexcept { return !refused_ && count_ < Limit; }
private:
  std::size_t count_ = 0;
  bool refused_ = false;
};
// Dispatcher-only aggregation; callers must supply the original inventory set
// and concrete source/native-issued receipts. A partial join never publishes.
template<class Receipt, std::size_t Limit> class queue_cut_join final {
public:
  explicit queue_cut_join(std::vector<std::uint64_t> expected) : expected_(std::move(expected)) {
    if (expected_.empty() || expected_.size() > Limit) throw std::invalid_argument("Invalid queue-cut interface set");
    for (std::size_t i=0;i<expected_.size();++i) {
      if (!expected_[i]) throw std::invalid_argument("Missing queue-cut interface");
      for (std::size_t j=0;j<i;++j) if (expected_[i]==expected_[j]) throw std::invalid_argument("Duplicate queue-cut interface");
    }
  }
  void cancel() noexcept { cancelled_ = true; }
  void append(Receipt receipt) {
    if (closed_ || cancelled_ || !receipt.current()) throw std::logic_error("Stale queue cut");
    bool expected=false;
    for (auto device:expected_) expected=expected || device==receipt.device();
    for (const auto& row:receipts_) if (row.device()==receipt.device()) throw std::logic_error("Duplicate queue-cut receipt");
    if (!expected) throw std::logic_error("Unexpected queue-cut receipt");
    receipts_.push_back(std::move(receipt));
  }
  template<class Recheck> std::vector<Receipt> finish(Recheck recheck) {
    if (closed_) throw std::logic_error("Queue cut already settled");
    closed_=true;
    require_current();
    // This is a pre-publication inventory/cancellation check, not a success
    // callback. Reentrant cancellation or owner replacement is checked again.
    recheck();
    require_current();
    return std::move(receipts_);
  }
private:
  void require_current() const {
    if (cancelled_ || receipts_.size()!=expected_.size()) throw std::logic_error("Incomplete queue-cut join");
    for (const auto& row:receipts_) if (!row.current()) throw std::logic_error("Queue cut ownership changed");
  }
  std::vector<std::uint64_t> expected_;
  std::vector<Receipt> receipts_;
  bool cancelled_=false, closed_=false;
};
} // namespace ergoptiplus::remap
