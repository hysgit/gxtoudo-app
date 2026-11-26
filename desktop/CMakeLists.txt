cmake_minimum_required(VERSION 3.25)
project(gxtodo_desktop VERSION 7.8.7 LANGUAGES CXX RC)

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

include(FetchContent)
set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
FetchContent_Declare(nlohmann_json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG 65ee68451d8eb2b5f3a30b410476ab83deb3289b)
FetchContent_Declare(qrcodegen
  GIT_REPOSITORY https://github.com/nayuki/QR-Code-generator.git
  GIT_TAG 7ad95cedd8464a87f82221283612732ae4f3f305)
FetchContent_MakeAvailable(nlohmann_json qrcodegen)

add_library(todo_core STATIC workspace.cpp server.cpp records.cpp)
target_compile_features(todo_core PUBLIC cxx_std_20)
target_compile_definitions(todo_core PUBLIC UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(todo_core PUBLIC nlohmann_json::nlohmann_json winsqlite3 winhttp bcrypt shell32 ole32)

add_executable(gxtodo WIN32 window.cpp editor.cpp app.rc "${qrcodegen_SOURCE_DIR}/cpp/qrcodegen.cpp")
target_include_directories(gxtodo PRIVATE "${qrcodegen_SOURCE_DIR}/cpp")
target_link_libraries(gxtodo PRIVATE todo_core comctl32 dwmapi uxtheme comdlg32 winmm)

install(TARGETS gxtodo RUNTIME DESTINATION .)
install(FILES "${nlohmann_json_SOURCE_DIR}/LICENSE.MIT" DESTINATION licenses RENAME nlohmann-json.txt)
install(FILES "${qrcodegen_SOURCE_DIR}/Readme.markdown" DESTINATION licenses RENAME nayuki-qrcode.md)

if(MSVC)
  target_link_options(gxtodo PRIVATE /MANIFEST:NO)
  foreach(target todo_core gxtodo)
    target_compile_options(${target} PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/utf-8> $<$<COMPILE_LANGUAGE:CXX>:/W4> $<$<COMPILE_LANGUAGE:CXX>:/permissive->)
  endforeach()
endif()

include(CTest)
if(BUILD_TESTING)
  add_executable(todo_tests tests.cpp)
  target_link_libraries(todo_tests PRIVATE todo_core)
  if(MSVC)
    target_compile_options(todo_tests PRIVATE /utf-8 /W4 /permissive-)
  endif()
  add_test(NAME todo_core COMMAND todo_tests)
endif()
