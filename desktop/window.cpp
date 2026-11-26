#include "ui.hpp"
#include "qrcodegen.hpp"
#include <dwmapi.h>
#include <commdlg.h>
#include <richedit.h>
#include <shellapi.h>
#include <uxtheme.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <future>
#include <sstream>
#include <thread>

namespace todo::ui {
namespace {
enum { nav_first=100, sync_id=117, new_id_button, edit_id, complete_id, delete_id, history_id, space_id,
    search_id, filter_id, period_id, note_section_id, record_id, totals_id, refresh_qr_id, server_id, account_id,
    ai_history_id, ai_new_id, ai_send_id, ai_attach_id, recycle_id, note_tree_id, date_id, backup_id, restore_id };
enum class Page { tasks, timeline, ai, bills, notes };
enum class Work { none, start, poll, sync, ai_history, ai_read, ai_send, logout };
constexpr COLORREF ink=RGB(27,41,60), muted=RGB(87,103,123), blue=RGB(38,91,160), rail=RGB(240,245,251),
    soft_blue=RGB(216,231,248), white=RGB(255,255,255);
const HBRUSH background=static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH));
const HBRUSH sidebar_brush=CreateSolidBrush(rail);

struct Display {
    std::vector<std::wstring> values;
    std::optional<Row::Key> key;
    Id occurrence{};
};
struct PartyFilter { std::string code, party, type; };
struct PartyRow { std::string code,party; Amount expense,income; };
struct Result {
    std::optional<Grant> grant;
    std::optional<std::pair<Account,Json>> login;
    Json json;
    int count{};
    std::string error;
};

std::wstring money(const Row& row) {
    try { return wide(bill_amount(Amount::parse(text(row.data,"amount")),currency(row))); }
    catch(const std::exception&) { return wide(text(row.data,"amount")); }
}
std::string readable_date(const Row& row) { return local_stamp(text(row.data,"created_at")); }
std::wstring bill_type(std::string_view type) {
    return type=="income"?L"收入":type=="transfer"?L"内转":L"支出";
}
std::string to_base64(std::string_view bytes) {
    constexpr char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string encoded;
    for(std::size_t i=0;i<bytes.size();i+=3) {
        const auto a=static_cast<unsigned char>(bytes[i]);
        const auto b=i+1<bytes.size()?static_cast<unsigned char>(bytes[i+1]):0;
        const auto c=i+2<bytes.size()?static_cast<unsigned char>(bytes[i+2]):0;
        encoded+=alphabet[a>>2]; encoded+=alphabet[(a&3)*16+(b>>4)];
        encoded+=i+1<bytes.size()?alphabet[(b&15)*4+(c>>6)]:'=';
        encoded+=i+2<bytes.size()?alphabet[c&63]:'=';
    }
    return encoded;
}
std::string image_bytes(const fs::path& file) {
    const auto size=fs::file_size(file);
    if(size==0||size>3*1024*1024)throw std::runtime_error("AI 图片不能超过 3 MB");
    std::ifstream input(file,std::ios::binary);
    std::string bytes(static_cast<std::size_t>(size),'\0');
    if(!input.read(bytes.data(),static_cast<std::streamsize>(size)))throw std::runtime_error("图片读取失败");
    return to_base64(bytes);
}
std::string timezone_offset() {
    TIME_ZONE_INFORMATION info{};
    const auto mode=GetTimeZoneInformation(&info);
    const long offset=mode==TIME_ZONE_ID_INVALID?0:-(info.Bias+(mode==TIME_ZONE_ID_DAYLIGHT?info.DaylightBias:info.StandardBias));
    const auto minutes=std::abs(offset);
    char buffer[16]{};
    std::snprintf(buffer,sizeof(buffer),"%c%02ld:%02ld",offset<0?'-':'+',minutes/60,minutes%60);
    return buffer;
}

std::string rtf_text(std::string_view value) {
    std::string output;
    for (const auto ch : wide(value)) {
        if(ch==L'\\'||ch==L'{'||ch==L'}') { output+='\\';output+=static_cast<char>(ch); }
        else if(ch==L'\n')output+="\\line ";
        else if(ch==L'\t')output+="\\tab ";
        else if(ch>=L' '&&ch<=L'~')output+=static_cast<char>(ch);
        else if(ch>=L' ')output+="\\u"+std::to_string(static_cast<std::int16_t>(ch))+"?";
    }
    return output;
}
std::string inline_markdown(std::string_view value) {
    std::string output;
    std::size_t current=0;
    bool bold=false;
    while(current<value.size()) {
        const auto next=value.find("**",current);
        output+=rtf_text(value.substr(current,next==value.npos?value.npos:next-current));
        if(next==value.npos)break;
        bold=!bold;output+=bold?"\\b ":"\\b0 ";current=next+2;
    }
    if(bold)output+="\\b0 ";
    return output;
}
std::string markdown_rtf(const std::string& value) {
    std::istringstream input(value);
    std::string result,line;
    const std::string fence(3,static_cast<char>(96));
    bool code=false;
    while(std::getline(input,line)) {
        if(line.starts_with(fence)) {code=!code;continue;}
        if(code) {result+="\\f1 "+rtf_text(line)+"\\f0\\par ";continue;}
        if(line.starts_with("|")&&line.size()>2) {
            if(line.find_first_not_of("|-: \t\r")==line.npos)continue;
            std::vector<std::string> cells;
            std::istringstream row(line.substr(1));
            for(std::string cell;std::getline(row,cell,'|');)cells.push_back(std::move(cell));
            if(cells.empty())continue;
            result+="\\trowd\\trgaph90 ";
            for(std::size_t column=0;column<cells.size();++column)
                result+="\\clbrdrb\\brdrs\\brdrw6\\brdrcf2\\cellx"+std::to_string((column+1)*10300/cells.size());
            for(const auto& cell:cells)result+="\\pard\\intbl "+inline_markdown(cell)+"\\cell ";
            result+="\\row ";
            continue;
        }
        result+="\\pard ";
        if(line.starts_with("#")) {
            const auto start=line.find_first_not_of("# ");
            if(start!=line.npos)result+="\\sb120\\b\\fs28 "+rtf_text(line.substr(start))+"\\b0\\fs23 ";
        } else if(line.starts_with("- "))result+="\\li240 "+rtf_text("• ")+inline_markdown(line.substr(2));
        else result+=inline_markdown(line);
        result+="\\par ";
    }
    return result;
}
DWORD CALLBACK stream_rtf(DWORD_PTR cookie,LPBYTE buffer,LONG capacity,LONG* read) {
    auto& data=*reinterpret_cast<std::string_view*>(cookie);
    const auto count=std::min(data.size(),static_cast<std::size_t>(capacity));
    if(count)std::memcpy(buffer,data.data(),count);
    data.remove_prefix(count);*read=static_cast<LONG>(count);
    return 0;
}

class Window {
public:
    explicit Window(const fs::path& root) : store(root) {
        origin=store.setting("server").value_or(public_server);
        if(const auto saved=store.setting("account")) {
            const auto candidate=Account::load(Json::parse(*saved));
            if(candidate.signed_in()&&candidate.server==origin)account=candidate;
        }
        team=account.personal;
        workspace=store.read(account.scope());
    }
    static LRESULT CALLBACK proc(HWND window,UINT message,WPARAM w,LPARAM l) {
        if(message==WM_NCCREATE) {
            auto* instance=static_cast<Window*>(reinterpret_cast<const CREATESTRUCTW*>(l)->lpCreateParams);
            SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(instance));
            instance->hwnd=window;
        }
        const auto self=reinterpret_cast<Window*>(GetWindowLongPtrW(window,GWLP_USERDATA));
        if(!self)return DefWindowProcW(window,message,w,l);
        try { return self->message(message,w,l); }
        catch(const std::exception& error) {show_error(window,error);return message==WM_CREATE?-1:0;}
    }
private:
    HWND hwnd{},rail_title{},header{},context{},status{},search{},space_picker{},main_list{},totals_list{},calendar{},
        tree{},month{},section{},filter{},qr_hint{},qr_code{},qr_refresh{},server_button{},sync_button{},add_button{},
        edit_button{},done_button{},delete_button{},history_button{},account_button{},recycle_button{},backup_button{},
        ai_display{},ai_input{},ai_history{},ai_new{},ai_send{},ai_attach{};
    HWND navigation[5]{};
    Store store;
    Account account;
    Workspace workspace;
    std::string origin;
    Id team{-1};
    Page page=Page::tasks;
    std::string selected_date=today();
    std::string selected_month=today().substr(0,7);
    std::string note_section;
    std::string query;
    int task_filter=0;
    bool recycling=false, rebuilding=false;
    std::vector<Display> display;
    std::vector<PartyRow> parties;
    std::optional<PartyFilter> party_filter;
    std::vector<Id> spaces;
    std::vector<std::string> months;
    std::vector<Row::Key> tree_rows;
    std::optional<Grant> grant;
    std::optional<qrcodegen::QrCode> qr;
    std::future<Result> operation;
    Work work=Work::none;
    Id next_poll=0, next_sync=0, next_ai=0;
    std::string thread;
    std::optional<fs::path> image;
    Json conversations=Json::array();
    Json ai_turns=Json::array();
    static constexpr int left=192;

    void label_status(std::wstring value) {SetWindowTextW(status,value.c_str());}
    void show(HWND control,bool visible) {ShowWindow(control,visible?SW_SHOW:SW_HIDE);}
    HWND button(const wchar_t* text,int id) {return control(hwnd,L"BUTTON",text,WS_TABSTOP|BS_PUSHBUTTON,id);}
    HWND label(const wchar_t* text=L"") {return control(hwnd,L"STATIC",text,SS_LEFT);}
    HWND combo(int id) {return control(hwnd,WC_COMBOBOXW,L"",WS_TABSTOP|WS_VSCROLL|CBS_DROPDOWNLIST,id);}
    void setup_list(HWND window) {
        ListView_SetExtendedListViewStyle(window,LVS_EX_FULLROWSELECT|LVS_EX_DOUBLEBUFFER|LVS_EX_LABELTIP);
        SetWindowTheme(window,L"Explorer",nullptr);
        ListView_SetBkColor(window,white);
        ListView_SetTextBkColor(window,white);
        ListView_SetTextColor(window,ink);
    }
    void build() {
        const auto dpi=GetDpiForWindow(hwnd);
        ui_font=CreateFontW(-MulDiv(15,dpi,96),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
        title_font=CreateFontW(-MulDiv(26,dpi,96),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
        rail_title=label(L"高效 Todo");
        SendMessageW(rail_title,WM_SETFONT,reinterpret_cast<WPARAM>(title_font),TRUE);
        header=label();
        SendMessageW(header,WM_SETFONT,reinterpret_cast<WPARAM>(title_font),TRUE);
        context=label();
        status=label();
        const wchar_t* titles[]{L"任务",L"时间轴",L"AI 对话",L"记账",L"便签"};
        for (int i=0;i<5;++i) navigation[i]=control(hwnd,L"BUTTON",titles[i],WS_TABSTOP|BS_OWNERDRAW,nav_first+i);
        sync_button=button(L"同步",sync_id); add_button=button(L"新建",new_id_button);
        edit_button=button(L"编辑",edit_id); done_button=button(L"完成／恢复",complete_id);
        history_button=button(L"历史版本",history_id); delete_button=button(L"删除",delete_id);
        account_button=button(L"账户",account_id); recycle_button=button(L"回收站",recycle_id); backup_button=button(L"备份",backup_id);
        search=control(hwnd,L"EDIT",L"",WS_TABSTOP|ES_AUTOHSCROLL,search_id,WS_EX_CLIENTEDGE);
        SendMessageW(search,EM_SETCUEBANNER,TRUE,reinterpret_cast<LPARAM>(L"搜索当前页面"));
        space_picker=combo(space_id); filter=combo(filter_id); month=combo(period_id); section=combo(note_section_id);
        for(const auto* label : {L"全部",L"未完成",L"已完成"})add_choice(filter,label);
        SendMessageW(filter,CB_SETCURSEL,0,0);
        for(const auto* label : {L"速记",L"精髓",L"内核"})add_choice(section,label);
        SendMessageW(section,CB_SETCURSEL,0,0);
        main_list=control(hwnd,WC_LISTVIEWW,L"",WS_TABSTOP|LVS_REPORT|LVS_OWNERDATA|LVS_SINGLESEL|LVS_SHOWSELALWAYS,record_id);
        totals_list=control(hwnd,WC_LISTVIEWW,L"",WS_TABSTOP|LVS_REPORT|LVS_OWNERDATA|LVS_SINGLESEL|LVS_SHOWSELALWAYS,totals_id);
        setup_list(main_list);setup_list(totals_list);
        calendar=control(hwnd,MONTHCAL_CLASSW,L"",WS_TABSTOP, date_id);
        tree=control(hwnd,WC_TREEVIEWW,L"",WS_TABSTOP|TVS_HASBUTTONS|TVS_LINESATROOT|TVS_SHOWSELALWAYS,note_tree_id);
        SetWindowTheme(tree,L"Explorer",nullptr);
        qr_hint=label(L"用手机打开「账户与服务端」 → 「扫码登录桌面端」");
        qr_code=label();
        qr_refresh=button(L"刷新二维码",refresh_qr_id); server_button=button(L"设置服务端",server_id);
        LoadLibraryW(L"Msftedit.dll");
        ai_display=control(hwnd,L"RICHEDIT50W",L"",WS_TABSTOP|WS_VSCROLL|ES_MULTILINE|ES_READONLY|ES_AUTOVSCROLL);
        SendMessageW(ai_display,EM_SETBKGNDCOLOR,0,white);
        ai_input=control(hwnd,L"EDIT",L"",WS_TABSTOP|WS_VSCROLL|ES_MULTILINE|ES_AUTOVSCROLL|ES_WANTRETURN,0,WS_EX_CLIENTEDGE);
        SendMessageW(ai_input,EM_SETLIMITTEXT,5000,0);
        ai_history=combo(ai_history_id); ai_new=button(L"新对话",ai_new_id);
        ai_send=button(L"发送",ai_send_id); ai_attach=button(L"附图片",ai_attach_id);
        SetTimer(hwnd,1,200,nullptr);
        refresh();
        if(account.signed_in())next_sync=now_ms()+300;
        else start_login();
    }

    void columns(HWND window,std::initializer_list<std::pair<const wchar_t*,int>> spec) {
        while(ListView_DeleteColumn(window,0)) {}
        int index=0;
        for(const auto& [name,width]:spec) {
            LVCOLUMNW column{LVCF_TEXT|LVCF_WIDTH|LVCF_FMT};
            column.pszText=const_cast<wchar_t*>(name);
            column.cx=width; column.fmt=LVCFMT_LEFT;
            ListView_InsertColumn(window,index++,&column);
        }
    }

    void refresh_choices() {
        rebuilding=true;
        SendMessageW(space_picker,CB_RESETCONTENT,0,0);spaces.clear();
        if(workspace.spaces.empty()&&account.signed_in()) {
            workspace.spaces.push_back({{"id",account.personal},{"name","个人空间"},{"type",1},{"user_id",account.user}});
        }
        int selected=-1;
        for(const auto& space:workspace.spaces) {
            const auto id=number(space,"id");
            if(id<=0)continue;
            if(id==team)selected=static_cast<int>(spaces.size());
            add_choice(space_picker,wide(text(space,"name","个人空间")));
            spaces.push_back(id);
        }
        if(selected<0&&!spaces.empty()){selected=0;team=spaces.front();}
        SendMessageW(space_picker,CB_SETCURSEL,selected,0);
        rebuilding=false;
    }
    bool match(const Row& row) const {
        if(query.empty())return true;
        for(const auto* key:{"name","title","remark","channel","party","location"})
            if(text(row.data,key).find(query)!=std::string::npos)return true;
        if(row.table==note)
            for(const auto& item:note_entries(workspace,row))if(text(item.data,"content").find(query)!=std::string::npos)return true;
        return false;
    }
    void build_tasks() {
        columns(main_list,{{L"状态",85},{L"任务",430},{L"计划",175},{L"优先级",100}});
        struct Occurrence {const TaskView* view;Id time;const Row* done;};
        const auto list=tasks(workspace,team);
        std::vector<Occurrence> visible;
        for(const auto& item:list) {
            if(!match(*item.row))continue;
            const auto when=page==Page::timeline?item.occurrence(selected_date):item.next(today());
            if(page==Page::timeline&&!when)continue;
            const auto complete=item.completed(account.user,when);
            if((task_filter==1&&complete)||(task_filter==2&&!complete))continue;
            visible.push_back({&item,when,complete});
        }
        std::ranges::sort(visible,[](const auto& a,const auto& b) {
            if(static_cast<bool>(a.done)!=static_cast<bool>(b.done))return !a.done;
            if(a.done&&b.done)return number(a.done->data,"check_at")>number(b.done->data,"check_at");
            if(!a.time||!b.time)return static_cast<bool>(a.time)&&!b.time;
            return a.time<b.time;
        });
        for(const auto& record:visible) {
            const bool all=number(record.view->one(schedule)?record.view->one(schedule)->data:Json{},"is_all_day")==1;
            const auto moment=record.time ? local_date(record.time)+(all?" 全天":" "+local_time(record.time)) : "未安排";
            const wchar_t* ranks[]{L"普通",L"重要",L"紧急",L"重要且紧急"};
            display.push_back({{record.done?L"已完成":L"待完成",wide(text(record.view->row->data,"name")),wide(moment),
                ranks[std::clamp<Id>(number(record.view->row->data,"rank",1),1,4)-1]},record.view->row->key(),record.time});
        }
        SetWindowTextW(context,page==Page::timeline?wide(selected_date).c_str():L"");
    }
    void build_bills() {
        columns(main_list,{{L"日期",110},{L"类型",65},{L"金额",130},{L"途径",95},{L"支出收入方",122},{L"事项",270}});
        columns(totals_list,{{L"支出收入方",260},{L"支出汇总",180},{L"收入汇总",180}});
        const auto all=workspace.list(team,bill);
        std::set<std::string,std::greater<>> known{today().substr(0,7)};
        for(const auto* row:all)if(text(row->data,"date").size()>=7)
            known.insert(text(row->data,"date").substr(0,7));
        if(!known.contains(selected_month))selected_month=today().substr(0,7);
        rebuilding=true;
        SendMessageW(month,CB_RESETCONTENT,0,0);
        months.assign(known.begin(),known.end());
        for(std::size_t i=0;i<months.size();++i) {
            add_choice(month,wide(months[i]+(months[i]==today().substr(0,7)?" · 本月":" · 已归档")));
            if(months[i]==selected_month)SendMessageW(month,CB_SETCURSEL,i,0);
        }
        rebuilding=false;
        std::map<std::string,std::pair<Amount,Amount>> segments;
        std::map<std::pair<std::string,std::string>,PartyRow> groups;
        auto bills=all;
        std::erase_if(bills,[&](const Row* row){return !text(row->data,"date").starts_with(selected_month+"-");});
        std::ranges::sort(bills,[](const Row* a,const Row* b){
            return std::tuple{text(a->data,"date"),text(a->data,"created_at"),a->uid}>
                std::tuple{text(b->data,"date"),text(b->data,"created_at"),b->uid};
        });
        for(const auto* row:bills) {
            const auto type=text(row->data,"type"), code=currency(*row), party=text(row->data,"party");
            if(type=="expense"||type=="income") try {
                const auto amount=Amount::parse(text(row->data,"amount"));
                if(total_included(*row)) {
                    auto& totals=segments[code];
                    auto& sum=type=="expense"?totals.first:totals.second; sum=sum+amount;
                }
                if(party_included(*row)) {
                    auto& group=groups.try_emplace({code,party},PartyRow{code,party}).first->second;
                    auto& sum=type=="expense"?group.expense:group.income; sum=sum+amount;
                }
            } catch(const std::exception&) {}
            if(!match(*row))continue;
            if(party_filter&&(party_filter->type!=type||party_filter->code!=code||party_filter->party!=party||!party_included(*row)))continue;
            display.push_back({{wide(text(row->data,"date")),bill_type(type),money(*row),wide(text(row->data,"channel")),
                wide(party),wide(text(row->data,"name"))},row->key()});
        }
        for(const auto& [key,item]:groups)parties.push_back(item);
        std::string summary;
        if(segments.empty())segments.emplace("CNY",std::pair<Amount,Amount>{});
        for(const auto& [code,sum]:segments) {
            if(!summary.empty())summary+="   ·   ";
            summary+="总支出 "+bill_amount(sum.first,code)+"     总收入 "+bill_amount(sum.second,code);
        }
        if(party_filter)summary+="     筛选 "+party_filter->party+" · "+(party_filter->type=="expense"?"支出":"收入");
        SetWindowTextW(context,wide(summary).c_str());
    }
    HTREEITEM tree_entry(HTREEITEM parent,const std::wstring& title,LPARAM id=-1) {
        TVINSERTSTRUCTW item{};
        item.hParent=parent; item.hInsertAfter=TVI_LAST;
        item.item.mask=TVIF_TEXT|TVIF_PARAM;item.item.pszText=const_cast<wchar_t*>(title.c_str());item.item.lParam=id;
        return TreeView_InsertItem(tree,&item);
    }
    void build_notes() {
        columns(main_list,{{L"标题",590},{L"创建时间",182}});
        TreeView_DeleteAllItems(tree);
        tree_rows.clear();
        const auto initial=note_section.empty()?L"速记":note_section=="essence"?L"精髓":L"内核";
        SetWindowTextW(context,initial);
        auto notes=workspace.list(team,note);
        std::ranges::sort(notes,std::greater{},[](const Row* row){return text(row->data,"created_at");});
        std::map<std::string,HTREEITEM> years, groups;
        bool expand=true;
        for(const auto* row:notes) {
            if(text(row->data,"notebook_section")!=note_section||!match(*row))continue;
            const auto date=readable_date(*row);
            if(note_section.empty()) {
                display.push_back({{wide(note_title(*row)),wide(date)},row->key()});continue;
            }
            const auto year=date.size()>=10?date.substr(0,4):"日期未知";
            const auto group=date.size()>=10?date.substr(0,7):year;
            if(!years.contains(year))years.emplace(year,tree_entry(TVI_ROOT,wide(year+(date.size()>=10?" 年":""))));
            if(!groups.contains(group))groups.emplace(group,tree_entry(years.at(year),wide(date.size()>=10?date.substr(5,2)+" 月":group)));
            tree_entry(groups.at(group),wide((date.size()>=10?date.substr(0,10)+" ":"")+note_title(*row)),
                static_cast<LPARAM>(tree_rows.size()));
            tree_rows.push_back(row->key());
            if(expand){TreeView_Expand(tree,years.at(year),TVE_EXPAND);TreeView_Expand(tree,groups.at(group),TVE_EXPAND);expand=false;}
        }
    }
    void refresh() {
        display.clear();
        parties.clear();
        refresh_choices();
        SetWindowTextW(header, page==Page::tasks?L"任务":page==Page::timeline?L"时间轴":page==Page::ai?L"AI 对话":page==Page::bills?L"记账":L"便签");
        if(recycling) {
            SetWindowTextW(header,L"回收站");
            SetWindowTextW(context,L"");
            columns(main_list,{{L"类型",125},{L"已删除记录",590}});
            for(const auto& [key,row]:workspace.rows)if(row.team==team&&row.removed&&(row.table==task||row.table==bill)&&match(row)&&!text(row.data,"name").empty())
                display.push_back({{row.table==bill?L"账单":L"任务",wide(text(row.data,"name"))},key});
        } else switch(page) {
            case Page::tasks:case Page::timeline:build_tasks();break;
            case Page::bills:build_bills();break;
            case Page::notes:build_notes();break;
            case Page::ai:SetWindowTextW(context,L"");break;
        }
        ListView_SetItemCountEx(main_list,static_cast<int>(display.size()),LVSICF_NOINVALIDATEALL);
        ListView_SetItemCountEx(totals_list,static_cast<int>(parties.size()),LVSICF_NOINVALIDATEALL);
        InvalidateRect(main_list,nullptr,TRUE);InvalidateRect(totals_list,nullptr,TRUE);
        layout();InvalidateRect(hwnd,nullptr,TRUE);
    }

    void layout() {
        RECT rect{};GetClientRect(hwnd,&rect);
        const auto dpi=GetDpiForWindow(hwnd);
        const int width=MulDiv(rect.right,96,dpi),height=MulDiv(rect.bottom,96,dpi),cx=left+28,cw=width-cx-26;
        const bool signed_in=account.signed_in();
        place(rail_title,24,22,165,47);
        for(int i=0;i<5;++i){place(navigation[i],12,86+i*49,167,41);show(navigation[i],signed_in);}
        place(space_picker,18,354,154,230);show(space_picker,signed_in);
        place(account_button,18,height-105,154,31);show(account_button,signed_in);
        place(recycle_button,18,height-186,154,31);show(recycle_button,signed_in);
        place(backup_button,18,height-146,154,31);show(backup_button,signed_in);
        place(status,cx,height-27,cw,21);
        show(header,signed_in);place(header,cx,22,cw,47);
        const bool ai=signed_in&&!recycling&&page==Page::ai;
        const bool ledger=signed_in&&!recycling&&page==Page::bills;
        const bool time=signed_in&&!recycling&&page==Page::timeline;
        const bool notes=signed_in&&!recycling&&page==Page::notes;
        const bool tasks_visible=signed_in&&!recycling&&(page==Page::tasks||page==Page::timeline);
        const bool note_groups=notes&&!note_section.empty();
        show(sync_button,signed_in);place(sync_button,width-122,25,94,32);
        show(add_button,signed_in&&!ai&&!recycling);place(add_button,width-229,25,94,32);
        show(context,signed_in&&!ai);place(context,cx,108,cw,25);
        show(search,signed_in&&!ai);place(search,cx,68,std::min(cw/2,343),29);
        show(filter,tasks_visible);place(filter,width-160,68,132,190);
        show(month,ledger);place(month,width-232,68,204,240);
        show(section,notes);place(section,width-177,68,149,190);
        show(calendar,time);place(calendar,cx,146,240,180);
        show(totals_list,ledger);place(totals_list,cx,139,cw,std::min(152,static_cast<int>(parties.size())*22+30));
        const int top=ledger?154+std::min(152,static_cast<int>(parties.size())*22+30):136;
        show(main_list,signed_in&&!ai&&!note_groups);
        place(main_list,time?cx+258:cx,top,time?cw-258:cw,height-top-79);
        show(tree,note_groups);place(tree,cx,136,cw,height-215);
        show(edit_button,signed_in&&!ai);place(edit_button,cx,height-63,88,28);
        show(done_button,tasks_visible);place(done_button,cx+100,height-63,110,28);
        show(history_button,ledger||tasks_visible);place(history_button,cx+222,height-63,108,28);
        show(delete_button,signed_in&&!ai&&!recycling);place(delete_button,width-122,height-63,94,28);
        SetWindowTextW(edit_button,recycling?L"恢复":L"编辑");
        show(ai_display,ai);place(ai_display,cx,104,cw,height-238);
        show(ai_input,ai);place(ai_input,cx,height-122,cw-120,82);
        show(ai_history,ai);place(ai_history,cx,66,cw-125,280);
        show(ai_new,ai);place(ai_new,width-131,66,103,30);
        show(ai_send,ai);place(ai_send,width-129,height-81,101,34);
        show(ai_attach,ai);place(ai_attach,width-129,height-123,101,33);
        const int center=(width+left)/2, y=std::max(20,height/2-195);
        show(qr_hint,!signed_in);place(qr_hint,center-190,y-14,440,26);
        show(qr_code,!signed_in);place(qr_code,center-99,y+300,245,26);
        show(qr_refresh,!signed_in);place(qr_refresh,center-138,y+340,128,33);
        show(server_button,!signed_in);place(server_button,center+12,y+340,128,33);
    }

    void launch(Work type,std::function<Result()> action) {
        if(work!=Work::none) return;
        work=type;
        std::promise<Result> promise;
        operation=promise.get_future();
        std::thread([action=std::move(action),promise=std::move(promise)]() mutable {
            try {promise.set_value(action());}
            catch(const std::exception& error){Result result;result.error=error.what();promise.set_value(std::move(result));}
        }).detach();
    }
    void start_login() {
        if (work!=Work::none) return;
        grant.reset();qr.reset();SetWindowTextW(qr_code,L"正在获取二维码…");InvalidateRect(hwnd,nullptr,TRUE);
        auto device=store.setting("desktop_device").value_or("");
        if(device.empty()){device="desktop-"+random_hex(16);store.setting("desktop_device",device);}
        const auto server=origin;
        launch(Work::start,[server,device]{Result result;result.grant=login_start(server,device);return result;});
    }
    void login_tick() {
        if(!grant||now_ms()<next_poll)return;
        if(now_ms()>=grant->expires){grant.reset();qr.reset();SetWindowTextW(qr_code,L"二维码已过期，请刷新");InvalidateRect(hwnd,nullptr,TRUE);return;}
        const auto token=*grant;
        const auto server=origin;
        launch(Work::poll,[token,server]{Result result;result.login=login_poll(server,token);return result;});
    }
    void begin_sync() {
        if(!account.signed_in()||work!=Work::none)return;
        const auto current=account;
        const auto local=store;
        label_status(L"正在同步…");
        launch(Work::sync,[current,local]{Result result;result.count=synchronize(local,current);return result;});
    }
    void load_ai(bool histories) {
        if(!account.signed_in())return;
        const auto current=account;const auto selected=thread;
        launch(histories?Work::ai_history:Work::ai_read,[current,selected,histories] {
            Result result;result.json=api(current.server,current,"/ai/chat","GET",
                histories?Json::object():Json{{"thread",selected}});return result;
        });
    }
    void send_ai() {
        if(work!=Work::none||!account.signed_in())return;
        const auto question=utf8(contents(ai_input));
        if(question.find_first_not_of(" \r\n\t")==std::string::npos)return;
        if(thread.empty())thread="chat-"+random_hex(16);
        const auto attachment=image;
        const auto current=account;
        const auto target=thread;
        label_status(L"正在提交问题…");
        launch(Work::ai_send,[current,target,attachment,question] {
            Json values={{"thread",target},{"request_id","ai-"+random_hex(16)},{"question",question},{"timezone",timezone_offset()}};
            if(attachment)values["image"]=image_bytes(*attachment);
            Result result;result.json=api(current.server,current,"/ai/chat","POST",std::move(values));return result;
        });
    }
    void ai_text() {
        std::string output="{\\rtf1\\ansi\\uc1{\\fonttbl{\\f0 Segoe UI;}{\\f1 Consolas;}}"
            "{\\colortbl;\\red27\\green41\\blue60;\\red215\\green224\\blue235;\\red38\\green91\\blue160;}"
            "\\f0\\fs23\\cf1 ";
        bool queue=false;
        bool any=false;
        for(const auto& turn:ai_turns) {
            if(any)output+="\\pard\\par ";
            any=true;
            output+="\\pard\\cf3\\b "+rtf_text("你")+"\\b0\\cf1\\par "+rtf_text(text(turn,"question"))+
                "\\par\\par\\cf3\\b AI\\b0\\cf1\\par ";
            const auto state=text(turn,"state");
            if(state=="done")output+=markdown_rtf(text(turn,"answer"));
            else if(state=="failed")output+=rtf_text(text(turn,"error","请求失败"));
            else {output+=rtf_text(state=="queued"?"排队中…":"正在查询和分析…");queue=true;}
        }
        if(!any)output+=rtf_text("输入问题，查询已同步的任务、账单和便签。");
        output+='}';
        std::string_view stream(output);
        EDITSTREAM source{reinterpret_cast<DWORD_PTR>(&stream),0,stream_rtf};
        SendMessageW(ai_display,EM_SETREADONLY,FALSE,0);
        SendMessageW(ai_display,EM_STREAMIN,SF_RTF,reinterpret_cast<LPARAM>(&source));
        SendMessageW(ai_display,EM_SETREADONLY,TRUE,0);
        SendMessageW(ai_display,EM_SETSEL,static_cast<WPARAM>(-1),static_cast<LPARAM>(-1));
        SendMessageW(ai_display,EM_SCROLLCARET,0,0);
        next_ai=queue?now_ms()+3000:0;
    }
    void timer() {
        if(work!=Work::none) {
            if(operation.wait_for(std::chrono::milliseconds(0))!=std::future_status::ready)return;
            auto result=operation.get();
            const auto completed=work;work=Work::none;
            if(!result.error.empty()) {
                label_status(wide(result.error));
                if(completed==Work::start)SetWindowTextW(qr_code,L"获取失败，请刷新");
                if(completed==Work::sync){workspace=store.read(account.scope());refresh();next_sync=now_ms()+45000;}
                if(completed==Work::poll)next_poll=now_ms()+2000;
                if(completed==Work::logout)start_login();
                return;
            }
            if(completed==Work::start&&result.grant) {
                grant=std::move(result.grant);
                qr=qrcodegen::QrCode::encodeText(grant->qr.c_str(),qrcodegen::QrCode::Ecc::MEDIUM);
                SetWindowTextW(qr_code,wide("核对码  "+grant->code).c_str());
                label_status(L"");next_poll=now_ms()+1400;InvalidateRect(hwnd,nullptr,TRUE);
            } else if (completed==Work::poll) {
                next_poll=now_ms()+2000;
                if(result.login) {
                    account=std::move(result.login->first);team=account.personal;
                    workspace=store.change(account.scope(),[&](Workspace& current){current.spaces=result.login->second;});
                    store.setting("account",account.encode().dump());
                    grant.reset();qr.reset();refresh();next_sync=now_ms();
                }
            } else if(completed==Work::sync) {
                workspace=store.read(account.scope());refresh();next_sync=now_ms()+45000;
                label_status(result.count?L"同步完成 · "+std::to_wstring(result.count)+L" 项":L"同步完成");
                if(page==Page::ai&&thread.empty())load_ai(true);
            } else if(completed==Work::ai_history) {
                conversations=field(result.json,"data");
                rebuilding=true;SendMessageW(ai_history,CB_RESETCONTENT,0,0);
                if(conversations.is_array()&&!conversations.empty()) {
                    for(const auto& item:conversations)add_choice(ai_history,wide(text(item,"question","对话")));
                    SendMessageW(ai_history,CB_SETCURSEL,0,0);
                    thread=text(conversations.front(),"thread");load_ai(false);
                }else{thread.clear();ai_turns=Json::array();ai_text();}
                rebuilding=false;
            } else if(completed==Work::ai_send) {
                SetWindowTextW(ai_input,L"");image.reset();load_ai(false);
            } else if(completed==Work::ai_read) {
                ai_turns=field(result.json,"data");ai_text();label_status(L"");
            } else if(completed==Work::logout) start_login();
            return;
        }
        if(!account.signed_in()){login_tick();return;}
        if(page==Page::ai&&next_ai>0&&now_ms()>=next_ai){next_ai=0;load_ai(false);return;}
        if(next_sync>0&&now_ms()>=next_sync)begin_sync();
    }

    std::optional<Row::Key> selection() const {
        if(page==Page::notes&&!note_section.empty()&&!recycling) {
            auto selected=TreeView_GetSelection(tree);
            TVITEMW item{};item.mask=TVIF_PARAM;item.hItem=selected;
            if(selected&&TreeView_GetItem(tree,&item)&&item.lParam>=0)
                return tree_rows.at(static_cast<std::size_t>(item.lParam));
            return {};
        }
        const auto position=ListView_GetNextItem(main_list,-1,LVNI_SELECTED);
        return position<0?std::nullopt:display.at(static_cast<std::size_t>(position)).key;
    }
    void read_local() {workspace=store.read(account.scope());refresh();}
    void edit_selected(bool create=false) {
        if(!account.signed_in())return;
        const auto selected=selection();
        if(!create&&!selected)return;
        if(recycling) {
            const auto key=*selected;
            store.change(account.scope(),[&](Workspace& state){
                const auto& row=state.rows.at(key);
                state.save(row.team,account.user,row.table,row.uid,Json::object(),true);
            });
            read_local();next_sync=now_ms()+750;return;
        }
        const int table=page==Page::bills?bill:page==Page::notes?note:task;
        if(edit_record(hwnd,store,account,team,table,create?"":std::get<2>(*selected),note_section)) {
            read_local();next_sync=now_ms()+750;
        }
    }
    void record_action(int id) {
        const auto selected=selection();
        if(!selected)return;
        const auto row=workspace.rows.at(*selected);
        if(id==history_id){show_history(hwnd,store,account,row);read_local();next_sync=now_ms()+750;return;}
        if(id==delete_id&&MessageBoxW(hwnd,L"要删除选中的记录吗？",L"删除",MB_YESNO|MB_ICONQUESTION)!=IDYES)return;
        const auto index=ListView_GetNextItem(main_list,-1,LVNI_SELECTED);
        const auto occurrence=(index>=0&&static_cast<std::size_t>(index)<display.size())?display[static_cast<std::size_t>(index)].occurrence:Id{0};
        store.change(account.scope(),[&](Workspace& state){
            if(id==delete_id)delete_record(state,account,row);
            else if(row.table==task)toggle_task(state,account,row,occurrence);
        });
        read_local();next_sync=now_ms()+750;
    }
    void change_account() {
        if(work!=Work::none){label_status(L"请等待当前操作完成");return;}
        if(MessageBoxW(hwnd,L"退出此桌面的登录吗？",L"账户",MB_YESNO|MB_ICONQUESTION)!=IDYES)return;
        const auto previous=account;
        store.setting("account",std::nullopt);
        account={};team=-1;next_sync=next_ai=0;page=Page::tasks;thread.clear();recycling=false;
        read_local();
        launch(Work::logout,[previous]{api(previous.server,previous,"/user/session","DELETE");return Result{};});
    }
    void save_backup() {
        wchar_t path[MAX_PATH]=L"gxtodo-backup.json";
        OPENFILENAMEW props{sizeof(props)};
        props.hwndOwner=hwnd;props.lpstrFile=path;props.nMaxFile=MAX_PATH;props.lpstrFilter=L"JSON 文件\0*.json\0\0";
        props.lpstrDefExt=L"json";props.Flags=OFN_OVERWRITEPROMPT|OFN_NOCHANGEDIR;
        if(!GetSaveFileNameW(&props))return;
        Json items=Json::array(), media=Json::object();
        for(const auto& [key,row]:workspace.rows)if(row.team==account.personal&&(!row.removed||row.table==task||row.table==bill)) {
            Json item={{"table",row.table},{"data",row.data}};
            if(row.removed)item["deleted"]=true;
            items.push_back(std::move(item));
        }
        for(const auto& pair:workspace.media.items())if(number(pair.value(),"team_id")==account.personal)media[pair.key()]=pair.value();
        std::ofstream output(fs::path(path),std::ios::binary);
        output<<Json{{"format","gxtodo-personal-v1"},{"items",items},{"media",media}}.dump(2);
        if(!output)throw std::runtime_error("备份写入失败");
        label_status(L"个人空间 JSON 备份已保存");
    }

    void command(int id,int notify) {
        if(rebuilding)return;
        if(id>=nav_first&&id<nav_first+5) {
            if(!account.signed_in())return;
            page=static_cast<Page>(id-nav_first);recycling=false;party_filter.reset();query.clear();
            rebuilding=true;SetWindowTextW(search,L"");rebuilding=false;
            refresh();
            if(page==Page::ai)load_ai(true);
        } else if(id==search_id&&notify==EN_CHANGE){query=utf8(contents(search));refresh();}
        else if(id==sync_id)begin_sync();
        else if(id==refresh_qr_id)start_login();
        else if(id==server_id&&work==Work::none) {
            if(const auto result=prompt(hwnd,L"服务端",L"服务端 HTTPS 地址",wide(origin))) {
                origin=validate_server(utf8(*result));store.setting("server",origin);start_login();
            }
        } else if(id==space_id&&notify==CBN_SELCHANGE&&choice(space_picker)>=0) {
            team=spaces.at(static_cast<std::size_t>(choice(space_picker)));party_filter.reset();refresh();
        } else if(id==filter_id&&notify==CBN_SELCHANGE) {task_filter=choice(filter);refresh();}
        else if(id==period_id&&notify==CBN_SELCHANGE&&choice(month)>=0) {selected_month=months.at(static_cast<std::size_t>(choice(month)));party_filter.reset();refresh();}
        else if(id==note_section_id&&notify==CBN_SELCHANGE) {note_section=choice(section)==1?"essence":choice(section)==2?"core":"";refresh();}
        else if(id==new_id_button)edit_selected(true);
        else if(id==edit_id)edit_selected();
        else if(id==complete_id||id==history_id||id==delete_id)record_action(id);
        else if(id==account_id)change_account();
        else if(id==recycle_id){recycling=!recycling;refresh();}
        else if(id==backup_id)save_backup();
        else if(id==ai_history_id&&notify==CBN_SELCHANGE&&choice(ai_history)>=0) {
            thread=text(conversations.at(static_cast<std::size_t>(choice(ai_history))),"thread");load_ai(false);
        } else if(id==ai_new_id&&work==Work::none){thread="chat-"+random_hex(16);ai_turns=Json::array();next_ai=0;ai_text();}
        else if(id==ai_send_id)send_ai();
        else if(id==ai_attach_id) {
            image=choose_file(hwnd,L"图片\0*.png;*.jpg;*.jpeg;*.gif;*.webp\0\0");
            if(image)label_status(std::wstring(L"已附图片 · ")+image->filename().wstring());
        }
    }
    LRESULT notify(const NMHDR& event) {
        if(event.code==LVN_GETDISPINFOW) {
            auto& value=reinterpret_cast<NMLVDISPINFOW&>(const_cast<NMHDR&>(event)).item;
            if(!(value.mask&LVIF_TEXT)||!value.pszText||value.cchTextMax<=0)return 0;
            const auto row=static_cast<std::size_t>(value.iItem), column=static_cast<std::size_t>(value.iSubItem);
            std::wstring label;
            if(event.idFrom==record_id&&row<display.size()&&column<display[row].values.size())label=display[row].values[column];
            if(event.idFrom==totals_id&&row<parties.size()) {
                const auto& party=parties[row];
                if(column==0)label=wide(party.party);
                if(column==1)label=wide(bill_amount(party.expense,party.code));
                if(column==2)label=wide(bill_amount(party.income,party.code));
            }
            wcsncpy_s(value.pszText,static_cast<std::size_t>(value.cchTextMax),label.c_str(),_TRUNCATE);
            return 0;
        }
        if(event.code==NM_DBLCLK&&(event.idFrom==record_id||event.idFrom==note_tree_id)){edit_selected();return 0;}
        if(event.code==NM_CLICK&&event.idFrom==totals_id) {
            const auto& selected=reinterpret_cast<const NMITEMACTIVATE&>(event);
            if(selected.iItem<0||selected.iSubItem<=0||selected.iSubItem>2)return 0;
            const auto& party=parties.at(static_cast<std::size_t>(selected.iItem));
            const std::string type=selected.iSubItem==1?"expense":"income";
            if(party_filter&&party_filter->type==type&&party_filter->party==party.party&&party_filter->code==party.code)party_filter.reset();
            else party_filter=PartyFilter{party.code,party.party,type};
            refresh();return 0;
        }
        if(event.code==MCN_SELCHANGE&&event.idFrom==date_id&&page==Page::timeline) {
            const auto& chosen=reinterpret_cast<const NMSELCHANGE&>(event).stSelStart;
            char value[16]{};
            std::snprintf(value,sizeof(value),"%04u-%02u-%02u",unsigned(chosen.wYear),unsigned(chosen.wMonth),unsigned(chosen.wDay));
            selected_date=value;refresh();
        }
        return 0;
    }
    void paint() {
        PAINTSTRUCT state{};
        const auto dc=BeginPaint(hwnd,&state);
        RECT bounds{};GetClientRect(hwnd,&bounds);
        const auto dpi=GetDpiForWindow(hwnd);
        const int rail_width=MulDiv(left,dpi,96), client_height=MulDiv(bounds.bottom,96,dpi);
        RECT side{0,0,rail_width,bounds.bottom};
        FillRect(dc,&side,sidebar_brush);
        if(!account.signed_in()&&qr) {
            const auto scale=std::max(1,MulDiv(248,dpi,96)/(qr->getSize()+8));
            const auto size=(qr->getSize()+8)*scale;
            const auto x=(bounds.right+rail_width-size)/2,y=static_cast<LONG>(MulDiv(std::max(20,client_height/2-195)+29,dpi,96));
            RECT paper{x,y,x+size,y+size};
            FillRect(dc,&paper,background);
            const auto black=static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
            for(int j=0;j<qr->getSize();++j)for(int i=0;i<qr->getSize();++i)if(qr->getModule(i,j)) {
                const RECT cell{x+(i+4)*scale,y+(j+4)*scale,x+(i+5)*scale,y+(j+5)*scale};
                FillRect(dc,&cell,black);
            }
        }
        EndPaint(hwnd,&state);
    }
    LRESULT message(UINT msg,WPARAM w,LPARAM l) {
        switch(msg) {
        case WM_CREATE: build();return 0;
        case WM_SIZE: if(header)layout();return 0;
        case WM_DPICHANGED: {
            const auto& suggested=*reinterpret_cast<const RECT*>(l);
            SetWindowPos(hwnd,nullptr,suggested.left,suggested.top,suggested.right-suggested.left,
                suggested.bottom-suggested.top,SWP_NOZORDER|SWP_NOACTIVATE);
            layout();InvalidateRect(hwnd,nullptr,TRUE);return 0;
        }
        case WM_GETMINMAXINFO: {
            auto* limits=reinterpret_cast<MINMAXINFO*>(l);
            const auto dpi=GetDpiForWindow(hwnd);
            limits->ptMinTrackSize={MulDiv(900,dpi,96),MulDiv(590,dpi,96)};return 0;
        }
        case WM_COMMAND: command(LOWORD(w),HIWORD(w));return 0;
        case WM_NOTIFY: return notify(*reinterpret_cast<const NMHDR*>(l));
        case WM_TIMER: timer();return 0;
        case WM_PAINT: paint();return 0;
        case WM_CTLCOLORSTATIC: {
            const auto dc=reinterpret_cast<HDC>(w);const auto control=reinterpret_cast<HWND>(l);
            SetTextColor(dc,control==status||control==context?muted:ink);
            SetBkMode(dc,TRANSPARENT);
            return reinterpret_cast<LRESULT>(control==rail_title?sidebar_brush:background);
        }
        case WM_DRAWITEM: {
            const auto& item=*reinterpret_cast<const DRAWITEMSTRUCT*>(l);
            if(item.CtlID>=nav_first&&item.CtlID<nav_first+5) {
                const bool selected=!recycling&&item.CtlID==nav_first+static_cast<UINT>(page);
                auto brush=CreateSolidBrush(selected?soft_blue:rail);
                FillRect(item.hDC,&item.rcItem,brush);DeleteObject(brush);
                SetBkMode(item.hDC,TRANSPARENT);SetTextColor(item.hDC,selected?blue:ink);
                SelectObject(item.hDC,ui_font);
                auto rect=item.rcItem;rect.left+=16;
                const auto label=contents(item.hwndItem);
                DrawTextW(item.hDC,label.c_str(),-1,&rect,DT_LEFT|DT_VCENTER|DT_SINGLELINE);
                if (item.itemState&ODS_FOCUS)DrawFocusRect(item.hDC,&rect);
                return TRUE;
            }
            break;
        }
        case WM_DESTROY:KillTimer(hwnd,1);PostQuitMessage(0);return 0;
        default: break;
        }
        return DefWindowProcW(hwnd,msg,w,l);
    }
};
}
}

int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int show) {
    using namespace todo;
    using namespace todo::ui;
    try {
        INITCOMMONCONTROLSEX info{sizeof(info),ICC_LISTVIEW_CLASSES|ICC_TREEVIEW_CLASSES|ICC_DATE_CLASSES|ICC_STANDARD_CLASSES};
        InitCommonControlsEx(&info);
        int argc=0;
        auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);
        fs::path root;
        if(argc==3&&std::wstring_view(argv[1])==L"--workspace")root=fs::path(argv[2]);
        if(argv)LocalFree(argv);
        if(root.empty())root=profile_path();
        Window window(root);
        WNDCLASSW type{};
        type.hInstance=instance;type.lpfnWndProc=Window::proc;type.lpszClassName=L"GxTodoNative";
        type.hCursor=LoadCursorW(nullptr,IDC_ARROW);
        type.hbrBackground=background;
        type.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(101));
        if(!RegisterClassW(&type))return 1;
        const auto hwnd=CreateWindowExW(0,type.lpszClassName,L"高效 Todo",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,
            CW_USEDEFAULT,CW_USEDEFAULT,1100,740,nullptr,nullptr,instance,&window);
        if(!hwnd)return 1;
        ShowWindow(hwnd,show);
        MSG message{};
        while(GetMessageW(&message,nullptr,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
        if(ui_font)DeleteObject(ui_font);
        if(title_font)DeleteObject(title_font);
        DeleteObject(sidebar_brush);
        return static_cast<int>(message.wParam);
    } catch(const std::exception& error){show_error(nullptr,error);return 1;}
}
