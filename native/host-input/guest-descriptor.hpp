#pragma once
#include "private-player.hpp"
#include <bcrypt.h>
#include <cstring>

namespace h2t_players {
struct RecordList { Addr begin{}, end{}, capacity{}; };
struct Location { float x{}, y{}; };
using Resolve = Addr (*)(Addr, int);
using UnitGet = Addr (*)(int);
inline Addr world_object(Addr world, int id) noexcept {
    return reinterpret_cast<Resolve>(game_base + 0x2ca370)(world, id);
}
inline Addr unit_object(int id) noexcept {
    return reinterpret_cast<UnitGet>(game_base + 0x2b2e80)(id);
}

class GuestDescriptor {
    RecordList list_{};
    Addr record_{};
    EngineHeap heap_{};
    // The loader keys its SJSON read/size overrides by FileStream address.
    // Keep this binary-only stream distinct from stock temporary streams.
    alignas(16) std::array<Addr,6> stream_{};
    char read_error_[128]{};
    static constexpr char stem[] = "H2TGuest";

    const char* verify_stream() noexcept {
        using Open = bool (*)(int, const char*, int, void*);
        using Read = size_t (*)(void*, void*, size_t);
        using Close = bool (*)(void*);
        constexpr std::array<unsigned char,32> expected{
            0x4a,0xac,0x2b,0x64,0xb1,0x8c,0xbb,0xf9,0xb7,0x6b,0x66,0x1d,0x50,0xd0,0x0a,0xc5,
            0x5c,0xe0,0xfd,0x4b,0x19,0xb6,0x6f,0xc9,0xbb,0x03,0x0e,0x91,0x23,0x05,0x0b,0xba};
        // LoadMapThings appends the extension and opens in resource directory 16 (Maps/bin).
        char filename[sizeof(stem) + sizeof(".thing_bin") - 1]{};
        sprintf_s(filename, "%s.thing_bin", stem);
        stream_ = {};
        if (!reinterpret_cast<Open>(game_base + 0x1c89b0)(16, filename, 9, stream_.data()))
            return "descriptor open failed: Maps/bin/H2TGuest.thing_bin";
        if (stream_[0] != game_base + 0x5487b0) {
            const auto close = read<Close>(stream_[0] + sizeof(Addr));
            if (close && *close) (*close)(stream_.data());
            return "descriptor open returned unexpected filesystem";
        }
        std::array<unsigned char,154> bytes{};
        const auto file_size = stream_[4]; // PlatformOpenFile caches ftell at +0x20.
        const auto n = reinterpret_cast<Read>(game_base + 0x178d0)(stream_.data(), bytes.data(), bytes.size());
        const bool closed = reinterpret_cast<Close>(game_base + 0x17880)(stream_.data());
        if (n != 153) {
            sprintf_s(read_error_, "descriptor read %zu bytes, expected 153 (stock file size %zu)", n, file_size);
            return read_error_;
        }
        if (!closed) return "descriptor stream close failed";
        std::array<unsigned char,32> digest{};
        if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, bytes.data(), 153, digest.data(), ULONG(digest.size())) < 0)
            return "descriptor SHA-256 calculation failed";
        return digest == expected ? nullptr : "descriptor SHA-256 mismatch";
    }
public:
    Addr address() const noexcept { return record_; }
    bool has_storage() const noexcept { return list_.begin != 0; }
    const char* load(Addr host_record, Location point) noexcept {
        if (!std::isfinite(point.x) || !std::isfinite(point.y)) return "descriptor spawn coordinates invalid";
        if (!host_record) return "original host descriptor unavailable";
        if (has_storage()) return "previous descriptor storage still retained";
        if (!heap_.bind()) return "descriptor allocator unavailable";
        if (const char* failure = verify_stream()) return failure;
        // EASTL inline string on the pinned build.
        alignas(8) char name[24]{};
        constexpr size_t length = sizeof(stem) - 1;
        static_assert(length < sizeof(name));
        memcpy(name, stem, length);
        name[23] = static_cast<char>(23 - length);
        using Parse = void (*)(RecordList*, const void*);
        reinterpret_cast<Parse>(game_base + 0xbed20)(&list_, name);
        if (!list_.begin) return "LoadMapThings returned no descriptor";
        if (list_.end != list_.begin + sizeof(Addr) || list_.capacity < list_.end || list_.capacity-list_.begin>64)
            return "unexpected LoadMapThings collection";
        const auto record = read<Addr>(list_.begin).value_or(0);
        const auto groups = read<RecordList>(record + 0x18), original = read<RecordList>(host_record + 0x18);
        const auto apart = [](Addr a, size_t n, Addr b, size_t m) {
            return a <= b ? n <= b-a : m <= a-b;
        };
        if (!record || !apart(record, 0xd8, host_record, 0xd8) || !groups || !original || !groups->begin ||
            groups->capacity < groups->begin || original->capacity < original->begin ||
            !apart(groups->begin, groups->capacity-groups->begin, original->begin, original->capacity-original->begin) ||
            !apart(record, 0xd8, list_.begin, list_.capacity-list_.begin) ||
            !apart(groups->begin, groups->capacity-groups->begin, record, 0xd8) ||
            !apart(groups->begin, groups->capacity-groups->begin, list_.begin, list_.capacity-list_.begin) ||
            read<std::uint8_t>(record + 0x97).value_or(0x80) >= 0x80 || groups->end != groups->begin + 4 ||
            groups->capacity < groups->end || groups->capacity-groups->begin>32 || groups->begin%4 ||
            !apart(list_.begin, list_.capacity-list_.begin, host_record, 0xd8) ||
            !apart(groups->begin, groups->capacity-groups->begin, host_record, 0xd8) || read<Addr>(record + 0x60) != Addr{0} ||
            read<Addr>(record + 0x98) != Addr{0}) return "descriptor members or ownership invalid";
        record_ = record;
        const auto hash = read<unsigned>(record + 4).value_or(0);
        using UnitData = Addr (*)(unsigned);
        const auto data = hash ? reinterpret_cast<UnitData>(game_base + 0xb7ff0)(hash) : 0;
        if (!data || read<std::uint8_t>(data + 0x31).value_or(0) == 0) return "descriptor PlayerUnit class unavailable";
        if (read<int>(record + 0x10) != -1 || read<std::uint8_t>(record) != 2 || read<int>(record + 0x58) != 0)
            return "descriptor type, ID or parent invalid";
        // Spawn arguments on a new unpublished map definition. Its Unit has not been created.
        memcpy(reinterpret_cast<void*>(record + 8), &point, sizeof(point));
        return nullptr;
    }
    bool release() noexcept {
        if (!has_storage()) return true;
        if (!record_ || read<Addr>(list_.begin) != record_) return false;
        using Destroy = void (*)(Addr);
        reinterpret_cast<Destroy>(game_base + 0xbf430)(record_);
        heap_.free(reinterpret_cast<void*>(record_));
        heap_.free(reinterpret_cast<void*>(list_.begin));
        list_ = {};
        record_ = 0;
        return true;
    }
};
}
