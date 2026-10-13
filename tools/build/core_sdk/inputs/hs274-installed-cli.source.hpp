// tools/diagnostics/hs274-installed-cli.hpp
// Installed-only capture keeps native peer admission and full retirement separate.
#pragma once
#include "hs274-stream-cli.hpp"
#include "hs274-installed-readiness.hpp"
#include "hs274-installed-baseline-client.hpp"
#include "remap_runtime_installed_capture.hpp"
#include <utility>
#include <exception>
#include <algorithm>
namespace krbn::cli::installed_capture {
using json=nlohmann::json;
class exchange final {
public:
  explicit exchange(const ergoptiplus::installed_capture::owner& owner) : owner_(owner) {
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
    const bool first_prepare=message.at("action")=="prepare_installed" && !preparation_started_;
    if (first_prepare) { preparation_started_=true; preparing_=true; }
    wait(lock, deadline, [this] { return connected_; });
    if (retiring_) throw std::logic_error("Ordinary installed request after retirement admission");
    if (pending_) throw std::logic_error("Capture request already pending");
    pending_action_=message.at("action").get<std::string>();
    pending_ = true;
    client_.async_hs274_capture(std::move(message), [this](const auto& error) {
      if (error) fail(error.message());
    });
    wait(lock, deadline, [this] { return response_.has_value(); });
    auto result = std::move(*response_);
    response_.reset();
    pending_ = false;
    preparing_=false;
    return result;
  }

  void pause(std::chrono::milliseconds interval) {
    std::unique_lock lock(mutex_);
    condition_.wait_for(lock, interval, [this] { return stopped_ || !error_.empty(); });
    check_locked();
  }

  // This continuation keeps the original socket and pending request. Stop never
  // clears a response debt or permits an ordinary new capture request.
  std::optional<std::pair<std::string,json>> begin_retirement(std::chrono::steady_clock::time_point deadline) {
    std::unique_lock lock(mutex_);
    retiring_=true; preparing_=false;
    check_locked();
    if (!pending_) return std::nullopt;
    wait(lock,deadline,[this] { return response_.has_value(); });
    auto result=std::make_pair(pending_action_,std::move(*response_));
    response_.reset(); pending_=false; pending_action_.clear();
    return result;
  }
  json retire(const json& prepared,std::chrono::steady_clock::time_point deadline) {
    std::unique_lock lock(mutex_);
    if (!retiring_ || pending_) throw std::logic_error("Installed retirement has unsettled original request");
    wait(lock,deadline,[this] { return connected_; });
    pending_=true; pending_action_="retire_installed";
    client_.async_hs274_capture({{"version",1u},{"action","retire_installed"},
        {"incarnation",prepared.at("incarnation")},{"preparation",prepared.at("preparation")}},
        [this](const auto& error) { if (error) fail(error.message()); });
    wait(lock,deadline,[this] { return response_.has_value(); });
    auto result=std::move(*response_);
    response_.reset(); pending_=false; pending_action_.clear();
    return result;
  }

  static std::chrono::milliseconds timeout() { return constants::get_unix_domain_stream_client_options().write_timeout; }

private:
  void fail(const std::string& reason) {
    std::lock_guard lock(mutex_);
    error_ = reason;
    condition_.notify_all();
  }

  void check_locked() const {
    if (!(retiring_ ? owner_.cleanup_current() : owner_.current()))
      throw std::runtime_error("Installed native CLI custody was revoked");
    if (stopped_ && !retiring_ && !preparing_) throw std::runtime_error("Capture stopped");
    if (!error_.empty()) throw std::runtime_error(error_);
  }

  template <typename Predicate>
  void wait(std::unique_lock<std::mutex>& lock, std::chrono::steady_clock::time_point deadline, Predicate ready) {
    if (!condition_.wait_until(lock, deadline, [&] { return ready() || (stopped_ && !retiring_ && !preparing_) || !error_.empty(); })) {
      throw std::runtime_error("Capture response timeout");
    }
    check_locked();
    if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Capture response timeout");
  }

  mutable std::mutex mutex_;
  std::condition_variable condition_;
  const ergoptiplus::installed_capture::owner& owner_;
  bool connected_ = false, pending_ = false, retiring_ = false, preparing_=false, preparation_started_=false;
  std::string pending_action_;
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

inline void await_receipt(const json& expected, const exchange& client) {
  const auto deadline = std::chrono::steady_clock::now() + exchange::timeout();
  hs274_stream_protocol::await_acknowledgement(
      expected, [&]() -> char {
    for (;;) {
      client.check();
      if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Capture acknowledgement timeout");
      pollfd descriptor{STDIN_FILENO, POLLIN, 0};
      const auto result = poll(&descriptor, 1, 100);
      if (result < 0 && errno == EINTR) continue;
      if (result < 0 || (descriptor.revents & (POLLERR | POLLNVAL))) {
        throw std::runtime_error("Capture acknowledgement input failed");
      }
      if (!result) continue;
      char character;
      const auto count = read(STDIN_FILENO, &character, 1);
      if (count < 0 && errno == EINTR) continue;
      if (count != 1) throw std::runtime_error("Capture acknowledgement input closed");
      return character;
    }
  });
}

inline void acknowledge(const json& opened, const json& sequence, const exchange& client) {
  await_receipt(hs274_stream_protocol::acknowledgement(opened, sequence), client);
}

inline void validate_prepared(const json& prepared) {
  if (!prepared.is_object() || prepared.size()!=5 || prepared.at("kind")!="prepared" ||
      prepared.at("coverage")!="pending" || !prepared.at("version").is_number_unsigned() ||
      prepared.at("version")!=1u || !prepared.at("incarnation").is_string() ||
      prepared.at("incarnation").get_ref<const std::string&>().empty() ||
      !hs274_stream_protocol::decimal(prepared.at("preparation")))
    throw std::runtime_error("Invalid installed observation preparation");
}
inline void validate_terminal(const json& prepared,const json& response) {
  validate_prepared(prepared);
  if (!response.is_object() || response.size()!=5 || !response.at("version").is_number_unsigned() ||
      response.at("version")!=1u || response.at("kind")!="cohort_retired" ||
      response.at("incarnation")!=prepared.at("incarnation") ||
      response.at("preparation")!=prepared.at("preparation") ||
      !hs274_stream_protocol::decimal(response.at("cohort")))
    throw std::runtime_error("Installed native cohort retirement refused");
}

// Only a response on this original native prepared socket is projected here.
inline bool observe_configuration(const json& prepared, exchange& client, output& writer,
                                  std::optional<json>& consumed,
                                  std::chrono::steady_clock::time_point deadline) {
  const auto response = client.request({{"version",1u},{"action","configuration_status"},
      {"incarnation",prepared.at("incarnation")},{"preparation",prepared.at("preparation")}}, deadline);
  if (!response.is_object() || !response.at("version").is_number_unsigned() || response.at("version") != 1u
      || response.at("incarnation") != prepared.at("incarnation") || response.at("preparation") != prepared.at("preparation"))
    throw std::runtime_error("Configuration observation changed original preparation");
  if (response.at("kind") == "configuration_pending") {
    if (response.size() != 4) throw std::runtime_error("Invalid pending configuration observation");
    writer.publish(response,client); return false;
  }
  const auto lower_hex = [](const json& field, std::size_t length) {
    if (!field.is_string()) return false;
    const auto& value = field.get_ref<const std::string&>();
    return value.size() == length && std::all_of(value.begin(),value.end(),[](unsigned char ch) {
      return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
    });
  };
  if (response.at("kind") != "configuration_consumed" || response.size() != 7
      || !lower_hex(response.at("configuration_generation"),32)
      || !lower_hex(response.at("configuration_sha256"),64)
      || !hs274_stream_protocol::decimal(response.at("cohort"))
      || (consumed && *consumed != response))
    throw std::runtime_error("Invalid original consumed configuration observation");
  consumed = response;
  writer.publish(response,client); return true;
}

// Installed-only control and ACK records share the original native stdin.
// Mode operands are not owner factories: Core still validates its held source.
class intent_channel final {
public:
  intent_channel(exchange& client,output& writer,const json& prepared,std::optional<json>& consumed,bool& configured_retirement)
      : client_(client),writer_(writer),prepared_(prepared),consumed_(consumed),configured_retirement_(configured_retirement) {}
  int applied_mode() const noexcept { return applied_mode_; }
  void receive(std::chrono::steady_clock::time_point deadline,bool required) {
    auto line=next_line(deadline,required);
    if (!line) return;
    apply(json::parse(*line),deadline);
  }
  void await_receipt(const json& expected) {
    const auto deadline=std::chrono::steady_clock::now()+exchange::timeout();
    for (;;) {
      const auto line=next_line(deadline,true);
      if (!line) throw std::runtime_error("Missing original capture acknowledgement");
      const auto record=json::parse(*line);
      if (record.is_object() && record.value("kind",std::string{})=="configuration_intent") {
        apply(record,deadline); continue;
      }
      // Exact original ACK validator stays whole, including its final LF rule.
      const auto bytes=*line+"\n"; std::size_t offset=0;
      hs274_stream_protocol::await_acknowledgement(expected,[&]() -> char {
        if (offset>=bytes.size()) throw std::runtime_error("Truncated original capture acknowledgement");
        return bytes[offset++];
      });
      if (offset!=bytes.size()) throw std::runtime_error("Trailing original capture acknowledgement bytes");
      return;
    }
  }
private:
  std::optional<std::string> next_line(std::chrono::steady_clock::time_point deadline,bool required) {
    for (;;) {
      client_.check();
      if (std::chrono::steady_clock::now()>=deadline
          || (line_deadline_ && std::chrono::steady_clock::now()>=*line_deadline_))
        throw std::runtime_error("Installed input deadline expired");
      pollfd input{STDIN_FILENO,POLLIN,0};
      const auto result=poll(&input,1,required?100:0);
      if (result<0 && errno==EINTR) continue;
      if (result<0 || (input.revents&(POLLERR|POLLNVAL))) throw std::runtime_error("Installed input refused");
      if (!result) { if (!required) return std::nullopt; continue; }
      char character; const auto count=read(STDIN_FILENO,&character,1);
      if (count<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)) continue;
      if (count!=1) throw std::runtime_error("Installed input closed");
      if (character=='\n') {
        if (line_.empty()) throw std::runtime_error("Empty installed input record");
        auto result=std::move(line_);line_.clear();line_deadline_.reset();return result;
      }
      if (line_.size()>=65536) throw std::runtime_error("Installed input record overflow");
      if (line_.empty()) line_deadline_=deadline;
      line_.push_back(character);
    }
  }
  void apply(const json& intent,std::chrono::steady_clock::time_point deadline) {
    if (!intent.is_object() || intent.size()!=9 || !intent.at("version").is_number_unsigned()
        || intent.at("version")!=1u || intent.at("kind")!="configuration_intent"
        || intent.at("incarnation")!=prepared_.at("incarnation") || intent.at("preparation")!=prepared_.at("preparation")
        || !intent.at("mode").is_number_integer() || intent.at("mode")<0 || intent.at("mode")>2)
      throw std::runtime_error("Invalid original configuration intent");
    const auto request=hs274_stream_protocol::decimal(intent.at("request"));
    (void)hs274_stream_protocol::decimal(intent.at("pause_epoch"));
    if (!request || request<=last_request_) throw std::runtime_error("Repeated original configuration intent");
    // Native Core performs the actual holder/generation/SHA/CMS admission. The
    // input operand cannot substitute that original same prepared owner.
    const auto original_response=client_.request({{"version",1u},{"action","configuration_mode"},
        {"incarnation",prepared_.at("incarnation")},{"preparation",prepared_.at("preparation")},
        {"configuration_generation",intent.at("configuration_generation")},
        {"configuration_sha256",intent.at("configuration_sha256")},{"mode",intent.at("mode")}},deadline);
    const bool unavailable=original_response.is_object() && original_response.value("kind",std::string{})=="configuration_unavailable";
    auto response=original_response;
    if (unavailable) {
      if (response.size()!=8 || response.at("reason")!="vhd_driver_incompatible" || intent.at("mode")==0)
        throw std::runtime_error("Invalid original configuration unavailability");
      response.erase("reason");response["kind"]="configuration_consumed";
    }
    if (!response.is_object() || response.size()!=7 || !response.at("version").is_number_unsigned()
        || response.at("version")!=1u || response.at("kind")!="configuration_consumed"
        || response.at("incarnation")!=prepared_.at("incarnation") || response.at("preparation")!=prepared_.at("preparation")
        || response.at("configuration_generation")!=intent.at("configuration_generation")
        || response.at("configuration_sha256")!=intent.at("configuration_sha256")
        || !hs274_stream_protocol::decimal(response.at("cohort")) || (consumed_ && *consumed_!=response))
      throw std::runtime_error("Original configuration mode readback refused");
    if (unavailable) {
      auto blocked=original_response;blocked["kind"]="configuration_mode_unavailable";
      blocked["mode"]=intent.at("mode");blocked["pause_epoch"]=intent.at("pause_epoch");blocked["request"]=intent.at("request");
      last_request_=request; // Checked negative result cannot replay this same request.
      writer_.publish(blocked,client_);
      return; // No applied_mode_, consumed_, input or retirement success from a diagnostic.
    }
    const int previous_mode=applied_mode_;
    consumed_=response;last_request_=request;
    applied_mode_=intent.at("mode").get<int>();
    auto applied=response;applied["kind"]="configuration_mode_applied";
    applied["mode"]=intent.at("mode");applied["pause_epoch"]=intent.at("pause_epoch");applied["request"]=intent.at("request");
    // Sole source is the exact pending native Core configuration_mode callback.
    writer_.publish(applied,client_);
    if (applied_mode_==0 && previous_mode>0) {
      // This fact derives from the exact original pending mode callback, not
      // the input operand alone. Full original retire_installed still follows.
      configured_retirement_=true;
      throw std::runtime_error("Configured OFF requires original native retirement");
    }
  }
  exchange& client_;output& writer_;const json& prepared_;std::optional<json>& consumed_;
  std::string line_;std::uint64_t last_request_=0;
  std::optional<std::chrono::steady_clock::time_point> line_deadline_;
  bool& configured_retirement_; int applied_mode_=-1;
};

// Original readiness validator remains whole. This installed caller also
// consumes genuine control intent while inventory is legitimately unavailable.
inline std::string await_controlled_readiness(exchange& client,intent_channel& input,
                                             std::chrono::milliseconds interval) {
  hs274_stream_protocol::installed_readiness observation;
  std::optional<std::chrono::steady_clock::time_point> deadline;
  for (;;) {
    input.receive(std::chrono::steady_clock::now()+exchange::timeout(),false);
    if (input.applied_mode()==0) {
      // Initial no-effects OFF is configured data custody only. It cannot
      // publish an empty/complete physical baseline or become mode1 authority.
      client.pause(interval);
      continue;
    }
    if (input.applied_mode()<0) throw std::runtime_error("Missing applied configuration intent");
    if (!deadline) deadline=std::chrono::steady_clock::now()+exchange::timeout();
    if (std::chrono::steady_clock::now()>=*deadline) throw std::runtime_error("Capture readiness timeout");
    const auto response=client.request({{"version",1u},{"action","status"}},*deadline);
    const bool ready=observation.observe(response);
    if (std::chrono::steady_clock::now()>=*deadline) throw std::runtime_error("Capture readiness timeout");
    if (ready) return observation.incarnation();
    client.pause(std::min(interval,std::chrono::duration_cast<std::chrono::milliseconds>(
        *deadline-std::chrono::steady_clock::now())));
  }
}

inline int run(int interval) {
  if (interval<=0) throw std::invalid_argument("Capture polling interval must be positive");
  auto native=ergoptiplus::installed_capture::owner::acquire();
  if (!native || !native->current()) throw std::runtime_error("Original installed CLI owner refused");
  output writer;
  exchange client(*native);
  termination_signal_monitor signals([&client](int number) { client.stop(number); });
  std::optional<json> prepared;
  std::optional<json> opened;
  std::optional<json> consumed;
  bool prepared_published=false, configured_retirement=false;
  try {
    auto deadline=std::chrono::steady_clock::now()+exchange::timeout();
    const auto response=client.request({{"version",1u},{"action","prepare_installed"}},deadline);
    validate_prepared(response); prepared=response;
    // The native registry consumes this private control record. It is never
    // forwarded as a Lua baseline or accepted from a public caller table.
    writer.publish(*prepared,client); prepared_published=true;
    intent_channel input(client,writer,*prepared,consumed,configured_retirement);
    input.receive(deadline,true);
    const auto incarnation=await_controlled_readiness(client,input,std::chrono::milliseconds(interval));
    deadline=std::chrono::steady_clock::now()+exchange::timeout();
    if (prepared->at("incarnation")!=incarnation) throw std::runtime_error("Preparation changed producer");
    while (!observe_configuration(*prepared,client,writer,consumed,deadline)) {
      if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Configuration consumption timeout");
      client.pause(std::chrono::milliseconds(interval));
    }
    opened=client.request({{"version",1u},{"action","open_installed"},
        {"incarnation",incarnation},{"preparation",prepared->at("preparation")}},deadline);
    const auto cut=hs274_stream_protocol::validate_installed_opened(*opened);
    if (opened->at("incarnation")!=incarnation) throw std::runtime_error("Opening changed producer");
    writer.publish(*opened,client);
    input.await_receipt(hs274_stream_protocol::acknowledgement(*opened,"0"));
    hs274_stream_protocol::transfer_installed_baseline<64>(*opened,
        [&](const json& request) { return client.request(request); },
        [&](const json& frame) { writer.publish(frame,client); },
        [&](const json& receipt) { input.await_receipt(receipt); });
    json request{{"version",1u},{"action","pull"},
        {"incarnation",opened->at("incarnation")},{"lease",opened->at("lease")}};
    for (;;) {
      input.receive(std::chrono::steady_clock::now()+exchange::timeout(),false);
      if (!observe_configuration(*prepared,client,writer,consumed,std::chrono::steady_clock::now()+exchange::timeout()))
        throw std::runtime_error("Original configured engine observation was lost");
      const auto frame=client.request(request);
      if (!frame.is_object() || frame.size()!=7 ||
          frame.at("version").type()!=opened->at("version").type() || frame.at("version")!=1u ||
          frame.at("coverage")!="complete" || frame.at("incarnation")!=opened->at("incarnation") ||
          frame.at("lease")!=opened->at("lease") || frame.at("baseline_sequence")!=opened->at("baseline_sequence"))
        throw std::runtime_error("Installed capture changed original lease or cut");
      if (frame.at("kind")=="lost") {
        if (!frame.at("reason").is_string()) throw std::runtime_error("Invalid installed loss");
        writer.publish(frame,client);
        throw std::runtime_error("Physical capture coverage lost");
      }
      if (frame.at("kind")!="batch" || !frame.at("records").is_array())
        throw std::runtime_error("Invalid installed capture batch");
      request.erase("ack");
      if (!frame.at("records").empty()) {
        const auto last=frame.at("records").back().at("sequence");
        if (hs274_stream_protocol::decimal(last)<=cut) throw std::runtime_error("Capture repeated baseline prefix");
        writer.publish(frame,client);
        input.await_receipt(hs274_stream_protocol::acknowledgement(*opened,last));
        request["ack"]=last;
      } else { client.pause(std::chrono::milliseconds(interval)); }
    }
  } catch (...) {
    // Stop only closes active admission. The same authenticated connection and
    // actual pending request remain available for the bounded terminal join.
    const auto failure=std::current_exception();
    try {
      const auto deadline=std::chrono::steady_clock::now()+exchange::timeout();
      if (const auto pending=client.begin_retirement(deadline)) {
        if (pending->first=="prepare_installed") {
          validate_prepared(pending->second);
          if (prepared && *prepared!=pending->second) throw std::runtime_error("Preparation was replaced");
          prepared=pending->second;
        }
      }
      if (!prepared) throw std::runtime_error("No authentic preparation for native retirement");
      if (!prepared_published) { writer.publish(*prepared,client); prepared_published=true; }
      const auto terminal=client.retire(*prepared,deadline);
      validate_terminal(*prepared,terminal);
      if (consumed && terminal.at("cohort") != consumed->at("cohort"))
        throw std::runtime_error("Retirement changed configured native cohort");
      // Sole source of this record is the original authenticated Core response.
      // Stream EOF or a child exit cannot synthesize it.
      writer.publish(terminal,client);
      if (client.stopped() || configured_retirement) return 0;
    } catch (...) {
      // Native Core self-custody keeps unacknowledged participants and SH debt.
      // Refusal is not a successful source or namespace terminal receipt.
      return 70;
    }
    try { std::rethrow_exception(failure); }
    catch (const std::exception&) { return 1; }
    catch (...) { return 1; }
  }
}
} // namespace krbn::cli::installed_capture
