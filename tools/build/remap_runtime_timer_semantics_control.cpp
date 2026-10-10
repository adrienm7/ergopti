// tools/build/remap_runtime_timer_semantics_control.cpp
// Actual pinned dispatcher with its software clock; no native manipulator engine.

#include <pqrs/dispatcher/extra/debounced_task.hpp>
#include <atomic>
#include <chrono>
#include <future>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
using namespace pqrs::dispatcher;
using namespace std::chrono_literals;

void require(bool value) {
	if (!value) throw std::runtime_error("pinned dispatcher control refused");
}

struct Scope final {
	static std::shared_ptr<pseudo_time_source> make_clock() {
		auto result = std::make_shared<pseudo_time_source>();
		result->set_now(time_point(duration(1000)));
		return result;
	}

	std::shared_ptr<pseudo_time_source> clock = make_clock();
	std::shared_ptr<dispatcher> worker = std::make_shared<dispatcher>(clock);
	extra::dispatcher_client barrier_owner{worker};

	~Scope() {
		barrier_owner.detach_from_dispatcher();
		worker->terminate();
	}

	void settle(int milliseconds) {
		// Enqueue at the controlled current time. The genuine dispatcher inserts
		// equal deadlines after earlier entries; an immediate barrier would not
		// witness a due timer. No sleep or replacement timer implementation.
		clock->set_now(time_point(duration(milliseconds)));
		auto completed = std::make_shared<std::promise<void>>();
		auto result = completed->get_future();
		require(barrier_owner.enqueue_to_dispatcher(
			[completed] { completed->set_value(); }, clock->now()));
		require(result.wait_for(2s) == std::future_status::ready);
		result.get();
	}
};

struct Owner final {
	extra::dispatcher_client client;
	extra::debounced_task timer;
	std::shared_ptr<std::atomic<int>> first = std::make_shared<std::atomic<int>>(0);
	std::shared_ptr<std::atomic<int>> second = std::make_shared<std::atomic<int>>(0);

	explicit Owner(Scope& scope) : client(scope.worker), timer(client) {}
	~Owner() { client.detach_from_dispatcher(); }

	bool arm(bool replacement = false) {
		auto count = replacement ? second : first;
		return timer.debounce_after([count] { ++*count; }, 200ms);
	}

	void counts(int expected_first, int expected_second = 0) const {
		require(first->load() == expected_first && second->load() == expected_second);
	}
};

void run(const std::string& scenario) {
	Scope scope;
	Owner owner(scope);
	if (scenario == "threshold_199_200") {
		require(owner.arm());
		scope.settle(1000);
		scope.settle(1199);
		owner.counts(0);
		scope.settle(1200);
		owner.counts(1);
		scope.settle(1200);
		owner.counts(1);
	} else if (scenario == "cancel_before_eligible") {
		require(owner.arm());
		scope.settle(1000);
		scope.settle(1100);
		owner.timer.cancel();
		scope.settle(1100);
		scope.settle(1500);
		owner.counts(0);
	} else if (scenario == "same_owner_rearm") {
		require(owner.arm());
		scope.settle(1000);
		scope.settle(1100);
		require(owner.arm(true));
		scope.settle(1100);
		scope.settle(1200);
		owner.counts(0);
		scope.settle(1300);
		owner.counts(0, 1);
	} else if (scenario == "same_deadline_rearm") {
		require(owner.arm());
		scope.settle(1000);
		require(owner.arm(true));
		scope.settle(1000);
		scope.settle(1200);
		owner.counts(0, 1);
	} else if (scenario == "independent_owners") {
		Owner sibling(scope);
		require(owner.arm() && sibling.arm());
		scope.settle(1000);
		scope.settle(1100);
		owner.timer.cancel();
		scope.settle(1100);
		scope.settle(1200);
		owner.counts(0);
		sibling.counts(1);
	} else if (scenario == "detach_before_due") {
		require(owner.arm());
		scope.settle(1000);
		owner.client.detach_from_dispatcher();
		require(!owner.client.attached());
		scope.settle(1500);
		owner.counts(0);
	} else if (scenario == "retained_rearm_after_detach_refuses") {
		require(owner.arm());
		scope.settle(1000);
		owner.client.detach_from_dispatcher();
		require(!owner.client.attached());
		require(!owner.arm(true));
		scope.settle(1500);
		owner.counts(0);
	} else {
		require(false);
	}
}
} // namespace

int main(int argc, char** argv) {
	try {
		require(argc == 2);
		run(argv[1]);
		// run() returns only after both exact clients detach and the actual
		// dispatcher worker joins. These fixed labels contain no input data.
		std::cout << "PASS actual pinned dispatcher " << argv[1]
			<< " native_engine=unexecuted\n";
		return 0;
	} catch (...) {
		std::cerr << "FAIL actual pinned dispatcher control\n";
		return 1;
	}
}
