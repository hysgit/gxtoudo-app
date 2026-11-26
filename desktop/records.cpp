#include "records.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <ranges>
#include <stdexcept>

namespace todo {
namespace {
using namespace std::chrono;
year_month_day date_value(std::string_view value) {
    int y=0,m=0,d=0;
    if (value.size()!=10||::sscanf_s(std::string(value).c_str(),"%d-%d-%d",&y,&m,&d)!=3)
        throw std::runtime_error("日期格式为 YYYY-MM-DD");
    const year_month_day date{year{y},month{static_cast<unsigned>(m)},day{static_cast<unsigned>(d)}};
    if (!date.ok()||y<1970||y>2100) throw std::runtime_error("日期无效");
    return date;
}
std::string date_string(year_month_day value) {
    char output[16]{};
    std::snprintf(output,sizeof(output),"%04d-%02u-%02u",int(value.year()),unsigned(value.month()),unsigned(value.day()));
    return output;
}
std::string format_time(Id seconds,const char* format) {
    if (seconds<=0) return {};
    const auto value=static_cast<time_t>(seconds);
    std::tm local{};
    if (localtime_s(&local,&value)) return {};
    char result[32]{};
    std::strftime(result,sizeof(result),format,&local);
    return result;
}
std::string body_title(std::string value) {
    const auto end=value.find('\n');
    if (end!=std::string::npos) value.resize(end);
    if (!value.empty()&&value.back()=='\r') value.pop_back();
    return value;
}
const Json& data(const Row* row) { static const Json empty; return row ? row->data : empty; }
std::vector<const Row*> linked(const Workspace& state,Id team,int table,std::string_view field_name,const std::string& value) {
    auto rows=state.list(team,table);
    std::erase_if(rows,[&](const auto* row){return text(row->data,field_name)!=value;});
    return rows;
}
void capture(Workspace& state,const Account& account,const Row& row,const Json& snapshot,const std::string& action) {
    const auto versions=history(state,row);
    const auto encoded=snapshot.dump();
    if (!versions.empty()&&text(versions.front()->data,"snapshot")==encoded&&text(versions.front()->data,"action")==action) return;
    const int version=row.table==task?task_version:bill_version;
    state.save(row.team,account.user,version,new_id(version),{{"parent_id",row.uid},{"snapshot",encoded},{"action",action},
        {"version_at",std::max(now_ms(),versions.empty()?Id{0}:number(versions.front()->data,"version_at")+1)}});
}
Json attachment_ids(const Workspace& state,const Row& row) {
    Json result=Json::array();
    for (const auto* media : linked(state,row.team,row.table==task?task_attachment:bill_attachment,"note_id",row.uid))
        if (!number(media->data,"detached")) result.push_back(media->uid);
    return result;
}
Json bill_snapshot(const Workspace& state,const Row& row) {
    Json result=Json::object();
    for (const auto* key : {"name","date","type","amount","channel","party","remark","location","latitude","longitude"})
        result[key]=text(row.data,key);
    result["currency"]=currency(row);
    result["include_in_totals"]=total_included(row)?1:0;
    result["include_in_party_stats"]=party_included(row)?1:0;
    result["attachments"]=attachment_ids(state,row);
    return result;
}
}

std::string local_date(Id seconds) { return format_time(seconds,"%Y-%m-%d"); }
std::string local_time(Id seconds) { return format_time(seconds,"%H:%M"); }
std::string today() { return local_date(now_ms()/1000); }
std::string shift_day(std::string_view date,int delta) { return date_string(year_month_day{sys_days{date_value(date)}+days{delta}}); }
Id timestamp(std::string_view date,std::string_view time) {
    const auto day=date_value(date);
    int hour=0, minute=0, consumed=0;
    if (::sscanf_s(std::string(time).c_str(),"%d:%d%n",&hour,&minute,&consumed)!=2 ||
        static_cast<std::size_t>(consumed)!=time.size()||hour<0||hour>23||minute<0||minute>59)
        throw std::runtime_error("时间格式为 HH:mm");
    std::tm local{};
    local.tm_year=int(day.year())-1900; local.tm_mon=static_cast<int>(unsigned(day.month()))-1;
    local.tm_mday=static_cast<int>(unsigned(day.day())); local.tm_hour=hour; local.tm_min=minute; local.tm_isdst=-1;
    const auto seconds=std::mktime(&local);
    if (seconds<0) throw std::runtime_error("时间无效");
    return seconds;
}
std::string local_stamp(std::string_view utc) {
    std::tm parsed{};
    int y=0,m=0,d=0,h=0,n=0,s=0;
    if (::sscanf_s(std::string(utc).c_str(),"%d-%d-%d %d:%d:%d",&y,&m,&d,&h,&n,&s)!=6) return std::string(utc);
    parsed.tm_year=y-1900; parsed.tm_mon=m-1; parsed.tm_mday=d; parsed.tm_hour=h; parsed.tm_min=n; parsed.tm_sec=s;
    return format_time(_mkgmtime64(&parsed),"%Y-%m-%d %H:%M");
}

Amount Amount::parse(std::string_view input) {
    const auto dot=input.find('.');
    const auto integer=dot==input.npos?input:input.substr(0,dot);
    const auto decimal=dot==input.npos?std::string_view{}:input.substr(dot+1);
    const auto valid=[](std::string_view item){return std::ranges::all_of(item,[](char ch){return ch>='0'&&ch<='9';});};
    if (integer.empty()||integer.size()>30||decimal.size()>18||(dot!=input.npos&&decimal.empty())||!valid(integer)||!valid(decimal))
        throw std::runtime_error("金额须为非负数字，最多 18 位小数");
    auto digits=std::string(integer)+std::string(decimal);
    const auto first=digits.find_first_not_of('0');
    if (first==std::string::npos) digits="0"; else digits.erase(0,first);
    return {digits,decimal.size()};
}
Amount Amount::operator+(const Amount& other) const {
    const auto common=std::max(scale,other.scale);
    const auto a=digits+std::string(common-scale,'0'), b=other.digits+std::string(common-other.scale,'0');
    std::string result;
    int carry=0;
    for(std::size_t i=0;i<std::max(a.size(),b.size())||carry;++i) {
        const auto value=carry+(i<a.size()?a[a.size()-i-1]-'0':0)+(i<b.size()?b[b.size()-i-1]-'0':0);
        result+=static_cast<char>('0'+value%10); carry=value/10;
    }
    std::ranges::reverse(result);
    const auto first=result.find_first_not_of('0');
    if (first==std::string::npos) result="0"; else result.erase(0,first);
    return {result,common};
}
std::string Amount::format() const {
    const auto display=std::max<std::size_t>(2,scale);
    auto output=digits+std::string(display-scale,'0');
    if (output.size()<=display) output.insert(0,display-output.size()+1,'0');
    output.insert(output.size()-display,1,'.');
    return output;
}
std::string currency(const Row& row) {
    const auto code=text(row.data,"currency");
    return code.empty()?"CNY":code;
}
std::string bill_amount(const Amount& amount,std::string_view code) {
    return code=="CNY"?amount.format()+" 元":std::string(code)+" "+amount.format();
}
bool total_included(const Row& row){return number(row.data,"legacy_include_in_totals",number(row.data,"include_in_totals",1))!=0;}
bool party_included(const Row& row){return number(row.data,"include_in_party_stats",1)!=0;}

const Row* TaskView::one(int table,Id owner) const {
    const auto found=std::ranges::find_if(parts,[&](const auto* part){return part->table==table&&(owner<0||number(part->data,"user_id")==owner);});
    return found==parts.end()?nullptr:*found;
}
Id TaskView::start() const {return number(data(one(schedule)),"start_at");}
Id TaskView::end() const {return number(data(one(schedule)),"end_at");}
int TaskView::repeat_kind() const {
    const auto& value=data(one(repeat));
    if (number(value,"repeat_start_day")>0) return 1;
    if (number(value,"repeat_start_week")>0) return text(value,"weekday")=="0234560"?3:2;
    if (number(value,"repeat_start_month")>0) return 4;
    return number(value,"repeat_start_year")>0?5:0;
}
Id TaskView::occurrence(const std::string& day) const {
    const auto first=start();
    if (first<=0) return 0;
    const auto initial=date_value(local_date(first)), target=date_value(day);
    const auto elapsed=(sys_days(target)-sys_days(initial)).count();
    if (elapsed<0) return 0;
    const auto mode=repeat_kind();
    if (mode==0) return elapsed==0?first:0;
    const auto& rule=data(one(repeat));
    const auto instance=elapsed==0?first:timestamp(day,local_time(first))+first%60;
    const auto limit=number(rule,"repeat_end");
    if (limit>0&&instance>limit) return 0;
    const auto count=number(rule,"repeat_count");
    if (mode==1) {
        const auto interval=std::max<Id>(1,number(rule,"day_interval")/86400);
        return elapsed%interval==0&&(count==0||elapsed/interval<count)?instance:0;
    }
    if (mode==2||mode==3) {
        const auto mask=text(rule,"weekday");
        const auto first_day=weekday(sys_days(initial)).c_encoding();
        const auto target_day=weekday(sys_days(target)).c_encoding();
        const auto week=(elapsed+first_day)/7;
        const auto interval=std::max<Id>(1,number(rule,"week_interval")/604800);
        if (mask.size()!=7||mask[target_day]=='0'||week%interval) return 0;
        if (count>0) {
            Id occurrences=0;
            for (Id i=0;i<=elapsed;++i) {
                const auto cursor=first_day+i;
                if ((cursor/7)%interval==0&&mask[cursor%7]!='0') ++occurrences;
            }
            if (occurrences>count) return 0;
        }
        return instance;
    }
    const auto max_day=unsigned(year_month_day_last{target.year(),month_day_last{target.month()}}.day());
    const auto wanted=std::clamp<Id>(number(rule,"day",unsigned(initial.day())),1,max_day);
    const auto years=int(target.year())-int(initial.year());
    const auto months=years*12+int(unsigned(target.month()))-int(unsigned(initial.month()));
    const auto interval=std::max<Id>(1,number(rule,mode==4?"month_interval":"year_interval"));
    const auto period=mode==4?months:years;
    return unsigned(target.day())==wanted && period%interval==0 && (count==0||period/interval<count) &&
        (mode==4||unsigned(target.month())==number(rule,"month",unsigned(initial.month()))) ? instance : 0;
}
Id TaskView::next(const std::string& date) const {
    if (!repeat_kind()||!start()) return start();
    const auto first=std::max(date,local_date(start()));
    for(int i=0;i<370;++i) if(const auto item=occurrence(shift_day(first,i)); item>0) return item;
    return start();
}
const Row* TaskView::completed(Id user,Id instance) const {
    const auto repeated=repeat_kind()!=0;
    const auto found=std::ranges::find_if(parts,[&](const auto* row){
        return row->table==check&&number(row->data,"user_id")==user&&number(row->data,"status")==1&&
            (!repeated||number(row->data,"start_at")==instance);
    });
    return found==parts.end()?nullptr:*found;
}
Json TaskView::snapshot(Id user,Id personal) const {
    Json result={{"name",text(row->data,"name")},{"rank",number(row->data,"rank",1)},{"project",text(row->data,"project_id")},
        {"place",text(row->data,"position_id")},{"start",start()},{"end",end()},{"allDay",number(data(one(schedule)),"is_all_day")==1},
        {"repeat",repeat_kind()},{"repeatEnd",number(data(one(repeat)),"repeat_end")},{"remark",""},{"review",""},
        {"tags",Json::array()},{"children",Json::array()}};
    std::vector<const Row*> children;
    for (const auto* part : parts) {
        if (part->table==detail) result[number(part->data,"type")==1?"review":"remark"]=text(part->data,"content");
        if (part->table==task_tag) result["tags"].push_back(text(part->data,"tag_name"));
        if (part->table==subtask) children.push_back(part);
    }
    std::ranges::sort(children,{},[](const Row* child){return number(child->data,"sequence");});
    for(const auto* child:children) result["children"].push_back(text(child->data,"name"));
    if (row->team==personal) {
        const auto& notification=data(one(alert,user));
        result["alert"]=number(notification,"alert_time",-1);
        result["reminderMode"]=text(notification,"reminder_mode","both");
        result["checks"]=Json::array();
        result["completedChildren"]=Json::array();
        for (const auto* part : parts) {
            if (number(part->data,"user_id")!=user||number(part->data,"status")!=1) continue;
            if (part->table==check) result["checks"].push_back({number(part->data,"start_at"),number(part->data,"check_at")});
            if (part->table==subcheck) for (std::size_t i=0;i<children.size();++i)
                if(children[i]->uid==text(part->data,"child_task_id")) result["completedChildren"].push_back(i);
        }
    }
    return result;
}
std::vector<TaskView> tasks(const Workspace& state,Id team) {
    std::map<std::string,std::vector<const Row*>> parts;
    for (const auto& [key,row] : state.rows) {
        if (row.team!=team||row.removed) continue;
        const auto id=text(row.data,"task_id");
        if (!id.empty()) parts[id].push_back(&row);
    }
    std::vector<TaskView> result;
    for (const auto* row : state.list(team,task)) result.push_back({row,std::move(parts[row->uid])});
    return result;
}
TaskView task_view(const Workspace& state,const Row& row) {
    TaskView result{&row,{}};
    for (const auto& [key,related] : state.rows)
        if (related.team==row.team&&!related.removed&&text(related.data,"task_id")==row.uid) result.parts.push_back(&related);
    return result;
}

void save_task(Workspace& state,const Account& account,Id team,const std::string& id,const Json& edit,bool create_history) {
    const auto old=state.get(team,task,id);
    const auto name=text(edit,"name");
    const auto start=number(edit,"start"), end=number(edit,"end");
    if (name.empty()||end<start) throw std::runtime_error("请填写任务标题和有效的开始、结束时间");
    const auto existing=old?task_view(state,*old):TaskView{};
    if (old&&history(state,*old).empty()) {
        auto snapshot=existing.snapshot(account.user,account.personal);
        snapshot["attachments"]=attachment_ids(state,*old);
        capture(state,account,*old,snapshot,"保存");
    }
    const auto& row=state.save(team,account.user,task,id,{{"name",name},{"rank",number(edit,"rank",1)},
        {"privacy",team==account.personal?6720:6728},{"project_id",text(edit,"project")},{"position_id",text(edit,"place")}});
    if (!old) state.save(team,account.user,assignee,new_id(assignee),{{"task_id",id},{"role",7680},{"sequence",0},{"status",0}});
    const auto previous_schedule=existing.one(schedule);
    const auto schedule_id=previous_schedule?previous_schedule->uid:new_id(schedule);
    const auto repeat_type=number(edit,"repeat");
    const auto old_repeat=existing.one(repeat);
    const bool keep_rule=old_repeat&&repeat_type==existing.repeat_kind()&&start==existing.start()&&
        number(edit,"repeatEnd")==number(old_repeat->data,"repeat_end");
    state.save(team,account.user,schedule,schedule_id,{{"task_id",id},{"start_at",start},{"end_at",end},
        {"is_all_day",field(edit,"allDay")==true?1:0},{"is_repeat",repeat_type>0&&start>0?1:0}});
    if (!keep_rule&&repeat_type>0&&start>0) {
        const auto day=date_value(local_date(start));
        const auto weekday_index=weekday(sys_days(day)).c_encoding();
        auto mask=std::string("0000000");
        mask[weekday_index]=static_cast<char>('1'+weekday_index);
        Json rule={{"task_id",id},{"schedule_id",schedule_id},{"repeat_start",start},{"repeat_end",number(edit,"repeatEnd")},
            {"repeat_count",0},{"status",0},{"repeat_start_day",0},{"repeat_start_week",0},{"repeat_start_month",0},
            {"repeat_start_year",0},{"day_interval",1},{"week_interval",1},{"month_interval",1},{"year_interval",1},
            {"month",0},{"day",0},{"weekday","0000000"}};
        if (repeat_type==1) { rule["repeat_start_day"]=timestamp(local_date(start),"00:00"); rule["day_interval"]=86400; }
        if (repeat_type==2||repeat_type==3) {
            rule["repeat_start_week"]=timestamp(shift_day(local_date(start),-static_cast<int>(weekday_index)),local_time(start));
            rule["week_interval"]=604800; rule["weekday"]=repeat_type==3?"0234560":mask;
        }
        if (repeat_type==4||repeat_type==5) {
            rule["repeat_start_year"]=int(day.year()); rule["day"]=unsigned(day.day());
            rule[repeat_type==4?"repeat_start_month":"month"]=unsigned(day.month());
        }
        state.save(team,account.user,repeat,old_repeat?old_repeat->uid:new_id(repeat),rule);
    } else if (old_repeat&&(repeat_type<=0||start<=0)) state.remove(*old_repeat);
    const auto old_alert=existing.one(alert,account.user);
    if (start>0&&number(edit,"alert",-1)>=0)
        state.save(team,account.user,alert,old_alert?old_alert->uid:new_id(alert),{{"task_id",id},{"schedule_id",schedule_id},
            {"alert_time",number(edit,"alert")},{"reminder_mode",text(edit,"reminderMode","both")}});
    else if(old_alert) state.remove(*old_alert);
    for(const auto& [kind,key]:std::array<std::pair<int,const char*>,2>{{{1,"review"},{2,"remark"}}}) {
        const Row* previous=nullptr;
        for(const auto* part:existing.parts) if(part->table==detail&&number(part->data,"type")==kind) previous=part;
        const auto content=text(edit,key);
        if(!content.empty()) state.save(team,account.user,detail,previous?previous->uid:new_id(detail),
            {{"task_id",id},{"type",kind},{"content",content}});
        else if(previous) state.remove(*previous);
    }
    if (field(edit,"children").is_array()) {
        auto remaining=linked(state,team,subtask,"task_id",id);
        int sequence=0;
        for(const auto& child:field(edit,"children")) {
            const auto title=child.get<std::string>();
            const auto found=std::ranges::find_if(remaining,[&](const auto* item){return text(item->data,"name")==title;});
            const auto child_id=found==remaining.end()?new_id(subtask):(*found)->uid;
            if(found!=remaining.end()) remaining.erase(found);
            state.save(team,account.user,subtask,child_id,{{"task_id",id},{"name",title},{"sequence",sequence++}});
        }
        for(const auto* item:remaining) state.remove(*item);
    }
    if (field(edit,"tags").is_array()) {
        auto remaining=linked(state,team,task_tag,"task_id",id);
        std::set<std::string> catalog;
        for (const auto* item : state.list(team,tag)) catalog.insert(text(item->data,"name"));
        for (const auto& value : field(edit,"tags")) {
            const auto tag_name=value.get<std::string>();
            if (catalog.insert(tag_name).second) state.save(team,account.user,tag,new_id(tag),{{"name",tag_name}});
            const auto found=std::ranges::find_if(remaining,[&](const auto* item){return text(item->data,"tag_name")==tag_name;});
            if(found!=remaining.end()) remaining.erase(found);
            else state.save(team,account.user,task_tag,new_id(task_tag),{{"task_id",id},{"tag_name",tag_name}});
        }
        for(const auto* item:remaining) state.remove(*item);
    }
    if(create_history) {
        auto snapshot=task_view(state,row).snapshot(account.user,account.personal);
        snapshot["attachments"]=attachment_ids(state,row);
        capture(state,account,row,snapshot,"保存");
    }
}

void toggle_task(Workspace& state,const Account& account,const Row& row,Id occurrence) {
    const auto* current=state.get(row.team,task,row.uid);
    if(!current||current->removed) return;
    const auto view=task_view(state,*current);
    const auto schedule_row=view.one(schedule);
    if(!schedule_row) return;
    if(const auto done=view.completed(account.user,occurrence)) state.remove(*done);
    else {
        const auto now=now_ms()/1000;
        state.save(row.team,account.user,check,new_id(check),{{"task_id",row.uid},{"schedule_id",schedule_row->uid},
            {"start_at",occurrence},{"begin_time",occurrence},{"check_at",now},{"cost_time",occurrence?std::max<Id>(0,now-occurrence):0},
            {"status",1},{"role",7680}});
    }
}

void save_bill(Workspace& state,const Account& account,Id team,const std::string& id,const Json& edit,bool create_history) {
    const auto old=state.get(team,bill,id);
    const auto type=text(edit,"type");
    if(text(edit,"name").empty()||text(edit,"channel").empty()||text(edit,"party").empty()||
        (type!="expense"&&type!="income"&&type!="transfer")) throw std::runtime_error("请填写账单事项、类型、途径和收支方");
    date_value(text(edit,"date"));
    if(old&&history(state,*old).empty()) capture(state,account,*old,bill_snapshot(state,*old),"保存");
    auto values=edit;
    values["amount"]=Amount::parse(text(edit,"amount")).format();
    if(old&&old->data.contains("legacy_include_in_totals")) values["legacy_include_in_totals"]="";
    const auto& row=state.save(team,account.user,bill,id,values);
    if(create_history) capture(state,account,row,bill_snapshot(state,row),"保存");
}

void delete_record(Workspace& state,const Account& account,const Row& row) {
    const auto* current=state.get(row.team,row.table,row.uid);
    if(!current||current->removed) return;
    if(row.table==task||row.table==bill) {
        auto snapshot=row.table==task?task_view(state,*current).snapshot(account.user,account.personal):bill_snapshot(state,*current);
        snapshot["attachments"]=attachment_ids(state,*current);
        capture(state,account,*current,snapshot,"删除");
    }
    if(row.table==note) for(const auto* child:linked(state,row.team,note_entry,"note_id",row.uid)) state.remove(*child);
    state.remove(*current);
}
std::vector<const Row*> history(const Workspace& state,const Row& row) {
    auto result=linked(state,row.team,row.table==task?task_version:bill_version,"parent_id",row.uid);
    std::ranges::sort(result,std::greater{},[](const Row* item){return number(item->data,"version_at");});
    return result;
}
void restore_version(Workspace& state,const Account& account,const Row& row,const Row& version) {
    auto snapshot=Json::parse(text(version.data,"snapshot"));
    const auto ids=field(snapshot,"attachments");
    snapshot.erase("attachments");
    if(row.table==task) {
        const auto* current=state.get(row.team,task,row.uid);
        if (!current||current->removed) throw std::runtime_error("任务已删除");
        const auto& reminder=data(task_view(state,*current).one(alert,account.user));
        if (!snapshot.contains("alert")) snapshot["alert"]=number(reminder,"alert_time",-1);
        if (!snapshot.contains("reminderMode")) snapshot["reminderMode"]=text(reminder,"reminder_mode","both");
        save_task(state,account,row.team,row.uid,snapshot,false);
        if(row.team==account.personal&&field(snapshot,"checks").is_array()) {
            const auto view=task_view(state,*state.get(row.team,task,row.uid));
            for (const auto* part : view.parts)
                if ((part->table==check||part->table==subcheck)&&number(part->data,"user_id")==account.user) state.remove(*part);
            const auto* schedule_row=view.one(schedule);
            for (const auto& item : field(snapshot,"checks")) if(item.is_array()&&item.size()==2&&schedule_row) {
                const auto started=item[0].get<Id>(),checked=item[1].get<Id>();
                state.save(row.team,account.user,check,new_id(check),{{"task_id",row.uid},{"schedule_id",schedule_row->uid},
                    {"start_at",started},{"begin_time",started},{"check_at",checked},
                    {"cost_time",started?std::max<Id>(0,checked-started):0},{"status",1},{"role",7680}});
            }
            auto children=linked(state,row.team,subtask,"task_id",row.uid);
            std::ranges::sort(children,{},[](const Row* child){return number(child->data,"sequence");});
            for (const auto& index : field(snapshot,"completedChildren")) if(index.is_number_unsigned()&&index.get<std::size_t>()<children.size())
                state.save(row.team,account.user,subcheck,new_id(subcheck),
                    {{"task_id",row.uid},{"child_task_id",children[index.get<std::size_t>()]->uid},{"status",1}});
        }
    } else {
        if (!snapshot.contains("currency")) snapshot["currency"]="CNY";
        if (!snapshot.contains("include_in_party_stats")) snapshot["include_in_party_stats"]=1;
        save_bill(state,account,row.team,row.uid,snapshot,false);
    }
    for(const auto* media:linked(state,row.team,row.table==task?task_attachment:bill_attachment,"note_id",row.uid)) {
        const auto found=ids.is_array()&&std::ranges::any_of(ids,[&](const auto& item){return item==media->uid;});
        state.save(row.team,account.user,media->table,media->uid,{{"detached",found?0:1}});
    }
    const auto* current=state.get(row.team,row.table,row.uid);
    auto recorded=row.table==task?task_view(state,*current).snapshot(account.user,account.personal):bill_snapshot(state,*current);
    recorded["attachments"]=attachment_ids(state,*current);
    capture(state,account,*current,recorded,"还原版本");
}

std::vector<Row> note_entries(const Workspace& state,const Row& note_row) {
    std::vector<Row> result;
    for(const auto* entry:linked(state,note_row.team,note_entry,"note_id",note_row.uid)) result.push_back(*entry);
    if (!number(note_row.data,"conversation_version")) {
        const auto base=std::to_string(note_row.team)+":"+note_row.uid+":";
        auto at=note_row.edited ? note_row.edited : timestamp(local_stamp(text(note_row.data,"created_at")).substr(0,10),"12:00")*1000;
        const auto title=text(note_row.data,"name");
        if(!title.empty()) result.push_back({note_entry,note_row.team,0,0,0,false,"50-"+sha256(base+"text"),
            {{"note_id",note_row.uid},{"kind","text"},{"content",title},{"entry_at",at}}});
        const auto media=Json::parse(text(note_row.data,"attachments","[]"),nullptr,false);
        if (media.is_array()) for (auto entry : media) {
            const auto id=text(entry,"id");
            if (id.empty()) continue;
            entry["note_id"]=note_row.uid;
            entry["entry_at"]=++at;
            entry["media_id"]=id;
            entry["client_media_id"]="remote-"+id;
            result.push_back({note_entry,note_row.team,0,0,0,false,"50-"+sha256(base+"media-"+id),std::move(entry)});
        }
    }
    std::ranges::sort(result,[](const auto& a,const auto& b){return std::tuple{number(a.data,"entry_at"),a.uid}<std::tuple{number(b.data,"entry_at"),b.uid};});
    return result;
}
std::string note_title(const Row& row) {
    const auto title=text(row.data,"title");
    if (!title.empty()) return title;
    const auto fallback=body_title(text(row.data,"name"));
    return fallback.empty()?"未命名便签":fallback;
}
void save_note(Workspace& state,const Account& account,Id team,const std::string& id,
    const std::string& section,const std::optional<std::string>& title,const std::vector<Row>& entries,
    const std::set<std::string>& removed,const std::vector<Row>& original_entries) {
    const auto previous=state.get(team,note,id);
    const bool migrate=previous&&!number(previous->data,"conversation_version");
    Json values={{"conversation_version",1}};
    if (!previous||migrate||title) {
        const auto name=title.value_or(previous?note_title(*previous):std::string{});
        values["name"]=values["title"]=name.empty()?(section.empty()?"新便签":"新记事本"):name;
    }
    if (!previous||migrate) values["attachments"]="[]";
    if (!previous) {
        values["status"]=0;
        if(section=="essence"||section=="core") values["notebook_section"]=section;
    }
    state.save(team,account.user,note,id,values);
    std::map<std::string,const Row*> originals;
    for(const auto& entry:original_entries) originals.emplace(entry.uid,&entry);
    for(const auto& entry:entries) {
        const auto old=state.get(team,note_entry,entry.uid);
        const auto initial=originals.find(entry.uid);
        if(initial==originals.end()||(migrate&&!old)) {
            auto payload=entry.data;
            payload["note_id"]=id;
            state.save(team,account.user,note_entry,entry.uid,payload);
        } else if(old&&!old->removed&&text(old->data,"note_id")==id) {
            Json patch=Json::object();
            for(const auto key:{"content","entry_at"})
                if(field(initial->second->data,key)!=field(entry.data,key)) patch[key]=field(entry.data,key);
            if(!patch.empty()) state.save(team,account.user,note_entry,entry.uid,patch);
        }
    }
    for(const auto& uid:removed) if(const auto row=state.get(team,note_entry,uid);row&&text(row->data,"note_id")==id) state.remove(*row);
}
}
