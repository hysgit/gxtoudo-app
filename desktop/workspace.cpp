#include "workspace.hpp"
#include <windows.h>
#include <bcrypt.h>
#include <shlobj.h>
#include <winsqlite/winsqlite3.h>
#include <algorithm>
#include <charconv>
#include <chrono>
#include <ctime>
#include <memory>
#include <set>
#include <stdexcept>

namespace todo {
std::wstring wide(std::string_view value) {
    if (value.empty()) return {};
    const auto count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (!count) throw std::runtime_error("无效 UTF-8");
    std::wstring output(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), output.data(), count);
    return output;
}

std::string utf8(std::wstring_view value) {
    if (value.empty()) return {};
    const auto count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!count) throw std::runtime_error("无效 UTF-16");
    std::string output(count, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), output.data(), count, nullptr, nullptr);
    return output;
}

const Json& field(const Json& value, std::string_view key) {
    static const Json empty;
    if (!value.is_object()) return empty;
    const auto found = value.find(key);
    return found == value.end() ? empty : found.value();
}
std::string text(const Json& value, std::string_view key, std::string fallback) {
    const auto& found = field(value, key);
    if (found.is_string()) return found.get<std::string>();
    return found.is_number() || found.is_boolean() ? found.dump() : std::move(fallback);
}
Id number(const Json& value, std::string_view key, Id fallback) {
    const auto& found = field(value, key);
    if (found.is_number_integer()) return found.get<Id>();
    if (!found.is_string()) return fallback;
    const auto& input = found.get_ref<const std::string&>();
    Id result{};
    const auto converted = std::from_chars(input.data(), input.data() + input.size(), result);
    return converted.ec == std::errc{} && converted.ptr == input.data() + input.size() ? result : fallback;
}

Id now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}
std::string stamp(Id ms) {
    const auto seconds = static_cast<time_t>(ms / 1000);
    std::tm utc{};
    gmtime_s(&utc, &seconds);
    char buffer[24]{};
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", &utc);
    return buffer;
}

static std::string hex(const std::vector<unsigned char>& bytes) {
    std::string result;
    result.reserve(bytes.size() * 2);
    for (const auto byte : bytes) {
        constexpr char digits[] = "0123456789abcdef";
        result += digits[byte >> 4];
        result += digits[byte & 15];
    }
    return result;
}
std::string random_hex(std::size_t count) {
    std::vector<unsigned char> bytes(count);
    if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
        throw std::runtime_error("系统随机数生成失败");
    return hex(bytes);
}
std::string sha256(std::string_view input) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
        throw std::runtime_error("无法初始化 SHA-256");
    std::vector<unsigned char> digest(32);
    const auto result = BCryptHash(algorithm, nullptr, 0,
        reinterpret_cast<PUCHAR>(const_cast<char*>(input.data())), static_cast<ULONG>(input.size()),
        digest.data(), static_cast<ULONG>(digest.size()));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (result < 0) throw std::runtime_error("SHA-256 校验失败");
    return hex(digest);
}
std::string new_id(int table) { return std::to_string(table) + "-" + random_hex(16); }

bool supported(int table) {
    static const std::set<int> tables{49,50,51,52,53,54,55,56,59,69,76,77,78,79,83,84,86,87,88,89,98,99};
    return tables.contains(table);
}
int parent_table(int table) {
    switch (table) {
    case note_entry: return note;
    case bill_attachment: return bill;
    case task_attachment: return task;
    default: return 0;
    }
}

std::string Account::scope() const { return signed_in() ? server + "/" + std::to_string(user) : "guest"; }
bool Account::signed_in() const { return user > 0 && login > 0 && personal > 0 && !token.empty(); }
Json Account::encode() const {
    return {{"server",server},{"token",token},{"email",email},{"nickname",nickname},{"user",user},{"login",login},{"personal",personal}};
}
Account Account::load(const Json& data) {
    return {text(data,"server"),text(data,"token"),text(data,"email"),text(data,"nickname"),
        number(data,"user"),number(data,"login"),number(data,"personal",-1)};
}

Row::Key Row::key() const { return {team,table,uid}; }
Json Row::encode() const {
    return {{"table",table},{"team",team},{"uid",uid},{"revision",revision},{"edited",edited},
        {"pending",pending},{"removed",removed},{"data",data}};
}
Json Row::upload() const {
    const Json payload = removed && table != task && table != bill
        ? Json{{"uid",uid},{"team_id",team},{"user_id",field(data,"user_id")}} : data;
    return {{"table",table},{"mode",pending},{"edit_time",edited},{"entropy",revision},{"data",payload}};
}
Row Row::load(const Json& data) {
    return {static_cast<int>(number(data,"table")),number(data,"team"),number(data,"revision"),number(data,"edited"),
        static_cast<int>(number(data,"pending")),field(data,"removed")==true,text(data,"uid"),field(data,"data")};
}

Workspace Workspace::load(const Json& payload) {
    Workspace result;
    if (field(payload,"items").is_array()) {
        for (const auto& item : field(payload,"items")) {
            auto row = Row::load(item);
            const auto key = row.key();
            result.rows.emplace(key,std::move(row));
        }
    }
    if (field(payload,"spaces").is_array()) result.spaces = field(payload,"spaces");
    if (field(payload,"media").is_object()) result.media = field(payload,"media");
    if (field(payload,"cursors").is_object())
        for (const auto& pair : field(payload,"cursors").items())
            result.cursors.emplace(pair.key(), number(field(payload,"cursors"),pair.key()));
    return result;
}
Json Workspace::encode() const {
    Json items = Json::array();
    for (const auto& [key,row] : rows) items.push_back(row.encode());
    return {{"items",std::move(items)},{"cursors",cursors},{"spaces",spaces},{"media",media}};
}
const Row* Workspace::get(Id team, int table, const std::string& uid) const {
    const auto it = rows.find({team,table,uid});
    return it == rows.end() ? nullptr : &it->second;
}
std::vector<const Row*> Workspace::list(Id team, int table) const {
    std::vector<const Row*> result;
    for (auto it = rows.lower_bound({team,table,{}}); it != rows.end() && it->second.team == team && it->second.table == table; ++it)
        if (!it->second.removed) result.push_back(&it->second);
    return result;
}
const Row& Workspace::save(Id team, Id user, int table, const std::string& uid, const Json& values, bool restore) {
    const auto previous = get(team,table,uid);
    if (previous && previous->removed && (!restore || (table != task && table != bill)))
        throw std::runtime_error("这条记录已删除");
    const auto edited = std::max(now_ms(), previous ? previous->edited + 1 : Id{0});
    Json data = previous ? previous->data : Json{{"created_at",stamp(edited)}};
    data.update(values);
    data["uid"] = uid;
    data["team_id"] = team;
    data["user_id"] = previous ? number(previous->data,"user_id",user) : number(values,"user_id",user);
    if (previous && !previous->removed && previous->data == data) return *previous;
    data["updated_at"] = stamp(edited);
    if (restore) data.erase("deleted_at");
    const int pending = previous && (previous->removed || previous->pending == 4) ? 4 : !previous || previous->pending == 1 ? 1 : 2;
    Row next{table,team,previous ? previous->revision : 0,edited,pending,false,uid,std::move(data)};
    const auto key = next.key();
    return rows.insert_or_assign(key,std::move(next)).first->second;
}
void Workspace::remove(const Row& row) {
    const auto it = rows.find(row.key());
    if (it == rows.end() || it->second.removed) return;
    it->second.removed = true;
    it->second.pending = 3;
    it->second.edited = std::max(now_ms(),it->second.edited+1);
}

namespace {
using Database = std::unique_ptr<sqlite3, decltype(&sqlite3_close)>;
using Query = std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)>;
void require(int code, sqlite3* db) { if (code != SQLITE_OK) throw std::runtime_error(db ? sqlite3_errmsg(db) : "无法打开本地数据库"); }
Database open(const fs::path& root) {
    sqlite3* raw = nullptr;
    const auto path = utf8((root/L"gxtodo.db").wstring());
    const auto status = sqlite3_open_v2(path.c_str(),&raw,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,nullptr);
    Database db(raw,sqlite3_close);
    require(status,raw);
    require(sqlite3_busy_timeout(raw,15000),raw);
    return db;
}
void sql(sqlite3* db,const char* statement) { require(sqlite3_exec(db,statement,nullptr,nullptr,nullptr),db); }
Query prepare(sqlite3* db,const char* statement) {
    sqlite3_stmt* raw=nullptr;
    require(sqlite3_prepare_v2(db,statement,-1,&raw,nullptr),db);
    return Query(raw,sqlite3_finalize);
}
void bind_text(sqlite3* db,sqlite3_stmt* stmt,int index,std::string_view value) {
    require(sqlite3_bind_text(stmt,index,value.data(),static_cast<int>(value.size()),SQLITE_TRANSIENT),db);
}
std::optional<std::string> get(sqlite3* db,const char* statement,std::string_view key) {
    const auto query=prepare(db,statement);
    bind_text(db,query.get(),1,key);
    const auto status=sqlite3_step(query.get());
    if (status==SQLITE_DONE) return {};
    if (status!=SQLITE_ROW) require(status,db);
    const auto data=sqlite3_column_text(query.get(),0);
    return std::string(reinterpret_cast<const char*>(data),sqlite3_column_bytes(query.get(),0));
}
Workspace read_workspace(sqlite3* db,std::string_view scope) {
    const auto payload=get(db,"SELECT payload FROM workspace WHERE scope=?1",scope);
    return payload ? Workspace::load(Json::parse(*payload)) : Workspace{};
}
}

Store::Store(fs::path root) : root_(std::move(root)) {
    fs::create_directories(root_);
    const auto db=open(root_);
    sql(db.get(),"CREATE TABLE IF NOT EXISTS workspace(scope TEXT PRIMARY KEY, payload TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS setting(key TEXT PRIMARY KEY, value TEXT NOT NULL);");
}
Workspace Store::read(std::string_view scope) const { const auto db=open(root_); return read_workspace(db.get(),scope); }
Workspace Store::change(std::string_view scope,const std::function<void(Workspace&)>& action) const {
    const auto db=open(root_);
    sql(db.get(),"BEGIN IMMEDIATE");
    try {
        auto workspace=read_workspace(db.get(),scope);
        action(workspace);
        const auto query=prepare(db.get(),"INSERT INTO workspace(scope,payload) VALUES(?1,?2) ON CONFLICT(scope) DO UPDATE SET payload=excluded.payload");
        bind_text(db.get(),query.get(),1,scope);
        bind_text(db.get(),query.get(),2,workspace.encode().dump());
        if (sqlite3_step(query.get()) != SQLITE_DONE) throw std::runtime_error(sqlite3_errmsg(db.get()));
        sql(db.get(),"COMMIT");
        return workspace;
    } catch (...) { sqlite3_exec(db.get(),"ROLLBACK",nullptr,nullptr,nullptr); throw; }
}
std::optional<std::string> Store::setting(std::string_view name) const {
    const auto db=open(root_);
    return get(db.get(),"SELECT value FROM setting WHERE key=?1",name);
}
void Store::setting(std::string_view name,std::optional<std::string_view> value) const {
    const auto db=open(root_);
    const auto query=prepare(db.get(),value ? "INSERT INTO setting(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        : "DELETE FROM setting WHERE key=?1");
    bind_text(db.get(),query.get(),1,name);
    if (value) bind_text(db.get(),query.get(),2,*value);
    if (sqlite3_step(query.get()) != SQLITE_DONE) throw std::runtime_error(sqlite3_errmsg(db.get()));
}
fs::path profile_path() {
    PWSTR roaming=nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData,0,nullptr,&roaming)))
        throw std::runtime_error("无法读取 Windows 个人数据目录");
    std::unique_ptr<wchar_t,decltype(&CoTaskMemFree)> path(roaming,CoTaskMemFree);
    return fs::path(path.get())/L"net.icycloud"/L"gxtodo";
}
}
