#pragma once
#include "observe-sampler-candidate.hpp"
#include "player-slots.hpp"
#include <bcrypt.h>
#include <filesystem>
#include <fstream>
#include <string>
#pragma comment(lib,"bcrypt.lib")

namespace h2t_observe_runtime {
using namespace h2t_observe;
namespace fs = std::filesystem;
constexpr auto exe_pin = "A6BE16E91683E6FE3E566C5D68C1DCF8992BAB9126B856606D57B7115E9C30DC";
constexpr auto pdb_pin = "DFEBC6219DEAAAA1D96DC03FE2866D14CA621E1836F685FF40E989C81D577EA7";
constexpr auto sdl_pin = "7457CC5C885505B7EBF9C05AD57881468C3DBBA551B3DF8E18CE5D31A09F6A2C";

inline bool hash_matches(const fs::path& path, std::string_view expected) {
    struct Hash {
        BCRYPT_ALG_HANDLE alg{};
        BCRYPT_HASH_HANDLE value{};
        ~Hash() { if (value) BCryptDestroyHash(value); if (alg) BCryptCloseAlgorithmProvider(alg,0); }
    } hash;
    if (BCryptOpenAlgorithmProvider(&hash.alg,BCRYPT_SHA256_ALGORITHM,nullptr,0) < 0 ||
        BCryptCreateHash(hash.alg,&hash.value,nullptr,0,nullptr,0,0) < 0) return false;
    std::ifstream file(path, std::ios::binary);
    if (!file) return false;
    std::array<char,65536> buffer{};
    while (file.read(buffer.data(),buffer.size()) || file.gcount()) {
        if (BCryptHashData(hash.value,reinterpret_cast<PUCHAR>(buffer.data()),
            static_cast<ULONG>(file.gcount()),0) < 0) return false;
    }
    std::array<unsigned char,32> bytes{};
    if (!file.eof() || BCryptFinishHash(hash.value,bytes.data(),bytes.size(),0) < 0) return false;
    constexpr std::string_view hex = "0123456789ABCDEF";
    for (unsigned i=0;i<bytes.size();++i)
        if (hex[bytes[i] >> 4] != expected[2*i] || hex[bytes[i] & 15] != expected[2*i+1]) return false;
    return true;
}
inline fs::path module_path(HMODULE module) {
    wchar_t path[32768]{};
    const auto size=GetModuleFileNameW(module,path,DWORD(std::size(path)));
    return size && size < std::size(path) ? fs::path(std::wstring_view(path,size)) : fs::path{};
}
inline bool pinned_identity() noexcept {
    try {
        wchar_t configured[32768]{};
        const auto size=GetEnvironmentVariableW(L"H2T_SAMPLER_SCRATCH_SHIP",configured,DWORD(std::size(configured)));
        if (!size || size >= std::size(configured)) return false;
        const auto root=fs::canonical(configured);
        const auto exe=fs::canonical(module_path(nullptr));
        const auto sdl=GetModuleHandleW(L"SDL2.dll");
        if (!sdl || exe != root/L"Hades2.exe" || fs::canonical(module_path(sdl)) != root/L"SDL2.dll")
            return false;
        return hash_matches(exe,exe_pin) && hash_matches(root/L"Hades2.pdb",pdb_pin)
            && hash_matches(root/L"SDL2.dll",sdl_pin);
    } catch (...) { return false; }
}

struct Controller;
struct Joystick;
struct Descriptor {
    std::uint16_t version,type,axes,buttons,hats,vendor,product,padding;
    std::uint32_t button_mask,axis_mask;
    const char* name;
    void* callbacks[8]{};
};
static_assert(offsetof(Descriptor,name)==24);
struct Sdl {
    int (*count)(){};
    int (*attach)(const Descriptor*){};
    int (*detach)(int){};
    void (*close)(Controller*){};
    Controller* (*open)(int){};
    Joystick* (*joystick)(Controller*){};
    int (*id)(Joystick*){};
    int (*device_id)(int){};
    int (*virtual_device)(int){};
    int (*attached)(Controller*){};
    std::int16_t (*axis)(Controller*,int){};
    std::uint8_t (*button)(Controller*,int){};
    std::uint8_t (*raw)(Joystick*,int){};
    void (*version)(std::uint8_t*){};
    bool bind() noexcept {
        const auto dll=GetModuleHandleW(L"SDL2.dll");
        if (!dll) return false;
        const auto load=[dll](auto& dest,const char* name){
            dest=reinterpret_cast<std::remove_reference_t<decltype(dest)>>(GetProcAddress(dll,name));
            return dest != nullptr;
        };
        if (!(load(count,"SDL_NumJoysticks") && load(attach,"SDL_JoystickAttachVirtualEx") &&
            load(detach,"SDL_JoystickDetachVirtual") && load(close,"SDL_GameControllerClose") &&
            load(open,"SDL_GameControllerOpen") && load(joystick,"SDL_GameControllerGetJoystick") &&
            load(id,"SDL_JoystickInstanceID") && load(device_id,"SDL_JoystickGetDeviceInstanceID") &&
            load(virtual_device,"SDL_JoystickIsVirtual") && load(attached,"SDL_GameControllerGetAttached") &&
            load(axis,"SDL_GameControllerGetAxis") && load(button,"SDL_GameControllerGetButton") &&
            load(raw,"SDL_JoystickGetButton") && load(version,"SDL_GetVersion"))) return false;
        std::array<std::uint8_t,3> v{};
        version(v.data());
        return v==std::array<std::uint8_t,3>{2,32,6};
    }
};
inline Sdl sdl;
using h2t_players::Owner;
inline std::optional<Owner> stock_owner(int id) noexcept {
    const auto slots = h2t_players::Slots::current();
    if (!slots) return {};
    const auto owner = slots->primary(id);
    if (!owner || !h2t_players::secondary.accepts(*slots, *owner)) return {};
    return owner;
}
struct PadVector { Addr begin{}; unsigned count{}; };
inline std::optional<PadVector> stock_vector() noexcept {
    const auto input=read<Addr>(game_base+0x65cc160).value_or(0);
    if (!input) return {};
    const auto begin=read<Addr>(input+0x20), end=read<Addr>(input+0x28);
    if (!begin || !end || *end<*begin || ((*end-*begin)%sizeof(Addr))) return {};
    return PadVector{*begin,static_cast<unsigned>((*end-*begin)/sizeof(Addr))};
}
inline int action_state(Addr handler, Addr action) noexcept {
    const auto index=read<int>(action);
    const auto states=read<Addr>(handler+0x68), end=read<Addr>(handler+0x70);
    if (!index || *index<0 || !states || !*states || !end || *end<*states ||
        static_cast<Addr>(*index)>=(*end-*states)/sizeof(int)) return -1;
    return read<int>(*states+*index*sizeof(int)).value_or(-1);
}
inline std::optional<Owner> before;
inline Controller* adapter_pad{};
inline Joystick* adapter_joystick{};
inline int adapter_id{-1}, hero_id{};
inline std::uint64_t arm_serial{};
inline bool attempted{};

inline Controller* guest_pad{};
inline Joystick* guest_joystick{};
inline int guest_pad_id{-1};
inline bool attaching_guest{};

inline bool neutral_device(int lane, Controller* pad, Joystick* joystick, int id) noexcept {
    if (!pad || !joystick || id<0 || !sdl.attached(pad) || sdl.device_id(lane)!=id ||
        !sdl.virtual_device(lane) || sdl.joystick(pad)!=joystick || sdl.id(joystick)!=id) return false;
    for (int n=0;n<6;++n) if (sdl.axis(pad,n)!=0) return false;
    for (int n=0;n<21;++n) if (sdl.button(pad,n)!=0 || sdl.raw(joystick,n)!=0) return false;
    return true;
}
inline bool sdl_neutral() noexcept {
    return adapter_pad && sdl.count()==(guest_pad ? 2 : 1) &&
        neutral_device(0,adapter_pad,adapter_joystick,adapter_id) &&
        (!guest_pad || (guest_pad!=adapter_pad && guest_pad_id!=adapter_id &&
                        neutral_device(1,guest_pad,guest_joystick,guest_pad_id)));
}
inline bool add_guest_pad() noexcept {
    if (guest_pad) return sdl_neutral();
    if (attaching_guest || !sdl_neutral()) return false;
    attaching_guest=true;
    constexpr Descriptor desc{1,1,6,21,1,0x045e,0x028e,0,0x1fffff,0x3f,"H2T Seat 2"};
    const int index=sdl.attach(&desc);
    if (index!=1) return false;
    const auto id=sdl.device_id(index);
    auto pad=sdl.open(index);
    auto joystick=pad ? sdl.joystick(pad) : nullptr;
    if (!neutral_device(index,pad,joystick,id) || pad==adapter_pad || id==adapter_id) {
        // Still inside the attach call's game update. The stock sampler has
        // never received this device. Balance only our own open and attachment.
        if (pad) sdl.close(pad);
        if (id>=0 && id!=adapter_id && sdl.device_id(index)==id && sdl.virtual_device(index))
            sdl.detach(index);
        return false;
    }
    guest_pad=pad;
    guest_joystick=joystick;
    guest_pad_id=id;
    return true;
}
inline bool verified_pad(Addr obj, Controller* pad, int id) noexcept {
    return obj && pad && id>=0 && read<int>(obj+0x50)==id && read<unsigned>(obj+0x38)==2u &&
        read<Addr>(obj+0x48)==reinterpret_cast<Addr>(pad);
}
inline bool managed_topology(const PadVector& vec) noexcept {
    return sdl_neutral() && (vec.count==1 || (vec.count==2 && guest_pad &&
        verified_pad(read<Addr>(vec.begin+8).value_or(0),guest_pad,guest_pad_id))) &&
        verified_pad(read<Addr>(vec.begin).value_or(0),adapter_pad,adapter_id);
}
inline const char* arm(int hero) noexcept {
    const auto trace=latest_on_game_thread();
    if (!trace.serial) return "outside_original_thread";
    if (trace.outcome!=Outcome::zero_pads) return "await_original_zero_pads";
    if (attempted) return "already_attempted";
    const auto own=stock_owner(hero);
    const auto pads=stock_vector();
    if (!own || !pads || pads->count!=0 || !sdl.bind() || sdl.count()!=0) return "stock_preconditions";
    attempted=true;
    before=own;
    hero_id=hero;
    arm_serial=trace.serial;
    constexpr Descriptor desc{1,1,6,21,1,0x045e,0x028e,0,0x1fffff,0x3f,"H2T Scratch Neutral Observer"};
    const int index=sdl.attach(&desc);
    if (index!=0) return "attach_failed";
    adapter_pad=sdl.open(index);
    if (!adapter_pad) return "open_failed";
    adapter_joystick=sdl.joystick(adapter_pad);
    if (!adapter_joystick) return "joystick_failed";
    adapter_id=sdl.id(adapter_joystick);
    return adapter_id>=0 && sdl_neutral() ? "attached" : "unconfirmed_neutral";
}

struct Check {
    Trace trace{};
    bool owner_same{}, stock_same{}, independent_neutral{}, handler_neutral{}, observed_neutral{};
    int instance{-1}, attack1{-1}, attack2{-1};
};
inline Check observe(int hero) noexcept {
    Check out;
    out.trace=latest_on_game_thread();
    if (!out.trace.serial || !before || hero!=hero_id || out.trace.serial<=arm_serial) return out;
    const auto own=stock_owner(hero);
    out.owner_same=own && *own==*before;
    if (!out.owner_same || out.trace.outcome!=Outcome::complete || (out.trace.count!=1 && out.trace.count!=2)) return out;
    const auto& lane=out.trace.lanes[0];
    out.instance=lane.pad.instance;
    const auto vec=stock_vector();
    const auto stock=vec && vec->count==out.trace.count && managed_topology(*vec) ? read<Addr>(vec->begin).value_or(0) : 0;
    out.stock_same=stock && lane.pad.object==stock && lane.pad.instance==adapter_id && lane.pad.model==2 &&
        read<int>(stock+0x50)==adapter_id && read<unsigned>(stock+0x38)==2 &&
        read<Addr>(stock+0x48)==reinterpret_cast<Addr>(adapter_pad) &&
        lane.pad.controller==reinterpret_cast<Addr>(adapter_pad);
    out.independent_neutral=out.stock_same && sdl_neutral();
    out.observed_neutral=lane.reads==20 && !lane.raw_seen &&
        std::ranges::all_of(lane.axes,[](auto v){return v==0;}) &&
        std::ranges::all_of(lane.buttons,[](auto v){return v==0;});
    out.attack1=action_state(own->handler,game_base+0x5516c0);
    out.attack2=action_state(own->handler,game_base+0x5525a0);
    out.handler_neutral=read<float>(own->handler+0x50)==0.f &&
        read<float>(own->handler+0x54)==0.f && out.attack1==0 && out.attack2==0;
    return out;
}
}
