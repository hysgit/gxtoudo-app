#include "server.hpp"
#include <windows.h>
#include <winhttp.h>
#include <algorithm>
#include <fstream>
#include <memory>
#include <set>
#include <stdexcept>

namespace todo {
namespace {
struct Url { std::wstring host; INTERNET_PORT port; std::string origin; };
Url parse_url(const std::string& url) {
    const auto input = wide(url);
    URL_COMPONENTS parts{sizeof(URL_COMPONENTS)};
    parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwUserNameLength = parts.dwPasswordLength = parts.dwExtraInfoLength = DWORD(-1);
    if (!WinHttpCrackUrl(input.c_str(),0,0,&parts) || parts.nScheme != INTERNET_SCHEME_HTTPS ||
        !parts.dwHostNameLength || parts.dwUserNameLength || parts.dwPasswordLength || parts.dwExtraInfoLength)
        throw std::runtime_error("请输入有效的 HTTPS 服务端地址");
    std::wstring_view path(parts.lpszUrlPath ? parts.lpszUrlPath : L"", parts.dwUrlPathLength);
    if (!path.empty() && path != L"/") throw std::runtime_error("服务端地址只填写域名和端口");
    std::wstring host(parts.lpszHostName,parts.dwHostNameLength);
    std::string origin = "https://" + utf8(host);
    if (parts.nPort != INTERNET_DEFAULT_HTTPS_PORT) origin += ":" + std::to_string(parts.nPort);
    return {host,parts.nPort,origin};
}

struct HttpCloser { void operator()(void* instance) const { if (instance) WinHttpCloseHandle(instance); } };
using Handle = std::unique_ptr<void,HttpCloser>;
struct Response { DWORD status{}; std::wstring type; std::string body; };
void check_http(BOOL success) {
    if (!success) throw std::runtime_error("网络请求失败 (" + std::to_string(GetLastError()) + ")");
}
Response request(const std::string& server, std::string_view route, const std::wstring& content_type,
    const std::string& body, std::size_t limit = 16 * 1024 * 1024, int timeout = 15000) {
    const auto url = parse_url(server);
    Handle session(WinHttpOpen(L"高效Todo Windows/7.8.6",WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0));
    check_http(static_cast<BOOL>(session != nullptr));
    check_http(WinHttpSetTimeouts(session.get(),5000,7000,timeout,timeout));
    Handle connection(WinHttpConnect(session.get(),url.host.c_str(),url.port,0));
    check_http(static_cast<BOOL>(connection != nullptr));
    const auto path = wide("/api/v7" + std::string(route));
    Handle handle(WinHttpOpenRequest(connection.get(),L"POST",path.c_str(),nullptr,WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE));
    check_http(static_cast<BOOL>(handle != nullptr));
    DWORD no_redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    check_http(WinHttpSetOption(handle.get(),WINHTTP_OPTION_REDIRECT_POLICY,&no_redirects,sizeof(no_redirects)));
    const auto header = L"Content-Type: " + content_type;
    check_http(WinHttpSendRequest(handle.get(),header.c_str(),static_cast<DWORD>(header.size()),
        const_cast<char*>(body.data()),static_cast<DWORD>(body.size()),static_cast<DWORD>(body.size()),0));
    check_http(WinHttpReceiveResponse(handle.get(),nullptr));
    Response response;
    DWORD length = sizeof(response.status);
    check_http(WinHttpQueryHeaders(handle.get(),WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX,&response.status,&length,WINHTTP_NO_HEADER_INDEX));
    wchar_t kind[128]{};
    length = sizeof(kind);
    if (WinHttpQueryHeaders(handle.get(),WINHTTP_QUERY_CONTENT_TYPE,WINHTTP_HEADER_NAME_BY_INDEX,kind,&length,WINHTTP_NO_HEADER_INDEX))
        response.type = kind;
    char buffer[65536];
    DWORD read = 0;
    do {
        check_http(WinHttpReadData(handle.get(),buffer,sizeof(buffer),&read));
        if (response.body.size()+read > limit) throw std::runtime_error("服务端响应超过大小限制");
        response.body.append(buffer,read);
    } while (read != 0);
    return response;
}
Json authenticated(const Account& account, Json values) {
    if (account.signed_in()) {
        values["user_id"]=account.user;
        values["login_id"]=account.login;
        values["token"]=account.token;
    }
    return values;
}
Json parse_reply(const Response& response) {
    if (response.status != 200) throw std::runtime_error("服务端返回 HTTP " + std::to_string(response.status));
    const auto result = Json::parse(response.body);
    if (text(result,"status")!="0") throw std::runtime_error(text(result,"message","服务端请求失败"));
    return result;
}
std::string escaped(std::string_view value) {
    std::string result;
    constexpr char digits[]="0123456789ABCDEF";
    for (const unsigned char byte : value) {
        if ((byte>='a'&&byte<='z')||(byte>='A'&&byte<='Z')||(byte>='0'&&byte<='9')||
            byte=='-'||byte=='_'||byte=='.'||byte=='~') result += static_cast<char>(byte);
        else { result += '%'; result += digits[byte>>4]; result += digits[byte&15]; }
    }
    return result;
}
std::string read_file(const fs::path& path) {
    const auto size=fs::file_size(path);
    if (size==0||size>100*1024*1024) throw std::runtime_error("附件大小应为 1 字节至 100 MB");
    std::string data(static_cast<std::size_t>(size),'\0');
    std::ifstream input(path,std::ios::binary);
    if (!input.read(data.data(),static_cast<std::streamsize>(data.size()))) throw std::runtime_error("无法读取附件");
    return data;
}
void write_file(const fs::path& target, std::string_view bytes) {
    fs::create_directories(target.parent_path());
    const auto temporary=fs::path(target.wstring()+L"."+wide(random_hex(8))+L".part");
    {
        std::ofstream output(temporary,std::ios::binary);
        output.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));
        if (!output) { output.close(); fs::remove(temporary); throw std::runtime_error("无法写入附件"); }
    }
    if (!MoveFileExW(temporary.c_str(),target.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) {
        fs::remove(temporary);
        throw std::runtime_error("无法提交附件");
    }
}
std::wstring extension(const Json& media) {
    const auto type=text(media,"content_type"), kind=text(media,"kind");
    if (type=="audio/wav") return L".wav";
    if (type=="audio/ogg") return L".ogg";
    if (type=="audio/mpeg") return L".mp3";
    if (type=="audio/mp4"||kind=="audio") return L".m4a";
    if (kind!="file") return L".image";
    auto result=fs::path(wide(text(media,"media_name"))).extension().wstring();
    if (result.size()<2||result.size()>13||!std::all_of(result.begin()+1,result.end(),[](wchar_t ch){
        return (ch>=L'A'&&ch<=L'Z')||(ch>=L'a'&&ch<=L'z')||(ch>=L'0'&&ch<=L'9');
    })) return L".bin";
    std::transform(result.begin(),result.end(),result.begin(),towlower);
    return result;
}
Json upload_attachment(const Account& account,const Row& row,const Json& media,const fs::path& path) {
    auto fields=authenticated(account,{{"team_id",row.team},{"note_id",text(row.data,"note_id")},
        {"kind",text(row.data,"kind")},{"parent_table",parent_table(row.table)},
        {"client_id",text(row.data,"client_media_id")},{"sha256",text(media,"sha256")}});
    const auto boundary="gxtodo-"+random_hex(16);
    std::string body;
    for (const auto& pair : fields.items())
        body += "--"+boundary+"\r\nContent-Disposition: form-data; name=\""+pair.key()+"\"\r\n\r\n"+text(fields,pair.key())+"\r\n";
    body += "--"+boundary+"\r\nContent-Disposition: form-data; name=\"file\"; filename=\"attachment\"\r\nContent-Type: application/octet-stream\r\n\r\n";
    body += read_file(path);
    body += "\r\n--"+boundary+"--\r\n";
    return field(parse_reply(request(account.server,"/media/upload",wide("multipart/form-data; boundary="+boundary),
        body,16*1024*1024,120000)),"data");
}
std::vector<Row> pending(const Workspace& data, const std::set<Id>& teams) {
    std::vector<Row> result;
    for (const auto& [key,row] : data.rows)
        if (row.pending && teams.contains(row.team) && (row.removed || !parent_table(row.table) ||
            text(row.data,"kind")=="text" || !text(row.data,"media_id").empty())) result.push_back(row);
    std::ranges::sort(result,{},&Row::edited);
    std::size_t bytes=0,count=0;
    while (count<result.size()&&count<300) {
        bytes+=result[count].upload().dump().size();
        if (bytes>8*1024*1024) break;
        ++count;
    }
    result.resize(count);
    return result;
}
}

std::string validate_server(const std::string& url) { return parse_url(url).origin; }
Json api(const std::string& server,const Account& account,std::string_view route,std::string_view method,Json values) {
    values=authenticated(account,std::move(values));
    if (method!="POST") values["_method"]=method;
    return parse_reply(request(server,route,L"application/json; charset=utf-8",values.dump()));
}
Grant login_start(const std::string& server,const std::string& device) {
    const auto verifier=random_hex(32).substr(0,43);
    const auto reply=api(server,{},"/desktop-login/start","POST",{{"challenge",sha256(verifier)},
        {"dev_id",device},{"label","Windows 桌面端"}});
    const auto grant=text(reply,"request");
    const auto validity=number(reply,"valid_seconds");
    if (grant.empty()||validity<=0||validity>600) throw std::runtime_error("服务端没有返回有效的登录二维码");
    return {grant,verifier,text(reply,"code"),"gxtodo://desktop-login?server="+escaped(server)+"&request="+escaped(grant),
        now_ms()+validity*1000};
}
std::optional<std::pair<Account,Json>> login_poll(const std::string& server,const Grant& grant) {
    const auto reply=api(server,{},"/desktop-login/poll","POST",{{"request",grant.request},{"verifier",grant.verifier}});
    if (text(reply,"state")!="complete") return {};
    auto spaces=field(reply,"teamData");
    if (!spaces.is_array()) throw std::runtime_error("服务端登录响应不完整");
    const auto& data=field(reply,"data");
    Account account{server,text(reply,"token"),text(data,"email"),text(data,"nickname"),number(reply,"user_id"),number(reply,"login_id")};
    for (const auto& space : spaces) if (number(space,"type")==1) account.personal=number(space,"id");
    if (!account.signed_in()) throw std::runtime_error("服务端登录响应不完整");
    return std::pair{std::move(account),std::move(spaces)};
}

void apply_page(Workspace& state,const std::vector<Row>& sent,const Json& reply) {
    for (const auto* key : {"data","down","down_extra"})
        if (!field(reply,key).is_array()) throw std::runtime_error("服务端同步响应不完整");
    std::map<std::string,const Row*> batch;
    for (const auto& row : sent)
        if (!batch.emplace(row.uid,&row).second) throw std::runtime_error("同步记录编号重复");
    for (const auto& ack : field(reply,"data")) {
        const auto uid=text(ack,"uid",text(ack,"id"));
        const auto record=batch.find(uid);
        const auto revision=number(ack,"entropy");
        if (record==batch.end()||number(ack,"status",-1)!=0||revision<=0) continue;
        auto& row=state.rows.at(record->second->key());
        row.revision=std::max(row.revision,revision);
        if (row.edited==record->second->edited) row.pending=0;
        else if (row.pending==1) row.pending=2;
        batch.erase(record);
    }
    if (!batch.empty()) throw std::runtime_error("服务端未确认全部改动，本机已保留");
    std::set<Id> teams;
    for (const auto& space : state.spaces) teams.insert(number(space,"id"));
    for (const auto& update : field(reply,"down")) {
        const auto table=static_cast<int>(number(update,"table_id"));
        const auto& data=field(update,"data");
        if (table==12) {
            for (auto& space : state.spaces) if (number(space,"id")==number(data,"id")&&!text(data,"name").empty()) space=data;
            continue;
        }
        if (!supported(table)) continue;
        const auto team=number(data,"team_id"), revision=number(update,"sync_entropy");
        const auto uid=text(data,"uid");
        if (!teams.contains(team)||uid.empty()||revision<=0) throw std::runtime_error("服务端下发了无效记录");
        const auto old=state.get(team,table,uid);
        if (old&&(old->pending||old->revision>revision)) continue;
        const auto removed=number(update,"edit_mode")==3;
        Row row{table,team,revision,removed ? number(data,"deleted_at") : (old ? old->edited : 0),0,removed,uid,data};
        state.rows.insert_or_assign(row.key(),row);
    }
    for (const auto& marker : field(reply,"down_extra")) {
        const auto team=number(marker,"team_id");
        if (!teams.contains(team)) continue;
        auto& cursor=state.cursors["t"+std::to_string(team)];
        cursor=std::max(cursor,number(marker,"entropy"));
    }
}

int synchronize(const Store& store,const Account& account) {
    if (!account.signed_in()) return 0;
    const auto teams=api(account.server,account,"/team/list","GET");
    if (!field(teams,"data").is_array()) throw std::runtime_error("服务端未返回空间列表");
    const auto scope=account.scope();
    auto state=store.change(scope,[&](Workspace& data) {
        if (data.cursors["ledger_version"]!=2||data.cursors["record_versions"]!=1||data.cursors["note_conversation_version"]!=1) {
            std::erase_if(data.cursors,[](const auto& pair){return pair.first.starts_with("t");});
            data.cursors["ledger_version"]=2;
            data.cursors["record_versions"]=1;
            data.cursors["note_conversation_version"]=1;
        }
        Json personal={{"id",account.personal},{"name","个人空间"},{"type",1},{"user_id",account.user}};
        for (const auto& space : data.spaces) if (number(space,"id")==account.personal) personal=space;
        data.spaces=Json::array({personal});
        for (const auto& space : field(teams,"data"))
            if (number(space,"id")>0&&number(space,"type")!=1) data.spaces.push_back(space);
    });
    std::set<Id> active;
    for (const auto& space : state.spaces) active.insert(number(space,"id"));
    bool media_failed=false;
    for (const auto& [key,row] : state.rows) {
        if (!active.contains(row.team)||row.removed||!parent_table(row.table)||text(row.data,"kind")=="text"||
            !text(row.data,"media_id").empty()) continue;
        const auto id=text(row.data,"client_media_id");
        const auto& media=field(state.media,id);
        const auto parent=state.get(row.team,parent_table(row.table),text(row.data,"note_id"));
        if (!parent||parent->removed) continue;
        try {
            const auto remote=upload_attachment(account,row,media,attachment_path(store,media));
            if (text(remote,"id").empty()||text(remote,"sha256")!=text(media,"sha256")||number(remote,"size")!=number(media,"size"))
                throw std::runtime_error("附件回执校验失败");
            store.change(scope,[&](Workspace& current){
                const auto local=current.get(row.team,row.table,row.uid);
                if (!local||local->removed||text(local->data,"client_media_id")!=id) return;
                const Json patch={{"media_id",text(remote,"id")},{"content_type",text(remote,"content_type")},
                    {"size",number(remote,"size")},{"sha256",text(remote,"sha256")}};
                current.media[id].update(patch);
                current.save(row.team,account.user,row.table,row.uid,patch);
            });
        } catch (const std::exception&) { media_failed=true; }
    }
    state=store.read(scope);
    int total=0;
    for(int page=0;page<250;++page) {
        const auto sent=pending(state,active);
        Json entropy=Json::object(), batch=Json::array();
        for(const auto team:active) entropy["t"+std::to_string(team)]=state.cursors["t"+std::to_string(team)];
        for(const auto& row:sent) batch.push_back(row.upload());
        const auto reply=api(account.server,account,"/sync/do","POST",{{"entropy",entropy},{"record_versions",1},
            {"bill_currency",1},{"_data",batch}});
        state=store.change(scope,[&](Workspace& current){apply_page(current,sent,reply);});
        total+=static_cast<int>(sent.size());
        const auto& markers=field(reply,"down_extra");
        if (!std::ranges::any_of(markers,[](const auto& marker){return number(marker,"remain")>0;})&&pending(state,active).empty()) {
            if (media_failed) throw std::runtime_error("文字已同步，附件会自动重试");
            return total;
        }
    }
    throw std::runtime_error("本轮同步达到分页上限，请再次同步");
}

fs::path attachment_path(const Store& store,const Json& media) {
    return store.root()/L"note-files"/(wide(sha256(text(media,"client_media_id")))+extension(media));
}
Json import_attachment(const Store& store,const fs::path& source,std::string_view kind,Id team,std::string_view parent) {
    const auto bytes=read_file(source);
    const auto ext=source.extension().wstring();
    const std::string type=kind=="file"?"application/octet-stream":kind!="audio"?"":ext==L".wav"?"audio/wav":ext==L".mp3"?"audio/mpeg":ext==L".ogg"?"audio/ogg":"audio/mp4";
    Json media={{"client_media_id","media-"+random_hex(16)},{"kind",kind},{"size",bytes.size()},{"sha256",sha256(bytes)},
        {"media_name",utf8(source.filename().wstring())},{"team_id",team},{"note_id",parent},{"local_ready",1},{"content_type",type}};
    write_file(attachment_path(store,media),bytes);
    return media;
}
fs::path open_attachment(const Store& store,const Account& account,const Json& media) {
    const auto path=attachment_path(store,media);
    if (fs::exists(path)) return path;
    const auto id=text(media,"media_id");
    if (id.empty()||!account.signed_in()) throw std::runtime_error("附件等待同步");
    const auto response=request(account.server,"/media/read",L"application/json",
        authenticated(account,{{"id",id}}).dump(),100*1024*1024,60000);
    if (response.status!=200||response.type.starts_with(L"application/json")) throw std::runtime_error("附件下载失败");
    const auto size=number(media,"size");
    const auto checksum=text(media,"sha256");
    if ((size>0&&static_cast<Id>(response.body.size())!=size)||(!checksum.empty()&&sha256(response.body)!=checksum))
        throw std::runtime_error("附件校验失败");
    write_file(path,response.body);
    return path;
}
}
