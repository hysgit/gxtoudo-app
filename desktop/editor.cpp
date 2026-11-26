#include "ui.hpp"
#include <commdlg.h>
#include <shellapi.h>
#include <algorithm>
#include <cstdio>
#include <fstream>
#include <sstream>

namespace todo::ui {
HFONT ui_font{};
HFONT title_font{};
HFONT label_font{};

int pixels(HWND window,int units) {
    const auto dpi=GetDpiForWindow(window);
    return MulDiv(units,static_cast<int>(dpi?dpi:96),96);
}
void fill(HDC dc,const RECT& bounds,COLORREF color) {
    const auto brush=CreateSolidBrush(color);
    FillRect(dc,&bounds,brush);
    DeleteObject(brush);
}
void rounded(HDC dc,const RECT& bounds,int diameter,COLORREF color,COLORREF outline) {
    const auto brush=CreateSolidBrush(color);
    const auto pen=outline==CLR_INVALID?static_cast<HPEN>(GetStockObject(NULL_PEN)):CreatePen(PS_SOLID,1,outline);
    const auto old_brush=SelectObject(dc,brush),old_pen=SelectObject(dc,pen);
    RoundRect(dc,bounds.left,bounds.top,bounds.right,bounds.bottom,diameter,diameter);
    SelectObject(dc,old_pen);SelectObject(dc,old_brush);
    if(outline!=CLR_INVALID)DeleteObject(pen);
    DeleteObject(brush);
}
void draw_button(const DRAWITEMSTRUCT& item,bool primary,bool on_rail,bool selected,const wchar_t* icon,HFONT icons) {
    using namespace theme;
    const auto saved=SaveDC(item.hDC);
    const auto dpi=GetDpiForWindow(item.hwndItem);
    const auto scale=[&](int n){return MulDiv(n,dpi?dpi:96,96);};
    const bool pressed=(item.itemState&ODS_SELECTED)!=0;
    const bool enabled=(item.itemState&ODS_DISABLED)==0;
    const bool focused=(item.itemState&ODS_FOCUS)!=0;
    const auto surface=on_rail?rail:GetSysColor(COLOR_WINDOW);
    fill(item.hDC,item.rcItem,on_rail?surface:white);
    const auto bg=on_rail?(selected?mint:pressed?RGB(48,81,68):rail):
        primary&&enabled?(pressed?RGB(12,77,55):accent):pressed?tint:white;
    const auto fg=on_rail?(selected?ink:rail_ink):!enabled?muted:primary?white:ink;
    RECT bounds=item.rcItem;
    InflateRect(&bounds,-1,-1);
    rounded(item.hDC,bounds,scale(12),bg,focused?(on_rail?mint:accent):on_rail||primary?CLR_INVALID:border);
    SetBkMode(item.hDC,TRANSPARENT);SetTextColor(item.hDC,fg);
    auto rect=bounds;
    if(icon&&icons) {
        rect.left+=scale(13);rect.right=rect.left+scale(22);
        SelectObject(item.hDC,icons);
        DrawTextW(item.hDC,icon,-1,&rect,DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);
        rect.right=bounds.right-scale(9);rect.left+=scale(28);
    } else InflateRect(&rect,-scale(4),0);
    SelectObject(item.hDC,selected||primary?label_font:ui_font);
    const auto label=contents(item.hwndItem);
    DrawTextW(item.hDC,label.c_str(),-1,&rect,(icon?DT_LEFT:DT_CENTER)|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX);
    RestoreDC(item.hDC,saved);
}

HWND control(HWND parent,const wchar_t* cls,const std::wstring& label,DWORD style,int id,DWORD extra) {
    const auto window=CreateWindowExW(extra,cls,label.c_str(),style|WS_CHILD|WS_VISIBLE,0,0,0,0,parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),GetModuleHandleW(nullptr),nullptr);
    SendMessageW(window,WM_SETFONT,reinterpret_cast<WPARAM>(ui_font),TRUE);
    return window;
}
std::wstring contents(HWND window) {
    const auto length=GetWindowTextLengthW(window);
    std::wstring value(static_cast<std::size_t>(length)+1,L'\0');
    value.resize(GetWindowTextW(window,value.data(),length+1));
    return value;
}
void place(HWND window,int x,int y,int w,int h) {
    const auto scale=[parent=GetParent(window)](int value){return pixels(parent,value);};
    MoveWindow(window,scale(x),scale(y),scale(std::max(0,w)),scale(std::max(0,h)),TRUE);
}
void add_choice(HWND combo,const std::wstring& value) { SendMessageW(combo,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(value.c_str())); }
int choice(HWND combo) { return static_cast<int>(SendMessageW(combo,CB_GETCURSEL,0,0)); }
void show_error(HWND owner,const std::exception& error) {
    std::wstring message;
    try { message=wide(error.what()); } catch (...) { message=L"操作未完成"; }
    MessageBoxW(owner,message.c_str(),L"高效 Todo",MB_OK|MB_ICONWARNING);
}
std::optional<fs::path> choose_file(HWND owner,const wchar_t* filters) {
    wchar_t path[32768]{};
    OPENFILENAMEW dialog{sizeof(dialog)};
    dialog.hwndOwner=owner;
    dialog.lpstrFilter=filters;
    dialog.lpstrFile=path;
    dialog.nMaxFile=static_cast<DWORD>(std::size(path));
    dialog.Flags=OFN_EXPLORER|OFN_FILEMUSTEXIST|OFN_PATHMUSTEXIST|OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&dialog)) return {};
    return fs::path(path);
}

namespace {
enum { save_id=IDOK, attachments_id=201, add_media_id, remove_media_id, open_media_id, append_id, notes_id, restore_id,
    timing_id, channel_id, bill_kind_id };
const HBRUSH page_brush=static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH));

struct Form {
    HWND owner{},window{};
    std::function<void(Form&)> build;
    std::function<void(int)> action;
    bool done=false, accepted=false;
    int content_height=0;
    void scroll_to(int next) const {
        SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE|SIF_POS};
        GetScrollInfo(window,SB_VERT,&info);
        next=std::clamp(next,0,std::max(0,info.nMax-static_cast<int>(info.nPage)+1));
        if(info.nPos==next)return;
        SetScrollPos(window,SB_VERT,next,TRUE);
        ScrollWindowEx(window,0,info.nPos-next,nullptr,nullptr,nullptr,nullptr,SW_SCROLLCHILDREN|SW_INVALIDATE|SW_ERASE);
    }
    void tab_to(bool backwards) const {
        auto control=GetFocus();
        while(control&&GetParent(control)!=window&&IsChild(window,control))control=GetParent(control);
        const auto next=GetNextDlgTabItem(window,control,backwards);
        if(!next)return;
        SetFocus(next);
        RECT client{},item{};
        GetClientRect(window,&client);GetWindowRect(next,&item);
        MapWindowPoints(HWND_DESKTOP,window,reinterpret_cast<POINT*>(&item),2);
        const auto current=GetScrollPos(window,SB_VERT), margin=pixels(window,8);
        if(item.top<0)scroll_to(current+item.top-margin);
        else if(item.bottom>client.bottom)scroll_to(current+item.bottom-client.bottom+margin);
    }
    static LRESULT CALLBACK proc(HWND window,UINT message,WPARAM w,LPARAM l) {
        if(message==WM_NCCREATE) {
            auto* form=static_cast<Form*>(reinterpret_cast<const CREATESTRUCTW*>(l)->lpCreateParams);
            SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(form));
            form->window=window;
        }
        auto* form=reinterpret_cast<Form*>(GetWindowLongPtrW(window,GWLP_USERDATA));
        if(!form)return DefWindowProcW(window,message,w,l);
        try {
            switch(message) {
            case WM_CREATE: form->build(*form); return 0;
            case WM_SIZE: {
                RECT client{};GetClientRect(window,&client);
                SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE,0,std::max(0,form->content_height-1),static_cast<UINT>(client.bottom)};
                if(GetWindowLongPtrW(window,GWL_STYLE)&WS_VSCROLL)SetScrollInfo(window,SB_VERT,&info,TRUE);
                return 0;
            }
            case WM_VSCROLL: {
                SCROLLINFO info{sizeof(info),SIF_ALL};
                GetScrollInfo(window,SB_VERT,&info);
                auto next=info.nPos;
                const int step=pixels(window,35);
                switch(LOWORD(w)) {
                case SB_LINEUP:next-=step;break;
                case SB_LINEDOWN:next+=step;break;
                case SB_PAGEUP:next-=static_cast<int>(info.nPage);break;
                case SB_PAGEDOWN:next+=static_cast<int>(info.nPage);break;
                case SB_THUMBTRACK:case SB_THUMBPOSITION:next=info.nTrackPos;break;
                case SB_TOP:next=0;break;
                case SB_BOTTOM:next=info.nMax;break;
                default:break;
                }
                form->scroll_to(next);return 0;
            }
            case WM_MOUSEWHEEL:
                form->scroll_to(GetScrollPos(window,SB_VERT)-GET_WHEEL_DELTA_WPARAM(w)*pixels(window,55)/WHEEL_DELTA);
                return 0;
            case WM_COMMAND:
                if(HIWORD(w)==0||HIWORD(w)==LBN_DBLCLK||HIWORD(w)==LBN_SELCHANGE||
                    (HIWORD(w)==EN_CHANGE&&LOWORD(w)==notes_id)) {
                    const auto id=LOWORD(w);
                    if(id==IDCANCEL) DestroyWindow(window); else form->action(id);
                }
                return 0;
            case WM_NOTIFY: {
                const auto& notice=*reinterpret_cast<const NMHDR*>(l);
                if(notice.idFrom==timing_id&&notice.code==DTN_DATETIMECHANGE)form->action(timing_id);
                return 0;
            }
            case WM_CTLCOLORSTATIC:
                SetTextColor(reinterpret_cast<HDC>(w),theme::muted);
                SetBkMode(reinterpret_cast<HDC>(w),TRANSPARENT);
                return reinterpret_cast<LRESULT>(page_brush);
            case WM_DRAWITEM:
                draw_button(*reinterpret_cast<const DRAWITEMSTRUCT*>(l),w==save_id);
                return TRUE;
            case WM_CLOSE: DestroyWindow(window); return 0;
            case WM_DESTROY: form->done=true; return 0;
            default: break;
            }
        } catch(const std::exception& error) { show_error(window,error); if(message==WM_CREATE)return -1; }
        return DefWindowProcW(window,message,w,l);
    }
    bool show(const std::wstring& title,int width,int height) {
        static const auto registration=[] {
            WNDCLASSW type{};
            type.lpfnWndProc=proc; type.hInstance=GetModuleHandleW(nullptr); type.hCursor=LoadCursorW(nullptr,IDC_ARROW);
            type.hbrBackground=page_brush; type.lpszClassName=L"GxTodoEditor";
            return RegisterClassW(&type);
        }();
        if(!registration)return false;
        RECT bounds{}; GetWindowRect(owner,&bounds);
        MONITORINFO monitor{sizeof(monitor)};
        GetMonitorInfoW(MonitorFromWindow(owner,MONITOR_DEFAULTTONEAREST),&monitor);
        const auto dpi=GetDpiForWindow(owner);
        auto style=static_cast<DWORD>(WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU);
        content_height=MulDiv(height,dpi,96);
        RECT size{0,0,MulDiv(width,dpi,96),content_height};
        AdjustWindowRectExForDpi(&size,style,FALSE,WS_EX_DLGMODALFRAME,dpi);
        const auto available=monitor.rcWork.bottom-monitor.rcWork.top;
        const auto totalH=std::min(size.bottom-size.top,available);
        auto totalW=size.right-size.left;
        if(totalH<size.bottom-size.top){style|=WS_VSCROLL;totalW+=GetSystemMetricsForDpi(SM_CXVSCROLL,dpi);}
        const auto left=std::clamp((bounds.left+bounds.right-totalW)/2,monitor.rcWork.left,std::max(monitor.rcWork.left,monitor.rcWork.right-totalW));
        const auto top=std::clamp((bounds.top+bounds.bottom-totalH)/2,monitor.rcWork.top,monitor.rcWork.bottom-totalH);
        EnableWindow(owner,FALSE);
        const auto created=CreateWindowExW(WS_EX_DLGMODALFRAME,L"GxTodoEditor",title.c_str(),style,
            left,top,totalW,totalH,owner,nullptr,GetModuleHandleW(nullptr),this);
        if(created) {
            ShowWindow(created,SW_SHOW);
            if(const auto first=GetNextDlgTabItem(created,nullptr,FALSE))SetFocus(first);
            MSG msg{};
            while(!done) {
                const auto result=GetMessageW(&msg,nullptr,0,0);
                if(result<=0) { if(result==0)PostQuitMessage(static_cast<int>(msg.wParam)); break; }
                if(msg.message==WM_KEYDOWN&&msg.wParam==VK_TAB) {
                    tab_to((GetKeyState(VK_SHIFT)&0x8000)!=0);continue;
                }
                if(msg.message==WM_KEYDOWN&&msg.wParam==VK_ESCAPE&&IsWindowEnabled(created)) {
                    DestroyWindow(created);continue;
                }
                if(msg.message==WM_KEYDOWN&&msg.wParam==VK_RETURN&&(GetKeyState(VK_CONTROL)&0x8000)) {
                    SendMessageW(created,WM_COMMAND,save_id,0);continue;
                }
                if(!IsDialogMessageW(created,&msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
            }
            if(IsWindow(created))DestroyWindow(created);
        }
        EnableWindow(owner,TRUE);
        SetActiveWindow(owner);
        return accepted;
    }
    void finish() { accepted=true; DestroyWindow(window); }
};

HWND label(HWND parent,const wchar_t* value,int x,int y,int w) {
    const auto child=control(parent,L"STATIC",value,SS_LEFT);
    SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(label_font),FALSE);
    place(child,x,y,w,22); return child;
}
HWND edit(HWND parent,const std::string& value,int x,int y,int w,int h=29,int limit=500) {
    const auto child=control(parent,L"EDIT",wide(value),WS_TABSTOP|(h>32?ES_MULTILINE|ES_AUTOVSCROLL|WS_VSCROLL|ES_WANTRETURN:ES_AUTOHSCROLL),0,WS_EX_CLIENTEDGE);
    SendMessageW(child,EM_SETLIMITTEXT,limit,0);
    place(child,x,y,w,h); return child;
}
HWND dropdown(HWND parent,const std::vector<std::wstring>& values,int index,int x,int y,int w,bool custom=false) {
    const auto combo=control(parent,WC_COMBOBOXW,L"",WS_TABSTOP|WS_VSCROLL|(custom?CBS_DROPDOWN:CBS_DROPDOWNLIST));
    for(const auto& value:values)add_choice(combo,value);
    SendMessageW(combo,CB_SETCURSEL,index,0); place(combo,x,y,w,240); return combo;
}
HWND date_field(HWND parent,const std::string& iso,bool optional,int x,int y,int w) {
    auto field=control(parent,DATETIMEPICK_CLASSW,L"",WS_TABSTOP|DTS_SHORTDATEFORMAT|(optional?DTS_SHOWNONE:0));
    DateTime_SetFormat(field,L"yyyy-MM-dd");
    SYSTEMTIME value{};
    GetLocalTime(&value);
    unsigned year=0,month=0,day=0;
    if(::sscanf_s(iso.c_str(),"%u-%u-%u",&year,&month,&day)==3&&year>=1970&&year<=2100&&month>=1&&month<=12&&day>=1&&day<=31) {
        value.wYear=static_cast<WORD>(year);value.wMonth=static_cast<WORD>(month);value.wDay=static_cast<WORD>(day);
    }
    DateTime_SetSystemtime(field,iso.empty()&&optional?GDT_NONE:GDT_VALID,&value);
    place(field,x,y,w,29);
    return field;
}
HWND time_field(HWND parent,const std::string& iso,int x,int y,int w) {
    auto field=control(parent,DATETIMEPICK_CLASSW,L"",WS_TABSTOP|DTS_TIMEFORMAT|DTS_UPDOWN);
    DateTime_SetFormat(field,L"HH:mm");
    SYSTEMTIME value{};
    GetLocalTime(&value);
    unsigned hour=9,minute=0;
    ::sscanf_s(iso.c_str(),"%u:%u",&hour,&minute);
    value.wHour=static_cast<WORD>(hour);value.wMinute=static_cast<WORD>(minute);value.wSecond=0;
    DateTime_SetSystemtime(field,GDT_VALID,&value);
    place(field,x,y,w,29);
    return field;
}
std::string picked(HWND field,bool date) {
    SYSTEMTIME value{};
    if(DateTime_GetSystemtime(field,&value)!=GDT_VALID)return {};
    char result[32]{};
    if(date)std::snprintf(result,sizeof(result),"%04u-%02u-%02u",unsigned(value.wYear),unsigned(value.wMonth),unsigned(value.wDay));
    else std::snprintf(result,sizeof(result),"%02u:%02u",unsigned(value.wHour),unsigned(value.wMinute));
    return result;
}
HWND button(HWND parent,const wchar_t* text,int id,int x,int y,int w=86,bool primary=false) {
    const auto child=control(parent,L"BUTTON",text,WS_TABSTOP|BS_OWNERDRAW,id);
    if(primary)SendMessageW(parent,DM_SETDEFID,id,0);
    place(child,x,y,w,31);return child;
}
HWND tick(HWND parent,const wchar_t* text,bool value,int x,int y,int w) {
    const auto child=control(parent,L"BUTTON",text,WS_TABSTOP|BS_AUTOCHECKBOX);
    SendMessageW(child,BM_SETCHECK,value?BST_CHECKED:BST_UNCHECKED,0);
    place(child,x,y,w,24);return child;
}
bool checked(HWND window) {return SendMessageW(window,BM_GETCHECK,0,0)==BST_CHECKED;}
std::string value(HWND window) {
    auto text=utf8(contents(window));
    text.erase(std::remove(text.begin(),text.end(),'\r'),text.end());
    return text;
}
Json lines(const std::string& content) {
    Json array=Json::array();
    std::istringstream stream(content);
    std::string item;
    while(std::getline(stream,item)) {
        const auto left=item.find_first_not_of(" \t\r");
        if(left!=std::string::npos) array.push_back(item.substr(left,item.find_last_not_of(" \t\r")-left+1));
    }
    return array;
}
std::string joined(const Json& list) {
    std::string result;
    if(list.is_array())for(const auto& item:list){if(!result.empty())result+="\r\n";result+=item.get<std::string>();}
    return result;
}
std::string media_kind(const fs::path& path) {
    auto ext=path.extension().wstring();
    std::transform(ext.begin(),ext.end(),ext.begin(),towlower);
    if(ext==L".png"||ext==L".jpg"||ext==L".jpeg"||ext==L".gif"||ext==L".webp"||ext==L".heic")return "image";
    if(ext==L".wav"||ext==L".m4a"||ext==L".mp3"||ext==L".ogg")return "audio";
    return "file";
}
}

std::optional<std::wstring> prompt(HWND owner,const std::wstring& caption,const std::wstring& title,const std::wstring& initial) {
    Form form{owner};
    HWND input{};
    form.build=[&](Form& dialog){
        label(dialog.window,title.c_str(),18,15,365);
        input=edit(dialog.window,utf8(initial),18,42,370);
        button(dialog.window,L"确定",save_id,211,86,82,true);
        button(dialog.window,L"取消",IDCANCEL,306,86,82);
        SetFocus(input);
    };
    std::wstring result;
    form.action=[&](int id){if(id==save_id){result=contents(input);form.finish();}};
    return form.show(caption,408,135)?std::optional(result):std::nullopt;
}

bool edit_record(HWND owner,const Store& store,const Account& account,Id team,int table,
    const std::string& existing_id,const std::string& section) {
    const auto snapshot=store.read(account.scope());
    const auto old=snapshot.get(team,table,existing_id);
    if (old&&old->removed) return false;
    const auto uid=existing_id.empty()?new_id(table):existing_id;
    const auto record_title=table==task?L"任务":table==bill?L"账单":section.empty()?L"便签":L"记事本";
    const auto row=old?*old:Row{table,team,0,0,0,false,uid,Json::object()};
    const auto current_task=table==task&&old?task_view(snapshot,row).snapshot(account.user,account.personal):Json::object();
    const auto original_entries=table==note&&old?note_entries(snapshot,row):std::vector<Row>{};
    auto entries=original_entries;
    const int media_table=table==task?task_attachment:table==bill?bill_attachment:note_entry;
    if(table!=note&&old)
        for(const auto* attachment:snapshot.list(team,media_table))
            if(text(attachment->data,"note_id")==uid&&!number(attachment->data,"detached")) entries.push_back(*attachment);
    std::map<std::string,fs::path> imported;
    std::set<std::string> removed;
    Form form{owner};
    HWND title{},description{},secondary{},date{},time{},end_date{},end_time{},repeat_rule{},lead{},mode{},all_day{},rank{},
        amount{},type{},unit{},channel{},party{},location{},total{},stats{},attachments{},details{};
    int selected_entry=-1;
    bool note_dirty=false;
    const int height=table==task?675:table==bill?650:555;
    const auto refresh_timing=[&] {
        const bool scheduled=!picked(date,true).empty(),all=checked(all_day);
        EnableWindow(time,scheduled&&!all);
        EnableWindow(end_date,scheduled);
        EnableWindow(end_time,scheduled&&!all&&!picked(end_date,true).empty());
        EnableWindow(all_day,scheduled);
        for(const auto item:{repeat_rule,lead,mode})EnableWindow(item,scheduled);
    };
    const auto rebuild=[&] {
        if(!attachments)return;
        SendMessageW(attachments,LB_RESETCONTENT,0,0);
        for(const auto& entry:entries) {
            if(removed.contains(entry.uid))continue;
            const auto content=text(entry.data,"kind")=="text" ? text(entry.data,"content").substr(0,text(entry.data,"content").find('\n')) : "附件 · "+text(entry.data,"media_name","图片");
            const auto display=wide(content.empty()?"正文":content);
            auto index=SendMessageW(attachments,LB_ADDSTRING,0,reinterpret_cast<LPARAM>(display.c_str()));
            SendMessageW(attachments,LB_SETITEMDATA,index,&entry-&entries.front());
        }
    };
    const auto capture_text=[&] {
        if(table!=note||!details||!note_dirty)return;
        const auto content=value(details);
        if(selected_entry>=0&&text(entries[static_cast<std::size_t>(selected_entry)].data,"kind")=="text")
            entries[static_cast<std::size_t>(selected_entry)].data["content"]=content;
        else if(!content.empty())
            entries.push_back({note_entry,team,0,0,0,false,new_id(note_entry),
                {{"note_id",uid},{"kind","text"},{"content",content},{"entry_at",now_ms()}}});
        note_dirty=false;
    };
    form.build=[&](Form& dialog){
        auto window=dialog.window;
        label(window,table==bill?L"事项":L"标题",18,12,535);
        title=edit(window,table==note&&old?note_title(row):text(row.data,"name"),18,35,564,29,table==note?100:500);
        if(table==task) {
            const auto started=number(current_task,"start"), stopped=number(current_task,"end");
            label(window,L"开始日期",18,78,132); label(window,L"开始时间",160,78,117);
            label(window,L"结束日期",301,78,132); label(window,L"结束时间",445,78,117);
            date=date_field(window,local_date(started),true,18,98,132);
            time=time_field(window,started?local_time(started):"09:00",160,98,115);
            end_date=date_field(window,local_date(stopped),true,301,98,132);
            end_time=time_field(window,stopped?local_time(stopped):"10:00",445,98,137);
            all_day=tick(window,L"全天",field(current_task,"allDay")==true,18,140,78);
            rank=dropdown(window,{L"普通",L"重要",L"紧急",L"重要且紧急"},
                static_cast<int>(std::clamp<Id>(number(current_task,"rank",1),1,4))-1,115,137,160);
            repeat_rule=dropdown(window,{L"不重复",L"每天",L"每周",L"每个工作日",L"每月",L"每年"},
                static_cast<int>(number(current_task,"repeat")),301,137,281);
            label(window,L"提醒",18,177,129); label(window,L"提醒方式",301,177,129);
            const std::vector<Id> leads{-1,0,300,600,1800,3600,86400};
            const auto found=std::ranges::find(leads,number(current_task,"alert",old?-1:0));
            lead=dropdown(window,{L"无提醒",L"开始时",L"提前 5 分钟",L"提前 10 分钟",L"提前 30 分钟",L"提前 1 小时",L"提前 1 天"},
                found==leads.end()?0:static_cast<int>(found-leads.begin()),18,198,257);
            mode=dropdown(window,{L"闹钟和系统推送",L"闹钟",L"系统推送"},
                text(current_task,"reminderMode")=="alarm"?1:text(current_task,"reminderMode")=="notification"?2:0,301,198,281);
            label(window,L"备注",18,235,250); label(window,L"复盘",301,235,250);
            description=edit(window,text(current_task,"remark"),18,257,257,92,12000);
            secondary=edit(window,text(current_task,"review"),301,257,281,92,12000);
            label(window,L"子任务（每行一项）",18,361,270); label(window,L"标签（每行一项）",301,361,270);
            details=edit(window,joined(field(current_task,"children")),18,384,257,88);
            location=edit(window,joined(field(current_task,"tags")),301,384,281,88);
            for(const auto item:{date,end_date,all_day})SetWindowLongPtrW(item,GWLP_ID,timing_id);
            refresh_timing();
        } else if(table==bill) {
            label(window,L"日期",18,78,155); label(window,L"类型",207,78,155); label(window,L"金额",396,78,155);
            date=date_field(window,text(row.data,"date",today()),false,18,99,167);
            type=dropdown(window,{L"支出",L"收入",L"内转"},text(row.data,"type")=="income"?1:text(row.data,"type")=="transfer"?2:0,207,99,167);
            SetWindowLongPtrW(type,GWLP_ID,bill_kind_id);
            amount=edit(window,text(row.data,"amount"),396,99,186,29,49);
            label(window,L"币种",18,140,120); label(window,L"途径",207,140,120); label(window,L"支出收入方",396,140,151);
            unit=dropdown(window,{L"CNY",L"USD",L"HKD",L"EUR",L"JPY",L"GBP",L"SGD",L"AUD",L"CAD",L"KRW",L"TWD"},0,18,161,167,true);
            SetWindowTextW(unit,wide(currency(row)).c_str());
            std::set<std::string> channels{"支付宝","微信","美团支付","抖音支付","银闪付","工行卡","建行卡","GooglePay","PayPal"};
            std::set<std::string> parties{"支付宝余额","微信余额","工行卡","建行卡","工行信用卡","建行信用卡","农行信用卡","招行卡"};
            for(const auto& [key,item]:snapshot.rows) if(!item.removed) {
                if(item.table==bill) {
                    channels.insert(text(item.data,"channel")); parties.insert(text(item.data,"party"));
                } else if(item.table==bill_option) (text(item.data,"kind")=="channel"?channels:parties).insert(text(item.data,"name"));
            }
            channel=dropdown(window,{},0,207,161,167,true);
            SetWindowLongPtrW(channel,GWLP_ID,channel_id);
            party=dropdown(window,{},0,396,161,186,true);
            for(const auto& item:channels)if(!item.empty())add_choice(channel,wide(item));
            for(const auto& item:parties)if(!item.empty())add_choice(party,wide(item));
            SetWindowTextW(channel,wide(text(row.data,"channel","支付宝")).c_str());
            SetWindowTextW(party,wide(text(row.data,"party","支付宝余额")).c_str());
            total=tick(window,L"计入总支出／总收入",total_included(row),18,205,250);
            stats=tick(window,choice(type)==1?L"计入收入统计":L"计入支出统计",party_included(row),301,205,250);
            EnableWindow(stats,choice(type)!=2);EnableWindow(total,choice(type)!=2);
            label(window,L"地点",18,245,186);
            location=edit(window,text(row.data,"location"),18,267,564);
            label(window,L"备注",18,309,186);
            description=edit(window,text(row.data,"remark"),18,331,564,125,12000);
        } else {
            label(window,section.empty()?L"记录内容":L"正文",18,79,320);
            details=edit(window,"",18,102,564,220,60000);
            if(!section.empty()&&!entries.empty()&&text(entries.front().data,"kind")=="text") {
                selected_entry=0;
                SetWindowTextW(details,wide(text(entries.front().data,"content")).c_str());
            }
            SetWindowLongPtrW(details,GWLP_ID,notes_id);
            button(window,section.empty()?L"添加文字":L"添加段落",append_id,483,330,99);
        }
        const int y=table==task?488:table==bill?474:374;
        label(window,table==note?L"内容与附件":L"附件",18,y-2,320);
        attachments=control(window,L"LISTBOX",L"",WS_TABSTOP|WS_VSCROLL|LBS_NOTIFY,attachments_id,WS_EX_CLIENTEDGE);
        place(attachments,18,y+21,564,80);
        rebuild();
        button(window,L"添加附件",add_media_id,18,y+106,91);
        button(window,L"打开",open_media_id,116,y+106,74);
        button(window,L"移除",remove_media_id,197,y+106,74);
        button(window,L"保存",save_id,405,height-48,81,true);
        button(window,L"取消",IDCANCEL,497,height-48,85);
        SetFocus(title);
    };
    form.action=[&](int id){
        if(id==timing_id){refresh_timing();return;}
        if(id==bill_kind_id) {
            SetWindowTextW(stats,choice(type)==1?L"计入收入统计":L"计入支出统计");
            EnableWindow(stats,choice(type)!=2);EnableWindow(total,choice(type)!=2);
            return;
        }
        if(id==channel_id&&choice(channel)>=0) {
            const auto count=SendMessageW(channel,CB_GETLBTEXTLEN,choice(channel),0);
            if(count>=0) {
                std::wstring selected(static_cast<std::size_t>(count)+1,L'\0');
                SendMessageW(channel,CB_GETLBTEXT,choice(channel),reinterpret_cast<LPARAM>(selected.data()));
                selected.resize(static_cast<std::size_t>(count));
                if(selected==L"微信")SetWindowTextW(party,L"微信余额");
            }
            return;
        }
        if(id==notes_id){note_dirty=true;return;}
        if(id==append_id) {
            capture_text(); selected_entry=-1;SetWindowTextW(details,L"");note_dirty=false;rebuild();SetFocus(details);return;
        }
        const auto current=static_cast<int>(SendMessageW(attachments,LB_GETCURSEL,0,0));
        const auto selected=current<0?-1:static_cast<int>(SendMessageW(attachments,LB_GETITEMDATA,current,0));
        if(id==attachments_id&&table==note&&selected>=0) {
            capture_text();
            const auto& entry=entries[static_cast<std::size_t>(selected)];
            if(text(entry.data,"kind")=="text") {
                selected_entry=selected;SetWindowTextW(details,wide(text(entry.data,"content")).c_str());
                note_dirty=false;SetFocus(details);
            }
            return;
        }
        if(id==add_media_id) {
            const auto file=choose_file(form.window,table==note?L"图片和音频\0*.png;*.jpg;*.jpeg;*.gif;*.webp;*.heic;*.wav;*.m4a;*.mp3;*.ogg\0\0":L"所有文件\0*.*\0\0");
            if(!file)return;
            const auto kind=media_kind(*file);
            if(table==note&&kind=="file")throw std::runtime_error("便签支持图片和录音附件");
            capture_text();
            const auto entry_id=new_id(media_table);
            imported.emplace(entry_id,*file);
            Id at=now_ms();
            if (table==note&&selected_entry>=0) {
                at=number(entries[static_cast<std::size_t>(selected_entry)].data,"entry_at")+1;
                for(std::size_t i=static_cast<std::size_t>(selected_entry)+1;i<entries.size();++i)
                    if(number(entries[i].data,"entry_at")<=at) entries[i].data["entry_at"]=at+static_cast<Id>(i)+1;
            }
            entries.push_back({media_table,team,0,0,0,false,entry_id,
                {{"note_id",uid},{"kind",kind},{"media_name",utf8(file->filename().wstring())},{"entry_at",at}}});
            std::ranges::sort(entries,{},[](const Row& entry){return number(entry.data,"entry_at");});
            selected_entry=-1;
            if(table==note){SetWindowTextW(details,L"");note_dirty=false;}
            rebuild();return;
        }
        if((id==open_media_id||id==remove_media_id)&&selected>=0) {
            const auto& entry=entries[static_cast<std::size_t>(selected)];
            if(id==remove_media_id){removed.insert(entry.uid);rebuild();return;}
            if(text(entry.data,"kind")=="text")return;
            const auto pending=imported.find(entry.uid);
            const auto path=pending==imported.end()?open_attachment(store,account,entry.data):pending->second;
            auto open=path;
            if(path.extension()==L".image") {
                auto extension=fs::path(wide(text(entry.data,"media_name"))).extension();
                if(media_kind(fs::path(L"original"+extension.wstring()))!="image")extension=L".jpg";
                open=path.parent_path()/fs::path(path.filename().wstring()+extension.wstring());
                fs::copy_file(path,open,fs::copy_options::overwrite_existing);
            }
            auto opened=INT_PTR{};
            if(media_kind(open)=="file") {
                const auto selection=L"/select,\""+open.wstring()+L"\"";
                opened=reinterpret_cast<INT_PTR>(ShellExecuteW(form.window,L"open",L"explorer.exe",selection.c_str(),nullptr,SW_SHOWNORMAL));
            } else opened=reinterpret_cast<INT_PTR>(ShellExecuteW(form.window,L"open",open.c_str(),nullptr,nullptr,SW_SHOWNORMAL));
            if(opened<=32)throw std::runtime_error("无法打开附件");
            return;
        }
        if(id!=save_id)return;
        capture_text();
        const auto name=value(title);
        if(table!=note&&name.empty())throw std::runtime_error("请输入标题");
        if(table==note&&name.empty()&&entries.empty()){form.finish();return;}
        Json edit_values;
        if(table==task) {
            const bool day=checked(all_day);
            const auto start_date=picked(date,true),stop_date=picked(end_date,true);
            const auto started=number(current_task,"start"),stopped=number(current_task,"end");
            const auto start_time=day?"00:00":picked(time,false),stop_time=day?"23:59":picked(end_time,false);
            const auto start=start_date.empty()?Id{0}:start_date==local_date(started)&&start_time==local_time(started)?
                started:timestamp(start_date,start_time);
            const auto end=!start?Id{0}:stop_date.empty()?(day?timestamp(start_date,"23:59")+59:start+3600):
                stop_date==local_date(stopped)&&stop_time==local_time(stopped)&&day==(field(current_task,"allDay")==true)?
                    stopped:timestamp(stop_date,stop_time)+(day?59:0);
            constexpr Id leads[]{-1,0,300,600,1800,3600,86400};
            edit_values={{"name",name},{"rank",choice(rank)+1},{"start",start},{"end",end},{"allDay",day},
                {"repeat",choice(repeat_rule)},{"repeatEnd",number(current_task,"repeatEnd")},
                {"alert",leads[std::clamp(choice(lead),0,6)]},{"reminderMode",choice(mode)==1?"alarm":choice(mode)==2?"notification":"both"},
                {"remark",value(description)},{"review",value(secondary)},{"children",lines(value(details))},{"tags",lines(value(location))},
                {"project",text(current_task,"project")},{"place",text(current_task,"place")}};
        } else if(table==bill) {
            edit_values={{"name",name},{"date",picked(date,true)},{"type",choice(type)==1?"income":choice(type)==2?"transfer":"expense"},
                {"amount",value(amount)},{"currency",value(unit)},{"channel",value(channel)},{"party",value(party)},
                {"location",value(location)},{"remark",value(description)},{"include_in_totals",checked(total)?1:0},
                {"include_in_party_stats",checked(stats)?1:0}};
            if(value(location)!=text(row.data,"location")){ edit_values["latitude"]="";edit_values["longitude"]=""; }
        }
        auto edited=entries;
        std::erase_if(edited,[&](const Row& entry){return removed.contains(entry.uid);});
        std::vector<Json> media;
        for(auto& entry:edited) {
            if(!imported.contains(entry.uid))continue;
            auto local=import_attachment(store,imported.at(entry.uid),text(entry.data,"kind"),team,uid);
            entry.data.update(local);
            entry.data.erase("local_ready");
            entry.data["media_id"]="";
            media.push_back(std::move(local));
        }
        store.change(account.scope(),[&](Workspace& state){
            for(auto& local:media)state.media[text(local,"client_media_id")]=local;
            if(table==note) {
                const auto title_change=old&&name==note_title(row)?std::nullopt:std::optional(name);
                save_note(state,account,team,uid,section,title_change,edited,removed,original_entries);
                return;
            }
            if(table==task)save_task(state,account,team,uid,edit_values,false);
            else save_bill(state,account,team,uid,edit_values,false);
            for(const auto& entry:edited) if(imported.contains(entry.uid))state.save(team,account.user,media_table,entry.uid,entry.data);
            for(const auto& entry:entries) if(removed.contains(entry.uid)&&!imported.contains(entry.uid))
                state.save(team,account.user,media_table,entry.uid,{{"detached",1}});
            if(table==task)save_task(state,account,team,uid,edit_values,true);
            else save_bill(state,account,team,uid,edit_values,true);
        });
        form.finish();
    };
    return form.show((existing_id.empty()?L"新建":L"编辑")+std::wstring(record_title),602,height);
}

void show_history(HWND owner,const Store& store,const Account& account,const Row& row) {
    const auto data=store.read(account.scope());
    const auto versions=history(data,row);
    if(versions.empty()){ MessageBoxW(owner,L"暂无历史版本",L"历史版本",MB_OK);return; }
    Form form{owner};
    HWND list{};
    form.build=[&](Form& dialog){
        list=control(dialog.window,L"LISTBOX",L"",WS_TABSTOP|WS_VSCROLL|LBS_NOTIFY,1,WS_EX_CLIENTEDGE);
        place(list,18,18,394,244);
        for(const auto* version:versions){
            const auto time=local_stamp(stamp(number(version->data,"version_at")));
            const auto title=wide(time+"   "+text(version->data,"action"));
            SendMessageW(list,LB_ADDSTRING,0,reinterpret_cast<LPARAM>(title.c_str()));
        }
        button(dialog.window,L"还原选中版本",restore_id,189,277,123,true);
        button(dialog.window,L"关闭",IDCANCEL,326,277,86);
    };
    form.action=[&](int id){
        if(id!=restore_id)return;
        const auto index=static_cast<int>(SendMessageW(list,LB_GETCURSEL,0,0));
        if(index<0)return;
        store.change(account.scope(),[&](Workspace& state){restore_version(state,account,row,*versions[static_cast<std::size_t>(index)]);});
        form.finish();
    };
    form.show(L"历史版本",430,326);
}
}
