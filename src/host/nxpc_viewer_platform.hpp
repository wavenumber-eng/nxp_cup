#pragma once

#include <filesystem>
#include <string>

namespace nxpc::host
{

bool choose_firmware_image(std::string &path, std::string &error);
std::filesystem::path current_executable_path(std::string &error);

} // namespace nxpc::host
