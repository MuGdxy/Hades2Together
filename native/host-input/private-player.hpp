#pragma once
#include "player-slots.hpp"
#include "player-constructor-bytes.hpp"

namespace h2t_players {
// Steam 1.143476. The stock constructor initializes the instance, then creates
// process-global debug registrations and a mutex already owned by the host.
struct PlayerConstruction {
    Addr storage{};
    bool initialized{};
};
inline thread_local PlayerConstruction* constructing{};
inline SafetyHookMid constructor_hook;

inline void finish_private_constructor(SafetyHookContext& frame) noexcept {
    if (!constructing || frame.rdi != constructing->storage) return;
    // Only our synchronous call can reach this receiver on this thread. The
    // validated function has not branched or called out since saving its frame.
    constructing->initialized = !constructing->initialized && frame.rcx == 0 &&
        frame.rbp == frame.rsp + 0x59 && read<Addr>(frame.rbp + 0x3f) == frame.rdi;
    // The pinned prefix makes no calls and leaves RSP unchanged. The original
    // epilogue uses RSP, independently of the member validation reported above.
    frame.rip = game_base + 0x1c9b7a;
}

inline bool prepare_player_constructor() {
    using namespace h2t_seat_owner_bytes;
    if (constructor_hook) return constructor_hook.enabled();
    DWORD64 base{};
    const auto f = RtlLookupFunctionEntry(game_base + 0x1c9980, &base, nullptr);
    constexpr std::array<unsigned char, 26> unwind{
        0x11,0x20,0x0b,0x00,0x20,0x74,0x1b,0x00,0x20,0x64,0x1a,0x00,0x20,
        0x34,0x19,0x00,0x20,0x01,0x14,0x00,0x14,0xf0,0x12,0xe0,0x10,0x50};
    if (!f || base != game_base || f->BeginAddress != 0x1c98d0 || f->EndAddress != 0x1c9b9a ||
        f->UnwindData != 0x51a74c ||
        read<std::array<unsigned char, 26>>(base + f->UnwindData) != unwind ||
        read<std::array<unsigned char, ctorPrefix.size()>>(base + 0x1c98d0) != ctorPrefix ||
        read<std::array<unsigned char, ctorBoundary.size()>>(base + 0x1c9980) != ctorBoundary ||
        read<std::array<unsigned char, ctorEpilogue.size()>>(base + 0x1c9b7a) != ctorEpilogue) return false;
    constructor_hook = safetyhook::create_mid(base + 0x1c9980, finish_private_constructor);
    return static_cast<bool>(constructor_hook);
}

struct EngineHeap {
    using Allocate = void* (*)(size_t, size_t);
    using Free = void (*)(void*);
    Allocate allocate{};
    Free free{};

    bool bind() noexcept {
        auto crt = GetModuleHandleW(L"ucrtbase.dll");
        if (!crt) return false;
        allocate = reinterpret_cast<Allocate>(GetProcAddress(crt, "_aligned_malloc"));
        free = reinterpret_cast<Free>(GetProcAddress(crt, "_aligned_free"));
        return allocate && free && read<Addr>(game_base + 0x3abe50) == reinterpret_cast<Addr>(allocate) &&
            read<Addr>(game_base + 0x3abe58) == reinterpret_cast<Addr>(free);
    }
};

struct RumbleVector { Addr begin{}, end{}, capacity{}; };
inline bool valid_rumble(const RumbleVector& v) noexcept {
    return v.begin <= v.end && v.end <= v.capacity &&
        (v.begin || !v.capacity) && !(v.begin % alignof(Addr)) &&
        (v.end - v.begin) % (2 * sizeof(Addr)) == 0 && (v.capacity - v.begin) % (2 * sizeof(Addr)) == 0;
}

class PrivatePlayer {
    EngineHeap heap_{};
    Addr player_{};
    DWORD thread_{};
    bool initialized_{};
public:
    PrivatePlayer() = default;
    PrivatePlayer(const PrivatePlayer&) = delete;
    PrivatePlayer& operator=(const PrivatePlayer&) = delete;
    Addr address() const noexcept { return player_; }
    bool create() {
        if (player_ || constructing || !h2t_observe::latest_on_game_thread().serial ||
            !heap_.bind() || !prepare_player_constructor()) return false;
        player_ = reinterpret_cast<Addr>(heap_.allocate(0xb8, 8));
        if (!player_) return false;
        thread_ = GetCurrentThreadId();
        PlayerConstruction request{player_};
        constructing = &request;
        const std::uint8_t parked = 4;
        using Ctor = Addr (*)(Addr, Addr, const std::uint8_t*);
        const auto result = reinterpret_cast<Ctor>(game_base + 0x1c98d0)(player_, 0, &parked);
        constructing = nullptr;
        // Even a rejected private prefix ran the exact member initialization.
        initialized_ = result == player_ && read<Addr>(player_ + 0x40) == game_base + 0x5488b0 &&
            read<Addr>(player_ + 0x48) == 1 && read<std::uint8_t>(player_ + 3) == parked;
        return initialized_ && request.initialized;
    }

    // The lifetime owner calls this only after closing dispatch and the matching
    // UnitManager::Remove return (or before a Unit has ever been constructed).
    bool release_detached() noexcept {
        if (!player_) return true;
        if (!initialized_ || GetCurrentThreadId() != thread_ || constructing) return false;
        const auto slots = Slots::current();
        if (!slots) return false;
        for (unsigned i = 0; i < 2; ++i) {
            const auto player = read<Addr>(slots->players + i * sizeof(Addr));
            if (!player || *player == player_) return false;
        }
        if (read<Addr>(player_ + 0x18) != Addr{0} || read<Addr>(player_ + 0x20) != Addr{0}) return false;
        const auto buckets = read<Addr>(player_ + 0x40);
        const auto count = read<size_t>(player_ + 0x48);
        const auto first = read<RumbleVector>(player_ + 0x78), second = read<RumbleVector>(player_ + 0x90);
        const auto empty = game_base + 0x5488b0;
        if (!buckets || !*buckets || !count || !*count || ((*count == 1) != (*buckets == empty)) ||
            !first || !second || !valid_rumble(*first) || !valid_rumble(*second) ||
            (first->begin && second->begin && first->begin < second->capacity && second->begin < first->capacity)) return false;

        // These are the per-instance calls at PlayerManager::ShutDown+0x65,
        // +0x92 and +0x9e. set_capacity here is the zero-capacity specialization:
        // it destroys each shared_ptr, zeroes all three fields and frees storage.
        using FreeNodes = void (*)(Addr, Addr, size_t);
        using ClearRumble = void (*)(Addr);
        reinterpret_cast<FreeNodes>(game_base + 0x6a6d0)(player_ + 0x40, *buckets, *count);
        if (*count > 1) heap_.free(reinterpret_cast<void*>(*buckets));
        *reinterpret_cast<Addr*>(player_ + 0x40) = empty;
        *reinterpret_cast<size_t*>(player_ + 0x48) = 1;
        *reinterpret_cast<size_t*>(player_ + 0x50) = 0;
        *reinterpret_cast<unsigned*>(player_ + 0x60) = 0;
        auto clear = reinterpret_cast<ClearRumble>(game_base + 0x1cc590);
        clear(player_ + 0x78);
        clear(player_ + 0x90);
        heap_.free(reinterpret_cast<void*>(player_));
        player_ = 0;
        initialized_ = false;
        return true;
    }
};
}
