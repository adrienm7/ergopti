#pragma once

// pqrs::osx::iokit_hid_device_events_monitor v5.0.0

// (C) Copyright Takayama Fumihiko 2018.
// Distributed under the Boost Software License, Version 1.0.
// (See https://www.boost.org/LICENSE_1_0.txt)

#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDQueue.h>
#include <limits>
#include "ergopti-owned-queue-fence.hpp"
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <nod/nod.hpp>
#include <optional>
#include <pqrs/cf/run_loop_thread.hpp>
#include <pqrs/dispatcher.hpp>
#include <pqrs/gsl.hpp>
#include <pqrs/osx/chrono.hpp>
#include <pqrs/osx/iokit_hid_device.hpp>
#include <pqrs/osx/iokit_return.hpp>
#include <pqrs/osx/iokit_types.hpp>
#include <span>
#include <string>
#include <utility>
#include <vector>

namespace krbn { class hid_device_events_monitor; }

namespace pqrs::osx {
class iokit_hid_device_events_monitor final : public dispatcher::extra::dispatcher_client {
public:
  //
  // Signals (invoked from the dispatcher thread)
  //

  nod::signal<void()> started;
  nod::signal<void()> stopped;
  nod::signal<void(not_null_shared_ptr_t<std::vector<cf::cf_ptr<IOHIDValueRef>>>)> input_values_arrived;
  // The report span is valid only for the duration of the signal invocation.
  nod::signal<void(uint32_t report_id,
                   std::span<const uint8_t> report,
                   chrono::absolute_time_point time_stamp)>
      input_report_arrived;
  nod::signal<void(const std::string&, iokit_return)> error_occurred;

  //
  // Methods
  //

  iokit_hid_device_events_monitor(const iokit_hid_device_events_monitor&) = delete;

  struct parameters final {
    bool observe_input_values = true;
    bool observe_input_reports = false;

    // Invoked synchronously and serially in the supplied run_loop_thread.
    // The same monitor instance never invokes this filter concurrently.
    // The filter must not destroy this monitor synchronously.
    std::function<bool(uint32_t report_id,
                       std::span<const uint8_t> report)>
        input_report_filter;

    // Invoked synchronously in the supplied run_loop_thread after each
    // successful device open and before the first input report is delivered.
    // Use this callback to reset state retained by input_report_filter.
    // It is never invoked concurrently with input_report_filter for the same
    // monitor instance and must not destroy this monitor synchronously.
    std::function<void()> input_report_filter_started;
  };

  // CFRunLoopRun may get stuck in rare cases if cf::run_loop_thread generation is repeated frequently in macOS 13.
  // If such a condition occurs, cf::run_loop_thread detects it and calls abort to avoid it.
  // However, to avoid the problem itself, cf::run_loop_thread should be provided externally instead of having it internally.
  iokit_hid_device_events_monitor(std::weak_ptr<dispatcher::dispatcher> weak_dispatcher,
                                  not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread,
                                  IOHIDDeviceRef device)
      : iokit_hid_device_events_monitor(weak_dispatcher,
                                        run_loop_thread,
                                        device,
                                        parameters{}) {
  }

  iokit_hid_device_events_monitor(std::weak_ptr<dispatcher::dispatcher> weak_dispatcher,
                                  not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread,
                                  IOHIDDeviceRef device,
                                  const parameters& parameters)
      : dispatcher_client(weak_dispatcher),
        run_loop_thread_(run_loop_thread),
        hid_device_(device),
        open_timer_(*this),
        last_open_error_(kIOReturnSuccess),
        observe_input_values_(parameters.observe_input_values),
        input_report_filter_(parameters.input_report_filter),
        input_report_filter_started_(parameters.input_report_filter_started) {
    if (parameters.observe_input_reports) {
      constexpr size_t minimum_input_report_buffer_size = 1024;

      auto size = minimum_input_report_buffer_size;
      if (auto max_input_report_size = hid_device_.find_max_input_report_size()) {
        if (*max_input_report_size > static_cast<int64_t>(size)) {
          size = static_cast<size_t>(*max_input_report_size);
        }
      }
      input_report_buffer_.resize(size);
    }

    // Schedule device

    if (CFRunLoopGetCurrent() == run_loop_thread_->get_run_loop()) {
      schedule_device();
    } else {
      auto wait = make_thread_wait();

      run_loop_thread_->enqueue(^{
        schedule_device();
        wait->notify();
      });

      wait->wait_notice();
    }
  }

  ~iokit_hid_device_events_monitor() override {
    //
    // dispatcher_client
    //

    detach_from_dispatcher();

    //
    // run_loop_thread
    //

    if (CFRunLoopGetCurrent() == run_loop_thread_->get_run_loop()) {
      cleanup_device();
    } else {
      auto wait = make_thread_wait();

      run_loop_thread_->enqueue(^{
        cleanup_device();
        wait->notify();
      });

      wait->wait_notice();
    }
  }

  void async_start(IOOptionBits open_options,
                   std::chrono::milliseconds open_timer_interval) {
    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      if (owned_stop_generation_!=0) return;
      requested_open_options_ = open_options;
      ++requested_open_options_generation_;
    }

    run_loop_thread_->enqueue(^{
      open_timer_.start(
          [this] {
            run_loop_thread_->enqueue(^{
              start();
            });
          },
          open_timer_interval);
    });
  }

  void async_stop() {
    uint64_t requested_open_options_generation = 0;

    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      if (!requested_open_options_) {
        return;
      }

      requested_open_options_ = std::nullopt;
      requested_open_options_generation = ++requested_open_options_generation_;
    }

    run_loop_thread_->enqueue(^{
      stop({.reason = stop_reason::async_stop,
            .requested_open_options_generation = requested_open_options_generation});
    });
  }


  class owned_queue_receipt final {
  public:
    owned_queue_receipt() = default;
    bool current() const noexcept {
      const auto owner=owner_.lock();
      return owner && owner->owned_queue_current(generation_);
    }
  private:
    friend class iokit_hid_device_events_monitor;
    owned_queue_receipt(const std::shared_ptr<iokit_hid_device_events_monitor>& owner, std::uint64_t generation)
        : owner_(owner),generation_(generation) {}
    std::weak_ptr<iokit_hid_device_events_monitor> owner_;
    std::uint64_t generation_=0;
  };

  // Supply this exact native instance and retain its original signal receiver.
  // Call only from that receiver's dispatcher. No input-report cut is claimed.
  bool async_owned_queue_cut(std::shared_ptr<iokit_hid_device_events_monitor> owner,
                             std::shared_ptr<void> receiver_lifetime,
                             std::function<void(owned_queue_receipt)> completion) {
    if (owner.get()!=this || !receiver_lifetime || !completion || !dispatcher_thread()) return false;
    std::uint64_t generation;
    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);
      generation=requested_open_options_generation_;
      if (!owned_queue_options_current(generation)) return false;
    }
    run_loop_thread_->enqueue(^{
      auto values=std::make_shared<std::vector<cf::cf_ptr<IOHIDValueRef>>>();
      bool complete=false;
      try {
        if (owner->owned_queue_current(generation) && owner->input_values_queue_) {
          ergoptiplus::remap::queue_drain_budget<4096> budget;
          while (budget.take()) {
            auto value=cf::adopt_cf_ptr(IOHIDQueueCopyNextValueWithTimeout(*owner->input_values_queue_,0.0));
            if (!value) { complete=budget.complete(); break; }
            values->emplace_back(std::move(value));
          }
        }
      } catch (...) { complete=false; }
      // Previously queued value callbacks precede this handoff. This run-loop
      // task enqueues its retained vector and receipt in one dispatcher action;
      // callbacks subsequently enqueued cannot precede that folded snapshot.
      const bool posted=owner->enqueue_to_dispatcher([owner,receiver_lifetime,completion,values,generation,complete] {
        const bool before=owner->owned_queue_current(generation);
        if (before && !values->empty()) owner->input_values_arrived(values);
        if (before && complete && owner->owned_queue_current(generation))
          completion(owned_queue_receipt(owner,generation));
        else completion({});
      });
      // No callback is fabricated on dispatcher refusal. The original caller's
      // finite request deadline must refuse unsettled work and retain its debt.
      if (!posted || !complete) {
        owner->run_loop_thread_->enqueue(^{ owner->input_values_available_callback(); });
      }
    });
    return true;
  }


  class owned_stop_receipt final {
  public:
    owned_stop_receipt() = default;
    bool settled() const noexcept {
      const auto owner=owner_.lock();
      if (!owner || !success_) return false;
      std::lock_guard<std::mutex> lock(owner->open_options_mutex_);
      return owner->owned_stop_generation_==generation_ &&
             owner->requested_open_options_generation_==generation_ &&
             !owner->requested_open_options_ && !owner->current_open_options_ &&
             !owner->owned_device_open_options_ && !owner->owned_device_scheduled_ &&
             owner->owned_failed_queues_.empty() && !owner->owned_retirement_failed_;
    }
  private:
    friend class iokit_hid_device_events_monitor;
    owned_stop_receipt(const std::shared_ptr<iokit_hid_device_events_monitor>& owner,
                       std::uint64_t generation, bool success)
        : owner_(owner),generation_(generation),success_(success) {}
    std::weak_ptr<iokit_hid_device_events_monitor> owner_;
    std::uint64_t generation_=0;
    bool success_=false;
  };

  class owned_stop_admission final {
    friend class iokit_hid_device_events_monitor;
    const std::shared_ptr<iokit_hid_device_events_monitor> owner_;
    const std::shared_ptr<void> receiver_lifetime_;
    const std::uint64_t generation_;
    owned_stop_admission(std::shared_ptr<iokit_hid_device_events_monitor> owner,
                         std::shared_ptr<void> receiver_lifetime, std::uint64_t generation)
        :owner_(std::move(owner)),receiver_lifetime_(std::move(receiver_lifetime)),generation_(generation) {}
  };
  std::shared_ptr<owned_stop_admission> retain_owned_stop(
      const std::shared_ptr<iokit_hid_device_events_monitor>& owner,
      const std::shared_ptr<void>& receiver_lifetime) {
    if (owner.get()!=this || !receiver_lifetime || !dispatcher_thread()) return nullptr;
    std::lock_guard<std::mutex> lock(open_options_mutex_);
    if (owned_stop_generation_ || !owned_stop_admission_.expired() ||
        owned_stop_admission_generation_==std::numeric_limits<std::uint64_t>::max()) return nullptr;
    auto admission=std::shared_ptr<owned_stop_admission>(new owned_stop_admission(
        owner,receiver_lifetime,++owned_stop_admission_generation_));
    owned_stop_admission_=admission;
    return admission;
  }
  // The original high-level receiver retains both native and dispatcher life.
  // Scheduling alone does not return native close or cohort retirement proof.
  bool async_owned_stop(const std::shared_ptr<owned_stop_admission>& admission,
                        std::function<void(owned_stop_receipt)> completion) {
    if (!admission || admission->owner_.get()!=this || !completion || !dispatcher_thread()) return false;
    const auto owner=admission->owner_;
    const auto receiver_lifetime=admission->receiver_lifetime_;
    std::uint64_t generation;
    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);
      // The immutable admission was minted while this native registration was
      // current. A later queue fault does not abandon its exact cleanup debt.
      if (owned_stop_generation_!=0 || owned_stop_admission_.lock().get()!=admission.get() ||
          admission->generation_!=owned_stop_admission_generation_ ||
          requested_open_options_generation_==std::numeric_limits<std::uint64_t>::max()) return false;
      requested_open_options_=std::nullopt;
      generation=++requested_open_options_generation_;
      owned_stop_generation_=generation;
    }
    // An enqueue exception has unknown delivery: preserve this closed admission
    // and the caller's outstanding debt rather than synthesizing a callback.
    run_loop_thread_->enqueue(^{
      std::optional<IOOptionBits> options;
      bool current=false;
      {
        std::lock_guard<std::mutex> lock(owner->open_options_mutex_);
        current=owner->owned_stop_generation_==generation &&
                owner->requested_open_options_generation_==generation &&
                !owner->requested_open_options_;
        options=owner->owned_device_open_options_;
      }
      // No open debt is a constructor/native-observed state, not caller input.
      bool success=current && !owner->owned_retirement_failed_;
      if (current) {
        owner->open_timer_.stop();
        if (owner->input_values_queue_) {
          const auto stopped=IOHIDQueueStop(*owner->input_values_queue_);
          success=success && stopped==kIOReturnSuccess;
          IOHIDQueueUnscheduleFromRunLoop(*owner->input_values_queue_,
                                         owner->run_loop_thread_->get_run_loop(),kCFRunLoopCommonModes);
          owner->input_values_queue_=nullptr;
        }
        for (auto& queue:owner->owned_failed_queues_) {
          const auto stopped=IOHIDQueueStop(*queue);
          success=success && stopped==kIOReturnSuccess;
        }
        if (success) owner->owned_failed_queues_.clear();
        const auto device=owner->hid_device_.get_device();
        if (owner->owned_device_scheduled_) {
          if (!device) success=false;
          else {
            if (!owner->input_report_buffer_.empty())
              IOHIDDeviceRegisterInputReportCallback(*device,owner->input_report_buffer_.data(),
                  static_cast<CFIndex>(owner->input_report_buffer_.size()),nullptr,nullptr);
            IOHIDDeviceRegisterRemovalCallback(*device,nullptr,nullptr);
            IOHIDDeviceUnscheduleFromRunLoop(*device,owner->run_loop_thread_->get_run_loop(),kCFRunLoopCommonModes);
            owner->owned_device_scheduled_=false;
          }
        }
        if (options) {
          if (!device) success=false;
          else {
            const auto closed=IOHIDDeviceClose(*device,*options);
            success=success && closed==kIOReturnSuccess;
            if (closed==kIOReturnSuccess) {
              std::lock_guard<std::mutex> lock(owner->open_options_mutex_);
              owner->owned_device_open_options_=std::nullopt;
            }
          }
        }
        {
          std::lock_guard<std::mutex> lock(owner->open_options_mutex_);
          success=success && owner->owned_stop_generation_==generation &&
                  owner->requested_open_options_generation_==generation &&
                  !owner->requested_open_options_;
          owner->owned_queue_open_generation_=0;
          // On native refusal retain the original options as unresolved debt.
          if (success) owner->current_open_options_=std::nullopt;
        }
      }
      // This same dispatcher receives the already queued native input work
      // before the terminal receipt; no independent clock comparison occurs.
      owner->enqueue_to_dispatcher([owner,receiver_lifetime,completion,generation,success] {
        if (success) owner->stopped();
        completion(owned_stop_receipt(owner,generation,success));
      });
    });
    return true;
  }

  [[nodiscard]] bool seized() const {
    std::lock_guard<std::mutex> lock(open_options_mutex_);

    return current_open_options_ != std::nullopt
               ? (*current_open_options_ & kIOHIDOptionsTypeSeizeDevice)
               : false;
  }

private:
  friend class ::krbn::hid_device_events_monitor;
  std::function<bool()> owned_input_scope_;
  bool bind_owned_input_scope(std::function<bool()> scope) {
    if (!dispatcher_thread() || !scope) return false;
    bool current=false;
    try { current=scope(); } catch (...) {}
    if (!current) return false;
    std::lock_guard<std::mutex> lock(open_options_mutex_);
    owned_input_scope_=std::move(scope);
    return true;
  }
  static bool owned_input_scope_current(const std::function<bool()>& scope) noexcept {
    try { return !scope || scope(); } catch (...) { return false; }
  }
  class owned_open_receipt final {
    friend class iokit_hid_device_events_monitor;
    friend class ::krbn::hid_device_events_monitor;
    const std::weak_ptr<iokit_hid_device_events_monitor> monitor_;
    const std::uint64_t generation_;
    const IOOptionBits options_;
    owned_open_receipt(const std::shared_ptr<iokit_hid_device_events_monitor>& monitor,
        std::uint64_t generation,IOOptionBits options)
      :monitor_(monitor),generation_(generation),options_(options) {}
    bool current() const {
      const auto monitor=monitor_.lock();
      if (!monitor) return false;
      std::lock_guard<std::mutex> lock(monitor->open_options_mutex_);
      return generation_ && generation_==monitor->requested_open_options_generation_ &&
        generation_==monitor->owned_queue_open_generation_ && monitor->owned_device_scheduled_ &&
        monitor->requested_open_options_ && monitor->current_open_options_ &&
        monitor->owned_device_open_options_ && *monitor->requested_open_options_==options_ &&
        *monitor->current_open_options_==options_ && *monitor->owned_device_open_options_==options_ &&
        !monitor->owned_queue_failed_;
    }
  };
  std::shared_ptr<const owned_open_receipt> retain_owned_open(
      const std::shared_ptr<iokit_hid_device_events_monitor>& self) {
    if (!dispatcher_thread() || self.get()!=this) return nullptr;
    std::lock_guard<std::mutex> lock(open_options_mutex_);
    if (!requested_open_options_ || !current_open_options_ || !owned_device_open_options_ ||
        *requested_open_options_!=*current_open_options_ ||
        *current_open_options_!=*owned_device_open_options_ || !owned_device_scheduled_ ||
        !owned_queue_open_generation_ || owned_queue_open_generation_!=requested_open_options_generation_ ||
        owned_queue_failed_) return nullptr;
    return std::shared_ptr<const owned_open_receipt>(
      new owned_open_receipt(self,owned_queue_open_generation_,*current_open_options_));
  }

  bool owned_queue_options_current(std::uint64_t generation) const noexcept {
    // Called only while holding the original acquisition mutex.
    return generation && generation==requested_open_options_generation_ && generation==owned_queue_open_generation_ &&
        requested_open_options_ && current_open_options_ &&
        *requested_open_options_==*current_open_options_ && observe_input_values_ &&
        input_report_buffer_.empty() && !owned_queue_failed_;
  }
  bool owned_queue_current(std::uint64_t generation) const noexcept {
    std::lock_guard<std::mutex> lock(open_options_mutex_);
    return owned_queue_options_current(generation);
  }
  bool owned_queue_failed_=false;
  std::uint64_t owned_queue_open_generation_=0;

  void schedule_device() {
    if (auto d = hid_device_.get_device()) {
      if (!input_report_buffer_.empty()) {
        IOHIDDeviceRegisterInputReportCallback(*d,
                                               input_report_buffer_.data(),
                                               static_cast<CFIndex>(input_report_buffer_.size()),
                                               static_input_report_callback,
                                               this);
      }

      IOHIDDeviceRegisterRemovalCallback(*d,
                                         static_device_removal_callback,
                                         this);

      IOHIDDeviceScheduleWithRunLoop(*d,
                                     run_loop_thread_->get_run_loop(),
                                     kCFRunLoopCommonModes);
      owned_device_scheduled_=true;
    }
  }

  void cleanup_device() {
    stop({.reason = stop_reason::cleanup});

    if (auto d = hid_device_.get_device()) {
      if (!input_report_buffer_.empty()) {
        IOHIDDeviceRegisterInputReportCallback(*d,
                                               input_report_buffer_.data(),
                                               static_cast<CFIndex>(input_report_buffer_.size()),
                                               nullptr,
                                               nullptr);
      }

      IOHIDDeviceUnscheduleFromRunLoop(*d,
                                       run_loop_thread_->get_run_loop(),
                                       kCFRunLoopCommonModes);
      owned_device_scheduled_=false;
    }
  }

  void start() {
    bool needs_stop = false;
    IOOptionBits open_options = kIOHIDOptionsTypeNone;
    std::uint64_t owned_queue_open_generation=0;
    std::function<bool()> owned_scope;

    auto device = hid_device_.get_device();
    if (!device) {
      goto finish;
    }

    //
    // Check requested_open_options_
    //

    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      if (requested_open_options_ == std::nullopt ||
          requested_open_options_ == current_open_options_) {
        goto finish;
      }

      if (current_open_options_) {
        needs_stop = true;
      }

      open_options = *requested_open_options_;
      owned_queue_open_generation=requested_open_options_generation_;
      owned_scope=owned_input_scope_;
    }

    if (needs_stop) {
      stop({.reason = stop_reason::reopen});
    }
    if (!owned_input_scope_current(owned_scope)) goto finish;

    //
    // Open the device
    //

    // Start queue before `IOHIDDeviceOpen` in order to avoid events drop.
    if (observe_input_values_ && !start_input_values_queue()) {
      enqueue_to_dispatcher([this] {
        // A null create has no native IOReturn; report only the observed failure.
        error_occurred("IOHIDQueueCreate returned null.", kIOReturnError);
      });
      // Preserve the existing open timer's retry and requested-options ownership.
      return;
    }

    if (!owned_input_scope_current(owned_scope)) {
      stop({.reason = stop_reason::reopen});
      goto finish;
    }
    {
      iokit_return r = IOHIDDeviceOpen(*device,
                                       open_options);
      if (!r) {
        if (last_open_error_ != r) {
          last_open_error_ = r;
          enqueue_to_dispatcher([this, r] {
            error_occurred("IOHIDDeviceOpen is failed.", r);
          });
        }

        // Retry
        return;
      }
    }

    last_open_error_ = kIOReturnSuccess;

    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      current_open_options_ = open_options;
      owned_device_open_options_ = open_options; // only after actual Open success
      owned_queue_open_generation_=owned_queue_open_generation;
    }
    if (!owned_input_scope_current(owned_scope)) {
      // Close only this already-opened original owner. No startup receipt is
      // emitted; original native close refusal remains retained cleanup debt.
      stop({.reason = stop_reason::reopen});
      goto finish;
    }

    if (!input_report_buffer_.empty() &&
        input_report_filter_started_) {
      try {
        input_report_filter_started_();
      } catch (...) {
        // Ignore exceptions from the lifecycle callback.
      }
    }

    enqueue_to_dispatcher([this] {
      started();
    });

  finish:
    open_timer_.stop();
  }

  enum class stop_reason {
    async_stop,
    reopen,
    device_removal,
    cleanup,
  };

  struct stop_arguments final {
    stop_reason reason;
    std::optional<uint64_t> requested_open_options_generation;
  };

  void stop(stop_arguments args) {
    // Since `stop()` can be called from within `start()`,
    // we must not stop `open_timer_` in `stop()` in order to preserve the retry when `IOHIDDeviceOpen` error.

    std::optional<IOOptionBits> open_options;
    bool should_emit_stopped = false;

    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      switch (args.reason) {
        case stop_reason::async_stop:
          // Ignore this asynchronous stop if it has been superseded by a newer start or stop request.
          if (requested_open_options_ ||
              args.requested_open_options_generation != requested_open_options_generation_) {
            return;
          }
          should_emit_stopped = true;
          break;

        case stop_reason::reopen:
          should_emit_stopped = current_open_options_.has_value();
          break;

        case stop_reason::device_removal:
          should_emit_stopped = requested_open_options_.has_value() ||
                                current_open_options_.has_value() ||
                                input_values_queue_;
          requested_open_options_ = std::nullopt;
          ++requested_open_options_generation_;
          break;

        case stop_reason::cleanup:
          requested_open_options_ = std::nullopt;
          ++requested_open_options_generation_;
          break;
      }

      open_options = current_open_options_;
      owned_queue_open_generation_=0;
    }

    //
    // The stop request is valid at this point, so release the resources and close the device.
    //

    // Stop value delivery before closing the device to prevent callbacks during IOHIDDeviceClose.
    stop_input_values_queue();

    auto device = hid_device_.get_device();
    if (device && open_options) {
      const auto closed=IOHIDDeviceClose(*device,
                                          *open_options);
      if (closed==kIOReturnSuccess) {
        std::lock_guard<std::mutex> lock(open_options_mutex_);
        owned_device_open_options_=std::nullopt;
      }
    }

    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      current_open_options_ = std::nullopt;
    }

    if (should_emit_stopped) {
      enqueue_to_dispatcher([this] {
        stopped();
      });
    }
  }

  bool start_input_values_queue() {
    if (!input_values_queue_) {
      const CFIndex depth = 1024;
      input_values_queue_ = hid_device_.make_queue(depth);

      if (input_values_queue_) {
        for (const auto& e : hid_device_.make_elements()) {
          IOHIDQueueAddElement(*input_values_queue_, *e);
        }

        IOHIDQueueRegisterValueAvailableCallback(*input_values_queue_,
                                                 static_input_values_available_callback,
                                                 this);

        IOHIDQueueScheduleWithRunLoop(*input_values_queue_,
                                      run_loop_thread_->get_run_loop(),
                                      kCFRunLoopCommonModes);

        IOHIDQueueStart(*input_values_queue_);
      }
    }
    return static_cast<bool>(input_values_queue_);
  }

  void stop_input_values_queue() {
    if (input_values_queue_) {
      const auto stopped=IOHIDQueueStop(*input_values_queue_);
      if (stopped!=kIOReturnSuccess) {
        try { owned_failed_queues_.push_back(input_values_queue_); }
        catch (...) { owned_retirement_failed_=true; }
      }

      // IOHIDQueueUnscheduleFromRunLoop might cause SIGSEGV if it is not called in run_loop_thread_.

      IOHIDQueueUnscheduleFromRunLoop(*input_values_queue_,
                                      run_loop_thread_->get_run_loop(),
                                      kCFRunLoopCommonModes);

      input_values_queue_ = nullptr;
    }
  }

  static void static_device_removal_callback(void* context,
                                             IOReturn result,
                                             void* sender) {
    if (result != kIOReturnSuccess) {
      return;
    }

    auto self = static_cast<iokit_hid_device_events_monitor*>(context);
    if (!self) {
      return;
    }

    self->device_removal_callback();
  }

  void device_removal_callback() {
    stop({.reason = stop_reason::device_removal});
  }

  static void static_input_values_available_callback(void* context,
                                                     IOReturn result,
                                                     void* sender) {
    auto self = static_cast<iokit_hid_device_events_monitor*>(context);
    if (!self) {
      return;
    }

    if (result != kIOReturnSuccess) {
      self->input_values_error_callback(result);
      return;
    }

    self->input_values_available_callback();
  }

  void input_values_error_callback(IOReturn result) {
    { std::lock_guard<std::mutex> lock(open_options_mutex_); if (current_open_options_) owned_queue_failed_=true; }
    // IOKit may invoke callbacks while device open has failed or stopped.
    // Preserve closed-device silence and the original dispatcher signal.
    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);
      if (!current_open_options_) {
        return;
      }
    }

    iokit_return r = result;
    enqueue_to_dispatcher([this, r] {
      error_occurred("input values callback error", r);
    });
  }

  void input_values_available_callback() {
    if (input_values_queue_) {
      not_null_shared_ptr_t<std::vector<cf::cf_ptr<IOHIDValueRef>>> values = std::make_shared<std::vector<cf::cf_ptr<IOHIDValueRef>>>();

      while (auto v = cf::adopt_cf_ptr(IOHIDQueueCopyNextValueWithTimeout(*input_values_queue_, 0.0))) {
        values->emplace_back(std::move(v));
      }

      // macOS Catalina (10.15) call the `ValueAvailableCallback`
      // even if `IOHIDDeviceOpen` is failed. (A bug of macOS)
      // Thus, we should ignore the events when `IOHIDDeviceOpen` is failed.
      // (== open_options_ == std::nullopt)

      {
        std::lock_guard<std::mutex> lock(open_options_mutex_);

        if (!current_open_options_) {
          return;
        }
      }

      enqueue_to_dispatcher([this, values] {
        input_values_arrived(values);
      });
    }
  }

  static void static_input_report_callback(void* context,
                                           IOReturn result,
                                           void* sender,
                                           IOHIDReportType type,
                                           uint32_t report_id,
                                           uint8_t* report,
                                           CFIndex report_length) {
    auto self = static_cast<iokit_hid_device_events_monitor*>(context);
    if (!self) {
      return;
    }

    if (result != kIOReturnSuccess) {
      self->input_report_error_callback(result);
      return;
    }

    if (type != kIOHIDReportTypeInput ||
        report == nullptr ||
        report_length < 0) {
      return;
    }

    self->input_report_callback(report_id,
                                std::span<const uint8_t>(report,
                                                         static_cast<size_t>(report_length)));
  }

  void input_report_error_callback(IOReturn result) {
    // The input report callback is registered before IOHIDDeviceOpen and remains
    // registered while the device is closed. Report errors should be emitted
    // only while the device is successfully open.
    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      if (!current_open_options_) {
        return;
      }
    }

    iokit_return r = result;
    enqueue_to_dispatcher([this, r] {
      error_occurred("input report callback error", r);
    });
  }

  void input_report_callback(uint32_t report_id,
                             std::span<const uint8_t> report) {
    // macOS may invoke callbacks even if IOHIDDeviceOpen failed. Apply the same
    // guard used by input_values_available_callback.
    {
      std::lock_guard<std::mutex> lock(open_options_mutex_);

      if (!current_open_options_) {
        return;
      }
    }

    // Capture the arrival time in run_loop_thread_ before filtering and
    // dispatching, so dispatcher congestion does not change the event time.
    auto time_stamp = chrono::mach_absolute_time_point();

    // Run the filter before copying the borrowed IOKit buffer or enqueueing work
    // to the dispatcher. The filter is invoked synchronously in run_loop_thread_.
    if (input_report_filter_) {
      try {
        if (!input_report_filter_(report_id, report)) {
          return;
        }
      } catch (...) {
        // Treat filter exceptions as rejected reports.
        return;
      }
    }

    auto report_copy = std::make_shared<std::vector<uint8_t>>(report.begin(),
                                                              report.end());

    enqueue_to_dispatcher([this, report_id, report_copy, time_stamp] {
      input_report_arrived(report_id,
                           std::span<const uint8_t>(*report_copy),
                           time_stamp);
    });
  }

  not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread_;

  iokit_hid_device hid_device_;
  dispatcher::extra::timer open_timer_;
  std::optional<IOOptionBits> requested_open_options_;
  uint64_t requested_open_options_generation_{0};
  std::optional<IOOptionBits> current_open_options_;
  bool owned_device_scheduled_=false;
  std::uint64_t owned_stop_generation_=0;
  std::uint64_t owned_stop_admission_generation_=0;
  std::weak_ptr<owned_stop_admission> owned_stop_admission_;
  std::optional<IOOptionBits> owned_device_open_options_;
  std::vector<cf::cf_ptr<IOHIDQueueRef>> owned_failed_queues_;
  bool owned_retirement_failed_=false;
  mutable std::mutex open_options_mutex_;
  iokit_return last_open_error_;
  cf::cf_ptr<IOHIDQueueRef> input_values_queue_;
  bool observe_input_values_;
  std::vector<uint8_t> input_report_buffer_;
  std::function<bool(uint32_t report_id,
                     std::span<const uint8_t> report)>
      input_report_filter_;
  std::function<void()> input_report_filter_started_;
};
} // namespace pqrs::osx
