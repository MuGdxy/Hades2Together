#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace h2t_observe {
// Retail controller number 4 is the parked handler. Only lower indices accept player input.
constexpr unsigned playable_lanes = 4;
using Addr = std::uintptr_t;
constexpr Addr update_return = 0x63596;
constexpr Addr reset_return = 0x6358a;
constexpr Addr sampler_return = 0x2f487e;
constexpr Addr buttons_return = 0x2f242d;
constexpr std::array button_ids{0,1,2,3,9,10,4,6,7,8,11,12,13,14};

struct Pad {
    Addr object{}, controller{};
    std::int32_t instance{-1};
    std::uint32_t model{};
};
struct Lane {
    Pad pad{};
    std::array<std::int16_t,6> axes{};
    std::array<std::uint8_t,14> buttons{};
    std::uint8_t raw{};
    unsigned reads{};
    bool raw_seen{};
};
enum class Outcome { none, complete, zero_pads, reset, incomplete };
struct Trace {
    std::uint64_t serial{};
    unsigned count{};
    std::array<Lane,playable_lanes> lanes{};
    Outcome outcome{Outcome::none};
};

class Recorder {
    std::atomic<unsigned> thread_{};
    bool opened_{}, topology_{}, fault_{}, reset_{};
    int lane_{-1};
    Trace pending_{}, latest_{};
    std::array<Addr,playable_lanes> expected_pads_{};
    bool on_thread(unsigned thread) const noexcept { return thread && thread == thread_.load(); }
    bool complete(const Lane& lane) const noexcept {
        return lane.reads == 20u + (lane.pad.model <= 1 ? 1u : 0u)
            && lane.raw_seen == (lane.pad.model <= 1);
    }
    void clear() noexcept {
        opened_ = topology_ = fault_ = reset_ = false;
        lane_ = -1;
        pending_ = {};
        expected_pads_ = {};
    }
public:
    void begin(unsigned thread, Addr caller) noexcept {
        if (caller != update_return || !thread) return;
        unsigned none = 0;
        thread_.compare_exchange_strong(none, thread);
        if (!on_thread(thread)) return;
        const bool overlapping = opened_;
        clear();
        opened_ = true;
        fault_ = overlapping;
    }
    void reset(unsigned thread, Addr caller) noexcept {
        if (caller != reset_return || !thread) return;
        unsigned none = 0;
        thread_.compare_exchange_strong(none, thread);
        if (!on_thread(thread)) return;
        clear();
        reset_ = true;
    }
    bool begin_topology(unsigned thread, Addr caller, unsigned pad_count, std::array<Addr,playable_lanes> objects) noexcept {
        if (!on_thread(thread) || !opened_ || caller != update_return) return false;
        if (topology_ || pad_count > pending_.lanes.size()) {
            fault_ = true;
            return false;
        }
        topology_ = true;
        pending_.count = pad_count;
        expected_pads_ = objects;
        return true;
    }
    void pad(unsigned thread, Addr caller, unsigned index, Pad value) noexcept {
        if (!on_thread(thread) || !opened_ || caller != sampler_return) return;
        if (!topology_ || index >= pending_.count || int(index) != lane_ + 1
            || !value.object || value.object != expected_pads_[index] || !value.controller || value.instance < 0) {
            fault_ = true;
            return;
        }
        if (lane_ >= 0 && !complete(pending_.lanes[lane_])) fault_ = true;
        for (unsigned previous_lane=0; previous_lane<index; ++previous_lane) {
            const auto& previous = pending_.lanes[previous_lane].pad;
            if (previous.object == value.object || previous.controller == value.controller
                || previous.instance == value.instance) fault_ = true;
        }
        lane_ = static_cast<int>(index);
        pending_.lanes[index].pad = value;
    }
    void value(unsigned thread, Addr caller, unsigned ordinal, std::uint16_t value) noexcept {
        if (!on_thread(thread) || !opened_ || lane_ < 0) return;
        const bool is_button = ordinal >= 6 && ordinal < 20;
        if (caller != (is_button ? buttons_return : sampler_return)) return;
        auto& lane = pending_.lanes[lane_];
        if (ordinal != lane.reads || ordinal > 20 || (ordinal == 20 && lane.pad.model > 1)) {
            fault_ = true;
            return;
        }
        if (ordinal < 6) lane.axes[ordinal] = static_cast<std::int16_t>(value);
        else if (ordinal < 20) lane.buttons[ordinal-6] = static_cast<std::uint8_t>(value);
        else { lane.raw = static_cast<std::uint8_t>(value); lane.raw_seen = true; }
        ++lane.reads;
    }
    void end(unsigned thread) noexcept {
        if (!on_thread(thread)) return;
        auto outcome = Outcome::incomplete;
        if (reset_) outcome = Outcome::reset;
        else if (opened_ && topology_ && !fault_) {
            if (!pending_.count && lane_ == -1) outcome = Outcome::zero_pads;
            if (lane_ >= 0 && unsigned(lane_+1) == pending_.count && complete(pending_.lanes[lane_]))
                outcome = Outcome::complete;
        }
        pending_.serial = latest_.serial + 1;
        pending_.outcome = outcome;
        latest_ = pending_;
        clear();
    }
    Trace latest(unsigned thread) const noexcept { return on_thread(thread) ? latest_ : Trace{}; }
};

enum class Install { unattempted, installing, ready, preflight_failed, prepare_failed, enable_failed, rollback_failed };

// Backend prepares disabled hooks. During enable or rollback every callback remains inert.
template<std::size_t N, class Backend>
Install install_all(Backend& backend, std::atomic<bool>& armed) noexcept {
    if (!backend.preflight()) return Install::preflight_failed;
    for (std::size_t i=0; i<N; ++i)
        if (!backend.prepare(i)) return Install::prepare_failed;
    for (std::size_t i=0; i<N; ++i) {
        if (backend.enable(i)) continue;
        bool restored = true;
        for (std::size_t remaining = i+1; remaining; --remaining)
            if (!backend.disable_if_enabled(remaining-1)) restored = false;
        return restored ? Install::enable_failed : Install::rollback_failed;
    }
    armed.store(true, std::memory_order_release);
    return Install::ready;
}
}
