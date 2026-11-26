#pragma once
#include "guest-descriptor.hpp"
#include <climits>

namespace h2t_players {
// One allocation per reserved seat in this World. Connection changes never reach
// the factory. Unit destruction belongs to the original World/UnitManager.
class RoomGuest {
    unsigned lane_;
    std::uint64_t seat_{};
    PrivatePlayer player_;
    GuestDescriptor descriptor_;
    Slots tables_{};
    Owner primary_{};
    Addr unit_{}, chosen_{}, generated_{}, remove_stack_{}, remove_return_{};
    int host_id_{}, id_{}, counter_{};
    std::atomic<DWORD> thread_{};
    std::uint64_t epoch_{}, publication_{};
    bool constructing_unit_{}, selected_{}, registered_{}, closing_{}, delete_requested_{}, removed_{};
    bool busy_{}, remove_returned_{};
    const char* reason_{"empty"};
    inline static std::array<SafetyHookMid,7> taps_;
    inline static std::uint64_t next_publication_{};
    struct Pending {
        Slots slots; Owner host; int id, point; std::uint64_t epoch, connection;
        bool operator==(const Pending&) const = default;
    };
    std::optional<Pending> pending_, refused_;
    bool leave_requested_{};

    bool on_thread() const noexcept { return thread_.load(std::memory_order_acquire) == GetCurrentThreadId(); }
    bool host_matches() const noexcept {
        return Slots::current() == tables_ && tables_.primary(host_id_) == primary_ &&
            read<Addr>(primary_.unit + 0x658) == primary_.player;
    }
    bool inactive_vacant(int id) const noexcept {
        struct Iterator { Addr node, info; } it{};
        using Find = Iterator* (*)(Addr, Iterator*, const int*);
        const auto sentinel = read<Addr>(tables_.world + 0x3b0);
        return sentinel && *sentinel &&
            reinterpret_cast<Find>(game_base + 0x8f9f0)(tables_.world + 0x398, &it, &id) == &it &&
            it.node == *sentinel && it.info;
    }
    bool detach() noexcept {
        if (!registered_) return true;
        if (!reservation(lane_).unpublish(publication_)) { reason_ = "slot detach pending"; return false; }
        registered_ = false;
        return true;
    }
    void reclaim() noexcept {
        if (busy_ || !on_thread() || !closing_ || registered_ || constructing_unit_) return;
        if (unit_ && !removed_) {
            if (!remove_returned_ || read<Addr>(game_base+0x4dcc1b0)!=tables_.world ||
                unit_object(id_) || world_object(tables_.world,id_) || !inactive_vacant(id_)) return;
            removed_=true;
        }
        busy_ = true;
        const bool released = descriptor_.release() && player_.release_detached();
        busy_ = false;
        if (!released) { reason_ = "private release pending"; return; }
        leave_requested_=false;
        unit_ = generated_ = chosen_ = remove_stack_ = remove_return_ = 0;
        thread_ = 0;
        epoch_ = 0;
        id_ = 0;
        closing_ = selected_ = delete_requested_ = removed_ = remove_returned_ = false;
        reason_ = "empty";
    }
    void retire(bool stock_removing) noexcept {
        if (!on_thread()) return;
        closing_ = true;
        if (constructing_unit_) return;
        // ClearUseTarget may notify Lua. Keep the Player/Unit association alive
        // through that callback and refuse a reentrant leave/join.
        if (registered_ && player_.address() && !busy_ && !removed_ && !remove_returned_ &&
            read<Addr>(player_.address()+0x20).value_or(0)) {
            busy_ = true;
            reinterpret_cast<void (*)(Addr)>(game_base+0x1cb120)(player_.address());
            busy_ = false;
        }
        if (!detach()) return;
        if (unit_ && !removed_ && !remove_returned_ && !stock_removing && !delete_requested_ &&
            read<Addr>(game_base+0x4dcc1b0)==tables_.world &&
            world_object(tables_.world, id_) == unit_ && unit_object(id_) == unit_) {
            delete_requested_ = true;
            reinterpret_cast<void (*)(Addr)>(game_base + 0x7bac0)(unit_);
        }
        reclaim();
    }

    void generated(SafetyHookContext& f) noexcept {
        if (!on_thread() || !constructing_unit_ || f.rdi != descriptor_.address()) return;
        const auto id = read<int>(f.rsi + 0x48).value_or(-1);
        if (generated_ || read<Addr>(f.rsi) != game_base + 0x4ef178 ||
            read<Addr>(f.rsi + 0x520) != f.rdi || id <= 0 || id != int64_t{counter_} + 1 ||
            read<int>(tables_.world + 0x14) != id || read<int>(f.rdi + 0x10) != -1 ||
            world_object(tables_.world,id) || unit_object(id) || !inactive_vacant(id)) {
            reason_ = "stock generated identity changed"; return;
        }
        *reinterpret_cast<int*>(f.rdi + 0x10) = id;
        id_ = id;
        generated_ = f.rsi;
    }
    void select_player(SafetyHookContext& f) noexcept {
        if (!on_thread() || !constructing_unit_ || read<Addr>(f.r14 + 0x520) != descriptor_.address()) return;
        // The original instruction loads [rax] into the new Unit's Player borrow.
        // The private descriptor alone identifies this factory call, including rollback.
        if (read<Addr>(f.r14) != game_base + 0x4ef178 || f.rax != tables_.players ||
            selected_ || chosen_ != player_.address()) { reason_ = "stock player selector changed"; return; }
        f.rax = reinterpret_cast<Addr>(&chosen_);
        selected_ = true;
    }
    void removing(SafetyHookContext& f) noexcept {
        if (!on_thread() || !unit_ || f.rcx != unit_ || removed_) return;
        const auto caller = read<Addr>(f.rsp).value_or(0);
        retire(true);
        if (registered_ || (caller != game_base + 0x2b1dc8 && caller != game_base + 0x2b2a5d) ||
            read<Addr>(unit_ + 0x520) != descriptor_.address() || read<int>(unit_ + 0x48) != id_) return;
        remove_stack_ = f.rsp;
        remove_return_ = caller;
    }
    void returned(SafetyHookContext& f, Addr rva) noexcept {
        if (!on_thread() || !remove_stack_ || remove_stack_ + sizeof(Addr) != f.rsp ||
            remove_return_ != game_base + rva) return;
        remove_stack_ = 0;
        remove_returned_ = true;
        reason_ = "awaiting vacant original lookups";
        reclaim();
    }
    void reset(SafetyHookContext& f) noexcept {
        if (on_thread() && f.rcx == tables_.world) retire(true);
    }
    void shutdown(SafetyHookContext& f) noexcept {
        if (on_thread() && f.rcx == tables_.manager) retire(true);
    }
    template<auto Method, Addr... Site>
    static void dispatch(SafetyHookContext& frame) noexcept {
        for (auto& room : rooms()) {
            if (room) ((*room).*Method)(frame, Site...);
        }
    }
    bool install() {
        if (taps_[0]) return true;
        const auto matches=[](Addr rva,std::string_view bytes) {
            std::array<char,16> current{};
            SIZE_T count{};
            return bytes.size()<=current.size() &&
                ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(game_base+rva),
                                  current.data(),bytes.size(),&count) && count==bytes.size() &&
                std::equal(bytes.begin(),bytes.end(),current.begin());
        };
        using namespace std::string_view_literals;
        if (!matches(0x2a84dc,"\x48\x8b\x08\x49\x89\x8e\x58\x06\x00\x00"sv) ||
            !matches(0x2ac75b,"\x48\x8b\x86\xb0\x00\x00\x00\x45\x33\xf6"sv) ||
            !matches(0x2b1dc8,"\x48\x8b\x47\x08\x48\x8b\xf8"sv) ||
            !matches(0x2b2a5d,"\x48\x8b\x47\x08\x48\x8b\xf8"sv)) return false;
        using Fn = safetyhook::MidHookFn;
        struct Site { Addr rva; Fn callback; };
        const std::array<Site,7> sites{{
            {0x2ac75b, dispatch<&RoomGuest::generated>},
            {0x2a84dc, dispatch<&RoomGuest::select_player>},
            {0x2b25b0, dispatch<&RoomGuest::removing>},
            {0x2b1dc8, dispatch<&RoomGuest::returned,0x2b1dc8>},
            {0x2b2a5d, dispatch<&RoomGuest::returned,0x2b2a5d>},
            {0x2cb420, dispatch<&RoomGuest::reset>},
            {0x1cd020, dispatch<&RoomGuest::shutdown>},
        }};
        std::array<SafetyHookMid,7> taps;
        for (size_t i=0; i<sites.size(); ++i) {
            taps[i] = safetyhook::create_mid(game_base+sites[i].rva, sites[i].callback);
            if (!taps[i]) return false;
        }
        taps_ = std::move(taps);
        return true;
    }

public:
    static std::span<std::optional<RoomGuest>> rooms();
    explicit RoomGuest(unsigned lane, std::uint64_t seat): lane_(lane), seat_(seat) {}
    std::uint64_t seat() const noexcept { return seat_; }
    unsigned lane() const noexcept { return lane_; }
    bool reusable() const noexcept { return !thread_ && !pending_ && !busy_; }
    bool published() const noexcept {
        return on_thread() && !closing_ && registered_ && host_matches() && reservation(lane_).accepts(tables_,primary_) &&
            world_object(tables_.world,id_)==unit_ && unit_object(id_)==unit_;
    }
    std::optional<Owner> owner() const noexcept {
        if (!published()) return {};
        return Owner{tables_.world, player_.address(), unit_, read<Addr>(tables_.handlers+lane_*sizeof(Addr)).value_or(0)};
    }
    int id() const noexcept { return published() ? id_ : 0; }
    std::uint64_t epoch() const noexcept { return epoch_; }
    std::uint64_t publication() const noexcept { return publication_; }
    const char* status() const noexcept { return reason_; }

    void leave(std::uint64_t epoch) noexcept {
        if (pending_ && pending_->epoch==epoch) pending_.reset();
        if (epoch && epoch==epoch_ && on_thread()) { closing_=true; leave_requested_=true; reason_="retiring"; }
    }
    void queue_join(int hero,std::uint64_t epoch,int point,std::uint64_t connection) {
        if (thread_ || pending_ || busy_) return;
        const auto slots=Slots::current();
        const auto host=slots ? slots->primary(hero) : std::nullopt;
        if (!host || !epoch || point<=0) { reason_="waiting for original room owner"; return; }
        Pending next{*slots,*host,hero,point,epoch,connection};
        if (refused_==next) return;
        pending_=next;
        reason_="waiting for original input return";
    }
    void input_return(std::uint64_t active_epoch) {
        if (leave_requested_ || closing_) { leave_requested_=false; retire(false); }
        if (!pending_) return;
        const auto request=*pending_;
        pending_.reset();
        if (!active_epoch || active_epoch!=request.epoch || Slots::current()!=request.slots ||
            request.slots.primary(request.id)!=request.host) { reason_="room changed before creation"; return; }
        if (!request.slots.ensure(lane_)) { reason_="stock Player capacity unavailable"; return; }
        join(request.id,request.epoch,request.point);
        if (!registered_ && std::string_view(reason_)!="stock spawn point blocked") refused_=request;
        else refused_.reset();
    }
    void maintain() noexcept {
        if (!on_thread() || busy_) return;
        if (closing_ || (registered_ && !published())) leave(epoch_);
    }
    void join(int hero, std::uint64_t epoch, int point_id) {
        if (thread_ || busy_ || !epoch || hero<=0 || point_id<=0 || hero==point_id ||
            !h2t_observe::latest_on_game_thread().serial || read<std::uint8_t>(game_base+0x837e3e)!=0 ||
            read<std::uint8_t>(game_base+0x837ebb)!=0) { reason_="room or fixed pads unavailable"; return; }
        const auto slots = Slots::current();
        const auto host = slots ? slots->primary(hero) : std::nullopt;
        if (!host || lane_>=slots->size() || read<Addr>(host->unit+0x658)!=host->player ||
            read<Addr>(slots->players+lane_*sizeof(Addr))!=Addr{0} || !install()) { reason_="stock host or vacant slot unavailable"; return; }
        const Addr point = world_object(slots->world, point_id);
        const auto loc = reinterpret_cast<Location* (*)(Addr,Location*)>(game_base+0x29ed10);
        Location xy{};
        if (!point || read<int>(point+0x48)!=point_id || loc(point,&xy)!=&xy ||
            !std::isfinite(xy.x) || !std::isfinite(xy.y)) { reason_="stock spawn point unavailable"; return; }
        // Same point and default obstacle/unit flags as ScriptAction::ExecuteBool
        // (IsLocationBlocked, CheckUnits=true), on the actual creation frame.
        using Blocked = bool (*)(Location,bool,bool,bool,bool,bool,bool);
        if (reinterpret_cast<Blocked>(game_base+0x2bc220)(xy,false,true,true,true,true,false)) {
            reason_="stock spawn point blocked"; return;
        }
        tables_ = *slots; primary_ = *host; host_id_ = hero; epoch_ = epoch;
        thread_ = GetCurrentThreadId();
        busy_ = true;
        const auto build = [&]() -> const char* {
            if (const char* failure = descriptor_.load(read<Addr>(host->unit+0x520).value_or(0),xy)) return failure;
            if (!player_.create()) return "private Player constructor refused";
            const auto counter = read<int>(tables_.world+0x14);
            if (!counter || *counter < 0 || *counter == INT_MAX || world_object(tables_.world,*counter+1) ||
                unit_object(*counter+1) || !inactive_vacant(*counter+1)) return "next stock ID unavailable";
            counter_ = *counter;
            chosen_ = player_.address();
            constructing_unit_ = true;
            using Create = Addr (*)(Addr,Addr,std::uint64_t,bool);
            unit_ = reinterpret_cast<Create>(game_base+0x2c8de0)(tables_.world,descriptor_.address(),0,true);
            constructing_unit_ = false;
            if (!unit_ && generated_) unit_ = generated_;
            if (!unit_ || !selected_ || generated_ != unit_ || read<Addr>(unit_+0x658)!=chosen_ ||
                world_object(tables_.world,id_)!=unit_ || unit_object(id_)!=unit_ || !host_matches() || closing_)
                return "original Unit creation incomplete";
            const auto handler = read<Addr>(tables_.handlers+lane_*sizeof(Addr));
            const auto cursor = read<Addr>(game_base+0x831910+lane_*sizeof(Addr));
            if (!handler || !cursor || (*handler ? *cursor!=*handler+0x20 : *cursor!=0))
                return "secondary controller slot occupied";
            reinterpret_cast<void (*)(Addr,Addr,std::uint8_t)>(game_base+0x1cc9e0)(tables_.manager,chosen_,static_cast<std::uint8_t>(lane_));
            Owner guest{tables_.world,chosen_,unit_,read<Addr>(tables_.handlers+lane_*sizeof(Addr)).value_or(0)};
            const auto result=reservation(lane_).publish(publication_=++next_publication_,hero,*host,id_,guest);
            registered_=result!=SecondarySlot::Publication::refused;
            return result==SecondarySlot::Publication::published ? nullptr : "secondary publication refused";
        };
        const char* failure = build();
        busy_ = false;
        if (failure) { retire(false); reason_ = failure; }
        else reason_ = "ready";
    }
};
inline std::span<std::optional<RoomGuest>> RoomGuest::rooms() {
    static std::array<std::optional<RoomGuest>,playable_lanes> entries;
    return entries;
}
inline RoomGuest* guest_for(std::uint64_t seat) {
    for (auto& room:RoomGuest::rooms()) if (room && room->seat()==seat) return &*room;
    return nullptr;
}
inline RoomGuest* claim_guest(std::uint64_t seat, unsigned capacity) {
    if (auto* guest=guest_for(seat)) return guest;
    auto rooms=RoomGuest::rooms();
    for (unsigned lane=1; lane<capacity && lane<rooms.size(); ++lane) {
        if (!rooms[lane]) return &rooms[lane].emplace(lane,seat);
    }
    return nullptr;
}
}
