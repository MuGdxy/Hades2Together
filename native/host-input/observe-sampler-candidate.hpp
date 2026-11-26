#pragma once
// Scratch-only Hell2Modding a800697 / pinned SafetyHook integration candidate.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <safetyhook.hpp>
#include <algorithm>
#include <new>
#include <optional>
#include <string_view>
#include "observe-sampler-core.hpp"

namespace h2t_observe {
template<class T> std::optional<T> read(Addr address) noexcept {
    T result{};
    SIZE_T actual = 0;
    if (!address || !ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(address),
        &result, sizeof result, &actual) || actual != sizeof result) return std::nullopt;
    return result;
}

inline Addr game_base{};
inline std::atomic<bool> armed{};
inline Recorder recorder;
// Installed only by the separate scratch active adapter, before its observations are armed.
struct SampleTaps {
    void (*input)(unsigned,Addr) noexcept{};
    void (*topology)(unsigned,Addr) noexcept{};
    void (*pad)(unsigned,Addr,unsigned,Pad) noexcept{};
    std::uint64_t (*after_original)(unsigned,Addr,unsigned,std::uint64_t) noexcept{};
    void (*reset)(unsigned,Addr) noexcept{};
    void (*end)(unsigned) noexcept{};
};
inline SampleTaps staged_taps;
inline Addr caller_at(const SafetyHookContext& context, unsigned delta) noexcept {
    const auto found = read<Addr>(context.rsp + delta);
    return found && *found >= game_base ? *found - game_base : 0;
}
inline void at_input(SafetyHookContext& context) noexcept {
    if (!armed.load(std::memory_order_acquire)) return;
    const auto thread=GetCurrentThreadId();
    const auto caller=caller_at(context,0);
    recorder.begin(thread,caller);
    if (staged_taps.input) staged_taps.input(thread,caller);
}
inline void at_reset(SafetyHookContext& context) noexcept {
    if (!armed.load(std::memory_order_acquire)) return;
    const auto thread=GetCurrentThreadId();
    const auto caller=caller_at(context,0);
    recorder.reset(thread,caller);
    if (staged_taps.reset) staged_taps.reset(thread,caller);
}
inline void at_topology(SafetyHookContext& context) noexcept {
    if (!armed.load(std::memory_order_acquire)) return;
    const auto first = read<Addr>(context.rsi + 0x20);
    const auto last = read<Addr>(context.rsi + 0x28);
    unsigned count = 3; // unreadable, misaligned, or above fixture limit
    if (first && last && *last >= *first && (*last-*first) % sizeof(Addr) == 0
        && (*last-*first) / sizeof(Addr) <= 2) count = unsigned((*last-*first) / sizeof(Addr));
    std::array<Addr,2> objects{};
    if (count <= objects.size()) {
        for (unsigned i = 0; i < count; ++i) objects[i] = read<Addr>(*first+i*sizeof(Addr)).value_or(0);
    }
    const auto thread=GetCurrentThreadId();
    const auto caller=caller_at(context,0xa8);
    if (recorder.begin_topology(thread,caller,count,objects) && staged_taps.topology)
        staged_taps.topology(thread,caller);
}
inline void at_pad(SafetyHookContext& context) noexcept {
    if (!armed.load(std::memory_order_acquire)) return;
    const auto object = context.rsi;
    const auto controller = read<Addr>(object + 0x48);
    const auto instance = read<std::int32_t>(object + 0x50);
    const auto model = read<std::uint32_t>(object + 0x38);
    const auto thread=GetCurrentThreadId();
    const auto caller=caller_at(context,0x88);
    const auto lane=unsigned(context.rbp);
    const Pad observed{object,controller.value_or(0),model ? instance.value_or(-1) : -1,model.value_or(0)};
    recorder.pad(thread,caller,lane,observed);
    if (staged_taps.pad) staged_taps.pad(thread,caller,lane,observed);
}
template<unsigned Ordinal> void at_read(SafetyHookContext& context) noexcept {
    if (!armed.load(std::memory_order_acquire)) return;
    const auto thread=GetCurrentThreadId();
    const auto caller=caller_at(context,Ordinal>=6 && Ordinal<20 ? 0x28 : 0x88);
    const auto original=context.rax;
    recorder.value(thread,caller,Ordinal,static_cast<std::uint16_t>(original));
    if constexpr (Ordinal<20) {
        if (staged_taps.after_original) {
            const auto replacement=staged_taps.after_original(thread,caller,Ordinal,original);
            if (replacement!=original) context.rax=replacement;
        }
    }
}
inline void at_return(SafetyHookContext&) noexcept {
    if (!armed.load(std::memory_order_acquire)) return;
    const auto thread=GetCurrentThreadId();
    recorder.end(thread);
    if (staged_taps.end) staged_taps.end(thread);
}struct Site {
    Addr rva;
    std::string_view bytes;
    safetyhook::MidHookFn read_context;
};
inline constexpr std::array sites{
    Site{0x2f43f0, {"\x4c\x8b\xdc\x56\x48\x81\xec\xa0\x00\x00\x00", 11}, at_input},
    Site{0x2f483c, {"\x48\x8b\x4e\x28\x48\x8b\xf8", 7}, at_topology},
    Site{0x2f22fa, {"\x4c\x8b\x76\x48\x33\xd2", 6}, at_pad},
    Site{0x63596, {"\x48\x8b\xb7\xc0\x00\x00\x00", 7}, at_return},
    Site{0x2f49b0, {"\x40\x57\x48\x83\xec\x20", 6}, at_reset},
    Site{0x2f2309, {"\xf3\x44\x0f\x10\x05\x1a\x58\x20\x00", 9}, at_read<0>},
    Site{0x2f2344, {"\x0f\xbf\xc8\xba\x02\x00\x00\x00", 8}, at_read<1>},
    Site{0x2f2373, {"\x0f\xbf\xc8\xba\x03\x00\x00\x00", 8}, at_read<2>},
    Site{0x2f239b, {"\x0f\xbf\xc8\xba\x04\x00\x00\x00", 8}, at_read<3>},
    Site{0x2f23ca, {"\x0f\xbf\xc8\xba\x05\x00\x00\x00", 8}, at_read<4>},
    Site{0x2f23fb, {"\x48\x8b\x57\x10\x44\x8b\xcd", 7}, at_read<5>},
    Site{0x2f20a3, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<6>},
    Site{0x2f20c7, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<7>},
    Site{0x2f20eb, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<8>},
    Site{0x2f210f, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<9>},
    Site{0x2f2133, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<10>},
    Site{0x2f2157, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<11>},
    Site{0x2f217b, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<12>},
    Site{0x2f219f, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<13>},
    Site{0x2f21c3, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<14>},
    Site{0x2f21e7, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<15>},
    Site{0x2f220b, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<16>},
    Site{0x2f222f, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<17>},
    Site{0x2f2253, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<18>},
    Site{0x2f2277, {"\x3c\x01\x75\x12\x48\x69\xc7\x60\x02\x00\x00", 11}, at_read<19>},
    Site{0x2f244a, {"\x3c\x01\x75\x14\x48\x8b\x47\x10", 8}, at_read<20>},
};

class Backend {
    Addr image_{};
    std::array<SafetyHookMid,sites.size()> hooks_{};
public:
    explicit Backend(Addr image) : image_(image) {}
    bool preflight() const noexcept {
        for (const auto& site : sites) {
            std::array<char,16> actual{};
            SIZE_T size{};
            if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(image_+site.rva),
                actual.data(), site.bytes.size(), &size) || size != site.bytes.size()
                || !std::equal(site.bytes.begin(), site.bytes.end(), actual.begin())) return false;
        }
        return true;
    }
    bool prepare(std::size_t index) noexcept {
        const auto& site = sites[index];
        try {
            auto hook = SafetyHookMid::create(image_+site.rva, site.read_context, SafetyHookMid::StartDisabled);
            if (!hook || hook->enabled() || hook->original_bytes().size() != site.bytes.size()) return false;
            hooks_[index] = std::move(*hook);
            return true;
        } catch (...) { return false; }
    }
    bool enable(std::size_t index) noexcept {
        try { return hooks_[index].enable().has_value(); }
        catch (...) { return false; }
    }
    bool disable_if_enabled(std::size_t index) noexcept {
        try { return !hooks_[index].enabled() || hooks_[index].disable().has_value(); }
        catch (...) { return false; }
    }
};

// Wire only into an explicitly approved pinned scratch loader. Loader supplies its
// exact symbol addresses and an independently established identity gate for the files.
inline Install install_for_reviewed_loader(bool identity_ok, Addr update_symbol, Addr pad_symbol) noexcept {
    static std::atomic<Install> status{Install::unattempted};
    auto expected = Install::unattempted;
    if (!status.compare_exchange_strong(expected, Install::installing)) return expected;
    const auto result = [&]() noexcept {
        const auto image = reinterpret_cast<Addr>(GetModuleHandleW(nullptr));
        if (!identity_ok || !image || update_symbol != image+0x2f43f0 || pad_symbol != image+0x2f22a0)
            return Install::preflight_failed;
        game_base = image;
        // Lifetime is the scratch process. Never free a hook after a failed rollback.
        const auto backend = new (std::nothrow) Backend(image);
        if (!backend) return Install::prepare_failed;
        const auto installed = install_all<sites.size()>(*backend, armed);
        if (installed != Install::ready && installed != Install::rollback_failed) delete backend;
        return installed;
    }();
    status.store(result, std::memory_order_release);
    return result;
}
inline Trace latest_on_game_thread() noexcept {
    return armed.load(std::memory_order_acquire) ? recorder.latest(GetCurrentThreadId()) : Trace{};
}
}
