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
        if (result.trace.count==1 && result.trace.outcome==Outcome::complete) {
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
