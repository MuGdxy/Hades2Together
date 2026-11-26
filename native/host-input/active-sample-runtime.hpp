#pragma once
#include "active-sample-core.hpp"
#include "observe-sampler-runtime.hpp"
#include "secondary-owner.hpp"

namespace h2t_active_runtime {
using h2t_active::Addr;
inline h2t_active::Adapter adapter;
using h2t_observe::playable_lanes;
struct GuestInput { h2t_active::Adapter input; h2t_active::Proof batch; bool bound{}; };
inline std::array<GuestInput,playable_lanes> guests;
inline h2t_active::Proof batch_route;
inline unsigned reading_lane{playable_lanes};
inline std::atomic<unsigned> game_thread{};
inline int hero_id{};
inline std::uint64_t room_epoch{}, host_seat{1};
inline std::uint64_t matching_observer_serial{};
inline bool active_thread(unsigned t) noexcept { return t && t==game_thread.load(std::memory_order_acquire); }

inline h2t_active::Proof route(unsigned lane=0) noexcept {
    using namespace h2t_observe_runtime;
    h2t_active::Proof result;
    const auto current=stock_owner(h2t_active_runtime::hero_id);
    const auto pads=stock_vector();
    if (!current || !before || *current!=*before || !pads || !managed_topology(*pads) ||
        h2t_observe::read<std::uint8_t>(h2t_observe::game_base+0x837e3e)!=0 ||
        h2t_observe::read<std::uint8_t>(current->world)!=1 ||
        (pads->count>1 && h2t_observe::read<std::uint8_t>(h2t_observe::game_base+0x837ebb)!=0)) return result;
    if (lane>=pads->count) return result;
    const auto& guest=h2t_players::RoomGuest::rooms()[lane];
    if (lane && (!guest || guest->epoch()!=room_epoch)) return result;
    const auto owner=lane ? guest->owner() : current;
    if (!owner) return result;
    const auto [controller,joystick,instance]=device(lane);
    const auto pad=h2t_observe::read<Addr>(pads->begin+sizeof(Addr)*lane).value_or(0);
    if (!pad || h2t_observe::read<Addr>(pad+0x48)!=reinterpret_cast<Addr>(controller) ||
        h2t_observe::read<int>(pad+0x50)!=instance || h2t_observe::read<unsigned>(pad+0x38)!=2u) return result;
    const auto a1=h2t_observe::game_base+0x5516c0;
    const auto a2=h2t_observe::game_base+0x5525a0;
    const auto use=h2t_observe::game_base+0x552140;
    // Controls::SetupControlScheme binds Use to logical 55, SDL right shoulder on model 2.
    result.use_mapping=lane==0 && h2t_observe::read<std::uint8_t>(use+0x0a)==1 &&
        h2t_observe::read<int>(use+0xd0)==55;
    result.mapping=h2t_observe::read<std::uint8_t>(a1+0x0a)==1 &&
        h2t_observe::read<std::uint8_t>(a2+0x0a)==1 &&
        h2t_observe::read<int>(a1+0xd0)==51 && h2t_observe::read<int>(a2+0xd0)==52;
    result.owner={owner->world,owner->player,owner->unit,owner->handler,pad,
        reinterpret_cast<Addr>(controller),reinterpret_cast<Addr>(joystick),
        lane ? guest->id() : h2t_active_runtime::hero_id,instance,lane,lane,lane,2,room_epoch};
    result.pad_count=pads->count;
    result.managed_lanes=pads->count>1;
    result.attached_virtual_neutral=true;
    return result;
}
inline void begin(unsigned thread,Addr caller) noexcept {
    if (!active_thread(thread) || caller!=h2t_active::app_return) return;
    reading_lane=playable_lanes;
    if (adapter.app_begin(thread,caller)) batch_route={};
    for(auto& guest:guests) if (guest.bound && guest.input.app_begin(thread,caller)) guest.batch={};
}
inline void topology(unsigned thread,Addr caller) noexcept {
    if (!active_thread(thread) || caller!=h2t_active::app_return) return;
    batch_route=route();
    const auto now=GetTickCount64();
    adapter.post_drain(thread,caller,now,batch_route);
    for (unsigned i=1;i<guests.size();++i) {
        auto& guest=guests[i];
        if (!guest.bound) continue;
        guest.batch=route(i);
        guest.input.post_drain(thread,caller,now,guest.batch);
    }
}
inline void pad(unsigned thread,Addr caller,unsigned lane,h2t_observe::Pad pad) noexcept {
    if (!active_thread(thread) || caller!=h2t_active::sampler_return) return;
    reading_lane=lane;
    if (lane>=guests.size() || (lane && !guests[lane].bound)) return;
    auto current=(lane ? guests[lane].batch : batch_route).owner;
    current.input_lane=lane;
    current.stock_pad=pad.object;
    current.sdl_pad=pad.controller;
    current.instance=pad.instance;
    current.model=pad.model;
    (lane ? guests[lane].input : adapter).pad_begin(thread,caller,current);
}
inline std::uint64_t after_original(unsigned thread,Addr caller,unsigned id,std::uint64_t rax) noexcept {
    if (!active_thread(thread) || reading_lane>=guests.size() || (reading_lane && !guests[reading_lane].bound)) return rax;
    return (reading_lane ? guests[reading_lane].input : adapter).after_read(thread,caller,id,rax);
}
inline void reset(unsigned thread,Addr caller) noexcept {
    if (!active_thread(thread) || caller!=h2t_observe::reset_return) return;
    matching_observer_serial=0;
    adapter.reset(thread);
    for(auto& g:guests) if(g.bound) g.input.reset(thread);
    reading_lane=playable_lanes;
    batch_route={};
}
inline void end(unsigned thread) noexcept {
    if (!active_thread(thread)) {
        if (h2t_observe::latest_on_game_thread().serial) for(auto& g:h2t_players::RoomGuest::rooms()) if(g) g->input_return(0);
        return;
    }
    matching_observer_serial=0;
    adapter.app_end(thread);
    for(auto& g:guests) if(g.bound) g.input.app_end(thread);
    reading_lane=playable_lanes;
    const auto trace=h2t_observe::latest_on_game_thread();
    const auto audit=adapter.audit(thread);
    if (trace.outcome==h2t_observe::Outcome::complete && (trace.count>0 && trace.count<=playable_lanes) &&
        audit.result==h2t_active::Result::complete && audit.reads==20)
        matching_observer_serial=trace.serial;
    batch_route={};
    for(auto& g:h2t_players::RoomGuest::rooms()) if(g) g->input_return(room_epoch);
}

inline bool guest_clear(unsigned index,std::uint64_t token) noexcept {
    const auto t=GetCurrentThreadId();
    if (!active_thread(t) || !guests[index].bound) return false;
    const auto proof=route(index);
    const auto trace=h2t_observe::latest_on_game_thread();
    if (!proof.valid() || trace.outcome!=h2t_observe::Outcome::complete || trace.count<=index) return false;
    const auto& lane=trace.lanes[index];
    using namespace h2t_observe_runtime;
    const Addr handler=proof.owner.handler;
    const bool neutral=lane.pad.object==proof.owner.stock_pad && lane.reads==20 && !lane.raw_seen &&
        read<float>(handler+0x50)==0.f && read<float>(handler+0x54)==0.f &&
        action_state(handler,game_base+0x5516c0)==0 && action_state(handler,game_base+0x5525a0)==0;
    auto& guest_input=guests[index].input;
    return guest_input.observe_neutral(t,token,proof,guest_input.audit(t).batch,neutral);
}
inline bool set_taps_before_install() noexcept {
    if (h2t_observe::armed.load(std::memory_order_acquire)) return false;
    h2t_observe::staged_taps={begin,topology,pad,after_original,reset,end};
    return true;
}
inline bool bind_after_neutral(int hero,std::uint64_t epoch,std::uint64_t seat) noexcept {
    if (game_thread || !epoch || !seat) return false;
    const auto stock=h2t_observe_runtime::observe(hero);
    if (!stock.owner_same || !stock.stock_same || !stock.observed_neutral ||
        !stock.independent_neutral || !stock.handler_neutral) return false;
    hero_id=hero;
    room_epoch=epoch;
    const unsigned caller=GetCurrentThreadId();
    if (!adapter.bind(caller,route())) return false;
    host_seat=seat;
    game_thread.store(caller,std::memory_order_release);
    return true;
}
inline bool revoke_room(std::uint64_t epoch) noexcept {
    const unsigned caller=GetCurrentThreadId();
    if (!active_thread(caller) || epoch!=room_epoch || !adapter.close_room(caller,epoch)) return false;
    guests={};
    h2t_observe_runtime::before.reset();
    room_epoch=0;
    game_thread.store(0,std::memory_order_release);
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
    const auto proof=route();
    const bool use_neutral=!proof.use_mapping || h2t_observe_runtime::action_state(
        proof.owner.handler,h2t_observe::game_base+0x552140)==0;
    return adapter.observe_neutral(caller,generation,proof,adapter.audit(caller).batch,stock.handler_neutral && use_neutral);
}
inline bool submit(std::uint64_t generation,std::uint64_t sequence,const h2t_active::Frame& frame) noexcept {
    const auto caller=GetCurrentThreadId();
    return active_thread(caller) && adapter.submit(caller,generation,sequence,GetTickCount64(),frame,route());
}
}
