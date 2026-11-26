#pragma once
#include "observe-sampler-candidate.hpp"
#include <span>

namespace h2t_players {
using h2t_observe::Addr;
using h2t_observe::game_base;
using h2t_observe::read;

struct Owner {
    Addr world{}, player{}, unit{}, handler{};
    bool operator==(const Owner&) const = default;
};

using Resize = void (*)(Addr, size_t);
constexpr auto playable_lanes = h2t_observe::playable_lanes;
inline Addr reserved_players{};
inline void reserve_at_first_allocation(SafetyHookContext& f) noexcept {
    const auto base = reinterpret_cast<Addr>(GetModuleHandleW(nullptr));
    if (f.rcx != base+0x65cc1e0 || f.rdx != 2 || read<Addr>(base+0x831dc0) != Addr{0} ||
        read<std::array<Addr,3>>(f.rcx) != std::array<Addr,3>{} ||
        read<std::uint8_t>(base+0x837e3e) != 0) return;
    // The original resize(2) immediately following this callback restores the stock
    // logical size, retaining this allocation. No Player vector has escaped yet.
    reinterpret_cast<Resize>(base+0xb9af0)(f.rcx,playable_lanes);
    reserved_players=read<Addr>(f.rcx).value_or(0);
}
struct Slots {
    Addr world{}, manager{}, players{}, handlers{};
    bool operator==(const Slots&) const = default;

    static std::optional<Slots> current() noexcept {
        const auto world = read<Addr>(game_base + 0x4dcc1b0).value_or(0);
        const auto manager = read<Addr>(game_base + 0x831dc0).value_or(0);
        if (!world || !manager) return {};
        const auto players = read<Addr>(manager + 0x18).value_or(0);
        const auto handlers = read<Addr>(manager).value_or(0);
        const auto end=read<Addr>(manager+0x20).value_or(0);
        if (!players || !handlers || end<players+2*sizeof(Addr) || (end-players)%sizeof(Addr) ||
            end>players+playable_lanes*sizeof(Addr) ||
            read<Addr>(manager+8)!=handlers+(playable_lanes+1)*sizeof(Addr)) return {};
        return Slots{world, manager, players, handlers};
    }

    unsigned size() const noexcept {
        return unsigned((read<Addr>(manager+0x20).value_or(players)-players)/sizeof(Addr));
    }
    unsigned capacity() const noexcept {
        return players == reserved_players && read<Addr>(manager+0x28)==players+playable_lanes*sizeof(Addr)
            ? playable_lanes : size();
    }
    bool ensure(unsigned lane) const noexcept {
        if (lane < size()) return true;
        if (lane >= capacity()) return false;
        reinterpret_cast<Resize>(game_base+0xb9af0)(manager+0x18,lane+1);
        return current()==*this && lane<size();
    }

    std::optional<Owner> primary(int hero_id) const noexcept {
        const auto player = read<Addr>(players).value_or(0);
        const auto handler = read<Addr>(handlers).value_or(0);
        if (hero_id <= 0 || !player || !handler || read<std::uint8_t>(player + 3) != 0 ||
            read<std::uint8_t>(handler + 0x0c) != 0) return {};
        const auto unit = read<Addr>(player + 0x18).value_or(0);
        if (!unit || read<int>(unit + 0x48) != hero_id) return {};
        return Owner{world, player, unit, handler};
    }
};

// The factory owns the allocations. Use this registration on the original game
// thread between stock dispatches, after both original World/UnitManager lookups
// identify the factory result and AssignController has returned. Unpublish before Remove.
class SecondarySlot {
    Slots slots_{};
    Owner primary_{}, secondary_{};
    int unit_id_{};
    std::uint64_t generation_{};
    DWORD thread_{};
    bool published_{};

    static bool replace(Addr cell, Addr expected, Addr next) noexcept {
        return reinterpret_cast<Addr>(InterlockedCompareExchangePointer(
            reinterpret_cast<void* volatile*>(cell), reinterpret_cast<void*>(next),
            reinterpret_cast<void*>(expected))) == expected;
    }

    bool same_tables() const noexcept {
        return thread_ == GetCurrentThreadId() && Slots::current() == slots_;
    }

    unsigned lane_{};
    bool assigned(const Slots& slots, const Owner& owner, int id) const noexcept {
        return owner.world == slots.world && id > 0 && owner.player && owner.unit && owner.handler &&
            read<Addr>(owner.unit) == game_base + 0x4ef178 && read<int>(owner.unit + 0x48) == id &&
            read<Addr>(owner.unit + 0x658) == owner.player && read<std::uint8_t>(owner.player + 3) == lane_ &&
            read<Addr>(slots.handlers + lane_*sizeof(Addr)) == owner.handler &&
            read<std::uint8_t>(owner.handler + 0x0c) == lane_ && read<std::uint8_t>(owner.handler+0x4c)==lane_ &&
            read<Addr>(game_base + 0x831910 + lane_*sizeof(Addr)) == owner.handler + 0x20;
    }

public:
    explicit SecondarySlot(unsigned lane) : lane_(lane) {}
    SecondarySlot(const SecondarySlot&) = delete;
    SecondarySlot& operator=(const SecondarySlot&) = delete;

    bool accepts(const Slots& current, const Owner& primary) const noexcept {
        if (lane_ >= current.size()) return !thread_;
        const auto entry = read<Addr>(current.players + lane_*sizeof(Addr));
        if (!thread_) return entry == Addr{0};
        return published_ && thread_ == GetCurrentThreadId() && current == slots_ &&
            primary == primary_ && read<Addr>(primary.unit + 0x658) == primary.player &&
            entry == secondary_.player && assigned(current, secondary_, unit_id_) &&
            read<Addr>(secondary_.player + 0x18) == secondary_.unit;
    }

    enum class Publication { refused, published, detach_pending };
    Publication publish(std::uint64_t generation, int host_id, const Owner& host,
                        int id, const Owner& guest) noexcept {
        if (thread_ || generation <= generation_ || !h2t_observe::latest_on_game_thread().serial || id == host_id ||
            guest.player == host.player || guest.unit == host.unit || guest.handler == host.handler)
            return Publication::refused;
        const auto slots = Slots::current();
        if (!slots || lane_>=slots->size() || slots->primary(host_id) != host || read<Addr>(host.unit + 0x658) != host.player ||
            !assigned(*slots, guest, id) ||
            read<Addr>(slots->players + lane_*sizeof(Addr)) != Addr{0} ||
            read<Addr>(guest.player + 0x18) != Addr{0}) return Publication::refused;
        if (!replace(guest.player + 0x18, 0, guest.unit)) return Publication::refused;
        slots_ = *slots;
        primary_ = host;
        generation_ = generation;
        secondary_ = guest;
        unit_id_ = id;
        thread_ = GetCurrentThreadId();
        published_ = replace(slots_.players + lane_*sizeof(Addr), 0, guest.player);
        if (published_) return Publication::published;
        return unpublish(generation) ? Publication::refused : Publication::detach_pending;
    }

    // Revoke input first. A failed detach retains the identity for retry and
    // the caller must keep the Player and Unit alive until this returns true.
    bool unpublish(std::uint64_t generation) noexcept {
        if (!generation || generation != generation_) return false;
        if (!thread_) return true;
        if (!same_tables()) return false;
        const auto primary = read<Addr>(slots_.players);
        if (!primary || *primary == secondary_.player) return false;
        if (published_ && !replace(slots_.players + lane_*sizeof(Addr), secondary_.player, 0)) return false;
        published_ = false;
        const auto entry = read<Addr>(slots_.players + lane_*sizeof(Addr));
        if (!entry || *entry == secondary_.player ||
            !replace(secondary_.player + 0x18, secondary_.unit, 0)) return false;
        thread_ = 0;
        return true;
    }
};

inline auto reservations() {
    static std::array<std::optional<SecondarySlot>,playable_lanes> slots;
    return std::span(slots);
}
inline SecondarySlot& reservation(unsigned lane) {
    auto& slot=reservations()[lane];
    if (!slot) slot.emplace(lane);
    return *slot;
}
}
