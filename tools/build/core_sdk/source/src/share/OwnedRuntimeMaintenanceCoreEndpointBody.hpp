// Included after the genuine Core receiver definition, never a replacement receiver.
#pragma once
namespace ergoptiplus::installed_maintenance {
inline core_endpoint::core_endpoint(::krbn::core_service::daemon::receiver& receiver,uid_t uid)
  :receiver_(&receiver),uid_(uid) {}
inline std::shared_ptr<core_endpoint> core_endpoint::acquire(
    ::krbn::core_service::daemon::receiver& receiver,std::optional<uid_t> uid) noexcept {
  std::shared_ptr<core_endpoint> result;
  try {
    const auto installed=ergoptiplus::installed_capture::local_fixed_core_location();
    if (getuid()!=0 || geteuid()!=0 || !uid || *uid==0 || !installed || !*installed) return nullptr;
    result=std::shared_ptr<core_endpoint>(new core_endpoint(receiver,*uid));
    result->custody_=result; // Before acquiring any native descriptor.
    result->anchor_=std::shared_ptr<native_socket>(new native_socket);
    result->anchor_->custody_=result->anchor_;
    if (!result->anchor_->anchor_parent() || !result->bind_fixed() || !result->arm()) {
      result->stop(); return nullptr;
    }
    receiver.hs274_capture_.maintenance_endpoint_=result;
    return result;
  } catch (...) { if (result) result->stop(); return nullptr; }
}
inline bool core_endpoint::bind_fixed() {
  if (!anchor_ || !anchor_->parent_current()) return false;
  struct stat existing{};
  if (fstatat(anchor_->parent_.back(),".runtime-maintenance.sock",&existing,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT)
    return false; // Never unlink another endpoint or infer an abandoned owner.
  listener_=::socket(AF_UNIX,SOCK_STREAM,0);
  if (listener_<0 || fcntl(listener_,F_SETFD,FD_CLOEXEC)!=0) return false;
  const int flags=fcntl(listener_,F_GETFL); int enabled=1;
  if (flags<0 || fcntl(listener_,F_SETFL,flags|O_NONBLOCK)!=0 ||
      setsockopt(listener_,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled))!=0 ||
      fstat(listener_,&listener_identity_)!=0) return false;
  sockaddr_un address{}; address.sun_family=AF_UNIX;
  constexpr auto length=sizeof(ERGOPTI_OWNED_MAINTENANCE_SOCKET)-1;
  static_assert(length<sizeof(address.sun_path));
  std::memcpy(address.sun_path,ERGOPTI_OWNED_MAINTENANCE_SOCKET,length+1);
  address.sun_len=static_cast<std::uint8_t>(offsetof(sockaddr_un,sun_path)+length+1);
  if (::bind(listener_,reinterpret_cast<sockaddr*>(&address),address.sun_len)!=0) return false;
  bound_=true;
  if (fstatat(anchor_->parent_.back(),".runtime-maintenance.sock",&named_identity_,AT_SYMLINK_NOFOLLOW)!=0 ||
      !S_ISSOCK(named_identity_.st_mode)) return false;
  // The protected root parent prevents user replacement; listen begins only
  // after original console ownership and the exact mode have been checked.
  if (fchownat(anchor_->parent_.back(),".runtime-maintenance.sock",uid_,0,AT_SYMLINK_NOFOLLOW)!=0 ||
      fchmodat(anchor_->parent_.back(),".runtime-maintenance.sock",0600,0)!=0 ||
      fstatat(anchor_->parent_.back(),".runtime-maintenance.sock",&named_identity_,AT_SYMLINK_NOFOLLOW)!=0 ||
      !named_current() || ::listen(listener_,8)!=0) return false;
  return true;
}
inline bool core_endpoint::named_current() const {
  struct stat named{},held{};
  return anchor_ && anchor_->parent_current() && listener_>=0 &&
    fstat(listener_,&held)==0 && held.st_dev==listener_identity_.st_dev && held.st_ino==listener_identity_.st_ino &&
    fstatat(anchor_->parent_.back(),".runtime-maintenance.sock",&named,AT_SYMLINK_NOFOLLOW)==0 &&
    S_ISSOCK(named.st_mode) && named.st_dev==named_identity_.st_dev && named.st_ino==named_identity_.st_ino &&
    named.st_uid==uid_ && named.st_gid==0 && (named.st_mode&07777)==0600;
}
inline bool core_endpoint::arm() {
  if (stopping_) return false;
  const auto self=shared_from_this();
  return receiver_->enqueue_to_dispatcher([self] { self->tick(); },
    receiver_->when_now()+std::chrono::milliseconds(25));
}
inline void core_endpoint::tick() noexcept {
  if (stopping_) return;
  try {
    if (!receiver_->installed_receiver_alive_->load() || !named_current()) { failed_=true; stop(); return; }
    for (const auto& original:exits_) {
      bool closed_history=original->observed && original->close_attempted && !original->close_refused && !original->failed;
      bool found=false;
      for (const auto& record:records_) if (record->exit==original) {
        found=true; if (!record->enrollment_closed) closed_history=false;
      }
      if (found && closed_history) continue;
      if (!poll_issuer_exit(*original)) { failed_=true; stop(); return; }
    }
    capture_terminals();
    accept_one();
    for (auto& client:streams_) {
      if (!client.socket) continue;
      if (!advance(client)) {
        if (!close_stream(client)) { failed_=close_refused_=true; continue; }
        client=stream{};
      }
    }
    capture_parent_terminals();
    if (!arm()) { failed_=true; stop(); }
  } catch (...) { failed_=true; stop(); }
}
inline bool core_endpoint::same_binding(const issuer_lineage& first,const issuer_lineage& second) {
  return first.hs_==second.hs_ && first.uid_==second.uid_ && first.gid_==second.gid_ &&
    first.hs_path_==second.hs_path_ && first.leaf_==second.leaf_;
}
inline std::optional<std::uint64_t> core_endpoint::decimal(const json& value) {
  if (!value.is_string()) return std::nullopt;
  const auto text=value.get<std::string>();
  if (text.empty() || text.front()=='0' || text.size()>20) return std::nullopt;
  std::uint64_t result=0;
  for (auto ch:text) {
    if (ch<'0' || ch>'9' || result>(UINT64_MAX-(ch-'0'))/10) return std::nullopt;
    result=result*10+(ch-'0');
  }
  return result;
}
inline std::optional<wire_frame::incarnation_type> core_endpoint::incarnation(const json& value) {
  if (!value.is_string()) return std::nullopt;
  const auto text=value.get<std::string>(); uuid_t parsed{};
  if (text.size()!=36 || uuid_parse(text.c_str(),parsed)!=0) return std::nullopt;
  char canonical[37]{}; uuid_unparse_lower(parsed,canonical);
  if (text!=canonical) return std::nullopt;
  wire_frame::incarnation_type result{}; std::copy(parsed,parsed+16,result.begin());
  if (std::all_of(result.begin(),result.end(),[](auto b) { return b==0; })) return std::nullopt;
  return result;
}
inline bool core_endpoint::enroll(runtime& owner,const std::shared_ptr<participant>& capture,const json& prepared) {
  if (stopping_ || failed_ || &owner!=receiver_->hs274_capture_owner_.get() || records_.size()>=64 ||
      !capture || capture!=owner.installed_capture_ || !capture->current() || !capture->published_ ||
      !capture->preparation_owner_ || !capture->preparation_owner_->current() ||
      capture->device_retention_!=receiver_->device_grabber_ || !receiver_->active_owned_cohort_ ||
      !receiver_->active_owned_cohort_->current() || !owner.installed_terminal_ ||
      owner.installed_terminal_->generation!=capture->generation_) return false;
  const auto actor=capture->preparation_owner_->issuer_lineage_;
  const auto uuid=incarnation(prepared.at("incarnation"));
  const auto preparation=decimal(prepared.at("preparation"));
  if (!actor || actor->uid_!=uid_ || !uuid || !preparation) return false;
  for (const auto& old:records_) {
    if (old->epoch==capture->generation_ || (old->incarnation==*uuid && old->preparation==*preparation)) return false;
    if (!old->core_closed || (!same_binding(*old->lineage,*actor) &&
        !old->parent_closed && !old->enrollment_closed)) return false;
  }
  records_.push_back(std::shared_ptr<record>(new record(capture,receiver_->active_owned_cohort_,actor,
    *uuid,*preparation,capture->generation_)));
  return true;
}
inline bool core_endpoint::capture_terminal(const std::shared_ptr<record>& original) {
  if (original->core_closed) return true;
  auto& owner=receiver_->hs274_capture_;
  if (original->capture->receiver_!=&owner || original->epoch!=owner.installed_generation_) return false;
  const auto actual=original->aggregate->terminal();
  if (!actual || !actual->same_cohort(*original->aggregate) || !actual->current()) return false;
  original->core_closed=std::shared_ptr<const closed_preparation>(new closed_preparation(*actual));
  return true;
}
inline bool core_endpoint::capture_terminals() {
  bool complete=true;
  for (const auto& original:records_) if (!capture_terminal(original)) complete=false;
  return complete;
}
inline bool core_endpoint::latest(const std::shared_ptr<record>& original) const {
  return !stopping_ && !failed_ && !records_.empty() && records_.back()==original &&
    receiver_->hs274_capture_.installed_generation_==original->epoch && named_current();
}
inline bool core_endpoint::full_terminal(const std::shared_ptr<record>& original) const {
  if (!latest(original) || !original->nonce || !original->maintenance || !original->parent_closed || records_.empty()) return false;
  for (const auto& old:records_) if (!old->core_closed || !old->nonce ||
      (!old->parent_closed && !old->enrollment_closed)) return false;
  return true;
}
inline bool core_endpoint::issuer_current(const record& original,const detail::native_peer_observation& observed) const {
  return observed.self.identifier=="com.ergoptiplus.remap.core" && observed.self_euid==0 &&
    observed.self.leaf==original.lineage->leaf_ && original.lineage->matches(observed);
}
inline bool core_endpoint::arm_issuer_exit(record& original,const std::shared_ptr<native_socket>& socket) {
  for (const auto& held:exits_) if (same_binding(*held->lineage,*original.lineage)) {
    if (!held->armed || held->failed || held->close_attempted || held->observed) return false;
    original.exit=held; return true;
  }
  auto held=std::shared_ptr<issuer_exit>(new issuer_exit(original.lineage));
  exits_.push_back(held); // Actual owned monitor remains reachable before kqueue.
  original.exit=held;
  const auto before=detail::native_birth::observe(held->lineage->hs_.pid);
  const auto peer=socket->observe();
  if (!before || !(*before==held->lineage->hs_) || !peer || !issuer_current(original,*peer)) return false;
  if (!arm_issuer_monitor(*held)) return false;
  const auto after=detail::native_birth::observe(held->lineage->hs_.pid);
  const auto final_peer=socket->observe();
  held->armed=after && *after==held->lineage->hs_ && final_peer && issuer_current(original,*final_peer);
  return held->armed;
}
inline bool core_endpoint::arm_issuer_monitor(issuer_exit& original) {
  if (original.monitor>=0 || original.armed || original.observed || original.failed || original.close_attempted) return false;
  const auto before=detail::native_birth::observe(original.birth.pid);
  if (!before || !(*before==original.birth)) return false;
  original.monitor=::kqueue();
  if (original.monitor<0 || ::fcntl(original.monitor,F_SETFD,FD_CLOEXEC)!=0) return false;
  struct kevent registration{};
  EV_SET(&registration,static_cast<uintptr_t>(original.birth.pid),EVFILT_PROC,
    EV_ADD|EV_ENABLE|EV_CLEAR,NOTE_EXIT|NOTE_EXEC,0,nullptr);
  if (::kevent(original.monitor,&registration,1,nullptr,0,nullptr)!=0) return false;
  const auto after=detail::native_birth::observe(original.birth.pid);
  original.armed=after && *after==original.birth;
  return original.armed;
}
inline bool core_endpoint::poll_issuer_exit(issuer_exit& original) {
  if (!original.armed || original.failed || original.close_attempted || original.close_refused || original.monitor<0) return false;
  std::array<struct kevent,4> events{}; const timespec immediate{};
  int count;
  do { count=::kevent(original.monitor,nullptr,0,events.data(),events.size(),&immediate); } while (count<0 && errno==EINTR);
  if (count<0) { original.failed=true; return false; }
  for (int index=0;index<count;++index) {
    const auto& event=events[static_cast<std::size_t>(index)];
    if (event.filter!=EVFILT_PROC || event.ident!=static_cast<uintptr_t>(original.birth.pid) ||
        (event.flags&EV_ERROR) || (event.fflags&NOTE_EXEC) || !(event.fflags&NOTE_EXIT)) {
      original.failed=true; return false;
    }
    original.observed=true;
  }
  const auto current=detail::native_birth::observe(original.birth.pid);
  if (current && !(*current==original.birth)) { original.failed=true; return false; }
  return true;
}
inline bool core_endpoint::close_issuer_exit(issuer_exit& original) {
  if (!original.close_attempted) {
    original.close_attempted=true;
    if (original.monitor>=0) {
      const int fd=std::exchange(original.monitor,-1);
      if (::close(fd)!=0) original.close_refused=true;
    }
  }
  return !original.close_refused;
}
inline bool core_endpoint::issuer_retirement_intent(const std::shared_ptr<record>& original) const {
  if (!latest(original) || !original->nonce || !original->maintenance || !original->exit ||
      !original->exit->armed || original->exit->observed || original->exit->failed ||
      original->exit->close_attempted) return false;
  const auto& held=*original->maintenance;
  const auto observed=held.socket_->observe();
  if (!observed || held.original_.operation()!=ERGOPTI_MAINTENANCE_REQUEST_RETIREMENT ||
      !held.original_.same_correlation(held.original_.with_correlation(
        original->epoch,original->incarnation,original->preparation,*original->nonce))) return false;
  return (held.staged_ && !held.update_ && held.staged_->cleanup_current(*observed)) ||
    (held.update_ && !held.staged_ && held.update_->cleanup_current(*observed));
}
inline bool core_endpoint::issuer_permission(const std::shared_ptr<record>& original) const {
  if (!latest(original) || !original->maintenance || !original->exit || !original->exit->armed ||
      original->exit->observed || original->exit->failed || original->exit->close_attempted) return false;
  for (const auto& old:records_) {
    if (old!=original && (old->parent_closed || old->enrollment_closed)) continue;
    if (!old->core_closed || !old->nonce || !old->settlement_acknowledged ||
        !same_binding(*old->lineage,*original->lineage)) return false;
  }
  const auto& request=*original->maintenance;
  const auto current=request.socket_->observe();
  if (!current || !request.original_.same_correlation(request.original_.with_correlation(
      original->epoch,original->incarnation,original->preparation,*original->nonce))) return false;
  return (request.staged_ && !request.update_ && request.staged_->cleanup_current(*current)) ||
    (request.update_ && !request.staged_ && request.update_->cleanup_current(*current));
}
inline bool core_endpoint::capture_parent_terminals() {
  bool complete=true;
  for (const auto& exit:exits_) {
    if (!exit->armed || !exit->observed || exit->failed) continue;
    bool found=false,settled=true;
    for (const auto& record:records_) if (record->exit==exit) {
      found=true;
      if (!record->core_closed || !record->nonce || !record->settlement_acknowledged || !record->endpoint_closed) settled=false;
    }
    if (found && settled && !close_issuer_exit(*exit)) { failed_=close_refused_=true; complete=false; }
  }
  for (const auto& original:records_) {
    const auto& exit=original->exit;
    const bool resources=original->core_closed && original->nonce && original->settlement_acknowledged &&
      original->endpoint_closed && exit && exit->armed && exit->observed && !exit->failed &&
      exit->close_attempted && !exit->close_refused && exit->monitor<0;
    if (resources && !original->enrollment_closed) {
      original->enrollment_closed=std::shared_ptr<const closed_for_enrollment>(
        new closed_for_enrollment(original->core_closed,original->endpoint_closed,exit));
    }
    if (original->parent_closed) continue;
    if (!resources || !exit->permit_sent) { complete=false; continue; }
    original->parent_closed=std::shared_ptr<const closed_parent>(new closed_parent(original->endpoint_closed,exit));
  }
  return complete;
}
inline wire_frame core_endpoint::process(stream& client,const wire_frame& request) {
  const auto refuse=request.reply(ERGOPTI_MAINTENANCE_WIRE_REFUSED);
  if (close_refused_) return request.operation()==ERGOPTI_MAINTENANCE_OBSERVE_RETIREMENT_INTENT ?
    refuse : request.reply(ERGOPTI_MAINTENANCE_WIRE_CLOSE_REFUSED);
  if (request.status()!=ERGOPTI_MAINTENANCE_WIRE_REQUEST) return refuse;
  const auto observed=client.socket->observe();
  if (!observed) return refuse;
  const auto op=request.operation();
  if (!client.acquired && (op==ERGOPTI_MAINTENANCE_ISSUER_REGISTER ||
      op==ERGOPTI_MAINTENANCE_ISSUER_SETTLED || op==ERGOPTI_MAINTENANCE_REQUEST_RETIREMENT ||
      op==ERGOPTI_MAINTENANCE_OBSERVE_RETIREMENT_INTENT)) {
    const auto nonce=request.nonce();
    if (client.acquired || request.preparation()==0 ||
        std::all_of(nonce.begin(),nonce.end(),[](auto b) { return b==0; })) return refuse;
    std::shared_ptr<record> match;
    for (const auto& candidate:records_) if (candidate->incarnation==request.incarnation() &&
        candidate->preparation==request.preparation()) match=candidate;
    if (!match || !issuer_current(*match,*observed) ||
        (request.cohort()!=0 && request.cohort()!=match->epoch)) return refuse;
    if (op==ERGOPTI_MAINTENANCE_ISSUER_REGISTER) {
      if (match->parent_closed || (match->issuer && match->issuer!=client.socket) ||
          (match->nonce && *match->nonce!=request.nonce())) return refuse;
      for (const auto& old:records_) if (same_binding(*old->lineage,*match->lineage) && old->nonce &&
          *old->nonce!=request.nonce() && (!old->core_closed || !old->settlement_acknowledged)) return refuse;
      if (!arm_issuer_exit(*match,client.socket)) { failed_=true; return refuse; }
      match->nonce=request.nonce(); match->issuer=client.socket;
      return request.with_correlation(match->epoch,match->incarnation,match->preparation,*match->nonce)
        .reply(ERGOPTI_MAINTENANCE_WIRE_OBSERVED);
    }
    if (!request.complete_correlation() || !match->nonce || request.nonce()!=*match->nonce ||
        match->issuer!=client.socket || match->parent_closed) return refuse;
    if (op==ERGOPTI_MAINTENANCE_OBSERVE_RETIREMENT_INTENT) {
      if (!issuer_retirement_intent(match)) return request.reply(ERGOPTI_MAINTENANCE_WIRE_PENDING);
      client.intent_response=match;
      return request.reply(ERGOPTI_MAINTENANCE_WIRE_OBSERVED);
    }
    if (op==ERGOPTI_MAINTENANCE_REQUEST_RETIREMENT) {
      if (!issuer_permission(match)) return request.reply(ERGOPTI_MAINTENANCE_WIRE_PENDING);
      client.permission_response=match->exit;
      return request.reply(ERGOPTI_MAINTENANCE_WIRE_OBSERVED);
    }
    if (!capture_terminal(match)) return request.reply(ERGOPTI_MAINTENANCE_WIRE_PENDING);
    // This ACK permits the original Auth socket-LAST sender to close its
    // anchors. It is provisional until live-issuer EOF and accepted close.
    match->settlement_acknowledged=true;
    return request.reply(ERGOPTI_MAINTENANCE_WIRE_OBSERVED);
  }
  const bool update=op==ERGOPTI_MAINTENANCE_ACQUIRE_CONFIRMED_UPDATE;
  if (op==ERGOPTI_MAINTENANCE_ACQUIRE || update) {
    if (client.acquired || !request.empty_correlation() || records_.empty()) return refuse;
    const bool admitted=update ? remote_confirmed_update_matches(*observed) : remote_staged_maintenance_matches(*observed);
    const auto original=records_.back();
    if (!admitted || !latest(original) || !original->nonce) return refuse;
    if (update) {
      client.update=confirmed_update_admission::acquire_core(*observed);
      if (!client.update) return refuse;
    } else {
      client.staged=staged_admission::acquire_core(*observed);
      if (!client.staged) return refuse;
    }
    client.acquired=original;
    return request.with_correlation(original->epoch,original->incarnation,original->preparation,*original->nonce)
      .reply(ERGOPTI_MAINTENANCE_WIRE_OBSERVED);
  }
  const auto original=client.acquired;
  if (!original || !latest(original) || !original->nonce || !request.complete_correlation() ||
      !request.same_correlation(request.with_correlation(original->epoch,original->incarnation,original->preparation,*original->nonce)) ||
      !((client.update && !client.staged && client.update->cleanup_current(*observed)) ||
        (client.staged && !client.update && client.staged->cleanup_current(*observed)))) return refuse;
  if (op==ERGOPTI_MAINTENANCE_REQUEST_RETIREMENT) {
    if (!original->core_closed && !original->aggregate->request_retirement()) return refuse;
    original->maintenance=std::shared_ptr<const image_request>(new image_request(
      client.socket,client.staged,client.update,request));
    return request.reply(full_terminal(original) ? ERGOPTI_MAINTENANCE_WIRE_OBSERVED : ERGOPTI_MAINTENANCE_WIRE_PENDING);
  }
  if (op==ERGOPTI_MAINTENANCE_OBSERVE_TERMINAL || op==ERGOPTI_MAINTENANCE_RECUT_TERMINAL) {
    capture_terminals();
    return request.reply(full_terminal(original) ? ERGOPTI_MAINTENANCE_WIRE_OBSERVED : ERGOPTI_MAINTENANCE_WIRE_PENDING);
  }
  return refuse;
}
inline void core_endpoint::accept_one() {
  auto vacant=std::find_if(streams_.begin(),streams_.end(),[](const auto& client) { return !client.socket; });
  if (vacant==streams_.end()) return;
  // Every accepted FD is assigned to its actual native owner before checks.
  auto socket=std::shared_ptr<native_socket>(new native_socket); socket->custody_=socket;
  vacant->socket=socket; // Reachable retained cleanup custody before accept.
  socket->socket_=::accept(listener_,nullptr,nullptr);
  if (socket->socket_<0) {
    if (socket->close()) *vacant=stream{};
    else failed_=close_refused_=true;
    return;
  }
  bool admitted=fcntl(socket->socket_,F_SETFD,FD_CLOEXEC)==0;
  const int flags=fcntl(socket->socket_,F_GETFL); int enabled=1;
  admitted=admitted && flags>=0 && fcntl(socket->socket_,F_SETFL,flags|O_NONBLOCK)==0 &&
    setsockopt(socket->socket_,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled))==0 && socket->anchor_parent();
  if (!admitted || !socket->observe()) {
    if (socket->close()) *vacant=stream{};
    else failed_=close_refused_=true;
    return;
  }
}
inline bool core_endpoint::advance(stream& client) {
  if (!named_current() ||
      ((client.read!=0 || client.responding) && std::chrono::steady_clock::now()>=client.deadline)) return false;
  const int fd=client.socket->socket_;
  // Readiness is not native actor authority. Idle issuer streams do not
  // sample signing identity on every dispatcher tick; actual boundaries do.
  pollfd ready{fd,static_cast<short>(client.responding ? POLLOUT : POLLIN),0};
  const int count_ready=::poll(&ready,1,0);
  if (count_ready<0) return errno==EINTR;
  if (count_ready==0) return true;
  if (ready.revents&(POLLERR|POLLNVAL)) return false;
  if (!(ready.revents&(ready.events|POLLHUP))) return true;
  if (client.responding) {
    const auto observed=client.socket->observe();
    if (!observed) return false;
    if (client.intent_response) {
      const auto& original=client.intent_response;
      if (original->issuer!=client.socket || !issuer_current(*original,*observed)) return false;
      if (!issuer_retirement_intent(original)) {
        if (client.written!=0) return false;
        const auto pending=wire_frame::decode(client.output);
        if (!pending) return false;
        client.output=pending->reply(ERGOPTI_MAINTENANCE_WIRE_PENDING).bytes();
        client.intent_response.reset();
      }
    }
    const auto count=::send(fd,client.output.data()+client.written,client.output.size()-client.written,0);
    if (count<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)) return true;
    if (count<=0) return false;
    client.written+=static_cast<std::size_t>(count);
    if (client.written<client.output.size()) return true;
    if (client.close_after) return false;
    if (client.permission_response) {
      client.permission_response->permit_sent=true; client.permission_response.reset();
    }
    client.intent_response.reset();
    client.responding=false; client.read=client.written=0; client.input.fill(0); client.output.fill(0);
    client.deadline={};
    return true;
  }
  const auto count=::recv(fd,client.input.data()+client.read,client.input.size()-client.read,0);
  if (count<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)) return true;
  if (count==0) {
    // Live-HS EOF closes only the Core's endpoint; never full Parent.
    // Dead-HS EOF is accepted solely after the original armed kernel exit.
    bool has_kernel=false;
    for (const auto& original:records_) if (original->issuer==client.socket && original->exit &&
        original->exit->armed && original->exit->observed && !original->exit->failed) has_kernel=true;
    const auto observed=client.read==0 && !has_kernel ? client.socket->observe() : std::nullopt;
    bool registered=false,complete=client.read==0;
    bool kernel_eof=false;
    for (const auto& original:records_) if (original->issuer==client.socket) {
      registered=true;
      const auto& exit=original->exit;
      const bool kernel=exit && exit->armed && exit->observed && !exit->failed;
      kernel_eof=kernel_eof || kernel;
      if ((!kernel && (!observed || !issuer_current(*original,*observed))) ||
          !original->core_closed || !original->nonce || !original->settlement_acknowledged ||
          original->endpoint_closed) complete=false;
    }
    if (kernel_eof) complete=complete && client.socket->same_original_peer_eof();
    client.issuer_eof=registered && complete;
    if (client.issuer_eof) client.socket->peer_eof_=true;
    return false;
  }
  if (count<0) return false;
  if (client.read==0) client.deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
  client.read+=static_cast<std::size_t>(count);
  if (client.read<client.input.size()) return true;
  const auto frame=wire_frame::decode(client.input);
  if (!frame) return false;
  // Serialize frames: pipelined/trailing bytes never get an authority reply.
  std::uint8_t extra=0;
  const auto pending=::recv(fd,&extra,1,MSG_PEEK);
  if (pending>0 || pending==0 || (pending<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)) return false;
  const auto response=process(client,*frame);
  client.output=response.bytes(); client.responding=true;
  client.close_after=response.status()==ERGOPTI_MAINTENANCE_WIRE_REFUSED;
  return true;
}
inline bool core_endpoint::release_admission(stream& client) {
  bool closed=true;
  if (client.staged && (!client.staged->close() || !client.staged->retired())) closed=false;
  if (client.update && (!client.update->close() || !client.update->retired())) closed=false;
  return closed;
}
inline bool core_endpoint::close_stream(stream& client) {
  // The private native close ACK includes the exact accepted descriptor and
  // all its retained parent anchors. A refusal retains the original debt.
  if (!release_admission(client) || !client.socket->close()) return false;
  if (client.issuer_eof) {
    for (const auto& original:records_) if (original->issuer==client.socket) {
      original->endpoint_closed=std::shared_ptr<const closed_issuer_endpoint>(
        new closed_issuer_endpoint(client.socket,original->lineage,*original->nonce));
    }
  }
  return true;
}
inline bool core_endpoint::stop() noexcept {
  stopping_=true;
  try {
    if (!close_attempted_) {
      close_attempted_=true;
      for (auto& client:streams_) {
        if (!release_admission(client)) close_refused_=true;
        if (client.socket && !client.socket->close()) close_refused_=true;
      }
      for (const auto& original:exits_) if (!close_issuer_exit(*original)) close_refused_=true;
      if (listener_>=0) { const int original=std::exchange(listener_,-1); if (::close(original)!=0) close_refused_=true; }
      if (bound_ && anchor_ && anchor_->parent_current()) {
        struct stat named{};
        if (fstatat(anchor_->parent_.back(),".runtime-maintenance.sock",&named,AT_SYMLINK_NOFOLLOW)!=0 ||
            !S_ISSOCK(named.st_mode) || named.st_dev!=named_identity_.st_dev || named.st_ino!=named_identity_.st_ino ||
            unlinkat(anchor_->parent_.back(),".runtime-maintenance.sock",0)!=0) close_refused_=true;
      } else if (bound_) close_refused_=true;
      if (anchor_ && !anchor_->close()) close_refused_=true;
    }
    // Refused native closure or unresolved prepared lineage retains debt;
    // mere receiver destruction/absence must not manufacture full settlement.
    bool settled=true;
    for (const auto& original:records_) if (!original->core_closed ||
        (!original->parent_closed && !original->enrollment_closed)) settled=false;
    if (!close_refused_ && settled) { records_.clear(); custody_.reset(); }
    return !close_refused_ && settled;
  } catch (...) { close_refused_=true; return false; }
}
} // namespace ergoptiplus::installed_maintenance

namespace hs274_stream_protocol {
inline bool runtime::maintenance_before_constructor() {
  const auto endpoint=maintenance_endpoint_.lock();
  return !endpoint || endpoint->capture_terminals();
}
inline bool runtime::maintenance_enroll_prepared(const std::shared_ptr<capture_participant>& participant,const json& prepared) {
  const auto endpoint=maintenance_endpoint_.lock();
  return endpoint && endpoint->enroll(*this,participant,prepared);
}
} // namespace hs274_stream_protocol
