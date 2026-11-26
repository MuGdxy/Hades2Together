#pragma once
#include "active-sample-runtime.hpp"

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
    ns.set_function("h2t_guest_owner", [](sol::this_state lua, int host, std::uint64_t load,
                                             int point, bool retain, std::uint64_t connection) {
        auto out=sol::state_view(lua).create_table();
        namespace runtime=h2t_active_runtime;
        auto& guest=h2t_players::room_guest;
        const auto t=GetCurrentThreadId();
        if (!h2t_observe::latest_on_game_thread().serial) return out;
        guest.maintain();
        if (!retain && (!guest.epoch() || guest.epoch()==load)) {
            runtime::release_guest_input();
            guest.leave(load);
        }
        if (runtime::active_thread(t) && runtime::room_epoch==load && retain && !guest.epoch() && point>0) {
            if (read<std::uint8_t>(game_base+0x837ebb)!=0) {
                out["status"]="requires stock AllowControlHotSwap=false";
                return out;
            }
            const auto pads=stock_vector();
            if (runtime::route().valid() && pads && add_guest_pad()) {
                if (pads->count!=2 || !managed_topology(*pads)) {
                    out["status"]="waiting for original second pad"; return out;
                }
                guest.queue_join(host,load,point,connection);
            }
        }
        if (guest.published() && guest.epoch()==load && runtime::active_thread(t)) {
            if (!runtime::guest_bound) runtime::guest_bound=runtime::guest_input.bind(t,runtime::route(1));
            out["id"]=guest.id();
            out["publication"]=guest.publication();
            out["inputBound"]=runtime::guest_bound;
            const auto audit=runtime::guest_input.audit(t);
            if (audit.result==h2t_active::Result::complete) out["sequence"]=audit.applied_sequence;
        } else if (runtime::guest_bound) runtime::release_guest_input();
        out["epoch"]=guest.epoch();
        out["status"]=guest.status();
        return out;
    });
    ns.set_function("h2t_guest_actor", [](sol::this_state script) {
        auto out=sol::state_view(script).create_table();
        const auto& guest=h2t_players::room_guest;
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
    ns.set_function("h2t_guest_connection", [](std::uint64_t epoch,std::uint64_t publication,std::uint64_t token,bool online) {
        namespace runtime=h2t_active_runtime;
        const auto t=GetCurrentThreadId();
        if (!runtime::active_thread(t) || !runtime::guest_bound ||
            epoch!=h2t_players::room_guest.epoch() || publication!=h2t_players::room_guest.publication()) return false;
        return online ? runtime::guest_input.connect(t,token) : runtime::guest_input.disconnect(t,token);
    });
    ns.set_function("h2t_guest_clear", [](std::uint64_t publication,std::uint64_t token) {
        return publication==h2t_players::room_guest.publication() && h2t_active_runtime::guest_clear(token);
    });
    ns.set_function("h2t_guest_submit", [](std::uint64_t epoch,std::uint64_t publication,std::uint64_t token,std::uint64_t seq,
                                           double x,double y,double aim_x,double aim_y,unsigned mask) {
        namespace runtime=h2t_active_runtime;
        const auto t=GetCurrentThreadId();
        return runtime::active_thread(t) && runtime::guest_bound && epoch==h2t_players::room_guest.epoch() &&
            publication==h2t_players::room_guest.publication() && runtime::guest_input.submit(t,token,seq,GetTickCount64(),{x,y,aim_x,aim_y,mask},runtime::route(1));
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
    ns.set_function("h2t_active_bind", h2t_active_runtime::bind_after_neutral);
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
        if ((result.trace.count==1 || result.trace.count==2) && result.trace.outcome==Outcome::complete) {
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
