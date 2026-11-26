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

// Resolve through the same engine file namespace used by LoadMapThings. Check
// the bytes before asking the engine to parse the redirected private resource.
inline const char* guest_descriptor_stem() noexcept {
    using Open = bool (*)(int, const char*, int, void*);
    using Read = size_t (*)(void*, void*, size_t);
    using Close = bool (*)(void*);
    constexpr std::array<unsigned char,32> expected{
        0x4a,0xac,0x2b,0x64,0xb1,0x8c,0xbb,0xf9,0xb7,0x6b,0x66,0x1d,0x50,0xd0,0x0a,0xc5,
        0x5c,0xe0,0xfd,0x4b,0x19,0xb6,0x6f,0xc9,0xbb,0x03,0x0e,0x91,0x23,0x05,0x0b,0xba};
    for (auto stem : {"Maps/bin/H2TGuest", "bin/H2TGuest", "H2TGuest"}) {
        char filename[40]{};
        sprintf_s(filename, "%s.thing_bin", stem);
        alignas(16) std::array<Addr,6> stream{};
        if (!reinterpret_cast<Open>(game_base + 0x1c89b0)(16, filename, 9, stream.data())) continue;
        if (stream[0] != game_base + 0x5487b0) {
            const auto close = read<Close>(stream[0] + sizeof(Addr));
            if (close && *close) (*close)(stream.data());
            return nullptr;
        }
        std::array<unsigned char,154> bytes{};
        const auto n = reinterpret_cast<Read>(game_base + 0x178d0)(stream.data(), bytes.data(), bytes.size());
        reinterpret_cast<Close>(game_base + 0x17880)(stream.data());
        std::array<unsigned char,32> digest{};
        if (n == 153 && BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, bytes.data(), 153,
                                   digest.data(), ULONG(digest.size())) >= 0 && digest == expected) return stem;
    }
    return nullptr;
}

class GuestDescriptor {
    RecordList list_{};
    Addr record_{};
    EngineHeap heap_{};
public:
    Addr address() const noexcept { return record_; }
    bool has_storage() const noexcept { return list_.begin != 0; }
    bool load(Addr host_record, Location point) noexcept {
        if (!std::isfinite(point.x) || !std::isfinite(point.y) || !host_record || has_storage() || !heap_.bind()) return false;
        const char* stem = guest_descriptor_stem();
        if (!stem) return false;
        // EASTL inline string on the pinned build.
        alignas(8) char name[24]{};
        const size_t length = strlen(stem);
        memcpy(name, stem, length);
        name[23] = static_cast<char>(23 - length);
        using Parse = void (*)(RecordList*, const void*);
        reinterpret_cast<Parse>(game_base + 0xbed20)(&list_, name);
        if (!list_.begin || list_.end != list_.begin + sizeof(Addr) || list_.capacity < list_.end || list_.capacity-list_.begin>64) return false;
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
            read<Addr>(record + 0x98) != Addr{0}) return false;
        record_ = record;
        const auto hash = read<unsigned>(record + 4).value_or(0);
        using UnitData = Addr (*)(unsigned);
        const auto data = hash ? reinterpret_cast<UnitData>(game_base + 0xb7ff0)(hash) : 0;
        if (!data || read<std::uint8_t>(data + 0x31).value_or(0) == 0 ||
            read<int>(record + 0x10) != -1 || read<std::uint8_t>(record) != 2 ||
            read<int>(record + 0x58) != 0) return false;
        // Spawn arguments on a new unpublished map definition. Its Unit has not been created.
        memcpy(reinterpret_cast<void*>(record + 8), &point, sizeof(point));
        return true;
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
