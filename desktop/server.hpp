#pragma once

#include "workspace.hpp"

namespace todo {
inline const std::string public_server = "https://tudosrv.woslx.com";
std::string validate_server(const std::string& url);
Json api(const std::string& server, const Account& account, std::string_view route,
    std::string_view method = "POST", Json values = Json::object());

struct Grant {
    std::string request, verifier, code, qr;
    Id expires{};
};
Grant login_start(const std::string& server, const std::string& device);
std::optional<std::pair<Account,Json>> login_poll(const std::string& server, const Grant& grant);
void apply_page(Workspace& state, const std::vector<Row>& sent, const Json& reply);
int synchronize(const Store& store, const Account& account);
fs::path attachment_path(const Store& store, const Json& media);
Json import_attachment(const Store& store, const fs::path& source, std::string_view kind, Id team, std::string_view parent);
fs::path open_attachment(const Store& store, const Account& account, const Json& media);
}
