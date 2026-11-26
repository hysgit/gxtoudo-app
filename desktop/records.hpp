#pragma once

#include "workspace.hpp"
#include <set>

namespace todo {
std::string local_date(Id seconds);
std::string local_time(Id seconds);
std::string today();
std::string local_stamp(std::string_view utc);
Id timestamp(std::string_view date, std::string_view time);
std::string shift_day(std::string_view date, int delta);

struct Amount {
    std::string digits{"0"};
    std::size_t scale{};
    static Amount parse(std::string_view text);
    Amount operator+(const Amount& other) const;
    std::string format() const;
};
std::string currency(const Row& row);
std::string bill_amount(const Amount& amount,std::string_view currency);
bool total_included(const Row& row);
bool party_included(const Row& row);

struct TaskView {
    const Row* row{};
    std::vector<const Row*> parts;
    const Row* one(int table, Id owner = -1) const;
    Id start() const;
    Id end() const;
    int repeat_kind() const;
    Id occurrence(const std::string& day) const;
    Id next(const std::string& today) const;
    const Row* completed(Id user, Id occurrence) const;
    Json snapshot(Id user, Id personal) const;
};
std::vector<TaskView> tasks(const Workspace& state, Id team);
TaskView task_view(const Workspace& state,const Row& row);
void save_task(Workspace& state,const Account& account,Id team,const std::string& id,const Json& edit,bool create_history=true);
void toggle_task(Workspace& state,const Account& account,const Row& row,Id occurrence);
void save_bill(Workspace& state,const Account& account,Id team,const std::string& id,const Json& edit,bool create_history=true);
void delete_record(Workspace& state,const Account& account,const Row& row);
void restore_version(Workspace& state,const Account& account,const Row& row,const Row& version);
std::vector<const Row*> history(const Workspace& state,const Row& row);
std::vector<Row> note_entries(const Workspace& state,const Row& note);
std::string note_title(const Row& note);
void save_note(Workspace& state,const Account& account,Id team,const std::string& id,
    const std::string& section,const std::optional<std::string>& title,const std::vector<Row>& entries,
    const std::set<std::string>& removed,const std::vector<Row>& original_entries={});
}
