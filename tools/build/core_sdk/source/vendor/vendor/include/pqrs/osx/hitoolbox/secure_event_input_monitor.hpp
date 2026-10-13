#pragma once

// (C) Copyright Takayama Fumihiko 2026.
// Distributed under the Boost Software License, Version 1.0.
// (See https://www.boost.org/LICENSE_1_0.txt)

// `pqrs::osx::hitoolbox::secure_event_input_monitor` can be used safely in a multi-threaded environment.

#include <Carbon/Carbon.h>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <nod/nod.hpp>
#include <pqrs/dispatcher.hpp>
#include <utility>

namespace krbn::core_service::daemon { class device_grabber; }

namespace pqrs::osx::hitoolbox {

class secure_event_input_monitor : public dispatcher::extra::dispatcher_client {
  friend class krbn::core_service::daemon::device_grabber;
  class owned_stop_receipt final {
    friend class secure_event_input_monitor;
    const secure_event_input_monitor* monitor_=nullptr;
    std::weak_ptr<void> lifetime_;
    owned_stop_receipt(const secure_event_input_monitor* monitor,const std::shared_ptr<void>& lifetime)
      :monitor_(monitor),lifetime_(lifetime) {}
  public:
    bool settled() const {
      const auto held=lifetime_.lock();
      return held && monitor_ && monitor_->dispatcher_thread() &&
             monitor_->owned_stop_completed_ && !monitor_->timer_.enabled();
    }
  };
  bool async_owned_stop(std::shared_ptr<void> receiver_lifetime,
                        std::function<void(owned_stop_receipt)> completion) {
    if (!dispatcher_thread() || !receiver_lifetime || !completion || owned_stop_requested_) return false;
    owned_stop_requested_=true;
    stop();
    return enqueue_to_dispatcher([this,receiver_lifetime,completion=std::move(completion)] {
      // Original timer.stop queued its function-id invalidation before this fence.
      if (timer_.enabled()) return;
      owned_stop_completed_=true;
      completion(owned_stop_receipt(this,receiver_lifetime));
    });
  }
  class owned_start_receipt final {
    friend class secure_event_input_monitor;
    friend class krbn::core_service::daemon::device_grabber;
    const secure_event_input_monitor* monitor_;
    const std::uint64_t generation_;
    owned_start_receipt(const secure_event_input_monitor* monitor,std::uint64_t generation)
      :monitor_(monitor),generation_(generation) {}
  };
  std::uint64_t owned_start_generation_=0;
  bool owned_start_sampled_=false;
  std::function<bool()> owned_start_scope_;
  std::function<void(std::shared_ptr<const owned_start_receipt>)> owned_start_completion_;
  bool owned_started(const std::shared_ptr<const owned_start_receipt>& receipt) const {
    return dispatcher_thread() && receipt && receipt->monitor_==this &&
      receipt->generation_==owned_start_generation_ && owned_start_sampled_ &&
      !owned_stop_requested_ && timer_.enabled();
  }
  bool async_owned_start(std::function<bool()> scope,
      std::function<void(std::shared_ptr<const owned_start_receipt>)> completion) {
    if (!dispatcher_thread() || !scope || !completion || owned_stop_requested_ ||
        owned_start_scope_ || owned_start_generation_==UINT64_MAX) return false;
    owned_start_scope_=std::move(scope);
    owned_start_completion_=std::move(completion);
    ++owned_start_generation_;
    async_start(); // The original native timer function issues the receipt.
    return true;
  }
  bool owned_stop_requested_=false;
  bool owned_stop_completed_=false;

public:
  //
  // Signals (invoked from the dispatcher thread)
  //

  nod::signal<void(bool)> secure_event_input_enabled_changed;

  //
  // Methods
  //

  secure_event_input_monitor(const secure_event_input_monitor&) = delete;
  secure_event_input_monitor& operator=(const secure_event_input_monitor&) = delete;

  secure_event_input_monitor(std::weak_ptr<dispatcher::dispatcher> weak_dispatcher,
                             std::chrono::milliseconds check_interval = std::chrono::milliseconds(200))
      : dispatcher_client(std::move(weak_dispatcher)),
        check_interval_(check_interval),
        timer_(*this),
        secure_event_input_enabled_(IsSecureEventInputEnabled()) {
  }

  ~secure_event_input_monitor() noexcept override {
    detach_from_dispatcher([this] {
      stop();
    });
  }

  void async_start() {
    enqueue_to_dispatcher([this] {
      if (owned_stop_requested_) return;
      if (owned_start_scope_) {
        bool current=false;
        try { current=owned_start_scope_(); } catch (...) {}
        if (!current) {
          auto completion=std::move(owned_start_completion_);
          owned_start_scope_={};
          if (completion) enqueue_to_dispatcher([completion] { completion(nullptr); });
          return;
        }
      }
      timer_.start(
          [this] {
            auto enabled = IsSecureEventInputEnabled();
            if (secure_event_input_enabled_ != enabled) {
              secure_event_input_enabled_ = enabled;
              secure_event_input_enabled_changed(secure_event_input_enabled_);
            }
            // This is after the original actual IsSecureEventInputEnabled call,
            // not timer.enabled's requested-state observation.
            if (owned_start_completion_) {
              bool current=false;
              try { current=owned_start_scope_ && owned_start_scope_(); } catch (...) {}
              owned_start_sampled_=current && !owned_stop_requested_;
              auto completion=std::move(owned_start_completion_);
              owned_start_scope_={};
              auto receipt=owned_start_sampled_ ? std::shared_ptr<const owned_start_receipt>(
                new owned_start_receipt(this,owned_start_generation_)) : nullptr;
              enqueue_to_dispatcher([completion,receipt] { completion(receipt); });
            }
          },
          check_interval_);
    });
  }

  void async_stop() {
    enqueue_to_dispatcher([this] {
      stop();
    });
  }

private:
  void stop() {
    owned_start_sampled_=false;
    timer_.stop();
    auto completion=std::move(owned_start_completion_);
    owned_start_scope_={};
    if (completion) enqueue_to_dispatcher([completion] { completion(nullptr); });
  }

  const std::chrono::milliseconds check_interval_;
  pqrs::dispatcher::extra::timer timer_;
  bool secure_event_input_enabled_;
};

} // namespace pqrs::osx::hitoolbox
