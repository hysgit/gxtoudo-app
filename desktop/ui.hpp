#pragma once
#include "records.hpp"
#include "server.hpp"
#include <windows.h>
#include <commctrl.h>

namespace todo::ui {
inline const UINT operation_finished=WM_APP+10;
extern HFONT ui_font;
extern HFONT title_font;
HWND control(HWND parent,const wchar_t* cls,const std::wstring& label,DWORD style,int id=0,DWORD extra=0);
std::wstring contents(HWND window);
void place(HWND control,int x,int y,int w,int h);
void add_choice(HWND combo,const std::wstring& text);
int choice(HWND combo);
std::optional<fs::path> choose_file(HWND owner,const wchar_t* filters);
std::optional<std::wstring> prompt(HWND owner,const std::wstring& title,const std::wstring& label,const std::wstring& initial={});
bool edit_record(HWND owner,const Store& store,const Account& account,Id team,int table,
    const std::string& id,const std::string& section);
void show_history(HWND owner,const Store& store,const Account& account,const Row& row);
void show_error(HWND owner,const std::exception& error);
}
