#pragma once

#include <nlohmann/json.hpp>
#include <filesystem>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

namespace todo {
using Json = nlohmann::json;
using Id = std::int64_t;
namespace fs = std::filesystem;

enum Table {
    note = 49, note_entry, bill, bill_attachment, bill_option, task_attachment, task_version, bill_version,
    tag = 59, place = 69, check = 76, alert, repeat, schedule, subcheck = 83, task_tag, detail = 86,
    subtask, assignee, task
};

std::wstring wide(std::string_view value);
std::string utf8(std::wstring_view value);
std::string text(const Json& value, std::string_view key, std::string fallback = {});
Id number(const Json& value, std::string_view key, Id fallback = 0);
const Json& field(const Json& value, std::string_view key);
Id now_ms();
std::string stamp(Id ms);
std::string random_hex(std::size_t count);
std::string sha256(std::string_view input);
std::string new_id(int table);
bool supported(int table);
int parent_table(int table);

struct Account {
    std::string server, token, email, nickname;
    Id user = 0, login = 0, personal = -1;
    std::string scope() const;
    bool signed_in() const;
    Json encode() const;
    static Account load(const Json& data);
};

struct Row {
    int table{};
    Id team{}, revision{}, edited{};
    int pending{};
    bool removed{};
    std::string uid;
    Json data = Json::object();
    using Key = std::tuple<Id, int, std::string>;
    Key key() const;
    Json encode() const;
    Json upload() const;
    static Row load(const Json& data);
};

struct Workspace {
    std::map<Row::Key, Row> rows;
    std::map<std::string, Id> cursors;
    Json spaces = Json::array();
    Json media = Json::object();
    Json encode() const;
    static Workspace load(const Json& payload);
    const Row* get(Id team, int table, const std::string& uid) const;
    std::vector<const Row*> list(Id team, int table) const;
    const Row& save(Id team, Id user, int table, const std::string& uid, const Json& values, bool restore = false);
    void remove(const Row& row);
};

class Store {
public:
    explicit Store(fs::path root);
    const fs::path& root() const { return root_; }
    Workspace read(std::string_view scope) const;
    Workspace change(std::string_view scope, const std::function<void(Workspace&)>& action) const;
    std::optional<std::string> setting(std::string_view name) const;
    void setting(std::string_view name, std::optional<std::string_view> value) const;
private:
    fs::path root_;
};

fs::path profile_path();
}
