#pragma once

#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

#pragma comment(lib, "bcrypt.lib")

namespace h2t_release {
inline bool matches(std::uintptr_t address, std::size_t length, std::string_view expected) noexcept {
    std::array<unsigned char, 176> bytes{};
    std::array<unsigned char, 32> digest{};
    if (!address || !length || length > bytes.size() || expected.size() != digest.size() * 2)
        return false;

    SIZE_T actual{};
    if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(address),
                           bytes.data(), length, &actual) || actual != length ||
        BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, bytes.data(), static_cast<ULONG>(length),
                   digest.data(), static_cast<ULONG>(digest.size())) < 0)
        return false;

    constexpr std::string_view hex = "0123456789abcdef";
    for (std::size_t i = 0; i < digest.size(); ++i) {
        if (expected[i * 2] != hex[digest[i] >> 4] || expected[i * 2 + 1] != hex[digest[i] & 15])
            return false;
    }
    return true;
}
}
