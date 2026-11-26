#pragma once
#include "records.hpp"
#include "server.hpp"
#include <windows.h>
#include <commctrl.h>

namespace todo::ui {
inline const UINT operation_finished=WM_APP+10;
extern HFONT ui_font;
extern HFONT title_font;
extern HFONT label_font;
namespace theme {
inline constexpr COLORREF ink=RGB(25,43,37), muted=RGB(85,103,97), canvas=RGB(245,248,246),
    white=RGB(255,255,255), rail=RGB(23,48,41), rail_ink=RGB(224,237,231), rail_muted=RGB(166,192,180),
    accent=RGB(20,108,77), mint=RGB(201,240,219), tint=RGB(230,244,236), border=RGB(219,229,223),
    expense=RGB(151,57,53), income=RGB(16,109,75);
}
int pixels(HWND window,int units);
void fill(HDC dc,const RECT& bounds,COLORREF color);
void rounded(HDC dc,const RECT& bounds,int diameter,COLORREF color,COLORREF outline=CLR_INVALID);
void draw_button(const DRAWITEMSTRUCT& item,bool primary,bool on_rail=false,bool selected=false,const wchar_t* icon=nullptr,HFONT icons=nullptr);
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
