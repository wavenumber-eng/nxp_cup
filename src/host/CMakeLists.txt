cmake_minimum_required(VERSION 3.24)

if(APPLE AND "${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum supported macOS version" FORCE)
endif()

project(nxp_cup_host LANGUAGES CXX)

if(APPLE)
    enable_language(C OBJC OBJCXX)
endif()

set(NXPC_HOST_IMGUI_DIR
    "${CMAKE_CURRENT_LIST_DIR}/vendor/imgui"
    CACHE PATH
    "Local Dear ImGui v1.91.9b source directory")
set(NXPC_HOST_SDL2_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../common/egfx/test/sdl/sdl2/cmake"
    CACHE PATH
    "SDL2 CMake package directory")
set(NXPC_HOST_SDL2_ARCHIVE
    "${CMAKE_CURRENT_LIST_DIR}/vendor/sdl2/SDL2-2.26.5.tar.gz"
    CACHE PATH
    "Pinned SDL2 source archive used for the macOS static build")
set(NXPC_HOST_RBLHOST_DIR
    "${CMAKE_CURRENT_LIST_DIR}/vendor/rblhost"
    CACHE PATH
    "Pinned NXP rblhost v0.2.0 runtime directory")
option(NXPC_HOST_BUILD_VIEWER "Build the native Dear ImGui viewer" ON)
set(NXPC_HOST_VERSION "0.0.0" CACHE STRING "Native host bundle version")

if(WIN32)
    set(NXPC_RBLHOST_NAME "rblhost.exe")
elseif(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$")
    set(NXPC_RBLHOST_NAME "rblhost-macos-arm64")
else()
    message(FATAL_ERROR "The native host supports Windows x64 and macOS arm64 only")
endif()

if(NOT EXISTS "${NXPC_HOST_RBLHOST_DIR}/${NXPC_RBLHOST_NAME}" OR
   NOT EXISTS "${NXPC_HOST_RBLHOST_DIR}/LICENSE")
    message(FATAL_ERROR "Vendored NXP rblhost v0.2.0 executable/license not found")
endif()

add_library(nxpc_host_core STATIC nxpc_host_core.cpp)
target_compile_features(nxpc_host_core PUBLIC cxx_std_17)
target_include_directories(nxpc_host_core PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
target_sources(nxpc_host_core PRIVATE nxpc_programmer.cpp)
if(WIN32)
    target_link_libraries(nxpc_host_core PUBLIC setupapi advapi32 hid bcrypt)
elseif(APPLE)
    find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
    find_library(IOKIT_FRAMEWORK IOKit REQUIRED)
    target_link_libraries(nxpc_host_core PUBLIC
        "${COREFOUNDATION_FRAMEWORK}"
        "${IOKIT_FRAMEWORK}"
    )
endif()

add_executable(nxpc_tool nxpc_tool.cpp)
target_compile_features(nxpc_tool PRIVATE cxx_std_17)
target_link_libraries(nxpc_tool PRIVATE nxpc_host_core)

add_custom_command(TARGET nxpc_tool POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${NXPC_HOST_RBLHOST_DIR}/${NXPC_RBLHOST_NAME}"
        "$<TARGET_FILE_DIR:nxpc_tool>/$<IF:$<BOOL:${WIN32}>,rblhost.exe,rblhost>"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${NXPC_HOST_RBLHOST_DIR}/LICENSE"
        "$<TARGET_FILE_DIR:nxpc_tool>/rblhost-LICENSE.txt"
)

if(NXPC_HOST_BUILD_VIEWER)
    if(WIN32)
        find_package(SDL2 CONFIG REQUIRED PATHS "${NXPC_HOST_SDL2_DIR}" NO_DEFAULT_PATH)
        set(NXPC_SDL2_LIBRARIES ${SDL2_LIBRARIES})
        set(NXPC_SDL2_INCLUDE_DIRS ${SDL2_INCLUDE_DIRS})
    elseif(APPLE)
        if(NOT EXISTS "${NXPC_HOST_SDL2_ARCHIVE}")
            message(FATAL_ERROR
                "Pinned SDL2 source archive not found at ${NXPC_HOST_SDL2_ARCHIVE}")
        endif()
        include(FetchContent)
        set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
        set(SDL_SHARED OFF CACHE BOOL "" FORCE)
        set(SDL_STATIC ON CACHE BOOL "" FORCE)
        set(SDL_TEST OFF CACHE BOOL "" FORCE)
        FetchContent_Declare(nxpc_sdl2
            URL "${NXPC_HOST_SDL2_ARCHIVE}"
            URL_HASH
                "SHA256=ad8fea3da1be64c83c45b1d363a6b4ba8fd60f5bde3b23ec73855709ec5eabf7"
            DOWNLOAD_EXTRACT_TIMESTAMP FALSE
        )
        FetchContent_MakeAvailable(nxpc_sdl2)
        set(NXPC_SDL2_LIBRARIES SDL2-static)
        set(NXPC_SDL2_INCLUDE_DIRS "${nxpc_sdl2_SOURCE_DIR}/include")
    endif()

    set(IMGUI_DIR "${NXPC_HOST_IMGUI_DIR}")

    if(NOT EXISTS "${IMGUI_DIR}/imgui.h" OR NOT EXISTS "${IMGUI_DIR}/LICENSE.txt")
        message(FATAL_ERROR "Vendored Dear ImGui v1.91.9b source/license not found at ${IMGUI_DIR}")
    endif()

    if(WIN32)
        set(NXPC_VIEWER_PLATFORM_SOURCE nxpc_viewer_platform_windows.cpp)
    elseif(APPLE)
        set(NXPC_VIEWER_PLATFORM_SOURCE nxpc_viewer_platform_macos.mm)
    endif()

    add_executable(nxpc_viewer
        nxpc_viewer.cpp
        ${NXPC_VIEWER_PLATFORM_SOURCE}
        "${IMGUI_DIR}/imgui.cpp"
        "${IMGUI_DIR}/imgui_draw.cpp"
        "${IMGUI_DIR}/imgui_tables.cpp"
        "${IMGUI_DIR}/imgui_widgets.cpp"
        "${IMGUI_DIR}/backends/imgui_impl_sdl2.cpp"
        "${IMGUI_DIR}/backends/imgui_impl_sdlrenderer2.cpp"
    )
    if(APPLE)
        set_target_properties(nxpc_viewer PROPERTIES
            MACOSX_BUNDLE TRUE
            OUTPUT_NAME "NXP Cup Viewer"
            MACOSX_BUNDLE_BUNDLE_NAME "NXP Cup Viewer"
            MACOSX_BUNDLE_GUI_IDENTIFIER "com.wavenumber.nxpc.viewer"
            MACOSX_BUNDLE_BUNDLE_VERSION "${NXPC_HOST_VERSION}"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${NXPC_HOST_VERSION}"
            MACOSX_BUNDLE_INFO_STRING "NXP Cup camera and telemetry viewer"
        )
    endif()
    target_compile_features(nxpc_viewer PRIVATE cxx_std_17)
    target_compile_definitions(nxpc_viewer PRIVATE SDL_MAIN_HANDLED=1)
    target_include_directories(nxpc_viewer PRIVATE
        "${IMGUI_DIR}"
        "${IMGUI_DIR}/backends"
        ${NXPC_SDL2_INCLUDE_DIRS}
    )
    target_link_libraries(nxpc_viewer PRIVATE nxpc_host_core ${NXPC_SDL2_LIBRARIES})
    if(WIN32)
        target_link_libraries(nxpc_viewer PRIVATE comdlg32)
    elseif(APPLE)
        find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
        find_library(UNIFORMTYPEIDENTIFIERS_FRAMEWORK UniformTypeIdentifiers REQUIRED)
        target_link_libraries(nxpc_viewer PRIVATE
            "${APPKIT_FRAMEWORK}"
            "${UNIFORMTYPEIDENTIFIERS_FRAMEWORK}"
        )
    endif()
endif()

if(MSVC)
    target_compile_options(nxpc_host_core PRIVATE /W4 /WX /permissive-)
    target_compile_options(nxpc_tool PRIVATE /W4 /WX /permissive-)
    set_source_files_properties(nxpc_viewer.cpp PROPERTIES COMPILE_OPTIONS "/W4;/WX;/permissive-")
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(nxpc_host_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(nxpc_tool PRIVATE -Wall -Wextra -Wpedantic -Werror)
    if(WIN32)
        target_link_options(nxpc_tool PRIVATE -static)
    endif()
    if(NXPC_HOST_BUILD_VIEWER)
        if(WIN32)
            target_link_options(nxpc_viewer PRIVATE -static)
        endif()
        set_source_files_properties(nxpc_viewer.cpp PROPERTIES
            COMPILE_OPTIONS "-Wall;-Wextra;-Wpedantic;-Werror")
    endif()
endif()

if(NXPC_HOST_BUILD_VIEWER)
    if(WIN32)
        add_custom_command(TARGET nxpc_viewer POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${SDL2_BINDIR}/SDL2.dll"
                "$<TARGET_FILE_DIR:nxpc_viewer>/SDL2.dll"
        )
    endif()
    if(WIN32)
        add_custom_command(TARGET nxpc_viewer POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${NXPC_HOST_RBLHOST_DIR}/${NXPC_RBLHOST_NAME}"
                "$<TARGET_FILE_DIR:nxpc_viewer>/rblhost.exe"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${NXPC_HOST_RBLHOST_DIR}/LICENSE"
                "$<TARGET_FILE_DIR:nxpc_viewer>/rblhost-LICENSE.txt"
        )
    elseif(APPLE)
        add_custom_command(TARGET nxpc_viewer POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory
                "$<TARGET_BUNDLE_CONTENT_DIR:nxpc_viewer>/Resources/bin"
            COMMAND ${CMAKE_COMMAND} -E make_directory
                "$<TARGET_BUNDLE_CONTENT_DIR:nxpc_viewer>/Resources/licenses"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${NXPC_HOST_RBLHOST_DIR}/${NXPC_RBLHOST_NAME}"
                "$<TARGET_BUNDLE_CONTENT_DIR:nxpc_viewer>/Resources/bin/rblhost"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${NXPC_HOST_RBLHOST_DIR}/LICENSE"
                "$<TARGET_BUNDLE_CONTENT_DIR:nxpc_viewer>/Resources/licenses/rblhost-LICENSE.txt"
        )
    endif()
endif()
