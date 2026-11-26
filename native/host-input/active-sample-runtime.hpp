#pragma once
#include "active-sample-core.hpp"
#include "observe-sampler-runtime.hpp"

namespace h2t_active_runtime {
using h2t_active::Addr;
inline h2t_active::Adapter adapter;
inline h2t_active::Proof batch_route;
inline std::atomic<unsigned> game_thread{};
inline int hero_id{};
inline std::uint64_t room_epoch{};
inline std::uint64_t matching_observer_serial{};
inline bool active_thread(unsigned t) noexcept { return t && t==game_thread.load(std::memory_order_acquire); }

inline h2t_active::Proof route() noexcept {
    using namespace h2t_observe_runtime;
    h2t_active::Proof result;
    const auto current=stock_owner(h2t_active_runtime::hero_id);
    const auto pads=stock_vector();
    if (!current || !before || *current!=*before || !pads || pads->count!=1 ||
        h2t_observe::read<std::uint8_t>(h2t_observe::game_base+0x837e3e)!=0 ||
        h2t_observe::read<std::uint8_t>(current->world)!=1 || !sdl_neutral()) return result;
    const auto pad=h2t_observe::read<Addr>(pads->begin).value_or(0);
    if (!pad || h2t_observe::read<Addr>(pad+0x48)!=reinterpret_cast<Addr>(adapter_pad) ||
        h2t_observe::read<int>(pad+0x50)!=adapter_id || h2t_observe::read<unsigned>(pad+0x38)!=2u) return result;
    const auto a1=h2t_observe::game_base+0x5516c0;
    const auto a2=h2t_observe::game_base+0x5525a0;
    result.mapping=h2t_observe::read<std::uint8_t>(a1+0x0a)==1 &&
        h2t_observe::read<std::uint8_t>(a2+0x0a)==1 &&
        h2t_observe::read<int>(a1+0xd0)==51 && h2t_observe::read<int>(a2+0xd0)==52;
    result.owner={current->world,current->player,current->unit,current->handler,pad,
        reinterpret_cast<Addr>(adapter_pad),reinterpret_cast<Addr>(adapter_joystick),
        h2t_active_runtime::hero_id,adapter_id,0,0,0,2,room_epoch};
    result.pad_count=1;
    result.attached_virtual_neutral=true;
    return result;
}
inline void begin(unsigned thread,Addr caller) noexcept {
    if (active_thread(thread) && adapter.app_begin(thread,caller)) batch_route={};
}
inline void topology(unsigned thread,Addr caller) noexcept {
    if (!active_thread(thread) || caller!=h2t_active::app_return) return;
    batch_route=route();
    adapter.post_drain(thread,caller,GetTickCount64(),batch_route);
}
inline void pad(unsigned thread,Addr caller,unsigned lane,h2t_observe::Pad pad) noexcept {
    if (!active_thread(thread) || caller!=h2t_active::sampler_return) return;
    auto current=batch_route.owner;
    current.input_lane=lane;
    current.stock_pad=pad.object;
    current.sdl_pad=pad.controller;
    current.instance=pad.instance;
    current.model=pad.model;
    adapter.pad_begin(thread,caller,current);
}
inline std::uint64_t after_original(unsigned thread,Addr caller,unsigned id,std::uint64_t rax) noexcept {
    return active_thread(thread) ? adapter.after_read(thread,caller,id,rax) : rax;
}
inline void reset(unsigned thread,Addr caller) noexcept {
    if (!active_thread(thread) || caller!=h2t_observe::reset_return) return;
    matching_observer_serial=0;
    adapter.reset(thread);
    batch_route={};
}
inline void end(unsigned thread) noexcept {
    if (!active_thread(thread)) return;
    matching_observer_serial=0;
    adapter.app_end(thread);
    const auto trace=h2t_observe::latest_on_game_thread();
    const auto audit=adapter.audit(thread);
    if (trace.outcome==h2t_observe::Outcome::complete && trace.count==1 &&
        audit.result==h2t_active::Result::complete && audit.reads==20)
        matching_observer_serial=trace.serial;
    batch_route={};
}

// C++ entry points for a future reviewed scratch bridge. No new Lua/CLI
// registration or installer invocation is included in this offline layer.
inline bool set_taps_before_install() noexcept {
    if (h2t_observe::armed.load(std::memory_order_acquire)) return false;
    h2t_observe::staged_taps={begin,topology,pad,after_original,reset,end};
    return true;
}
inline bool bind_after_neutral(int hero,std::uint64_t epoch) noexcept {
    if (game_thread || !epoch) return false;
    const auto stock=h2t_observe_runtime::observe(hero);
    if (!stock.owner_same || !stock.stock_same || !stock.observed_neutral ||
        !stock.independent_neutral || !stock.handler_neutral) return false;
    hero_id=hero;
    room_epoch=epoch;
    const unsigned caller=GetCurrentThreadId();
    if (!adapter.bind(caller,route())) return false;
    game_thread.store(caller,std::memory_order_release);
    return true;
}
inline bool revoke_room(std::uint64_t epoch) noexcept {
    const unsigned caller=GetCurrentThreadId();
    if (!active_thread(caller) || !adapter.revoke_owner(caller,epoch)) return false;
    matching_observer_serial=0;
    return true;
}
inline bool connect(std::uint64_t generation) noexcept {
    const unsigned caller=GetCurrentThreadId();
    return active_thread(caller) && adapter.connect(caller,generation);
}
inline bool disconnect(std::uint64_t generation) noexcept {
    const unsigned caller=GetCurrentThreadId();
    return active_thread(caller) && adapter.disconnect(caller,generation);
}
inline bool prove_clear(std::uint64_t generation) noexcept {
    const auto caller=GetCurrentThreadId();
    if (!active_thread(caller) || !matching_observer_serial) return false;
    const auto stock=h2t_observe_runtime::observe(hero_id);
    if (stock.trace.serial!=matching_observer_serial || !stock.owner_same || !stock.stock_same ||
        !stock.independent_neutral || !stock.observed_neutral) return false;
    return adapter.observe_neutral(caller,generation,route(),adapter.audit(caller).batch,stock.handler_neutral);
}
inline bool submit(std::uint64_t generation,std::uint64_t sequence,const h2t_active::Frame& frame) noexcept {
    const auto caller=GetCurrentThreadId();
    return active_thread(caller) && adapter.submit(caller,generation,sequence,GetTickCount64(),frame,route());
}
}
