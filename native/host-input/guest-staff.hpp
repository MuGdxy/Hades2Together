#pragma once
#include "secondary-owner.hpp"

namespace h2t_players {
// Steam v1.143476. This is the default guest weapon and its original
// WeaponSets.HeroWeaponSets list. No weapon or control fields are written here.
inline constexpr std::array<std::string_view,6> staff_names{
    "WeaponStaffSwing", "WeaponStaffSwing2", "WeaponStaffSwing3", "WeaponStaffSwing5",
    "WeaponStaffBall", "WeaponStaffDash"
};
using StaffKeys = std::array<std::uint32_t,staff_names.size()>;

inline bool stock_staff_keys(StaffKeys& keys) {
    using Lookup = std::uint32_t* (*)(std::uint32_t*,const char*,size_t);
    const auto lookup=reinterpret_cast<Lookup>(game_base+0x1b3b40);
    const auto definition=reinterpret_cast<Addr (*)(std::uint32_t)>(game_base+0xb5800);
    for (size_t i=0;i<keys.size();++i) {
        lookup(&keys[i],staff_names[i].data(),staff_names[i].size());
        if (!keys[i]) return false;
    }
    std::uint32_t null_key{};
    lookup(&null_key,"null",4);
    for (auto key: keys) {
        const Addr data=definition(key);
        if (!data || read<std::uint32_t>(data+8)!=key || read<std::uint8_t>(data+0x30)!=0) return false;
        // AddWeapon can allocate swap/add/release bundles recursively. The
        // capacity bound below is valid only for a closed set of stock guns.
        for (unsigned offset: {0x28cu,0x290u,0x288u}) {
            const auto edge=read<std::uint32_t>(data+offset);
            if (!edge) return false;
            if (*edge && !(*edge==null_key && !definition(*edge)) &&
                std::find(keys.begin(),keys.end(),*edge)==keys.end()) return false;
        }
    }
    return true;
}

inline std::optional<size_t> missing_staff(Addr unit,int id,const StaffKeys& keys) {
    const Addr arsenal=read<Addr>(unit+0x708).value_or(0);
    if (!arsenal || read<Addr>(arsenal)!=unit) return {};
    const auto vec=read<std::array<Addr,3>>(arsenal+8);
    if (!vec) return {};
    const auto [begin,end,capacity]=*vec;
    if (end<begin || capacity<end || (!begin && capacity) || capacity-begin>128*sizeof(Addr) ||
        (end-begin)%sizeof(Addr)) return {};
    std::array<bool,staff_names.size()> found{};
    for (Addr row=begin;row<end;row+=sizeof(Addr)) {
        const Addr weapon=read<Addr>(row).value_or(0);
        if (!weapon || read<int>(weapon+0x44)!=id) return {};
        const Addr data=read<Addr>(weapon+0x78).value_or(0);
        const auto key=data ? read<std::uint32_t>(data+8) : std::nullopt;
        if (!key || !*key) return {};
        const auto hit=std::find(keys.begin(),keys.end(),*key);
        if (hit!=keys.end()) {
            const size_t i=hit-keys.begin();
            if (found[i]) return {};
            found[i]=true;
        }
    }
    return std::count(found.begin(),found.end(),false);
}

inline bool gun_capacity(Addr pool,size_t needed) {
    std::array<bool,32> visited{};
    auto next=read<std::uint16_t>(pool+0x30);
    size_t count{};
    while (next && *next) {
        if (*next>=visited.size() || visited[*next]) return false;
        visited[*next]=true;
        const Addr node=pool+0x30+*next*4;
        if (read<std::uint8_t>(node+2)!=0) return false;
        next=read<std::uint16_t>(node);
        ++count;
    }
    return next.has_value() && count>=needed;
}

inline const char* equip_guest_staff(sol::this_state script,std::uint64_t seat,std::uint64_t load,
                                     std::uint64_t publication,int id,sol::table linked) {
    const auto* guest=guest_for(seat);
    const auto owner=guest ? guest->owner() : std::nullopt;
    if (!owner || guest->epoch()!=load || guest->publication()!=publication || guest->id()!=id ||
        !read<Addr>(owner->unit+0x668).value_or(0)) return "guest weapon owner changed";
    if (linked.size()+1!=staff_names.size()) return "unsupported stock staff set";
    for (size_t i=1;i<staff_names.size();++i) {
        if (linked.get<sol::optional<std::string>>(i).value_or("")!=staff_names[i]) return "unsupported stock staff set";
    }
    StaffKeys keys{};
    if (!stock_staff_keys(keys)) return "stock staff definitions unavailable";
    const auto missing=missing_staff(owner->unit,id,keys);
    if (!missing) return "guest arsenal unreadable";
    if (!*missing) return "equipped";
    const auto assets=read<Addr>(game_base+0x8319a8).value_or(0);
    const auto loaded=reinterpret_cast<bool (*)(Addr,std::uint32_t)>(game_base+0x2c59f0);
    if (!assets || !loaded(assets,keys.front())) return "staff package not loaded";

    sol::state_view lua(script);
    sol::object action=lua["EquipWeapon"];
    if (action.get_type()!=sol::type::function) return "stock EquipWeapon unavailable";
    // Call the original action only, while holding its recursive allocator lock.
    lua_State* L=script;
    const int top=lua_gettop(L);
    action.push(L);
    const auto entry=reinterpret_cast<Addr>(lua_tocfunction(L,-1));
    const auto actions=read<Addr>(game_base+0x1741550).value_or(0);
    const bool original=actions && entry==game_base+0x247310 && lua_getupvalue(L,-1,1) &&
        lua_islightuserdata(L,-1) && reinterpret_cast<Addr>(lua_touserdata(L,-1))==actions+5*0x20;
    lua_settop(L,top);
    if (!original) return "stock EquipWeapon unavailable";
    auto names=lua.create_table();
    for (size_t i=0;i<keys.size();++i) names[i+1]=std::string(staff_names[i]);
    auto args=lua.create_table_with("DestinationId",id,"Names",names,"LoadPackages",false);
    const Addr pool=game_base+0x550a80;
    auto* mutex=reinterpret_cast<CRITICAL_SECTION*>(pool);
    if (!read<Addr>(pool+0xb0).value_or(0) || !TryEnterCriticalSection(mutex)) return "staff pool unavailable";
    struct Unlock { CRITICAL_SECTION* value; ~Unlock(){ LeaveCriticalSection(value); } } unlock{mutex};
    if (!gun_capacity(pool,*missing)) return "insufficient stock gun capacity";
    if (!action.as<sol::protected_function>()(args).valid()) return "stock EquipWeapon failed";
    if (guest->owner()!=owner || missing_staff(owner->unit,id,keys)!=size_t{0}) return "guest staff set incomplete";
    return "equipped";
}
}
