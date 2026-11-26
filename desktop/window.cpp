#include "ui.hpp"
#include "qrcodegen.hpp"
#include <dwmapi.h>
#include <commdlg.h>
#include <richedit.h>
#include <shellapi.h>
#include <uxtheme.h>
#include <windowsx.h>
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
using namespace theme;
const HBRUSH background=CreateSolidBrush(canvas);
const HBRUSH sidebar_brush=CreateSolidBrush(rail);
const HBRUSH paper_brush=static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH));
constexpr const wchar_t* page_titles[]{L"任务",L"时间轴",L"AI 对话",L"记账",L"便签"};
constexpr const wchar_t* page_icons[]{L"\uE73A",L"\uE787",L"\uE8BD",L"\uE8C7",L"\uE70B"};

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
    std::string ai_thread;
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
        catch(const std::exception& error) {self->rebuilding=false;show_error(window,error);return message==WM_CREATE?-1:0;}
    }
    bool shortcut(const MSG& message) {
        if(message.message!=WM_KEYDOWN)return false;
        const auto focus=GetFocus();
        if(!account.signed_in()||(focus!=hwnd&&!IsChild(hwnd,focus)))return false;
        const auto key=message.wParam;
        const bool ctrl=(GetKeyState(VK_CONTROL)&0x8000)!=0;
        if(ctrl&&key=='N'){SendMessageW(hwnd,WM_COMMAND,page==Page::ai&&!recycling?ai_new_id:new_id_button,0);return true;}
        if(ctrl&&key=='F'&&IsWindowVisible(search)){SetFocus(search);SendMessageW(search,EM_SETSEL,0,-1);return true;}
        if(ctrl&&key==VK_RETURN&&focus==ai_input){SendMessageW(hwnd,WM_COMMAND,ai_send_id,0);return true;}
        if(key==VK_F5){SendMessageW(hwnd,WM_COMMAND,sync_id,0);return true;}
        if(key==VK_ESCAPE&&focus==search&&!query.empty()){SetWindowTextW(search,L"");return true;}
        if(focus==main_list||focus==tree) {
            if(key==VK_RETURN){SendMessageW(hwnd,WM_COMMAND,edit_id,0);return true;}
            if(key==VK_SPACE&&!recycling&&(page==Page::tasks||page==Page::timeline)){SendMessageW(hwnd,WM_COMMAND,complete_id,0);return true;}
            if(key==VK_DELETE&&!recycling){SendMessageW(hwnd,WM_COMMAND,delete_id,0);return true;}
        }
        return false;
    }
private:
    HWND hwnd{},rail_title{},header{},context{},status{},search{},space_picker{},main_list{},totals_list{},calendar{},
        tree{},month{},section{},filter{},qr_hint{},qr_code{},qr_refresh{},server_button{},sync_button{},add_button{},
        edit_button{},done_button{},delete_button{},history_button{},account_button{},recycle_button{},backup_button{},
        ai_display{},ai_input{},ai_history{},ai_new{},ai_send{},ai_attach{},empty{},rail_space{},
        details_heading{},details_title{},details_meta{},details_body{},qr_title{};
    HWND navigation[5]{};
    HFONT icons{},detail_font{};
    HIMAGELIST list_height{},totals_height{};
    RECT workspace_panel{},detail_panel{},signin_panel{};
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
    bool recycling=false, rebuilding=false, show_details=false, detail_has_text=false;
    int column_set=-1;
    std::vector<Display> display;
    std::vector<PartyRow> parties;
    std::optional<PartyFilter> party_filter;
    std::vector<Id> spaces;
    std::vector<std::string> months;
    std::vector<Row::Key> tree_rows;
    std::vector<HTREEITEM> tree_items;
    std::optional<Grant> grant;
    std::optional<qrcodegen::QrCode> qr;
    std::future<Result> operation;
    Work work=Work::none;
    Id next_poll=0, next_sync=0, next_ai=0;
    std::string thread;
    std::optional<bool> pending_ai;
    std::optional<fs::path> image;
    Json conversations=Json::array();
    Json ai_turns=Json::array();
    static constexpr int left=206;

    void label_status(std::wstring value) {SetWindowTextW(status,value.c_str());}
    void show(HWND control,bool visible) {ShowWindow(control,visible?SW_SHOWNA:SW_HIDE);}
    HWND button(const wchar_t* text,int id) {return control(hwnd,L"BUTTON",text,WS_TABSTOP|BS_OWNERDRAW,id);}
    HWND label(const wchar_t* text=L"",DWORD style=SS_LEFT) {return control(hwnd,L"STATIC",text,style);}
    HWND combo(int id) {return control(hwnd,WC_COMBOBOXW,L"",WS_TABSTOP|WS_VSCROLL|CBS_DROPDOWNLIST,id);}
    void setup_list(HWND window) {
        ListView_SetExtendedListViewStyle(window,LVS_EX_FULLROWSELECT|LVS_EX_DOUBLEBUFFER|LVS_EX_LABELTIP);
        SetWindowTheme(window,L"Explorer",nullptr);
        ListView_SetBkColor(window,white);
        ListView_SetTextBkColor(window,white);
        ListView_SetTextColor(window,ink);
    }
    void fonts() {
        const auto font=[&](int size,int weight,const wchar_t* face=L"Segoe UI") {
            return CreateFontW(-pixels(hwnd,size),0,0,0,weight,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,face);
        };
        const auto old_ui=ui_font,old_title=title_font,old_label=label_font,old_icons=icons,old_detail=detail_font;
        ui_font=font(14,FW_NORMAL);title_font=font(32,FW_SEMIBOLD);label_font=font(14,FW_SEMIBOLD);
        icons=font(16,FW_NORMAL,L"Segoe MDL2 Assets");detail_font=font(20,FW_SEMIBOLD);
        for(auto child=GetWindow(hwnd,GW_CHILD);child;child=GetWindow(child,GW_HWNDNEXT)) {
            auto selected=ui_font;
            if(child==header||child==qr_title)selected=title_font;
            else if(child==details_title||child==rail_title)selected=detail_font;
            else if(child==context||child==details_heading||child==rail_space)selected=label_font;
            SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(selected),FALSE);
        }
        if(main_list) {
            const auto row=ImageList_Create(1,pixels(hwnd,38),ILC_COLOR32,1,1);
            const auto total=ImageList_Create(1,pixels(hwnd,33),ILC_COLOR32,1,1);
            ListView_SetImageList(main_list,row,LVSIL_SMALL);
            ListView_SetImageList(totals_list,total,LVSIL_SMALL);
            if(list_height)ImageList_Destroy(list_height);
            if(totals_height)ImageList_Destroy(totals_height);
            list_height=row;totals_height=total;
            TreeView_SetItemHeight(tree,pixels(hwnd,35));
        }
        for(auto previous:{old_ui,old_title,old_label,old_icons,old_detail})if(previous)DeleteObject(previous);
    }
    void build() {
        rail_title=label(L"高效 Todo",SS_LEFT|SS_CENTERIMAGE);
        rail_space=label(L"空间");
        header=label();
        context=label(L"",SS_LEFT|SS_CENTERIMAGE|SS_ENDELLIPSIS);
        status=label(L"",SS_LEFT|SS_CENTERIMAGE|SS_ENDELLIPSIS);
        for (int i=0;i<5;++i) navigation[i]=button(page_titles[i],nav_first+i);
        sync_button=button(L"立即同步",sync_id); add_button=button(L"＋ 新建任务",new_id_button);
        edit_button=button(L"编辑",edit_id); done_button=button(L"完成／恢复",complete_id);
        history_button=button(L"历史版本",history_id); delete_button=button(L"移到回收站",delete_id);
        account_button=button(L"账户与服务端",account_id); recycle_button=button(L"回收站",recycle_id); backup_button=button(L"导出个人数据",backup_id);
        search=control(hwnd,L"EDIT",L"",WS_TABSTOP|ES_AUTOHSCROLL,search_id,WS_EX_CLIENTEDGE);
        SendMessageW(search,EM_SETMARGINS,EC_LEFTMARGIN|EC_RIGHTMARGIN,MAKELPARAM(pixels(hwnd,8),pixels(hwnd,8)));
        space_picker=combo(space_id); filter=combo(filter_id); month=combo(period_id); section=combo(note_section_id);
        for(const auto* label : {L"全部",L"未完成",L"已完成"})add_choice(filter,label);
        SendMessageW(filter,CB_SETCURSEL,0,0);
        for(const auto* label : {L"速记",L"精髓",L"内核"})add_choice(section,label);
        SendMessageW(section,CB_SETCURSEL,0,0);
        main_list=control(hwnd,WC_LISTVIEWW,L"",WS_TABSTOP|LVS_REPORT|LVS_OWNERDATA|LVS_SINGLESEL|LVS_SHOWSELALWAYS|LVS_SHAREIMAGELISTS,record_id);
        totals_list=control(hwnd,WC_LISTVIEWW,L"",WS_TABSTOP|LVS_REPORT|LVS_OWNERDATA|LVS_SINGLESEL|LVS_SHOWSELALWAYS|LVS_SHAREIMAGELISTS,totals_id);
        setup_list(main_list);setup_list(totals_list);
        calendar=control(hwnd,MONTHCAL_CLASSW,L"",WS_TABSTOP, date_id);
        tree=control(hwnd,WC_TREEVIEWW,L"",WS_TABSTOP|TVS_HASBUTTONS|TVS_LINESATROOT|TVS_SHOWSELALWAYS,note_tree_id);
        SetWindowTheme(tree,L"Explorer",nullptr);
        empty=label(L"",SS_CENTER|SS_CENTERIMAGE|SS_NOPREFIX);
        details_heading=label(L"详情",SS_NOPREFIX);
        details_title=label(L"",SS_NOPREFIX|SS_WORDELLIPSIS);
        details_meta=label(L"",SS_NOPREFIX);
        details_body=control(hwnd,L"EDIT",L"",WS_TABSTOP|ES_MULTILINE|ES_READONLY|ES_AUTOVSCROLL|WS_VSCROLL);
        qr_title=label(L"扫码登录",SS_CENTER);
        qr_hint=label(L"在手机端打开「账户与服务端」→「扫码登录桌面端」",SS_CENTER);
        qr_code=label(L"",SS_CENTER|SS_CENTERIMAGE);
        qr_refresh=button(L"刷新二维码",refresh_qr_id); server_button=button(L"设置服务端",server_id);
        LoadLibraryW(L"Msftedit.dll");
        ai_display=control(hwnd,L"RICHEDIT50W",L"",WS_TABSTOP|WS_VSCROLL|ES_MULTILINE|ES_READONLY|ES_AUTOVSCROLL);
        SendMessageW(ai_display,EM_SETBKGNDCOLOR,0,white);
        ai_input=control(hwnd,L"EDIT",L"",WS_TABSTOP|WS_VSCROLL|ES_MULTILINE|ES_AUTOVSCROLL|ES_WANTRETURN,0,WS_EX_CLIENTEDGE);
        SendMessageW(ai_input,EM_SETLIMITTEXT,5000,0);
        ai_history=combo(ai_history_id); ai_new=button(L"新对话",ai_new_id);
        ai_send=button(L"发送",ai_send_id); ai_attach=button(L"添加图片",ai_attach_id);
        SendMessageW(ai_display,EM_SETMARGINS,EC_LEFTMARGIN|EC_RIGHTMARGIN,MAKELPARAM(pixels(hwnd,14),pixels(hwnd,14)));
        SendMessageW(ai_input,EM_SETMARGINS,EC_LEFTMARGIN|EC_RIGHTMARGIN,MAKELPARAM(pixels(hwnd,10),pixels(hwnd,10)));
        fonts();
        SetTimer(hwnd,1,200,nullptr);
        refresh();
        if(account.signed_in())next_sync=now_ms()+300;
        else start_login();
    }

    void columns(HWND window,std::initializer_list<const wchar_t*> spec) {
        while(ListView_DeleteColumn(window,0)) {}
        int index=0;
        for(const auto* name:spec) {
            LVCOLUMNW column{LVCF_TEXT|LVCF_WIDTH|LVCF_FMT};
            column.pszText=const_cast<wchar_t*>(name);
            column.cx=pixels(hwnd,100); column.fmt=LVCFMT_LEFT;
            ListView_InsertColumn(window,index++,&column);
        }
    }
    void configure_columns() {
        const auto next=recycling?5:static_cast<int>(page);
        if(column_set==next)return;
        column_set=next;
        if(recycling)columns(main_list,{L"类型",L"已删除记录"});
        else switch(page) {
        case Page::tasks:case Page::timeline:columns(main_list,{L"",L"任务",L"计划",L"优先级"});break;
        case Page::bills:
            columns(main_list,{L"日期",L"类型",L"金额",L"途径",L"支出收入方",L"事项"});
            columns(totals_list,{L"支出收入方",L"支出汇总",L"收入汇总"});
            break;
        case Page::notes:columns(main_list,{L"标题",L"创建时间"});break;
        case Page::ai:break;
        }
    }
    void fit_columns(HWND list,std::initializer_list<int> widths) {
        const int count=Header_GetItemCount(ListView_GetHeader(list));
        if(count!=static_cast<int>(widths.size()))return;
        RECT bounds{};GetClientRect(list,&bounds);
        const int available=std::max(0,static_cast<int>(bounds.right)-pixels(hwnd,18));
        int fixed=0;
        for(const auto width:widths)if(width>0)fixed+=pixels(hwnd,width);
        int i=0;
        for(const auto width:widths) {
            const auto wanted=width>0?pixels(hwnd,width):std::max(pixels(hwnd,-width),available-fixed);
            if(ListView_GetColumnWidth(list,i)!=wanted)ListView_SetColumnWidth(list,i,wanted);
            ++i;
        }
    }

    void refresh_choices() {
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
        struct Occurrence {const TaskView* view;Id time;const Row* done;};
        const auto list=tasks(workspace,team);
        std::vector<Occurrence> visible;
        int complete_count=0,open_count=0;
        for(const auto& item:list) {
            if(!match(*item.row))continue;
            const auto when=page==Page::timeline?item.occurrence(selected_date):item.next(today());
            if(page==Page::timeline&&!when)continue;
            const auto complete=item.completed(account.user,when);
            if(complete)++complete_count;else ++open_count;
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
        const auto summary=(page==Page::timeline?wide(selected_date)+L"   ·   ":L"")+
            std::to_wstring(open_count)+L" 待完成     "+std::to_wstring(complete_count)+L" 已完成";
        SetWindowTextW(context,summary.c_str());
    }
    void build_bills() {
        const auto all=workspace.list(team,bill);
        std::set<std::string,std::greater<>> known{today().substr(0,7)};
        for(const auto* row:all)if(text(row->data,"date").size()>=7)
            known.insert(text(row->data,"date").substr(0,7));
        if(!known.contains(selected_month))selected_month=today().substr(0,7);
        SendMessageW(month,CB_RESETCONTENT,0,0);
        months.assign(known.begin(),known.end());
        for(std::size_t i=0;i<months.size();++i) {
            add_choice(month,wide(months[i]+(months[i]==today().substr(0,7)?" · 本月":" · 已归档")));
            if(months[i]==selected_month)SendMessageW(month,CB_SETCURSEL,i,0);
        }
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
        TreeView_DeleteAllItems(tree);
        tree_rows.clear();
        tree_items.clear();
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
            tree_items.push_back(tree_entry(groups.at(group),wide((date.size()>=10?date.substr(0,10)+" ":"")+note_title(*row)),
                static_cast<LPARAM>(tree_rows.size())));
            tree_rows.push_back(row->key());
            if(expand){TreeView_Expand(tree,years.at(year),TVE_EXPAND);TreeView_Expand(tree,groups.at(group),TVE_EXPAND);expand=false;}
        }
        SetWindowTextW(context,(std::to_wstring(display.size()+tree_rows.size())+L" 条便签").c_str());
    }
    void select_tree(LPARAM index) {
        const auto item=tree_items.at(static_cast<std::size_t>(index));
        TreeView_SelectItem(tree,item);
        TreeView_EnsureVisible(tree,item);
    }
    void refresh(bool keep_selection=true) {
        const auto selected=keep_selection?selection():std::nullopt;
        const auto selected_index=ListView_GetNextItem(main_list,-1,LVNI_SELECTED);
        const auto selected_time=selected_index>=0&&static_cast<std::size_t>(selected_index)<display.size()
            ?display[static_cast<std::size_t>(selected_index)].occurrence:Id{0};
        rebuilding=true;
        display.clear();
        parties.clear();
        refresh_choices();
        configure_columns();
        SetWindowTextW(header,recycling?L"回收站":page_titles[static_cast<int>(page)]);
        SetWindowTextW(add_button,page==Page::bills?L"＋ 新建账单":page==Page::notes?
            (note_section.empty()?L"＋ 新建速记":L"＋ 新建记事本"):L"＋ 新建任务");
        SendMessageW(search,EM_SETCUEBANNER,TRUE,reinterpret_cast<LPARAM>(recycling?L"搜索已删除记录":
            page==Page::bills?L"搜索账单":page==Page::notes?L"搜索便签标题或内容":L"搜索任务"));
        if(recycling) {
            for(const auto& [key,row]:workspace.rows)if(row.team==team&&row.removed&&(row.table==task||row.table==bill)&&match(row)&&!text(row.data,"name").empty())
                display.push_back({{row.table==bill?L"账单":L"任务",wide(text(row.data,"name"))},key});
            SetWindowTextW(context,(std::to_wstring(display.size())+L" 条已删除记录").c_str());
        } else switch(page) {
            case Page::tasks:case Page::timeline:build_tasks();break;
            case Page::bills:build_bills();break;
            case Page::notes:build_notes();break;
            case Page::ai:SetWindowTextW(context,L"");break;
        }
        ListView_SetItemCountEx(main_list,static_cast<int>(display.size()),LVSICF_NOINVALIDATEALL);
        ListView_SetItemCountEx(totals_list,static_cast<int>(parties.size()),LVSICF_NOINVALIDATEALL);
        ListView_SetItemState(main_list,-1,0,LVIS_SELECTED|LVIS_FOCUSED);
        if(selected) {
            const auto exact=std::ranges::find_if(display,[&](const auto& row){return row.key==selected&&row.occurrence==selected_time;});
            const auto item=exact!=display.end()?exact:std::ranges::find(display,selected,&Display::key);
            if(item!=display.end()) {
                const auto index=static_cast<int>(item-display.begin());
                ListView_SetItemState(main_list,index,LVIS_SELECTED|LVIS_FOCUSED,LVIS_SELECTED|LVIS_FOCUSED);
            } else if(page==Page::notes&&!note_section.empty()) {
                const auto found=std::ranges::find(tree_rows,*selected);
                if(found!=tree_rows.end())select_tree(static_cast<LPARAM>(found-tree_rows.begin()));
            }
        }
        rebuilding=false;
        update_details();
        InvalidateRect(main_list,nullptr,TRUE);InvalidateRect(totals_list,nullptr,TRUE);
        layout();InvalidateRect(hwnd,nullptr,TRUE);
    }

    void layout() {
        RECT rect{};GetClientRect(hwnd,&rect);
        const auto dpi=GetDpiForWindow(hwnd);
        const int width=MulDiv(rect.right,96,dpi),height=MulDiv(rect.bottom,96,dpi),cx=left+24,cw=width-cx-24;
        const auto scaled=[&](int x,int y,int w,int h)->RECT {
            return {pixels(hwnd,x),pixels(hwnd,y),pixels(hwnd,x+w),pixels(hwnd,y+h)};
        };
        const bool signed_in=account.signed_in();
        place(rail_title,64,20,132,37);
        place(rail_space,22,87,160,21);show(rail_space,signed_in);
        place(space_picker,20,113,166,259);show(space_picker,signed_in);
        for(int i=0;i<5;++i){place(navigation[i],14,164+i*44,178,39);show(navigation[i],signed_in);}
        place(account_button,14,height-52,178,36);show(account_button,signed_in);
        place(recycle_button,14,height-172,178,36);show(recycle_button,signed_in);
        place(backup_button,14,height-132,178,36);show(backup_button,signed_in);
        place(sync_button,14,height-92,178,36);show(sync_button,signed_in);
        place(status,cx+10,height-30,cw-20,24);
        show(header,signed_in);place(header,cx+1,23,cw-170,48);
        const bool ai=signed_in&&!recycling&&page==Page::ai;
        const bool ledger=signed_in&&!recycling&&page==Page::bills;
        const bool time=signed_in&&!recycling&&page==Page::timeline;
        const bool notes=signed_in&&!recycling&&page==Page::notes;
        const bool tasks_visible=signed_in&&!recycling&&(page==Page::tasks||page==Page::timeline);
        const bool note_groups=notes&&!note_section.empty();
        show_details=signed_in&&!ai&&width>=(time?1250:1100);
        const int body=show_details?cw-278:cw, x=cx+14, right=cx+body-14;
        workspace_panel=signed_in?scaled(cx,82,body,height-116):RECT{};
        detail_panel=show_details?scaled(cx+body+14,82,264,height-116):RECT{};
        show(add_button,signed_in&&!ai&&!recycling);place(add_button,width-159,27,135,37);
        show(context,signed_in&&!ai);place(context,x+2,127,right-x-4,28);
        show(search,signed_in&&!ai);place(search,x,94,std::min(body-214,360),29);
        show(filter,tasks_visible);place(filter,right-131,94,131,190);
        show(month,ledger);place(month,right-178,94,178,260);
        show(section,notes);place(section,right-146,94,146,190);
        const int actions_y=show_details?253:156;
        const int pane_top=show_details?161:199;
        const int totals_size=ledger&&!parties.empty()?std::min(131,static_cast<int>(parties.size())*33+28):0;
        show(totals_list,totals_size>0);
        place(totals_list,x,pane_top,right-x,totals_size);
        const int top=pane_top+(totals_size?totals_size+14:0);
        RECT cal{};MonthCal_GetMinReqRect(calendar,&cal);
        const int cal_width=MulDiv(cal.right,96,dpi),cal_height=MulDiv(cal.bottom,96,dpi);
        const int list_x=time?x+cal_width+10:x;
        show(calendar,time);place(calendar,x,top,cal_width,cal_height);
        show(main_list,signed_in&&!ai&&!note_groups);
        place(main_list,list_x,top,right-list_x,height-top-46);
        show(tree,note_groups);place(tree,x,top,right-x,height-top-46);
        const int detail_x=cx+body+30;
        show(details_heading,show_details);place(details_heading,detail_x,101,230,20);
        show(details_title,show_details);place(details_title,detail_x,133,232,54);
        show(details_meta,show_details);place(details_meta,detail_x,194,232,53);
        show(details_body,show_details&&detail_has_text);place(details_body,detail_x,341,232,height-386);
        const int action_x=show_details?detail_x:x;
        show(edit_button,signed_in&&!ai);place(edit_button,action_x,actions_y,show_details?112:83,32);
        show(done_button,tasks_visible);place(done_button,action_x+(show_details?120:91),actions_y,show_details?112:89,32);
        const int other_y=actions_y+(show_details?39:0);
        show(history_button,ledger||tasks_visible);
        place(history_button,action_x+(show_details?0:tasks_visible?188:91),other_y,show_details?112:94,32);
        show(delete_button,signed_in&&!ai&&!recycling);
        SetWindowTextW(delete_button,notes?L"删除便签":L"移到回收站");
        place(delete_button,action_x+(show_details?120:tasks_visible?290:ledger?193:91),other_y,112,32);
        show(ai_display,ai);place(ai_display,x,143,right-x,height-288);
        show(ai_input,ai);place(ai_input,x,height-130,right-x-115,81);
        show(ai_history,ai);place(ai_history,x,98,right-x-116,280);
        show(ai_new,ai);place(ai_new,right-105,96,105,33);
        show(ai_send,ai);place(ai_send,right-105,height-84,105,34);
        show(ai_attach,ai);place(ai_attach,right-105,height-130,105,34);
        const int center=(width+left)/2, y=std::max(16,height/2-233);
        signin_panel=!signed_in?scaled(center-234,y,468,466):RECT{};
        show(qr_title,!signed_in);place(qr_title,center-212,y+24,424,46);
        show(qr_hint,!signed_in);place(qr_hint,center-213,y+75,426,25);
        show(qr_code,!signed_in);place(qr_code,center-172,y+351,344,30);
        show(qr_refresh,!signed_in);place(qr_refresh,center-142,y+404,134,36);
        show(server_button,!signed_in);place(server_button,center+8,y+404,134,36);
        const auto empty_list=note_groups?tree_rows.empty():display.empty();
        show(empty,signed_in&&!ai&&empty_list);
        if(empty_list&&signed_in&&!ai) {
            SetWindowTextW(empty,!query.empty()?L"没有找到匹配的记录":recycling?L"回收站为空":
                ledger?(party_filter?L"该统计项没有账单":L"当月没有账单"):
                notes?L"还没有便签":time?L"这一天没有任务":L"没有符合条件的任务");
            place(empty,list_x,top+48,right-list_x,65);
            SetWindowPos(empty,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
        }
        if(recycling)fit_columns(main_list,{95,-155});
        else if(ledger) {
            fit_columns(main_list,{91,58,104,88,110,-112});
            fit_columns(totals_list,{-130,134,134});
        } else if(notes)fit_columns(main_list,{-120,163});
        else if(tasks_visible)fit_columns(main_list,{41,-120,134,93});
        InvalidateRect(hwnd,nullptr,FALSE);
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
        if(work!=Work::none){pending_ai=histories;return;}
        pending_ai.reset();
        const auto current=account;const auto selected=thread;
        launch(histories?Work::ai_history:Work::ai_read,[current,selected,histories] {
            Result result;result.ai_thread=selected;result.json=api(current.server,current,"/ai/chat","GET",
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
        for(auto control:{ai_input,ai_attach,ai_send,ai_new,ai_history})EnableWindow(control,FALSE);
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
            if(completed==Work::ai_send)
                for(auto control:{ai_input,ai_attach,ai_send,ai_new,ai_history})EnableWindow(control,TRUE);
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
            } else if(completed==Work::ai_read&&result.ai_thread==thread) {
                ai_turns=field(result.json,"data");ai_text();label_status(L"");
            } else if(completed==Work::logout) start_login();
            return;
        }
        if(!account.signed_in()){login_tick();return;}
        if(page==Page::ai&&pending_ai){load_ai(*pending_ai);return;}
        if(page==Page::ai&&next_ai>0&&now_ms()>=next_ai){next_ai=0;load_ai(false);return;}
        if(next_sync>0&&now_ms()>=next_sync)begin_sync();
    }

    std::optional<Row::Key> selection() const {
        if(page==Page::notes&&!note_section.empty()&&!recycling) {
            auto selected=TreeView_GetSelection(tree);
            TVITEMW item{};item.mask=TVIF_PARAM;item.hItem=selected;
            if(selected&&TreeView_GetItem(tree,&item)&&item.lParam>=0&&static_cast<std::size_t>(item.lParam)<tree_rows.size())
                return tree_rows[static_cast<std::size_t>(item.lParam)];
            return {};
        }
        const auto position=ListView_GetNextItem(main_list,-1,LVNI_SELECTED);
        return position<0||static_cast<std::size_t>(position)>=display.size()?std::nullopt:display[static_cast<std::size_t>(position)].key;
    }
    void update_details() {
        const auto key=selection();
        const auto found=key?workspace.rows.find(*key):workspace.rows.end();
        const auto row=found!=workspace.rows.end()?&found->second:nullptr;
        for(auto control:{edit_button,delete_button,history_button,done_button})EnableWindow(control,row!=nullptr);
        SetWindowTextW(edit_button,recycling?L"恢复记录":L"打开编辑");
        SetWindowTextW(done_button,L"标记完成");
        std::wstring title,meta,body;
        if(!row)title=L"选择一条记录";
        else if(recycling)title=wide(text(row->data,"name"));
        else if(row->table==task) {
            const auto view=task_view(workspace,*row);
            const auto data=view.snapshot(account.user,account.personal);
            title=wide(text(row->data,"name"));
            const auto index=ListView_GetNextItem(main_list,-1,LVNI_SELECTED);
            const auto when=index>=0&&static_cast<std::size_t>(index)<display.size()?display[static_cast<std::size_t>(index)].occurrence:Id{0};
            const auto done=view.completed(account.user,when)!=nullptr;
            SetWindowTextW(done_button,done?L"恢复待完成":L"标记完成");
            meta=done?L"已完成\r\n":L"待完成\r\n";
            if(index>=0&&static_cast<std::size_t>(index)<display.size())meta+=display[static_cast<std::size_t>(index)].values[2];
            body=wide(text(data,"remark"));
            const auto& children=field(data,"children");
            if(children.is_array()&&!children.empty()) {
                if(!body.empty())body+=L"\n\n";
                body+=L"子任务";
                for(const auto& child:children)if(child.is_string())body+=L"\n· "+wide(child.get<std::string>());
            }
        } else if(row->table==bill) {
            title=wide(text(row->data,"name"));
            meta=bill_type(text(row->data,"type"))+L"  "+money(*row)+L"\r\n"+wide(text(row->data,"date"));
            const auto channel=text(row->data,"channel"),party=text(row->data,"party"),remark=text(row->data,"remark");
            body=wide(channel+(party.empty()?"":" · "+party)+(remark.empty()?"":"\n\n"+remark));
        } else if(row->table==note) {
            title=wide(note_title(*row));
            meta=wide(readable_date(*row));
            for(const auto& entry:note_entries(workspace,*row)) {
                if(body.size()>10000)break;
                if(!body.empty())body+=L"\n\n";
                const auto kind=text(entry.data,"kind");
                body+=kind=="text"?wide(text(entry.data,"content")):kind=="image"?L"[图片]":kind=="audio"?L"[语音]":L"[附件]";
            }
        }
        std::wstring windows_lines;
        for(const auto ch:body) {
            if(ch==L'\n'&&(windows_lines.empty()||windows_lines.back()!=L'\r'))windows_lines+=L'\r';
            windows_lines+=ch;
        }
        SetWindowTextW(details_title,title.c_str());
        SetWindowTextW(details_meta,meta.c_str());
        SetWindowTextW(details_body,windows_lines.c_str());
        detail_has_text=!windows_lines.empty();
        show(details_body,show_details&&detail_has_text);
    }
    void read_local() {workspace=store.read(account.scope());refresh();}
    void edit_selected(bool create=false) {
        if(!account.signed_in())return;
        const auto selected=selection();
        if(!create&&!selected)return;
        if(recycling) {
            if(create||!selected)return;
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
        if(id==delete_id&&MessageBoxW(hwnd,row.table==note?L"要删除这条便签吗？":L"要将这条记录移到回收站吗？",
            row.table==note?L"删除便签":L"移到回收站",MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2)!=IDYES)return;
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
        account={};team=-1;next_sync=next_ai=0;page=Page::tasks;thread.clear();recycling=false;pending_ai.reset();
        label_status(L"");
        read_local();
        launch(Work::logout,[previous]{api(previous.server,previous,"/user/session","DELETE");return Result{};});
    }
    void account_menu() {
        const auto menu=CreatePopupMenu();
        if(!menu)return;
        const auto user=wide(account.nickname.empty()?account.email:account.nickname);
        if(!user.empty())AppendMenuW(menu,MF_STRING|MF_GRAYED,0,user.c_str());
        AppendMenuW(menu,MF_STRING|MF_GRAYED,0,wide(origin).c_str());
        AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        AppendMenuW(menu,MF_STRING,1,L"退出桌面端");
        RECT anchor{};GetWindowRect(account_button,&anchor);
        const auto choice=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_BOTTOMALIGN,anchor.left,anchor.top,0,hwnd,nullptr);
        DestroyMenu(menu);
        if(choice==1)change_account();
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
            refresh(false);
            if(page==Page::ai){
                ai_text();
                if(thread.empty())load_ai(true);
            }
        } else if(id==search_id&&notify==EN_CHANGE){query=utf8(contents(search));refresh();}
        else if(id==sync_id)begin_sync();
        else if(id==refresh_qr_id)start_login();
        else if(id==server_id&&work==Work::none) {
            if(const auto result=prompt(hwnd,L"服务端",L"服务端 HTTPS 地址",wide(origin))) {
                origin=validate_server(utf8(*result));store.setting("server",origin);start_login();
            }
        } else if(id==space_id&&notify==CBN_SELCHANGE&&choice(space_picker)>=0) {
            team=spaces.at(static_cast<std::size_t>(choice(space_picker)));party_filter.reset();refresh(false);
        } else if(id==filter_id&&notify==CBN_SELCHANGE) {task_filter=choice(filter);refresh();}
        else if(id==period_id&&notify==CBN_SELCHANGE&&choice(month)>=0) {selected_month=months.at(static_cast<std::size_t>(choice(month)));party_filter.reset();refresh(false);}
        else if(id==note_section_id&&notify==CBN_SELCHANGE) {note_section=choice(section)==1?"essence":choice(section)==2?"core":"";refresh(false);}
        else if(id==new_id_button)edit_selected(true);
        else if(id==edit_id)edit_selected();
        else if(id==complete_id||id==history_id||id==delete_id)record_action(id);
        else if(id==account_id)account_menu();
        else if(id==recycle_id){
            recycling=!recycling;query.clear();
            rebuilding=true;SetWindowTextW(search,L"");rebuilding=false;
            refresh(false);
        }
        else if(id==backup_id)save_backup();
        else if(id==ai_history_id&&notify==CBN_SELCHANGE&&choice(ai_history)>=0) {
            thread=text(conversations.at(static_cast<std::size_t>(choice(ai_history))),"thread");
            ai_turns=Json::array();ai_text();label_status(L"正在打开对话…");load_ai(false);
        } else if(id==ai_new_id&&work==Work::none){thread="chat-"+random_hex(16);ai_turns=Json::array();next_ai=0;ai_text();}
        else if(id==ai_send_id)send_ai();
        else if(id==ai_attach_id) {
            image=choose_file(hwnd,L"图片\0*.png;*.jpg;*.jpeg;*.gif;*.webp\0\0");
            if(image)label_status(std::wstring(L"已附图片 · ")+image->filename().wstring());
        }
    }
    LRESULT draw_rows(const NMLVCUSTOMDRAW& item) {
        if(item.nmcd.dwDrawStage==CDDS_PREPAINT)return CDRF_NOTIFYITEMDRAW;
        if(item.nmcd.dwDrawStage==CDDS_ITEMPREPAINT)return CDRF_NOTIFYSUBITEMDRAW;
        if(item.nmcd.dwDrawStage!=(CDDS_ITEMPREPAINT|CDDS_SUBITEM))return CDRF_DODEFAULT;
        const auto list=item.nmcd.hdr.hwndFrom;
        const auto index=static_cast<int>(item.nmcd.dwItemSpec);
        const auto i=static_cast<std::size_t>(index);
        const int col=item.iSubItem;
        const bool summary=list==totals_list;
        if(index<0||col<0||(summary?i>=parties.size():i>=display.size()))return CDRF_DODEFAULT;
        RECT bounds{};
        if(col==0) {
            ListView_GetItemRect(list,index,&bounds,LVIR_BOUNDS);
            bounds.right=bounds.left+ListView_GetColumnWidth(list,0);
        } else ListView_GetSubItemRect(list,index,col,LVIR_BOUNDS,&bounds);
        const auto dc=item.nmcd.hdc;
        const bool task_row=!summary&&!recycling&&(page==Page::tasks||page==Page::timeline);
        const bool done=task_row&&display[i].values[0]==L"已完成";
        const bool selected=(ListView_GetItemState(list,index,LVIS_SELECTED)&LVIS_SELECTED)!=0;
        const bool active_stat=summary&&party_filter&&col>0&&parties[i].party==party_filter->party&&
            parties[i].code==party_filter->code&&party_filter->type==(col==1?"expense":"income");
        fill(dc,bounds,active_stat?mint:selected?tint:white);
        fill(dc,{bounds.left,bounds.bottom-1,bounds.right,bounds.bottom},border);
        const auto saved=SaveDC(dc);
        IntersectClipRect(dc,bounds.left,bounds.top,bounds.right,bounds.bottom);
        SetBkMode(dc,TRANSPARENT);
        if(task_row&&col==0) {
            const auto side=pixels(hwnd,17);
            const auto x=bounds.left+pixels(hwnd,12),y=(bounds.top+bounds.bottom-side)/2;
            rounded(dc,{x,y,x+side,y+side},pixels(hwnd,6),done?accent:white,done?accent:RGB(139,160,150));
            if(done) {
                auto check=CreatePen(PS_SOLID,std::max(1,pixels(hwnd,2)),white);
                const auto old=SelectObject(dc,check);
                MoveToEx(dc,x+side*2/9,y+side/2,nullptr);
                LineTo(dc,x+side*4/9,y+side*7/10);
                LineTo(dc,x+side*7/9,y+side*3/10);
                SelectObject(dc,old);DeleteObject(check);
            }
        } else {
            std::wstring value;
            auto color=ink;
            auto font=ui_font;
            if(summary) {
                const auto& party=parties[i];
                value=col==0?wide(party.party):wide(bill_amount(col==1?party.expense:party.income,party.code));
                color=col==1?expense:col==2?income:ink;
                if(col>0)font=label_font;
            } else if(static_cast<std::size_t>(col)<display[i].values.size()) {
                value=display[i].values[static_cast<std::size_t>(col)];
                if(task_row) {
                    color=done||col>=2?muted:ink;
                    if(col==1&&!done)font=label_font;
                    if(col==3&&!done&&value!=L"普通") color=value==L"重要"?accent:expense;
                } else if(!recycling&&page==Page::bills&&col==2) {
                    font=label_font;
                    const auto& type=display[i].values[1];
                    color=type==L"支出"?expense:type==L"收入"?income:muted;
                } else if(!recycling&&page==Page::notes&&col==1)color=muted;
            }
            SelectObject(dc,font);SetTextColor(dc,color);
            InflateRect(&bounds,-pixels(hwnd,8),0);
            DrawTextW(dc,value.c_str(),-1,&bounds,DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX|DT_END_ELLIPSIS);
        }
        RestoreDC(dc,saved);
        return CDRF_SKIPDEFAULT;
    }
    void record_menu(HWND source,POINT point) {
        if(!selection())return;
        const auto menu=CreatePopupMenu();
        if(!menu)return;
        AppendMenuW(menu,MF_STRING,edit_id,recycling?L"恢复记录":L"打开编辑\tEnter");
        if(!recycling) {
            if(page==Page::tasks||page==Page::timeline)
                AppendMenuW(menu,MF_STRING,complete_id,(contents(done_button)+L"\tSpace").c_str());
            if(page!=Page::notes)AppendMenuW(menu,MF_STRING,history_id,L"历史版本");
            AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
            AppendMenuW(menu,MF_STRING,delete_id,page==Page::notes?L"删除便签\tDelete":L"移到回收站\tDelete");
        }
        if(point.x==-1&&point.y==-1) {
            RECT bounds{};GetWindowRect(source,&bounds);
            point={bounds.left+pixels(hwnd,15),bounds.top+pixels(hwnd,32)};
        }
        const auto id=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_RIGHTBUTTON,point.x,point.y,0,hwnd,nullptr);
        DestroyMenu(menu);
        if(id)command(static_cast<int>(id),0);
    }
    LRESULT notify(const NMHDR& event) {
        if(event.code==NM_CUSTOMDRAW&&(event.idFrom==record_id||event.idFrom==totals_id))
            return draw_rows(reinterpret_cast<const NMLVCUSTOMDRAW&>(event));
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
        if(rebuilding)return 0;
        if((event.code==LVN_ITEMCHANGED&&event.idFrom==record_id)||(event.code==TVN_SELCHANGEDW&&event.idFrom==note_tree_id)) {
            update_details();return 0;
        }
        if(event.code==NM_DBLCLK&&event.idFrom==record_id) {
            const auto& selected=reinterpret_cast<const NMITEMACTIVATE&>(event);
            const bool checkbox=!recycling&&(page==Page::tasks||page==Page::timeline)&&selected.iSubItem==0;
            if(selected.iItem>=0&&!checkbox)edit_selected();
            return 0;
        }
        if(event.code==NM_DBLCLK&&event.idFrom==note_tree_id){edit_selected();return 0;}
        if(event.code==NM_CLICK&&event.idFrom==record_id&&!recycling&&(page==Page::tasks||page==Page::timeline)) {
            const auto& selected=reinterpret_cast<const NMITEMACTIVATE&>(event);
            if(selected.iItem>=0&&selected.iSubItem==0&&selected.ptAction.x<pixels(hwnd,41)) {
                ListView_SetItemState(main_list,selected.iItem,LVIS_SELECTED|LVIS_FOCUSED,LVIS_SELECTED|LVIS_FOCUSED);
                record_action(complete_id);
            }
            return 0;
        }
        if(event.code==NM_CLICK&&event.idFrom==totals_id) {
            const auto& selected=reinterpret_cast<const NMITEMACTIVATE&>(event);
            if(selected.iItem<0||static_cast<std::size_t>(selected.iItem)>=parties.size()||selected.iSubItem<=0||selected.iSubItem>2)return 0;
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
            selected_date=value;refresh(false);
        }
        return 0;
    }
    void paint() {
        PAINTSTRUCT state{};
        const auto dc=BeginPaint(hwnd,&state);
        RECT bounds{};GetClientRect(hwnd,&bounds);
        const auto dpi=GetDpiForWindow(hwnd);
        const int rail_width=MulDiv(left,dpi,96);
        RECT side{0,0,rail_width,bounds.bottom};
        FillRect(dc,&side,sidebar_brush);
        const auto r=[&](int x,int y,int w,int h)->RECT{return {pixels(hwnd,x),pixels(hwnd,y),pixels(hwnd,x+w),pixels(hwnd,y+h)};};
        rounded(dc,r(19,21,35,35),pixels(hwnd,12),mint);
        const auto icon_state=SaveDC(dc);
        SelectObject(dc,icons);SetBkMode(dc,TRANSPARENT);SetTextColor(dc,ink);
        auto brand=r(19,21,35,35);
        DrawTextW(dc,L"\uE73E",-1,&brand,DT_CENTER|DT_VCENTER|DT_SINGLELINE);
        RestoreDC(dc,icon_state);
        if(account.signed_in()) {
            fill(dc,r(20,71,166,1),RGB(51,79,68));
            RECT tools{pixels(hwnd,20),bounds.bottom-pixels(hwnd,183),rail_width-pixels(hwnd,20),bounds.bottom-pixels(hwnd,182)};
            fill(dc,tools,RGB(51,79,68));
        }
        for(const auto& panel:{workspace_panel,detail_panel,signin_panel})if(!IsRectEmpty(&panel))
            rounded(dc,panel,pixels(hwnd,18),white,border);
        if(!account.signed_in()&&qr) {
            const auto scale=std::max(1,pixels(hwnd,229)/(qr->getSize()+8));
            const auto size=(qr->getSize()+8)*scale;
            const auto x=(bounds.right+rail_width-size)/2;
            const auto y=signin_panel.top+pixels(hwnd,220)-size/2;
            RECT paper{x,y,x+size,y+size};
            FillRect(dc,&paper,paper_brush);
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
            fonts();
            SetWindowPos(hwnd,nullptr,suggested.left,suggested.top,suggested.right-suggested.left,
                suggested.bottom-suggested.top,SWP_NOZORDER|SWP_NOACTIVATE);
            layout();InvalidateRect(hwnd,nullptr,TRUE);return 0;
        }
        case WM_GETMINMAXINFO: {
            auto* limits=reinterpret_cast<MINMAXINFO*>(l);
            const auto dpi=GetDpiForWindow(hwnd);
            limits->ptMinTrackSize={MulDiv(870,dpi,96),MulDiv(590,dpi,96)};return 0;
        }
        case WM_COMMAND: command(LOWORD(w),HIWORD(w));return 0;
        case WM_NOTIFY: return notify(*reinterpret_cast<const NMHDR*>(l));
        case WM_SETCURSOR: {
            const auto source=reinterpret_cast<HWND>(w);
            const bool tasks=!recycling&&(page==Page::tasks||page==Page::timeline);
            if((source==main_list&&tasks)||source==totals_list) {
                LVHITTESTINFO hit{};
                GetCursorPos(&hit.pt);ScreenToClient(source,&hit.pt);
                if(ListView_SubItemHitTest(source,&hit)>=0&&(source==main_list?hit.iSubItem==0:hit.iSubItem>0)) {
                    SetCursor(LoadCursorW(nullptr,IDC_HAND));return TRUE;
                }
            }
            break;
        }
        case WM_CONTEXTMENU: {
            const auto source=reinterpret_cast<HWND>(w);
            if(source==main_list||source==tree) {
                POINT point{GET_X_LPARAM(l),GET_Y_LPARAM(l)};
                if(point.x!=-1||point.y!=-1) {
                    auto client=point;ScreenToClient(source,&client);
                    if(source==main_list) {
                        LVHITTESTINFO hit{};hit.pt=client;
                        const auto index=ListView_SubItemHitTest(source,&hit);
                        if(index<0)return 0;
                        ListView_SetItemState(source,index,LVIS_SELECTED|LVIS_FOCUSED,LVIS_SELECTED|LVIS_FOCUSED);
                    } else {
                        TVHITTESTINFO hit{};hit.pt=client;
                        if(!TreeView_HitTest(source,&hit))return 0;
                        TreeView_SelectItem(source,hit.hItem);
                    }
                }
                record_menu(source,point);return 0;
            }
            break;
        }
        case WM_TIMER: timer();return 0;
        case WM_PAINT: paint();return 0;
        case WM_CTLCOLORSTATIC: {
            const auto dc=reinterpret_cast<HDC>(w);const auto control=reinterpret_cast<HWND>(l);
            auto brush=paper_brush;auto color=ink;
            if(control==rail_title||control==rail_space){brush=sidebar_brush;color=control==rail_title?rail_ink:rail_muted;}
            else if(control==status||control==header){brush=background;color=control==status?muted:ink;}
            else if(control==details_meta||control==details_heading||control==empty||control==qr_hint)color=muted;
            else if(control==context||control==qr_code)color=accent;
            SetTextColor(dc,color);
            SetBkMode(dc,TRANSPARENT);
            return reinterpret_cast<LRESULT>(brush);
        }
        case WM_DRAWITEM: {
            const auto& item=*reinterpret_cast<const DRAWITEMSTRUCT*>(l);
            if(item.CtlID>=nav_first&&item.CtlID<nav_first+5) {
                const auto index=item.CtlID-nav_first;
                draw_button(item,false,true,!recycling&&index==static_cast<UINT>(page),page_icons[index],icons);
            } else if(item.CtlID==account_id||item.CtlID==backup_id||item.CtlID==recycle_id||item.CtlID==sync_id) {
                const auto icon=item.CtlID==account_id?L"\uE713":item.CtlID==backup_id?L"\uE898":item.CtlID==recycle_id?L"\uE74D":L"\uE895";
                draw_button(item,false,true,recycling&&item.CtlID==recycle_id,icon,icons);
            } else draw_button(item,item.CtlID==new_id_button||item.CtlID==ai_send_id||item.CtlID==refresh_qr_id||item.CtlID==edit_id);
            return TRUE;
        }
        case WM_DESTROY:KillTimer(hwnd,1);PostQuitMessage(0);return 0;
        case WM_NCDESTROY:
            if(list_height)ImageList_Destroy(list_height);
            if(totals_height)ImageList_Destroy(totals_height);
            for(const auto font:{icons,detail_font})if(font)DeleteObject(font);
            break;
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
        RECT work{};
        SystemParametersInfoW(SPI_GETWORKAREA,0,&work,0);
        const auto dpi=GetDpiForSystem();
        const auto width=std::min<LONG>(MulDiv(1280,dpi,96),work.right-work.left);
        const auto height=std::min<LONG>(MulDiv(790,dpi,96),work.bottom-work.top);
        const auto hwnd=CreateWindowExW(0,type.lpszClassName,L"高效 Todo",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,
            CW_USEDEFAULT,CW_USEDEFAULT,width,height,nullptr,nullptr,instance,&window);
        if(!hwnd)return 1;
        ShowWindow(hwnd,show);
        MSG message{};
        while(GetMessageW(&message,nullptr,0,0)>0) {
            if(window.shortcut(message))continue;
            if(message.message==WM_KEYDOWN&&message.wParam==VK_TAB&&IsChild(hwnd,GetFocus())) {
                auto control=GetFocus();
                while(GetParent(control)!=hwnd)control=GetParent(control);
                if(const auto next=GetNextDlgTabItem(hwnd,control,(GetKeyState(VK_SHIFT)&0x8000)!=0))SetFocus(next);
                continue;
            }
            TranslateMessage(&message);DispatchMessageW(&message);
        }
        if(ui_font)DeleteObject(ui_font);
        if(title_font)DeleteObject(title_font);
        if(label_font)DeleteObject(label_font);
        DeleteObject(background);
        DeleteObject(sidebar_brush);
        return static_cast<int>(message.wParam);
    } catch(const std::exception& error){show_error(nullptr,error);return 1;}
}
