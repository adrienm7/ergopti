// Generated from the fixed original installed CLI implementation.
#pragma once

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
