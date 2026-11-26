#pragma once
#include "observe-sampler-core.hpp"
#include <array>
#include <cmath>
#include <cstdint>
#include <optional>

namespace h2t_active {
using Addr = std::uintptr_t;
using ClockMs = std::uint64_t;
constexpr Addr app_return = 0x63596;
constexpr Addr sampler_return = 0x2f487e;
constexpr Addr buttons_return = 0x2f242d;
constexpr unsigned max_lease_ms = 500;

struct Owner {
    Addr world{}, player{}, unit{}, handler{}, stock_pad{}, sdl_pad{}, joystick{};
    int hero{}, instance{-1};
    unsigned player_slot{}, handler_index{}, input_lane{}, model{};
    std::uint64_t room_epoch{};
    bool operator==(const Owner&) const = default;
};
struct Proof {
    Owner owner{};
    unsigned pad_count{};
    bool attached_virtual_neutral{}, mapping{}, managed_lanes{};
    bool valid() const noexcept {
        const auto& p = owner;
        const bool routed = pad_count>0 && pad_count<=h2t_observe::playable_lanes &&
            p.player_slot<pad_count && (pad_count==1 || managed_lanes);
        return routed && attached_virtual_neutral && mapping && p.world && p.player && p.unit &&
            p.handler && p.stock_pad && p.sdl_pad && p.joystick && p.hero>0 && p.instance>=0 &&
            p.handler_index==p.player_slot && p.input_lane==p.player_slot && p.model==2 && p.room_epoch;
    }
};
struct Frame { double x{},y{},aim_x{},aim_y{}; unsigned buttons{}; };
struct Sample {
    std::array<std::int16_t,6> axes{};
    std::array<std::uint8_t,14> buttons{};
    bool operator==(const Sample&) const = default;
};
inline std::optional<Sample> encode(const Frame& frame) noexcept {
    const auto in_range=[](double n){return std::isfinite(n) && n>=-1 && n<=1;};
    if (!in_range(frame.x) || !in_range(frame.y) || frame.aim_x!=0 || frame.aim_y!=0 ||
        (frame.buttons & ~3u)) return {};
    Sample result;
    result.axes[0]=static_cast<std::int16_t>(std::lround(frame.x*32767.0));
    result.axes[1]=static_cast<std::int16_t>(std::lround(frame.y*32767.0));
    // Ordinals after the six axes are exactly the stock list 0,1,2,3,9,10,4,6,7,8,11,12,13,14.
    result.buttons[1]=static_cast<std::uint8_t>(frame.buttons & 1u);
    result.buttons[2]=static_cast<std::uint8_t>((frame.buttons & 2u)!=0);
    return result;
}

enum class Result { none, complete, incomplete, reset };
struct Audit {
    std::uint64_t batch{};
    unsigned reads{}, changed{};
    Result result{Result::none};
    bool neutral_witness{};
    std::uint64_t applied_sequence{};
};
class Adapter {
    unsigned thread_{};
    std::optional<Owner> owner_;
    std::uint64_t generation_{}, latest_generation_{}, sequence_{}, minimum_neutral_batch_{};
    ClockMs received_{};
    Sample desired_{}, frozen_{};
    bool have_sample_{}, session_ready_{}, opened_{}, topology_{}, lane_{}, fault_{};
    std::uint64_t batch_{}, frozen_sequence_{};
    unsigned cursor_{}, changed_{};
    Audit latest_{};
    bool on(unsigned t) const noexcept { return t && thread_==t; }
    bool match(const Proof& proof) const noexcept { return owner_ && proof.valid() && proof.owner==*owner_; }
    void invalidate() noexcept {
        generation_=sequence_=0;
        session_ready_=have_sample_=false;
        desired_={};
    }
    void clear_batch() noexcept {
        opened_=topology_=lane_=fault_=false;
        cursor_=changed_=0;
        frozen_={};
        frozen_sequence_=0;
    }
public:
    // Called only after the independent stock owner + controller route and
    // recent stock-neutral handler evidence have been verified by the scratch bridge.
    bool bind(unsigned t, const Proof& p) noexcept {
        if (!t || (thread_ && t!=thread_) || owner_ || !p.valid()) return false;
        thread_=t;
        owner_=p.owner;
        return true;
    }

    bool connect(unsigned t, std::uint64_t gen) noexcept {
        if (!on(t) || !owner_ || opened_ || generation_ || !gen || gen<=latest_generation_) return false;
        latest_generation_=generation_=gen;
        minimum_neutral_batch_=batch_;
        session_ready_=false;
        return true;
    }
    bool observe_neutral(unsigned t, std::uint64_t gen, const Proof& p, std::uint64_t batch,
                         bool handler_zero_and_edges_clear) noexcept {
        if (!on(t) || opened_ || !gen || gen!=generation_ || !match(p) ||
            batch<=minimum_neutral_batch_ || batch!=latest_.batch ||
            !latest_.neutral_witness || !handler_zero_and_edges_clear) return false;
        session_ready_=true;
        return true;
    }
    bool disconnect(unsigned t, std::uint64_t gen) noexcept {
        if (!on(t) || opened_ || !gen || gen!=generation_) return false;
        invalidate();
        received_=0;
        latest_={};
        return true;
    }
    bool submit(unsigned t, std::uint64_t gen, std::uint64_t seq, ClockMs now,
                const Frame& frame, const Proof& current) noexcept {
        if (!on(t) || opened_ || !gen || gen!=generation_) return false;
        if (!match(current)) { invalidate(); owner_.reset(); return false; }
        if (!session_ready_ || seq<=sequence_ || (have_sample_ && now<received_)) return false;
        const auto sample=encode(frame);
        if (!sample) return false;
        sequence_=seq;
        desired_=*sample;
        received_=now;
        have_sample_=true;
        return true;
    }

    // Entry, range, and exit are the prior observer's exact scoped sites.
    bool app_begin(unsigned t, Addr caller) noexcept {
        if (!on(t) || caller!=app_return) return false;
        const bool overlapping=opened_;
        clear_batch();
        opened_=true;
        fault_=overlapping;
        ++batch_;
        return true;
    }
    bool post_drain(unsigned t, Addr caller, ClockMs now, const Proof& current) noexcept {
        if (!on(t) || !opened_ || caller!=app_return || fault_) return false;
        if (topology_) { fault_=true; return false; }
        if (!match(current)) { invalidate(); owner_.reset(); fault_=true; return false; }
        topology_=true;
        if (session_ready_ && have_sample_ && now>=received_ && now-received_<=max_lease_ms) {
            frozen_=desired_;
            frozen_sequence_=sequence_;
        }
        else if (have_sample_ && (now<received_ || now-received_>max_lease_ms)) {
            have_sample_=false;
            desired_={};
        }
        return true;
    }
    bool pad_begin(unsigned t, Addr caller, const Owner& observed) noexcept {
        if (!on(t) || !opened_ || !topology_ || caller!=sampler_return || fault_) return false;
        if (lane_ || !owner_ || observed!=*owner_) { invalidate(); owner_.reset(); fault_=true; return false; }
        lane_=true;
        return true;
    }
    std::uint64_t after_read(unsigned t, Addr caller, unsigned ordinal, std::uint64_t original) noexcept {
        if (!on(t) || !opened_ || !topology_ || !lane_ || fault_) return original;
        if (ordinal>=20 || caller!=(ordinal<6 ? sampler_return : buttons_return)) return original;
        const auto mask=ordinal<6 ? 0xffffULL : 0xffULL;
        if (ordinal!=cursor_ || (original & mask)!=0) {
            invalidate();
            owner_.reset();
            fault_=true;
            return original;
        }
        ++cursor_;
        const std::uint64_t next=ordinal<6
            ? static_cast<std::uint16_t>(frozen_.axes[ordinal]) : frozen_.buttons[ordinal-6];
        if (next) ++changed_;
        return (original & ~mask) | next;
    }
    void app_end(unsigned t) noexcept {
        if (!on(t) || !opened_) return;
        const bool complete=opened_ && topology_ && lane_ && !fault_ && cursor_==20;
        latest_={batch_,cursor_,changed_,complete ? Result::complete : Result::incomplete,complete && changed_==0,complete ? frozen_sequence_ : 0};
        if (!complete) invalidate();
        clear_batch();
    }
    void reset(unsigned t) noexcept {
        if (!on(t)) return;
        invalidate();
        latest_={batch_,0,0,Result::reset,false};
        clear_batch();
    }
    bool revoke_owner(unsigned t,std::uint64_t epoch) noexcept {
        if (!on(t) || opened_ || !owner_ || epoch!=owner_->room_epoch) return false;
        invalidate();
        owner_.reset();
        return true;
    }
    bool close_room(unsigned t,std::uint64_t epoch) noexcept {
        if (!on(t) || opened_ || !epoch || (owner_ && owner_->room_epoch!=epoch)) return false;
        invalidate();
        owner_.reset();
        latest_={};
        return true;
    }
    Audit audit(unsigned t) const noexcept { return on(t) ? latest_ : Audit{}; }
};
}
