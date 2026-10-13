// Actual Darwin mechanics only; this fixture never creates a Core or a wire request.
#if !defined(ERGOPTIPLUS_OWNED_RUNTIME_TEST_ONLY)
#error "Native observer fixture requires its explicitly named test-only build"
#endif
#include "core_service/daemon/receiver.hpp"
#include <sys/wait.h>
#include <cstdio>
#include <thread>

namespace ergoptiplus::installed_maintenance {
class native_observer_test final {
  using observer = core_endpoint::issuer_exit;
  struct child_guard final {
    const pid_t original_parent=::getpid();
    pid_t owned=-1;
    int command=-1,endpoint=-1;
    std::array<int,4> acquired{{-1,-1,-1,-1}};
    std::array<bool,4> close_attempted{},close_refused_by_role{};
    bool reaped=false,refused=false,close_refused=false,force_attempted=false;
    int status=0;
    std::optional<detail::native_birth> birth;
    std::optional<std::chrono::steady_clock::time_point> deadline;
  };
  static std::vector<std::shared_ptr<child_guard>>& child_guards() {
    static auto* roots=new std::vector<std::shared_ptr<child_guard>>;
    return *roots; // Original metadata survives every wrapper destructor.
  }
  struct monitor_guard final { std::shared_ptr<observer> original; int acquired=-1; };
  static std::vector<std::shared_ptr<monitor_guard>>& monitor_guards() {
    static auto* roots=new std::vector<std::shared_ptr<monitor_guard>>;
    return *roots; // Checked-close refusal remains an explicit source debt.
  }
  static std::shared_ptr<child_guard> retain_child() {
    auto result=std::make_shared<child_guard>(); child_guards().push_back(result); return result;
  }
  struct child final {
    const std::shared_ptr<child_guard> guard=retain_child();
    pid_t& owned=guard->owned;
    int& command=guard->command;
    int& endpoint=guard->endpoint;
    bool& reaped=guard->reaped;
    bool& refused=guard->refused;
    std::optional<detail::native_birth>& birth=guard->birth;
    child(const child&)=delete;
    child& operator=(const child&)=delete;
    child() {
      int commands[2]{-1,-1},sockets[2]{-1,-1};
      if (::socketpair(AF_UNIX,SOCK_STREAM,0,commands)!=0) { refused=true; return; }
      command=commands[1]; guard->acquired[0]=commands[0]; guard->acquired[1]=commands[1];
      if (::socketpair(AF_UNIX,SOCK_STREAM,0,sockets)!=0) {
        refused=true;
        close_role(0); close_role(1); command=-1;
        return;
      }
      endpoint=sockets[0]; guard->acquired[2]=sockets[0]; guard->acquired[3]=sockets[1];
      bool setup=true; int one=1;
      for (int fd:{commands[0],commands[1],sockets[0],sockets[1]})
        if (::fcntl(fd,F_SETFD,FD_CLOEXEC)!=0 ||
            ::setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one))!=0) setup=false;
      if (!setup) {
        refused=true;
        for (std::size_t role=0;role<guard->acquired.size();++role) close_role(role);
        command=endpoint=-1; return;
      }
      owned=::fork();
      if (owned==0) {
        ::close(commands[1]); ::close(sockets[0]);
        for (;;) {
          char operation=0; ssize_t count;
          do { count=::read(commands[0],&operation,1); } while (count<0 && errno==EINTR);
          if (count!=1 || operation=='q') _exit(0);
          if (operation=='h') { ::close(sockets[1]); sockets[1]=-1; continue; }
          if (operation=='e') {
            char executable[]="/usr/bin/true"; char* argv[]{executable,nullptr};
            ::execv(executable,argv); _exit(91);
          }
          _exit(92);
        }
      }
      close_role(0); close_role(3); // No short-circuit: retain each exact result.
      if (owned<0) { refused=true; settle(); return; }
      birth=detail::native_birth::observe(owned);
      if (!birth) refused=true;
    }
    bool close_role(std::size_t role) {
      if (guard->close_attempted[role]) return !guard->close_refused_by_role[role];
      guard->close_attempted[role]=true;
      const int original=guard->acquired[role];
      if (original>=0 && ::close(original)!=0) {
        guard->close_refused_by_role[role]=true; guard->close_refused=true;
      }
      return !guard->close_refused_by_role[role];
    }
    bool send(char operation) {
      if (refused || command<0) return false;
      ssize_t result; do { result=::send(command,&operation,1,0); } while (result<0 && errno==EINTR);
      return result==1;
    }
    bool eof() const {
      if (endpoint<0) return false;
      pollfd ready{endpoint,POLLIN,0};
      if (::poll(&ready,1,0)!=1 || !(ready.revents&(POLLIN|POLLHUP))) return false;
      char byte=0; return ::recv(endpoint,&byte,1,MSG_DONTWAIT)==0;
    }
    bool close_endpoint() {
      if (endpoint<0) return false;
      endpoint=-1; return close_role(2);
    }
    bool settle() {
      if (!guard->deadline) guard->deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
      if (command>=0) { command=-1; close_role(1); }
      if (endpoint>=0) close_endpoint();
      while (owned>1 && !reaped && std::chrono::steady_clock::now()<*guard->deadline) {
        int status=0; const auto result=::waitpid(owned,&status,WNOHANG);
        if (result==owned) {
          reaped=true; guard->status=status;
          if (!WIFEXITED(status) || WEXITSTATUS(status)!=0) refused=true;
          break;
        }
        if (result<0 && errno==EINTR) continue;
        if (result<0) { refused=true; break; }
        // Native direct-fork custody and unreaped waitpid0 precede ANY signal.
        const auto now=std::chrono::steady_clock::now();
        if (!guard->force_attempted && now>=*guard->deadline-std::chrono::milliseconds(1500)) {
          guard->force_attempted=true;
          const auto current=detail::native_birth::observe(owned); proc_bsdinfo process{};
          if (!birth || !current || !(*current==*birth) ||
              ::proc_pidinfo(owned,PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process) ||
              process.pbi_pid!=static_cast<std::uint32_t>(owned) ||
              process.pbi_ppid!=static_cast<std::uint32_t>(guard->original_parent) ||
              ::kill(owned,SIGKILL)!=0) { refused=true; break; }
          // Forced cleanup proves no healthy child behavior; it always fails its case.
          refused=true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      if (!reaped) refused=true;
      return owned>1 && reaped && !refused && !guard->close_refused && command<0 && endpoint<0;
    }
    ~child() { if (!settle()) guard->refused=true; } // Original guardian stays rooted.
  };
  struct monitor final {
    const std::shared_ptr<monitor_guard> guard=std::make_shared<monitor_guard>();
    std::shared_ptr<observer> value;
    monitor(const monitor&)=delete;
    monitor& operator=(const monitor&)=delete;
    explicit monitor(const child& original) {
      if (!original.refused && original.birth) {
        value=std::make_shared<observer>(*original.birth);
        guard->original=value; monitor_guards().push_back(guard); // Before kqueue acquisition.
      }
    }
    bool arm() {
      if (!value) return false;
      const bool armed=core_endpoint::arm_issuer_monitor(*value);
      guard->acquired=value->monitor; return armed;
    }
    bool poll() { return value && core_endpoint::poll_issuer_exit(*value); }
    bool close() {
      if (!value) return false;
      if (value->monitor>=0) guard->acquired=value->monitor;
      return core_endpoint::close_issuer_exit(*value);
    }
    ~monitor() { if (value && !close()) value->failed=true; }
  };
  template<class Predicate> static bool until(Predicate predicate) {
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while (std::chrono::steady_clock::now()<deadline) {
      if (predicate()) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return false;
  }
  static bool real_owned_child_exit() {
    child owned; monitor kernel(owned);
    if (!kernel.arm() || !owned.send('q')) return false;
    const bool exited=until([&] { return kernel.poll() && kernel.value->observed; });
    const bool eof=until([&] { return owned.eof(); });
    const bool closed=kernel.close();
    return exited && eof && closed && kernel.value->monitor<0 &&
      kernel.value->close_attempted && !kernel.value->close_refused && owned.settle();
  }
  static bool live_child_socket_EOF() {
    child owned; monitor kernel(owned);
    if (!kernel.arm() || !owned.send('h')) return false;
    const bool eof=until([&] { return owned.eof(); });
    const auto alive=detail::native_birth::observe(owned.owned);
    const bool no_exit=kernel.poll() && !kernel.value->observed;
    const bool closed=kernel.close();
    return eof && alive && owned.birth && *alive==*owned.birth && no_exit && closed && owned.settle();
  }
  static bool actual_owned_child_exec() {
    child owned; monitor kernel(owned);
    if (!kernel.arm() || !owned.send('e')) return false;
    const bool refused=until([&] { return !kernel.poll(); });
    const bool correct=refused && kernel.value->failed && !kernel.value->observed;
    const bool closed=kernel.close();
    return correct && closed && owned.settle();
  }
  static bool real_monitor_EBADF() {
    child owned; monitor kernel(owned);
    if (!kernel.arm() || ::close(kernel.value->monitor)!=0) return false;
    // Deliberate fixture-only owner corruption. Real EBADF must remain refusal.
    const bool refused=!kernel.close() && kernel.value->close_refused && kernel.value->close_attempted;
    return refused && !kernel.close() && owned.settle();
  }
  static bool real_socket_EBADF() {
    child owned;
    if (owned.refused || ::close(owned.endpoint)!=0) return false;
    const bool refused=!owned.close_endpoint() && errno==EBADF;
    const bool settled=owned.settle();
    return refused && owned.endpoint<0 && !settled && owned.reaped && owned.guard->close_refused &&
      !owned.guard->force_attempted && WIFEXITED(owned.guard->status) && WEXITSTATUS(owned.guard->status)==0;
  }
  static bool already_reaped_owned_child() {
    child owned;
    if (owned.refused || !owned.birth || !owned.send('q')) return false;
    const auto original=*owned.birth;
    if (!owned.settle()) return false;
    observer ended(original);
    const bool absent=!detail::native_birth::observe(original.pid);
    const bool refused=!core_endpoint::arm_issuer_monitor(ended);
    const bool no_credit=!ended.armed && !ended.observed && ended.monitor<0;
    return absent && refused && no_credit && core_endpoint::close_issuer_exit(ended);
  }

public:
  static int run() {
    const std::pair<const char*,bool(*)()> controls[]{
      {"real_owned_child_exit",real_owned_child_exit},
      {"live_child_socket_EOF",live_child_socket_EOF},
      {"actual_owned_child_exec",actual_owned_child_exec},
      {"real_monitor_EBADF",real_monitor_EBADF},
      {"real_socket_EBADF",real_socket_EBADF},
      {"already_reaped_owned_child",already_reaped_owned_child}
    };
    int failures=0;
    for (std::size_t index=0;index<std::size(controls);++index) {
      // Whole case isolation lets the actual outer wait consume case process
      // death, never an in-process false close ACK for the intentional negatives.
      auto owner=retain_child();
      owner->owned=::fork();
      if (owner->owned==0) {
        child_guards().clear(); monitor_guards().clear();
        const bool behavior=controls[index].second();
        bool children_reaped=true,unexpected_refusal=false;
        for (const auto& original:child_guards()) {
          if (original->owned>1 && !original->reaped) children_reaped=false;
          const bool expected_fd_refusal=index==4 && original->reaped && original->close_refused &&
            !original->force_attempted && WIFEXITED(original->status) && WEXITSTATUS(original->status)==0;
          if (original->refused && !expected_fd_refusal) unexpected_refusal=true;
        }
        for (const auto& original:monitor_guards())
          if ((!original->original->close_attempted || original->original->close_refused) && index!=3) unexpected_refusal=true;
        // An unresolved original child guardian keeps this case alive/refused;
        // the genuine outer runner must settle its owned process scope on timeout.
        if (!children_reaped) {
          for (;;) ::pause(); // No successful result or dropped live-child owner.
        }
        const bool intentional=index==3 || index==4;
        _exit(behavior && !unexpected_refusal ? (intentional ? 3 : 0) : 1);
      }
      if (owner->owned>1) owner->birth=detail::native_birth::observe(owner->owned);
      const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
      while (owner->owned>1 && std::chrono::steady_clock::now()<deadline) {
        int status=0; const auto observed=::waitpid(owner->owned,&status,WNOHANG);
        if (observed==owner->owned) { owner->reaped=true; owner->status=status; break; }
        if (observed<0 && errno!=EINTR) { owner->refused=true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      const int expected=index==3 || index==4 ? 3 : 0;
      const bool passed=owner->reaped && !owner->refused && WIFEXITED(owner->status) && WEXITSTATUS(owner->status)==expected;
      if (!passed) { owner->refused=true; ++failures; }
      std::printf("CONTROL %s %s\n",controls[index].first,passed ? "PASS" : "FAIL");
      if (!owner->reaped) {
        std::fflush(stdout);
        // This source owner cannot drop original case/descendant custody.
        // Hosted receiver must provide its actual outer process guardian; no SDK
        // qualification may run this fixture under an unowned shell timeout.
        for (;;) ::pause();
      }
    }
    return failures ? 1 : 0;
  }
};
}
int main() { return ergoptiplus::installed_maintenance::native_observer_test::run(); }
