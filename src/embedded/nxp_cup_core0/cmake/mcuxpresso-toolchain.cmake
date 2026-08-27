# Arm bare-metal toolchain for the NXP Cup firmware build.
#
# Toolchain discovery order, highest priority first:
#   1. -DNXPC_ARM_TOOLCHAIN_DIR=<path to bin>
#   2. the NXPC_ARM_TOOLCHAIN_DIR environment variable
#   3. a standalone Arm GNU toolchain provisioned by setup.ps1 under
#      out/toolchains/arm-gnu-toolchain-*-arm-none-eabi/bin
#   4. the GCC bundled with MCUXpresso  (the byte-parity reference)
#
# setup.ps1 downloads the same Arm GNU version MCUXpresso 25.6 bundles
# (14.2.Rel1), so builds are comparable regardless of which is found.
# MCUXpresso is a fallback, not a requirement.

set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# --- 1/2/3: explicit, environment, or locally provisioned -------------------
if(NOT DEFINED NXPC_ARM_TOOLCHAIN_DIR)
    if(DEFINED ENV{NXPC_ARM_TOOLCHAIN_DIR})
        set(NXPC_ARM_TOOLCHAIN_DIR "$ENV{NXPC_ARM_TOOLCHAIN_DIR}")
    else()
        # Repository root is four levels up from src/embedded/nxp_cup_core0/cmake.
        get_filename_component(_nxpc_repo_root "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
        file(GLOB _nxpc_local_arm
            "${_nxpc_repo_root}/out/toolchains/arm-gnu-toolchain-*-arm-none-eabi/bin")
        if(_nxpc_local_arm)
            list(SORT _nxpc_local_arm ORDER DESCENDING)
            list(GET _nxpc_local_arm 0 NXPC_ARM_TOOLCHAIN_DIR)
        endif()
    endif()
endif()

if(NXPC_ARM_TOOLCHAIN_DIR)
    file(TO_CMAKE_PATH "${NXPC_ARM_TOOLCHAIN_DIR}" NXPC_ARM_TOOLCHAIN_DIR)
endif()

if(NOT DEFINED MCUXPRESSO_IDE)
    if(DEFINED ENV{MCUXPRESSO_IDE})
        set(MCUXPRESSO_IDE "$ENV{MCUXPRESSO_IDE}" CACHE PATH "MCUXpresso IDE directory")
    elseif(APPLE)
        set(MCUXPRESSO_IDE "/Applications/MCUXpressoIDE_25.6.136/ide" CACHE PATH "MCUXpresso IDE directory")
    elseif(WIN32)
        set(MCUXPRESSO_IDE "C:/nxp/MCUXpressoIDE_25.6.136/ide" CACHE PATH "MCUXpresso IDE directory")
    else()
        set(MCUXPRESSO_IDE "" CACHE PATH "MCUXpresso IDE directory")
    endif()
endif()

file(TO_CMAKE_PATH "${MCUXPRESSO_IDE}" MCUXPRESSO_IDE)

# The standalone toolchain, when present, is searched before MCUXpresso.
set(_MCUXPRESSO_TOOL_DIRS "")
if(NXPC_ARM_TOOLCHAIN_DIR)
    list(APPEND _MCUXPRESSO_TOOL_DIRS "${NXPC_ARM_TOOLCHAIN_DIR}")
endif()
list(APPEND _MCUXPRESSO_TOOL_DIRS "${MCUXPRESSO_IDE}/tools/bin")
if(EXISTS "${MCUXPRESSO_IDE}/plugins")
    file(GLOB _MCUXPRESSO_TOOL_PLUGINS LIST_DIRECTORIES true "${MCUXPRESSO_IDE}/plugins/com.nxp.mcuxpresso.tools.*_*")
    list(SORT _MCUXPRESSO_TOOL_PLUGINS ORDER DESCENDING)
    foreach(_plugin IN LISTS _MCUXPRESSO_TOOL_PLUGINS)
        list(APPEND _MCUXPRESSO_TOOL_DIRS "${_plugin}/tools/bin")
    endforeach()
endif()

function(_mcux_find_tool out_var tool_name description)
    find_program(
        ${out_var}
        NAMES "${tool_name}" "${tool_name}.exe"
        HINTS ${_MCUXPRESSO_TOOL_DIRS}
        NO_DEFAULT_PATH
    )
    if(NOT ${out_var})
        find_program(${out_var} NAMES "${tool_name}" "${tool_name}.exe")
    endif()
    if(NOT ${out_var})
        message(FATAL_ERROR
            "${description} not found.
"
            "Run the repository-root setup.sh on macOS or .\setup.ps1 on Windows to provision a standalone Arm GNU toolchain, "
            "or set NXPC_ARM_TOOLCHAIN_DIR to a toolchain bin directory, "
            "or set MCUXPRESSO_IDE to the MCUXpresso IDE 'ide' directory.")
    endif()
    set(${out_var} "${${out_var}}" CACHE FILEPATH "${description}" FORCE)
endfunction()

_mcux_find_tool(CMAKE_C_COMPILER "arm-none-eabi-gcc" "MCUXpresso Arm GCC")
set(CMAKE_ASM_COMPILER "${CMAKE_C_COMPILER}" CACHE FILEPATH "MCUXpresso Arm GCC assembler driver" FORCE)
_mcux_find_tool(CMAKE_OBJCOPY "arm-none-eabi-objcopy" "MCUXpresso objcopy")
_mcux_find_tool(CMAKE_SIZE "arm-none-eabi-size" "MCUXpresso size")
_mcux_find_tool(CMAKE_AR "arm-none-eabi-ar" "MCUXpresso ar")
_mcux_find_tool(CMAKE_RANLIB "arm-none-eabi-ranlib" "MCUXpresso ranlib")

get_filename_component(MCUXPRESSO_TOOLCHAIN_BIN "${CMAKE_C_COMPILER}" DIRECTORY)

set(CMAKE_FIND_ROOT_PATH "${MCUXPRESSO_TOOLCHAIN_BIN}/..")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
