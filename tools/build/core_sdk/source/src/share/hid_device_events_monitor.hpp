#pragma once

#include "hs274-stream-runtime.hpp"
#include "hs274-stream-baseline-probe.hpp"
#include "hs274-stream-key-policy.hpp"

#include "device_properties.hpp"
#include "hid_report_only_events.hpp"
#include <chrono>
#include <functional>
#include <memory>
#include <nod/nod.hpp>
#include <pqrs/cf/run_loop_thread.hpp>
#include <pqrs/dispatcher.hpp>
#include <pqrs/gsl.hpp>
#include <pqrs/osx/iokit_hid_device_events_monitor.hpp>
#include <pqrs/osx/iokit_hid_value.hpp>
#include <pqrs/osx/iokit_return.hpp>
#include <string>
#include <vector>

namespace krbn::core_service::daemon { class device_grabber; }

namespace krbn {
// Publishes the values exposed by IOHIDQueue and, when enabled, events recovered
// directly from raw input reports through one chronologically consistent stream.
class hid_device_events_monitor final : public pqrs::dispatcher::extra::dispatcher_client {
  friend class core_service::daemon::device_grabber;
  bool bind_owned_input_scope(std::function<bool()> scope) {
    return device_events_monitor_->bind_owned_input_scope(std::move(scope));
  }
  using owned_open_receipt=pqrs::osx::iokit_hid_device_events_monitor::owned_open_receipt;
  std::shared_ptr<const owned_open_receipt> retain_owned_open() {
    return device_events_monitor_->retain_owned_open(device_events_monitor_);
  }
  static bool owned_open_current(const std::shared_ptr<const owned_open_receipt>& receipt) {
    return receipt && receipt->current();
  }
  using owned_stop_receipt=pqrs::osx::iokit_hid_device_events_monitor::owned_stop_receipt;
  using owned_stop_admission=pqrs::osx::iokit_hid_device_events_monitor::owned_stop_admission;
  std::shared_ptr<owned_stop_admission> retain_owned_stop(const std::shared_ptr<hid_device_events_monitor>& self) {
    if (self.get()!=this || !device_events_monitor_ || !dispatcher_thread()) return nullptr;
    return device_events_monitor_->retain_owned_stop(device_events_monitor_,self);
  }
  bool async_owned_stop(const std::shared_ptr<owned_stop_admission>& admission,
                        std::function<void(owned_stop_receipt)> completion) {
    if (!admission || !device_events_monitor_ || !completion || !dispatcher_thread()) return false;
    return device_events_monitor_->async_owned_stop(admission,std::move(completion));
  }
public:
  //
  // Signals (invoked from the shared dispatcher thread)
  //

  nod::signal<void()> started;
  nod::signal<void()> stopped;
  nod::signal<void(pqrs::not_null_shared_ptr_t<std::vector<pqrs::osx::iokit_hid_value>>)> values_arrived;
  nod::signal<void(const std::string&, pqrs::osx::iokit_return)> error_occurred;

  //
  // Methods
  //

  struct configuration final {
    bool enable_input_report_handler = true;
    std::function<void(uint32_t, std::span<const uint8_t>)> input_report_observer;
  };

  hid_device_events_monitor(const hid_device_events_monitor&) = delete;

  hid_device_events_monitor(
      std::weak_ptr<pqrs::dispatcher::dispatcher> weak_dispatcher,
      pqrs::not_null_shared_ptr_t<pqrs::cf::run_loop_thread> run_loop_thread,
      IOHIDDeviceRef device,
      const device_properties& device_properties,
      configuration configuration)
      : dispatcher_client(weak_dispatcher),
        hs274_capture_device_id_(type_safe::get(device_properties.get_device_id())),
        hs274_stream_selected_(!device_properties.get_device_identifiers().get_is_virtual_device()),
        hs274_native_binding_(hs274_stream_selected_ ? device : nullptr, hs274_capture_device_id_),
        hs274_monitor_(hs274_stream_selected_ ? hs274_stream_protocol::runtime::attach(hs274_native_binding_)
                                         : hs274_stream_protocol::runtime::monitor{}),
        last_time_stamp_(0) {
    pqrs::osx::iokit_hid_device_events_monitor::parameters parameters;

    const auto& identifiers = device_properties.get_device_identifiers();
    if (configuration.enable_input_report_handler &&
        hid_report_only_events::is_target_device(identifiers)) {
      // Reading and parsing the descriptor is unnecessary for all other devices.
      auto report_descriptor = find_report_descriptor(device);

      input_report_handler_ =
          hid_report_only_events::make_report_handler(
              identifiers,
              report_descriptor);

      if (input_report_handler_) {
        parameters.input_report_filter_started =
            [handler = input_report_handler_] {
              handler->reset_filter_state();
            };
      }
    }

    if (configuration.input_report_observer || input_report_handler_) {
      parameters.observe_input_reports = true;

      parameters.input_report_filter =
          [observer = std::move(configuration.input_report_observer),
           handler = input_report_handler_](auto report_id, auto report) {
            if (observer) {
              observer(report_id, report);
            }

            return handler && handler->should_accept_report(report_id, report);
          };
    }

    device_events_monitor_ =
        std::make_shared<pqrs::osx::iokit_hid_device_events_monitor>(
            weak_dispatcher,
            run_loop_thread,
            device,
            parameters);

    device_events_monitor_->started.connect([this, device] {
      if (input_report_handler_) {
        // The vendor monitor enqueues started before any input_report_arrived
        // signal from the newly opened device.
        input_report_handler_->reset();
      }

      if (hs274_stream_selected_) {
        hs274_stream_protocol::runtime::started(hs274_monitor_, hs274_native_binding_, device);
      }
      started();
    });

    device_events_monitor_->stopped.connect([this] {
      hs274_monitor_.stopped();
      stopped();
    });

    device_events_monitor_->input_values_arrived.connect([this](auto&& values) {
      auto hid_values = std::make_shared<std::vector<pqrs::osx::iokit_hid_value>>();
      hid_values->reserve(values->size());

      for (const auto& value : *values) {
        // Inspect native metadata before the portable wrapper discards it.
        const auto element = IOHIDValueGetElement(*value);
        const auto usage = IOHIDElementGetUsage(element);
        const auto page = IOHIDElementGetUsagePage(element);
        // Array handlers accompany qualified individual leaves, never keys.
        if (hs274_stream_selected_ && hs274_key_policy::is_button_page(page) &&
            usage != 0 && usage != UINT32_MAX) {
          const auto type = IOHIDElementGetType(element);
          const auto integer = IOHIDValueGetIntegerValue(*value);
          const hs274_stream_protocol::key_element descriptor{
              type >= kIOHIDElementTypeInput_Misc && type <= kIOHIDElementTypeInput_ScanCodes,
              static_cast<bool>(IOHIDElementIsRelative(element)),
              static_cast<bool>(IOHIDElementIsArray(element)),
              IOHIDElementGetReportSize(element), IOHIDElementGetReportCount(element),
              IOHIDElementGetLogicalMin(element), IOHIDElementGetLogicalMax(element)};
          if (!(page == 7 && usage <= 3 && integer == 0) &&
              hs274_key_policy::admit_button(page, usage, descriptor, integer) !=
              hs274_key_policy::button_admission::admitted) {
            // Preserve remapping output, but revoke physical observation readiness.
            hs274_monitor_.stopped();
          }
        }
        hid_values->emplace_back(*value);
      }

      if (hs274_stream_selected_) {
        for (std::size_t index = 0; index < hid_values->size(); ++index) {
          const auto& value = hid_values->at(index);
          // The wrapper drops element identity; use the corresponding native value.
          const auto cookie = IOHIDElementGetCookie(IOHIDValueGetElement(*values->at(index)));
          const auto page = value.get_usage_page();
          const auto usage = value.get_usage();
          hs274_stream_protocol::runtime::append(hs274_monitor_, {
              hs274_capture_device_id_, type_safe::get(value.get_time_stamp()),
              value.get_integer_value(), page.has_value(), usage.has_value(),
              page ? static_cast<std::int32_t>(type_safe::get(*page)) : 0,
              usage ? static_cast<std::int32_t>(type_safe::get(*usage)) : 0,
              0, true, static_cast<std::uint32_t>(cookie)});
        }
      }
      input_values_arrived(hid_values);
    });

    device_events_monitor_->input_report_arrived.connect(
        [this](auto report_id, auto report, auto time_stamp) {
          if (!input_report_handler_) {
            return;
          }

          auto hid_values = std::make_shared<std::vector<pqrs::osx::iokit_hid_value>>(
              input_report_handler_->handle(
                  report_id,
                  report,
                  time_stamp));
          if (hid_values->empty()) {
            return;
          }

          input_values_arrived(hid_values);
        });

    device_events_monitor_->error_occurred.connect([this](auto&& message, auto&& result) {
      hs274_monitor_.stopped();
      error_occurred(message, result);
    });
  }

  ~hid_device_events_monitor() override {
    detach_from_dispatcher([this] {
      hs274_monitor_.retire();
      device_events_monitor_ = nullptr;
    });
  }


  class owned_queue_cut final {
  public:
    owned_queue_cut() = default;
    bool current() const noexcept { return native_.current() && folded_.current(); }
    std::uint64_t device() const noexcept { return folded_.device(); }
    const hs274_stream_protocol::runtime::queue_snapshot& snapshot() const noexcept { return folded_; }
  private:
    friend class hid_device_events_monitor;
    owned_queue_cut(pqrs::osx::iokit_hid_device_events_monitor::owned_queue_receipt native,
                    hs274_stream_protocol::runtime::queue_snapshot folded)
        : native_(std::move(native)),folded_(std::move(folded)) {}
    pqrs::osx::iokit_hid_device_events_monitor::owned_queue_receipt native_;
    hs274_stream_protocol::runtime::queue_snapshot folded_;
  };

  // Preserve both original monitor lifetimes; retaining the native child alone
  // would leave its signal callbacks with a dangling high-level receiver.
  bool async_owned_queue_cut(std::shared_ptr<hid_device_events_monitor> owner,
                            std::function<void(owned_queue_cut)> completion) {
    if (owner.get()!=this || !completion || !dispatcher_thread()) return false;
    auto interval=hs274_monitor_.capture_queue_interval();
    if (!interval.current()) return false;
    return device_events_monitor_->async_owned_queue_cut(device_events_monitor_,owner,
        [owner,interval,completion](auto native) {
          if (!native.current() || !interval.current()) { completion({}); return; }
          hs274_stream_protocol::runtime::queue_snapshot folded;
          try { folded=interval.freeze(mach_absolute_time()); }
          catch (...) { completion({}); return; }
          if (!native.current() || !folded.current()) { completion({}); return; }
          completion(owned_queue_cut(std::move(native),std::move(folded)));
        });
  }

  void async_start(IOOptionBits open_options,
                   std::chrono::milliseconds open_timer_interval) {
    device_events_monitor_->async_start(open_options,
                                        open_timer_interval);
  }

  void async_stop() {
    device_events_monitor_->async_stop();
  }

  [[nodiscard]] bool seized() const {
    return device_events_monitor_->seized();
  }

private:
  void input_values_arrived(
      pqrs::not_null_shared_ptr_t<std::vector<pqrs::osx::iokit_hid_value>> hid_values) {
    normalize_time_stamps(*hid_values);
    values_arrived(hid_values);
  }

  [[nodiscard]] static std::vector<uint8_t> find_report_descriptor(IOHIDDeviceRef device) {
    std::vector<uint8_t> result;

    if (auto property = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey))) {
      if (CFGetTypeID(property) == CFDataGetTypeID()) {
        auto data = static_cast<CFDataRef>(property);
        auto length = CFDataGetLength(data);
        if (length > 0) {
          result.resize(static_cast<size_t>(length));
          CFDataGetBytes(data, CFRangeMake(0, length), result.data());
        }
      }
    }

    return result;
  }

  void normalize_time_stamps(
      std::vector<pqrs::osx::iokit_hid_value>& values) {
    for (auto& value : values) {
      // Some devices send events with a timestamp that is zero, fixed, or moves
      // backwards, possibly due to macOS input event handling.
      //
      // For example, Swiftpoint ProPoint sends pointing events with normal
      // timestamps, but consumer key-up events with a zero or fixed timestamp.
      // Correct backward movement so time-dependent features such as to_if_alone
      // continue to work correctly.
      //
      // The IOHIDQueue and raw-report callbacks can also arrive in either order,
      // even when their events originated in the same input report. Applying the
      // same correction to both sources keeps their combined stream monotonic.
      auto time_stamp = value.get_time_stamp();
      if (time_stamp < last_time_stamp_) {
        value.set_time_stamp(last_time_stamp_);
      } else {
        last_time_stamp_ = time_stamp;
      }
    }
  }

  std::shared_ptr<pqrs::osx::iokit_hid_device_events_monitor> device_events_monitor_;

  // should_accept_report and reset_filter_state access filter state from run_loop_thread, while
  // handle and reset access handler state from the shared dispatcher thread.
  std::shared_ptr<hid_report_only_events::report_handler> input_report_handler_;
  std::uint64_t hs274_capture_device_id_;
  bool hs274_stream_selected_;
  const hs274_stream_protocol::native_binding hs274_native_binding_;
  hs274_stream_protocol::runtime::monitor hs274_monitor_;
  pqrs::osx::chrono::absolute_time_point last_time_stamp_;
};
} // namespace krbn
