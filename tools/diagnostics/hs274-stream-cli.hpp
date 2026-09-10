// tools/diagnostics/hs274-stream-cli.hpp
// Experimental CLI: one request and one output batch at a time.
#pragma once

#include "core_service_daemon_client.hpp"
#include "termination_signal_monitor.hpp"
#include "hs274-stream-readiness.hpp"
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <fcntl.h>
#include <iostream>
#include <mutex>
#include <optional>
#include <poll.h>
#include <unistd.h>

namespace krbn::cli::hs274_capture {
using json = nlohmann::json;

class exchange final {
public:
  exchange() {
    client_.connected.connect([this] {
      std::lock_guard lock(mutex_);
      if (connected_) error_ = "Unexpected capture reconnect";
      connected_ = true;
      condition_.notify_all();
    });
    client_.connect_failed.connect([this](const auto& error) { fail(error.message()); });
    client_.closed.connect([this] { fail("Capture connection closed"); });
    client_.received.connect([this](auto operation, const auto& message) {
      if (operation != operation_type::hs274_capture) return;
      std::lock_guard lock(mutex_);
      try {
        if (!pending_ || response_) throw std::runtime_error("Unsolicited capture response");
        response_ = message.at("capture");
      } catch (const std::exception& error) {
        error_ = error.what();
      }
      condition_.notify_all();
    });
    client_.async_start();
  }

  ~exchange() { client_.unregister_callbacks_and_detach(); }

  void stop(int signal) {
    std::lock_guard lock(mutex_);
    stopped_ = signal;
    condition_.notify_all();
  }

  int stopped() const {
    std::lock_guard lock(mutex_);
    return stopped_;
  }

  void check() const {
    std::lock_guard lock(mutex_);
    check_locked();
  }

  json request(json message, std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + timeout()) {
    std::unique_lock lock(mutex_);
    wait(lock, deadline, [this] { return connected_; });
    if (pending_) throw std::logic_error("Capture request already pending");
    pending_ = true;
    client_.async_hs274_capture(std::move(message), [this](const auto& error) {
      if (error) fail(error.message());
    });
    wait(lock, deadline, [this] { return response_.has_value(); });
    auto result = std::move(*response_);
    response_.reset();
    pending_ = false;
    return result;
  }

  void pause(std::chrono::milliseconds interval) {
    std::unique_lock lock(mutex_);
    condition_.wait_for(lock, interval, [this] { return stopped_ || !error_.empty(); });
    check_locked();
  }

  static std::chrono::milliseconds timeout() { return constants::get_unix_domain_stream_client_options().write_timeout; }

private:
  void fail(const std::string& reason) {
    std::lock_guard lock(mutex_);
    error_ = reason;
    condition_.notify_all();
  }

  void check_locked() const {
    if (stopped_) throw std::runtime_error("Capture stopped");
    if (!error_.empty()) throw std::runtime_error(error_);
  }

  template <typename Predicate>
  void wait(std::unique_lock<std::mutex>& lock, std::chrono::steady_clock::time_point deadline, Predicate ready) {
    if (!condition_.wait_until(lock, deadline, [&] { return ready() || stopped_ || !error_.empty(); })) {
      throw std::runtime_error("Capture response timeout");
    }
    check_locked();
    if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Capture response timeout");
  }

  mutable std::mutex mutex_;
  std::condition_variable condition_;
  bool connected_ = false, pending_ = false;
  int stopped_ = 0;
  std::string error_;
  std::optional<json> response_;
  // Destroy callbacks before the state they capture, including on construction failure.
  core_service_daemon_client client_;
};

class output final {
public:
  output() {
    descriptor_ = dup(STDOUT_FILENO);
    if (descriptor_ < 0) throw std::runtime_error("Cannot preserve capture stdout");
    flags_ = fcntl(descriptor_, F_GETFL);
    if (flags_ < 0 || fcntl(descriptor_, F_SETFL, flags_ | O_NONBLOCK) < 0 ||
        dup2(STDERR_FILENO, STDOUT_FILENO) < 0) {
      if (flags_ >= 0 && fcntl(descriptor_, F_SETFL, flags_) < 0) std::terminate();
      close(descriptor_);
      throw std::runtime_error("Cannot isolate capture output");
    }
    // This dedicated CLI mode keeps all existing logger stdout on stderr.
  }
  output(const output&) = delete;
  output& operator=(const output&) = delete;
  ~output() {
    // dup shares file status flags with inherited descriptors (including a tty).
    if (fcntl(descriptor_, F_SETFL, flags_) < 0) std::terminate();
    close(descriptor_);
  }

  void publish(const json& message, const exchange& client) {
    const auto line = message.dump() + "\n";
    const auto deadline = std::chrono::steady_clock::now() + exchange::timeout();
    std::size_t offset = 0;
    while (offset < line.size()) {
      client.check();
      if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Capture output timeout");
      pollfd descriptor{descriptor_, POLLOUT, 0};
      // Bound stop latency while a downstream reader has stopped consuming.
      const auto result = poll(&descriptor, 1, 100);
      if (result < 0 && errno == EINTR) continue;
      if (result < 0 || (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL))) {
        throw std::runtime_error("Capture output disconnected");
      }
      if (!result) continue;
      const auto written = write(descriptor_, line.data() + offset, line.size() - offset);
      if (written < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
      if (written <= 0) throw std::runtime_error("Capture output write failed");
      offset += static_cast<std::size_t>(written);
    }
  }

private:
  int descriptor_ = -1;
  int flags_ = -1;
};

inline int run(int interval) {
  if (interval <= 0) throw std::invalid_argument("Capture polling interval must be positive");
  output writer;
  exchange client;
  termination_signal_monitor signals([&client](int number) { client.stop(number); });
  try {
    const auto deadline = std::chrono::steady_clock::now() + exchange::timeout();
    const auto prepared = client.request({{"version", 1u}, {"action", "prepare"}}, deadline);
    if (!prepared.is_object() || prepared.size() != 5 || prepared.at("kind") != "prepared" ||
        prepared.at("coverage") != "fixture_only" || !prepared.at("version").is_number_unsigned() ||
        !prepared.at("incarnation").is_string() || prepared.at("incarnation").get_ref<const std::string&>().empty() ||
        prepared.at("version") != 1u || !hs274_stream_protocol::decimal(prepared.at("preparation"))) {
      throw std::runtime_error("Invalid observation preparation");
    }
    const auto incarnation = hs274_stream_protocol::await_readiness(client, std::chrono::milliseconds(interval), deadline);
    if (prepared.at("incarnation") != incarnation) throw std::runtime_error("Preparation changed producer");
    const auto opened = client.request({{"version", 1u}, {"action", "open"},
                                       {"incarnation", incarnation}, {"preparation", prepared.at("preparation")}}, deadline);
    if (opened.at("kind") != "opened" || opened.at("coverage") != "fixture_only" ||
        opened.at("version") != 1u || !opened.at("lease").is_string() || opened.at("incarnation") != incarnation) {
      throw std::runtime_error("Invalid capture handshake");
    }
    writer.publish(opened, client);
    json request{{"version", 1u}, {"action", "pull"},
                 {"incarnation", opened.at("incarnation")}, {"lease", opened.at("lease")}};
    for (;;) {
      auto response = client.request(request);
      if (response.at("incarnation") != opened.at("incarnation") || response.at("lease") != opened.at("lease") ||
          response.at("version") != 1u || response.at("coverage") != "fixture_only") {
        throw std::runtime_error("Capture response changed session identity");
      }
      if (response.at("kind") == "lost") {
        writer.publish(response, client);
        throw std::runtime_error("Physical capture coverage lost");
      }
      if (response.at("kind") != "batch" || !response.at("records").is_array()) {
        throw std::runtime_error("Invalid capture batch");
      }
      request.erase("ack");
      if (!response.at("records").empty()) {
        writer.publish(response, client);
        request["ack"] = response.at("records").back().at("sequence");
      } else {
        client.pause(std::chrono::milliseconds(interval));
      }
    }
  } catch (const std::exception& error) {
    if (const auto signal = client.stopped()) return 128 + signal;
    std::cerr << "Physical capture failed: " << error.what() << std::endl;
    return 1;
  }
}
} // namespace krbn::cli::hs274_capture
