#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <commdlg.h>

#include "nxpc_viewer_platform.hpp"

#include <array>
#include <cstdio>

namespace nxpc::host
{

bool choose_firmware_image(std::string &path, std::string &error)
{
    std::array<char, 32768> selected{};
    std::snprintf(selected.data(), selected.size(), "%s", path.c_str());
    OPENFILENAMEA dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.lpstrFilter = "NXP Cup firmware image (*.bin)\0*.bin\0All files (*.*)\0*.*\0\0";
    dialog.lpstrFile = selected.data();
    dialog.nMaxFile = static_cast<DWORD>(selected.size());
    dialog.lpstrTitle = "Select an NXP Cup firmware image";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (GetOpenFileNameA(&dialog))
    {
        path = selected.data();
        error.clear();
        return true;
    }
    const DWORD code = CommDlgExtendedError();
    error = (code == 0u) ? std::string{} : "firmware file dialog failed: " + std::to_string(code);
    return false;
}

std::filesystem::path current_executable_path(std::string &error)
{
    std::array<wchar_t, 32768> path{};
    const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if ((length == 0u) || (length >= path.size()))
    {
        error = "cannot resolve viewer executable path";
        return {};
    }
    error.clear();
    return std::filesystem::path(path.data());
}

} // namespace nxpc::host
