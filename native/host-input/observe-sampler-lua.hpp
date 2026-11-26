#pragma once
#include "active-sample-runtime.hpp"
#include "guest-staff.hpp"

namespace h2t_observe_runtime {
inline const char* name(Install value) noexcept {
    switch(value) {
    case Install::unattempted: return "unattempted";
    case Install::installing: return "installing";
    case Install::ready: return "ready";
    case Install::preflight_failed: return "preflight_failed";
    case Install::prepare_failed: return "prepare_failed";
    case Install::enable_failed: return "enable_failed";
    case Install::rollback_failed: return "rollback_failed_inert_retained";
    }
    return "unknown";
}
inline const char* name(Outcome value) noexcept {
    switch(value) {
    case Outcome::none: return "none";
    case Outcome::complete: return "complete";
    case Outcome::zero_pads: return "zero_pads";
    case Outcome::reset: return "reset";
    case Outcome::incomplete: return "incomplete";
    }
    return "unknown";
}
inline void bind(sol::table& ns) {
    ns.set_function("h2t_sampler_install", []() {
        static const char* result = []() {
            if (!pinned_identity()) return "identity_refused";
            const auto& symbols=big::hades2_symbol_to_address;
            const auto update=symbols.find("sgg::InputSystemImplSDL::Update");
            const auto pad=symbols.find("sgg::InputSystemImplSDL::ReadGamePadState");
            if (update==symbols.end() || pad==symbols.end()) return "symbol_refused";
            if (!h2t_active_runtime::set_taps_before_install()) return "tap_refused";
            return name(install_for_reviewed_loader(true,
                reinterpret_cast<Addr>(update->second.as<void*>()),
                reinterpret_cast<Addr>(pad->second.as<void*>())));
        }();
        return result;
    });
    // Optional final seat preserves the existing two-seat Lua ABI.
    const auto seat_id=[](sol::optional<std::uint64_t> seat){return seat.value_or(2u);};
    ns.set_function("h2t_guest_equip_staff", &h2t_players::equip_guest_staff);
    ns.set_function("h2t_guest_capacity", []() {
        const auto slots=h2t_players::Slots::current();
        return slots ? slots->capacity() : 0u;
    });
    ns.set_function("h2t_guest_seats", [](sol::this_state lua) {
        auto ids=sol::state_view(lua).create_table();
        unsigned n=0;
        for (const auto& room:h2t_players::RoomGuest::rooms())
            if (room && room->published()) ids[++n]=room->seat();
        return ids;
    });
    ns.set_function("h2t_guest_owner", [seat_id](sol::this_state lua, int host, std::uint64_t load,
                                             int point, bool retain, std::uint64_t connection, sol::optional<std::uint64_t> seat, sol::optional<bool> reserve) {
        auto out=sol::state_view(lua).create_table();
        namespace runtime=h2t_active_runtime;
        const auto id=seat_id(seat);
        if (!id || id==runtime::host_seat) {out["status"]="host seat uses original owner"; return out;}
        auto* owner=h2t_players::guest_for(id);
        const auto t=GetCurrentThreadId();
        if (!h2t_observe::latest_on_game_thread().serial) return out;
        if (!owner && retain && runtime::active_thread(t) && runtime::room_epoch==load && point>0) {
            const auto slots=h2t_players::Slots::current();
            if (slots && slots->primary(host)) owner=h2t_players::claim_guest(id,slots->capacity());
            if (!owner) {
                out["status"]=slots && slots->capacity()<playable_lanes
                    ? "stock Player table already initialized without reserve"
                    : "all native playable controller lanes reserved";
                return out;
            }
        }
        if (!owner) {out["epoch"]=0;out["status"]="empty";return out;}
        auto& guest=*owner;
        const unsigned lane=guest.lane();
        auto& channel=runtime::guests[lane];
        if (guest.epoch() && guest.epoch()!=load) {
            out["epoch"]=guest.epoch();
            out["status"]="different room owner";
            return out;
        }
        guest.maintain();
        if (!retain && (!guest.epoch() || guest.epoch()==load)) {
            channel={};
            guest.leave(load);
        }
        if (runtime::active_thread(t) && runtime::room_epoch==load && retain && !guest.epoch() && point>0) {
            if (read<std::uint8_t>(game_base+0x837ebb)!=0) {
                out["status"]="requires stock AllowControlHotSwap=false";
                return out;
            }
            const auto pads=stock_vector();
            if (!runtime::route().valid() || !pads) {
                out["status"]="stock host or pad route unavailable"; return out;
            }
            if (!add_guest_pad(lane)) {
                out["status"]="guest SDL device unavailable"; return out;
            }
            if (pads->count<=lane || !managed_topology(*pads)) {
                out["status"]="waiting for original guest pad"; return out;
            }
            guest.queue_join(host,load,point,connection);
        }
        if (guest.published() && guest.epoch()==load && runtime::active_thread(t)) {
            if (!channel.bound) channel.bound=channel.input.bind(t,runtime::route(lane));
            out["id"]=guest.id();
            out["publication"]=guest.publication();
            out["inputBound"]=channel.bound;
            const auto audit=channel.input.audit(t);
            if (audit.result==h2t_active::Result::complete) {
                out["sequence"]=audit.applied_sequence;
                if (audit.reads==20 && !audit.changed && !audit.applied_sequence) out["idleBatch"]=audit.batch;
            }
        } else if (channel.bound) channel={};
        out["epoch"]=guest.epoch();
        out["status"]=guest.status();
        if (!retain && !reserve.value_or(false) && guest.reusable()) h2t_players::RoomGuest::rooms()[lane].reset();
        return out;
    });
    ns.set_function("h2t_guest_actor", [seat_id](sol::this_state script, sol::optional<std::uint64_t> seat) {
        auto out=sol::state_view(script).create_table();
        const auto* room=h2t_players::guest_for(seat_id(seat));
        if (!room) return out;
        const auto& guest=*room;
        const auto owner=guest.owner();
        if (!owner) return out;
        const auto state=read<Addr>(owner->unit+0x128);
        const auto ref=read<int>(owner->unit+0x130);
        out["id"]=guest.id();
        out["load"]=guest.epoch();
        if (state==Addr{0} && ref==0) { out["empty"]=true; return out; }
        lua_State* lua=script;
        const int top=lua_gettop(lua);
        lua_rawgeti(lua,LUA_REGISTRYINDEX,LUA_RIDX_MAINTHREAD);
        const Addr main=reinterpret_cast<Addr>(lua_tothread(lua,-1));
        lua_settop(lua,top);
        // Read the caller's registry only for an original binding on this state
        // or its known main thread. Never enter an unrelated or stale Lua state.
        if (!state || !*state || (*state!=reinterpret_cast<Addr>(lua) && *state!=main) || !ref || *ref<=0)
            return out;
        lua_rawgeti(lua,LUA_REGISTRYINDEX,*ref);
        if (lua_istable(lua,-1)) out["actor"]=sol::stack::get<sol::object>(lua,-1);
        lua_settop(lua,top);
        return out;
    });
    ns.set_function("h2t_guest_connection", [seat_id](std::uint64_t epoch,std::uint64_t publication,std::uint64_t token,bool online,sol::optional<std::uint64_t> seat) {
        namespace runtime=h2t_active_runtime;
        const auto t=GetCurrentThreadId();
        const auto* guest=h2t_players::guest_for(seat_id(seat));
        if (!guest) return false;
        auto& channel=runtime::guests[guest->lane()];
        if (!runtime::active_thread(t) || !channel.bound ||
            epoch!=guest->epoch() || publication!=guest->publication()) return false;
        return online ? channel.input.connect(t,token) : channel.input.disconnect(t,token);
    });
    ns.set_function("h2t_guest_clear", [seat_id](std::uint64_t publication,std::uint64_t token,sol::optional<std::uint64_t> seat) {
        const auto* guest=h2t_players::guest_for(seat_id(seat));
        return guest && publication==guest->publication() && h2t_active_runtime::guest_clear(guest->lane(),token);
    });
    ns.set_function("h2t_guest_submit", [seat_id](std::uint64_t epoch,std::uint64_t publication,std::uint64_t token,std::uint64_t seq,
                                           double x,double y,double aim_x,double aim_y,unsigned mask,sol::optional<std::uint64_t> seat) {
        namespace runtime=h2t_active_runtime;
        const auto t=GetCurrentThreadId();
        const auto* guest=h2t_players::guest_for(seat_id(seat));
        if (!guest) return false;
        const auto lane=guest->lane();
        auto& channel=runtime::guests[lane];
        return runtime::active_thread(t) && channel.bound && epoch==guest->epoch() &&
            publication==guest->publication() && channel.input.submit(t,token,seq,GetTickCount64(),{x,y,aim_x,aim_y,mask},runtime::route(lane));
    });
    ns.set_function("h2t_sampler_resume", [](int hero) {
        if (h2t_active_runtime::game_thread.load() || !adapter_pad) return false;
        const auto trace=latest_on_game_thread();
        const auto pads=stock_vector();
        const auto host=stock_owner(hero);
        if (!trace.serial || !host || !pads || trace.outcome!=Outcome::complete ||
            trace.count!=pads->count || !managed_topology(*pads)) return false;
        before=host;
        hero_id=hero;
        arm_serial=trace.serial;
        return true;
    });
    ns.set_function("h2t_sampler_arm", arm);
    ns.set_function("h2t_active_bind", [](int hero,std::uint64_t epoch,sol::optional<std::uint64_t> seat) {
        return h2t_active_runtime::bind_after_neutral(hero,epoch,seat.value_or(1));
    });
    ns.set_function("h2t_active_revoke", h2t_active_runtime::revoke_room);
    ns.set_function("h2t_active_connect", h2t_active_runtime::connect);
    ns.set_function("h2t_active_disconnect", h2t_active_runtime::disconnect);
    ns.set_function("h2t_active_clear", h2t_active_runtime::prove_clear);
    ns.set_function("h2t_active_submit", [](std::uint64_t generation,std::uint64_t sequence,
        double x,double y,double aim_x,double aim_y,unsigned mask) {
        return h2t_active_runtime::submit(generation,sequence,{x,y,aim_x,aim_y,mask});
    });
    ns.set_function("h2t_active_audit", [](sol::this_state script) {
        auto out=sol::state_view(script).create_table();
        using namespace h2t_active_runtime;
        const unsigned thread=GetCurrentThreadId();
        if (!active_thread(thread)) return out;
        const auto value=adapter.audit(thread);
        out["batch"]=value.batch;
        out["sequence"]=value.applied_sequence;
        out["changed"]=value.changed;
        out["reads"]=value.reads;
        out["complete"]=value.result==h2t_active::Result::complete && matching_observer_serial!=0;
        out["reset"]=value.result==h2t_active::Result::reset;
        const auto proof=route();
        out["valid"]=proof.valid();
        if (proof.valid()) {
            const auto handler=proof.owner.handler;
            out["axisX"]=read<float>(handler+0x50);
            out["axisY"]=read<float>(handler+0x54);
            out["attack1"]=action_state(handler,game_base+0x5516c0);
            out["attack2"]=action_state(handler,game_base+0x5525a0);
        }
        return out;
    });
    ns.set_function("h2t_sampler_observe", [](sol::this_state script, int hero) {
        auto out=sol::state_view(script).create_table();
        const auto result=observe(hero);
        out["batch"]=result.trace.serial;
        out["outcome"]=name(result.trace.outcome);
        out["thread"]=result.trace.serial ? GetCurrentThreadId() : 0;
        out["count"]=result.trace.count;
        if ((result.trace.count>0 && result.trace.count<=playable_lanes) && result.trace.outcome==Outcome::complete) {
            const auto& lane=result.trace.lanes[0];
            out["instance"]=result.instance;
            out["model"]=lane.pad.model;
            out["reads"]=lane.reads;
            out["raw"]=lane.raw_seen;
            out["owner_same"]=result.owner_same;
            out["stock_same"]=result.stock_same;
            out["direct_neutral"]=result.independent_neutral;
            out["sample_neutral"]=result.observed_neutral;
            out["handler_neutral"]=result.handler_neutral;
            out["attack1"]=result.attack1;
            out["attack2"]=result.attack2;
        }
        return out;
    });
}
}
