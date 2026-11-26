#include "records.hpp"
#include "server.hpp"
#include <iostream>
#include <stdexcept>

using namespace todo;

static void expect(bool condition, const char* label) {
    if (!condition) throw std::runtime_error(label);
}

int main(int argc,char* argv[]) {
    if(argc==3&&std::string_view(argv[1])=="--read-profile") {
        try {
            Store store(fs::path(wide(argv[2])));
            const auto saved=store.setting("account");
            auto state=store.read("guest");
            if(saved) {
                const auto account=Account::load(Json::parse(*saved));
                if(account.signed_in())state=store.read(account.scope());
            }
            std::cout<<"Read desktop profile: "<<state.rows.size()<<" rows, "<<state.spaces.size()<<" spaces.\n";
            return 0;
        } catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
    }
    if(argc==3&&std::string_view(argv[1])=="--probe-login") {
        try {
            const auto server=validate_server(argv[2]);
            const auto grant=login_start(server,"desktop-"+random_hex(16));
            expect(grant.qr.starts_with("gxtodo://desktop-login?")&&grant.expires>now_ms(),"valid desktop login grant");
            expect(!login_poll(server,grant),"unapproved grant must not sign in");
            std::cout<<"Server issued a QR grant and held it pending phone approval.\n";
            return 0;
        } catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
    }
    const auto temporary=fs::canonical(fs::temp_directory_path());
    const auto root=temporary/wide("gxtodo-test-"+random_hex(8));
    const auto clean=[&] {
        if (fs::exists(root)&&fs::canonical(root).parent_path()==temporary) fs::remove_all(root);
    };
    try {
        {
            Store store(root);
            Account account{"https://todo.example.invalid","test","test@example.invalid","测试",31,40,51};
            store.setting("account",account.encode().dump());
            expect(Account::load(Json::parse(*store.setting("account"))).scope()==account.scope(),"legacy account format");
            const auto state=store.change(account.scope(),[&](Workspace& data){
                data.spaces=Json::array({{{"id",51},{"name","个人空间"},{"type",1},{"user_id",31}}});
                save_task(data,account,51,"89-task",{{"name","会议"},{"start",timestamp("2032-06-15","09:00")},
                    {"end",timestamp("2032-06-15","10:00")},{"repeat",1},{"alert",0},{"children",Json::array({"准备"})}});
                save_bill(data,account,51,"51-bill",{{"name","账目"},{"date","2032-06-15"},{"amount","12.009"},{"type","expense"},
                    {"channel","微信"},{"party","微信余额"},{"currency","CNY"},{"include_in_totals",1},{"include_in_party_stats",0}});
                const Row entry{note_entry,51,0,0,0,false,"50-body",{{"kind","text"},{"content","正文"},{"entry_at",now_ms()}}};
                save_note(data,account,51,"49-note","core",std::string("笔记"),{entry},{});
            });
            expect(Workspace::load(state.encode()).get(51,note,"49-note")!=nullptr,"legacy workspace JSON");
            const auto* task_row=state.get(51,task,"89-task");
            expect(task_view(state,*task_row).occurrence("2032-06-16")==timestamp("2032-06-16","09:00"),"recurring task");
            const auto bill_row=*state.get(51,bill,"51-bill");
            const auto initial_entries=note_entries(state,*state.get(51,note,"49-note"));
            expect(total_included(bill_row)&&!party_included(bill_row),"ledger inclusion");
            expect((Amount::parse("999999999999999999999999999999.01")+Amount::parse("0.09")).format()=="999999999999999999999999999999.10","decimal precision");
            store.change(account.scope(),[&](Workspace& data){
                data.save(51,31,bill,bill_row.uid,{{"name","回执到达前的修改"}});
                apply_page(data,{bill_row},{{"data",Json::array({{{"uid",bill_row.uid},{"entropy",22},{"status",0}}})},
                    {"down",Json::array()},{"down_extra",Json::array({{{"team_id",51},{"entropy",22}}})}});
                data.save(51,31,note,"49-note",{{"title","其他设备改名"}});
                data.save(51,31,note_entry,"50-body",{{"content","其他设备更新正文"}});
                auto edited=initial_entries;
                edited.front().data["entry_at"]=number(edited.front().data,"entry_at")+1;
                save_note(data,account,51,"49-note","core",std::nullopt,edited,{},initial_entries);
            });
            const auto next=store.read(account.scope());
            const auto changed=next.get(51,bill,bill_row.uid);
            expect(changed->pending==2&&changed->revision==22&&text(changed->data,"name")=="回执到达前的修改","pending edit survives an older reply");
            expect(next.cursors.at("t51")==22&&store.read("guest").rows.empty(),"cursor and account isolation");
            const auto notebook=next.get(51,note,"49-note");
            const auto entries=note_entries(next,*notebook);
            expect(note_title(*notebook)=="其他设备改名"&&entries.size()==1&&
                text(entries.front().data,"content")=="其他设备更新正文"&&
                number(entries.front().data,"entry_at")==number(initial_entries.front().data,"entry_at")+1,
                "notebook editor preserves concurrently synced title and content");
            expect(validate_server("https://todo.example.invalid/")=="https://todo.example.invalid","server normalization");
        }
        clean();
        std::cout<<"Native workspace, task, ledger, notebook, and sync tests passed.\n";
        return 0;
    } catch(const std::exception& error) {
        std::cerr<<error.what()<<'\n';
        clean();
        return 1;
    }
}
