#pragma once
#include "observe-sampler-candidate.hpp"

namespace h2t_players {
using h2t_observe::Addr;
using h2t_observe::game_base;
using h2t_observe::read;

struct Owner {
    Addr world{}, player{}, unit{}, handler{};
    bool operator==(const Owner&) const = default;
};

struct Slots {
    Addr world{}, manager{}, players{}, handlers{};
    bool operator==(const Slots&) const = default;

    static std::optional<Slots> current() noexcept {
        const auto world = read<Addr>(game_base + 0x4dcc1b0).value_or(0);
        const auto manager = read<Addr>(game_base + 0x831dc0).value_or(0);
        if (!world || !manager) return {};
        const auto players = read<Addr>(manager + 0x18).value_or(0);
        const auto handlers = read<Addr>(manager).value_or(0);
        if (!players || !handlers || read<Addr>(manager + 0x20) != players + 2 * sizeof(Addr) ||
            read<Addr>(manager + 8) != handlers + 5 * sizeof(Addr)) return {};
        return Slots{world, manager, players, handlers};
    }

    std::optional<Owner> primary(int hero_id) const noexcept {
        const auto player = read<Addr>(players).value_or(0);
        const auto handler = read<Addr>(handlers).value_or(0);
        if (hero_id <= 0 || !player || !handler || read<std::uint8_t>(player + 3) != 0 ||
            read<std::uint8_t>(handler + 0x0c) != 0) return {};
        const auto unit = read<Addr>(player + 0x18).value_or(0);
        if (!unit || read<int>(unit + 0x48) != hero_id || read<Addr>(unit + 0x658) != player) return {};
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

    static bool assigned(const Slots& slots, const Owner& owner, int id) noexcept {
        return owner.world == slots.world && id > 0 && owner.player && owner.unit && owner.handler &&
            read<Addr>(owner.unit) == game_base + 0x4ef178 && read<int>(owner.unit + 0x48) == id &&
            read<Addr>(owner.unit + 0x658) == owner.player && read<std::uint8_t>(owner.player + 3) == 1 &&
            read<Addr>(slots.handlers + sizeof(Addr)) == owner.handler &&
            read<std::uint8_t>(owner.handler + 0x0c) == 1 &&
            read<Addr>(game_base + 0x831918) == owner.handler + 0x20;
    }

public:
    SecondarySlot() = default;
    SecondarySlot(const SecondarySlot&) = delete;
    SecondarySlot& operator=(const SecondarySlot&) = delete;

    bool accepts(const Slots& current, const Owner& primary) const noexcept {
        const auto entry = read<Addr>(current.players + sizeof(Addr));
        if (!thread_) return entry == Addr{0};
        return published_ && thread_ == GetCurrentThreadId() && current == slots_ &&
            primary == primary_ && entry == secondary_.player && assigned(current, secondary_, unit_id_) &&
            read<Addr>(secondary_.player + 0x18) == secondary_.unit;
    }

    enum class Publication { refused, published, detach_pending };
    Publication publish(std::uint64_t generation, int host_id, const Owner& host,
                        int id, const Owner& guest) noexcept {
        if (thread_ || generation <= generation_ || !h2t_observe::latest_on_game_thread().serial || id == host_id ||
            guest.player == host.player || guest.unit == host.unit || guest.handler == host.handler)
            return Publication::refused;
        const auto slots = Slots::current();
        if (!slots || slots->primary(host_id) != host || !assigned(*slots, guest, id) ||
            read<Addr>(slots->players + sizeof(Addr)) != Addr{0} ||
            read<Addr>(guest.player + 0x18) != Addr{0}) return Publication::refused;
        if (!replace(guest.player + 0x18, 0, guest.unit)) return Publication::refused;
        slots_ = *slots;
        primary_ = host;
        generation_ = generation;
        secondary_ = guest;
        unit_id_ = id;
        thread_ = GetCurrentThreadId();
        published_ = replace(slots_.players + sizeof(Addr), 0, guest.player);
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
        if (published_ && !replace(slots_.players + sizeof(Addr), secondary_.player, 0)) return false;
        published_ = false;
        const auto entry = read<Addr>(slots_.players + sizeof(Addr));
        if (!entry || *entry == secondary_.player ||
            !replace(secondary_.player + 0x18, secondary_.unit, 0)) return false;
        thread_ = 0;
        return true;
    }
};

inline SecondarySlot secondary;
}
