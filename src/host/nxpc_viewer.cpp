#include "nxpc_host_core.hpp"
#include "nxpc_programmer.hpp"
#include "nxpc_viewer_platform.hpp"

#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_sdlrenderer2.h"
#include <SDL.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace
{

struct Options
{
    std::string port;
    uint32_t baud = 115200u;
    uint32_t test_seconds = 0u;
};

struct SharedState
{
    std::mutex mutex;
    std::string status = "Looking for NXP CUP TELEMETRY...";
    std::string error;
    std::string port;
    bool connected = false;
    uint64_t connection_count = 0u;
    nxpc_dbg_control_hello_response_t hello{};
    nxpc::host::Frame frame;
    nxpc::host::ParserCounters counters;
    std::vector<nxpc::host::LogRecord> logs;
    std::vector<nxpc::host::TelemetrySample> telemetry;
    bool rom_connected = false;
    bool program_requested = false;
    bool program_busy = false;
    bool program_waiting_reconnect = false;
    bool program_succeeded = false;
    std::string program_image_path;
    std::string program_status = "Ready";
    std::string program_detail;
    std::string program_error;
};

constexpr size_t kMaximumTelemetryRows = 128u;
constexpr float kUiFontSizePixels = 18.0f;
constexpr float kImGuiDefaultFontSizePixels = 13.0f;
constexpr float kCameraAspectRatio = 320.0f / 200.0f;

struct CameraAspectConstraint
{
    float title_height;
    float minimum_content_width;
    float minimum_content_height;
};

void constrain_camera_aspect(ImGuiSizeCallbackData *data)
{
    const auto *constraint = static_cast<const CameraAspectConstraint *>(data->UserData);
    const bool width_changed = std::fabs(data->DesiredSize.x - data->CurrentSize.x) > 0.5f;
    const bool height_changed = std::fabs(data->DesiredSize.y - data->CurrentSize.y) > 0.5f;

    if (width_changed || !height_changed)
    {
        data->DesiredSize.x = std::max(data->DesiredSize.x, constraint->minimum_content_width);
        data->DesiredSize.y = (data->DesiredSize.x / kCameraAspectRatio) + constraint->title_height;
    }
    else
    {
        const float content_height = std::max(data->DesiredSize.y - constraint->title_height,
                                              constraint->minimum_content_height);
        data->DesiredSize.y = content_height + constraint->title_height;
        data->DesiredSize.x = content_height * kCameraAspectRatio;
    }
}

float display_dpi_scale(int display_index)
{
#if defined(__APPLE__)
    // SDL window and ImGui display coordinates are already expressed in macOS
    // points. Scaling them again from the panel's physical DPI makes the
    // sidebar minimum heights exceed a Retina display's usable point height.
    (void)display_index;
    return 1.0f;
#else
    float diagonal_dpi = 96.0f;
    float horizontal_dpi = 96.0f;
    float vertical_dpi = 96.0f;
    if (SDL_GetDisplayDPI(display_index, &diagonal_dpi, &horizontal_dpi, &vertical_dpi) != 0)
    {
        return 1.0f;
    }

    return std::clamp(std::max(horizontal_dpi, vertical_dpi) / 96.0f, 1.0f, 3.0f);
#endif
}

void update_telemetry_rows(std::vector<nxpc::host::TelemetrySample> &rows,
                           const std::vector<nxpc::host::TelemetrySample> &samples)
{
    for (const nxpc::host::TelemetrySample &sample : samples)
    {
        const auto existing =
            std::find_if(rows.begin(), rows.end(), [&](const nxpc::host::TelemetrySample &row)
                         { return row.name == sample.name; });
        if (existing != rows.end())
        {
            *existing = sample;
        }
        else if (rows.size() < kMaximumTelemetryRows)
        {
            rows.push_back(sample);
        }
    }
}

uint32_t parse_u32(const std::string &text, const char *name)
{
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(text.c_str(), &end, 10);
    if (text.empty() || (end == nullptr) || (*end != '\0') || (parsed > 0xFFFFFFFFul))
    {
        throw std::runtime_error(std::string("invalid ") + name + ": " + text);
    }
    return static_cast<uint32_t>(parsed);
}

Options parse_args(int argc, char **argv)
{
    Options options;
    for (int index = 1; index < argc; ++index)
    {
        const std::string argument = argv[index];
        auto value = [&](const char *name) -> std::string
        {
            if (++index >= argc)
            {
                throw std::runtime_error(std::string("missing value for ") + name);
            }
            return argv[index];
        };

        if (argument == "--port")
        {
            options.port = value("--port");
        }
        else if (argument == "--baud")
        {
            options.baud = parse_u32(value("--baud"), "--baud");
        }
        else if (argument == "--test-seconds")
        {
            options.test_seconds = parse_u32(value("--test-seconds"), "--test-seconds");
        }
        else if ((argument == "--help") || (argument == "-h"))
        {
            std::printf("NXP Cup native camera and telemetry viewer\n\n"
                        "usage: nxpc_viewer [--port <device>] [--baud 115200]\n"
                        "                      [--test-seconds N]\n\n"
                        "Without --port, exactly one VID_1FC9/PID_0094 device must be present.\n");
            std::exit(0);
        }
        else
        {
            throw std::runtime_error("unknown argument: " + argument);
        }
    }
    return options;
}

void publish_status(SharedState &shared, const std::string &status, const std::string &error,
                    bool connected)
{
    std::lock_guard<std::mutex> lock(shared.mutex);
    shared.status = status;
    shared.error = error;
    shared.connected = connected;
    if (!connected)
    {
        shared.port.clear();
    }
}

bool send_and_wait(nxpc::host::SerialPort &port, nxpc::host::StreamParser &parser,
                   uint32_t sequence, uint32_t msg_id, uint32_t arg0, uint32_t arg1, uint32_t arg2,
                   nxpc::host::ControlResponse &response, std::string &error);

void publish_program_status(SharedState &shared, const std::string &status,
                            const std::string &detail = {})
{
    std::lock_guard<std::mutex> lock(shared.mutex);
    shared.program_status = status;
    shared.program_detail = detail;
}

void fail_program(SharedState &shared, const std::string &error)
{
    std::lock_guard<std::mutex> lock(shared.mutex);
    shared.program_busy = false;
    shared.program_waiting_reconnect = false;
    shared.program_succeeded = false;
    shared.program_status = "Programming failed";
    shared.program_error = error;
}

bool take_program_request(SharedState &shared, std::string &image_path)
{
    std::lock_guard<std::mutex> lock(shared.mutex);
    if (!shared.program_requested)
    {
        return false;
    }
    shared.program_requested = false;
    image_path = shared.program_image_path;
    return true;
}

bool wait_for_rom_device(SharedState &shared, std::string &error)
{
    publish_program_status(shared, "Waiting for MCXN947 ROM HID...");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline)
    {
        const std::vector<nxpc::host::HidDevice> devices = nxpc::host::find_hid_devices(
            nxpc::host::kNxpCupUsbVid, nxpc::host::kMcxn947RomPid, error);
        if (!error.empty())
        {
            return false;
        }
        if (devices.size() > 1u)
        {
            error = "multiple MCXN947 ROM HID devices found; refusing to guess";
            return false;
        }
        if (devices.size() == 1u)
        {
            std::lock_guard<std::mutex> lock(shared.mutex);
            shared.rom_connected = true;
            shared.status = "MCXN947 ROM connected";
            shared.error.clear();
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    error = "ROM HID did not appear within 5 seconds";
    return false;
}

bool run_programmer(const std::string &requested_image, SharedState &shared, std::string &error)
{
    publish_program_status(shared, "Validating firmware image...");
    nxpc::host::FirmwareImage image;
    if (!nxpc::host::validate_firmware_image(requested_image, image, error))
    {
        return false;
    }

    nxpc::host::ProgrammerTool programmer;
    if (!nxpc::host::resolve_programmer({}, programmer, error))
    {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(shared.mutex);
        shared.program_detail = std::to_string(image.bytes) + " bytes, SHA-256 " + image.sha256;
    }

    if (!nxpc::host::program_rom(
            programmer, image,
            [&](nxpc::host::ProgramStage stage, const std::string &detail)
            {
                publish_program_status(
                    shared, std::string("Programming: ") + nxpc::host::program_stage_name(stage),
                    detail);
            },
            error))
    {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(shared.mutex);
        shared.rom_connected = false;
        shared.program_waiting_reconnect = true;
        shared.program_status = "Programming complete; reconnecting...";
        shared.program_detail = image.sha256;
        shared.status = "Waiting for NXP CUP TELEMETRY to reconnect...";
        shared.error.clear();
    }
    return true;
}

bool handle_runtime_program_request(nxpc::host::SerialPort &port, nxpc::host::StreamParser &parser,
                                    const nxpc_dbg_control_hello_response_t &hello,
                                    const std::string &image_path, SharedState &shared)
{
    std::string error;
    publish_program_status(shared, "Validating firmware image...");
    nxpc::host::FirmwareImage image;
    if (!nxpc::host::validate_firmware_image(image_path, image, error))
    {
        fail_program(shared, error);
        return false;
    }

    nxpc::host::ProgrammerTool programmer;
    if (!nxpc::host::resolve_programmer({}, programmer, error))
    {
        fail_program(shared, error);
        return false;
    }
    if ((hello.capability_flags & NXPC_DBG_CAPABILITY_ENTER_ISP) == 0u)
    {
        fail_program(shared, "connected firmware does not advertise ENTER_ISP capability");
        return false;
    }

    publish_program_status(shared, "Entering ROM ISP...",
                           std::to_string(image.bytes) + " bytes, SHA-256 " + image.sha256);
    nxpc::host::ControlResponse response;
    if (!send_and_wait(port, parser, 2u, NXPC_DBG_CONTROL_ENTER_ISP,
                       NXPC_DBG_ENTER_ISP_CONFIRMATION, 0u, 0u, response, error))
    {
        fail_program(shared, error);
        return false;
    }
    if (response.status != NXPC_DBG_CONTROL_STATUS_OK)
    {
        fail_program(shared, "ENTER_ISP rejected with status " + std::to_string(response.status));
        return false;
    }

    port.close();
    publish_status(shared, "Entering MCXN947 ROM...", {}, false);
    if (!wait_for_rom_device(shared, error))
    {
        fail_program(shared, error);
        return false;
    }

    if (!nxpc::host::program_rom(
            programmer, image,
            [&](nxpc::host::ProgramStage stage, const std::string &detail)
            {
                publish_program_status(
                    shared, std::string("Programming: ") + nxpc::host::program_stage_name(stage),
                    detail);
            },
            error))
    {
        fail_program(shared, error);
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(shared.mutex);
        shared.rom_connected = false;
        shared.program_waiting_reconnect = true;
        shared.program_status = "Programming complete; reconnecting...";
        shared.program_detail = image.sha256;
        shared.status = "Waiting for NXP CUP TELEMETRY to reconnect...";
        shared.error.clear();
    }
    return true;
}

bool send_and_wait(nxpc::host::SerialPort &port, nxpc::host::StreamParser &parser,
                   uint32_t sequence, uint32_t msg_id, uint32_t arg0, uint32_t arg1, uint32_t arg2,
                   nxpc::host::ControlResponse &response, std::string &error)
{
    return nxpc::host::send_control_request(port, sequence, msg_id, arg0, arg1, arg2, error) &&
           nxpc::host::wait_for_control_response(port, parser, msg_id, sequence, 2000u, response,
                                                 error);
}

bool run_session(const Options &options, SharedState &shared, const std::atomic<bool> &running)
{
    std::string error;
    nxpc::host::SerialDevice device;
    if (!nxpc::host::select_unique_runtime_port(options.port, device, error))
    {
        publish_status(shared, "NXP CUP TELEMETRY disconnected", error, false);
        return false;
    }

    publish_status(shared, "Opening " + device.port_name + "...", {}, false);
    nxpc::host::SerialPort port;
    if (!port.open(device.port_name, options.baud, 16u * 1024u * 1024u, error))
    {
        publish_status(shared, "NXP CUP TELEMETRY disconnected", error, false);
        return false;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    if (!port.clear_input(error))
    {
        publish_status(shared, "NXP CUP TELEMETRY disconnected", error, false);
        return false;
    }

    nxpc::host::StreamParser parser;
    nxpc::host::ControlResponse response;
    if (!send_and_wait(port, parser, 0u, NXPC_DBG_CONTROL_HELLO, 0u, 0u, 0u, response, error))
    {
        publish_status(shared, "NXP CUP TELEMETRY did not answer HELLO", error, false);
        return false;
    }

    nxpc_dbg_control_hello_response_t hello{};
    if (!nxpc::host::decode_hello(response, hello, error))
    {
        publish_status(shared, "NXP CUP TELEMETRY rejected HELLO", error, false);
        return false;
    }

    constexpr uint32_t channels =
        NXPC_DBG_CHANNEL_FRAMES | NXPC_DBG_CHANNEL_LOGS | NXPC_DBG_CHANNEL_TELEMETRY;
    if (!send_and_wait(port, parser, 1u, NXPC_DBG_CONTROL_SET_CHANNELS, channels,
                       NXPC_DBG_STREAM_SOURCE_CAMERA, 0u, response, error) ||
        (response.status != NXPC_DBG_CONTROL_STATUS_OK))
    {
        if (error.empty())
        {
            error = "SET_CHANNELS rejected with status " + std::to_string(response.status);
        }
        publish_status(shared, "NXP CUP TELEMETRY stream setup failed", error, false);
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(shared.mutex);
        shared.status = "NXP CUP TELEMETRY connected";
        shared.error.clear();
        shared.port = device.port_name;
        shared.connected = true;
        ++shared.connection_count;
        shared.rom_connected = false;
        shared.hello = hello;
        if (shared.program_waiting_reconnect)
        {
            shared.program_waiting_reconnect = false;
            shared.program_busy = false;
            shared.program_succeeded = true;
            shared.program_status = "Programming complete; preview reconnected";
        }
    }

    std::vector<uint8_t> read_buffer(256u * 1024u);
    uint64_t published_generation = 0u;
    while (running.load())
    {
        std::string requested_image;
        if (take_program_request(shared, requested_image))
        {
            (void)handle_runtime_program_request(port, parser, hello, requested_image, shared);
            return false;
        }

        const int received =
            port.read(read_buffer.data(), static_cast<uint32_t>(read_buffer.size()), error);
        if (received < 0)
        {
            publish_status(shared, "NXP CUP TELEMETRY disconnected", error, false);
            return false;
        }
        if (received == 0)
        {
            continue;
        }

        parser.feed(read_buffer.data(), static_cast<size_t>(received));
        nxpc::host::Frame frame;
        const bool has_new_frame = parser.latest_frame(published_generation, frame);
        {
            std::lock_guard<std::mutex> lock(shared.mutex);
            if (has_new_frame)
            {
                published_generation = frame.generation;
                frame.generation = shared.frame.generation + 1u;
                shared.frame = std::move(frame);
            }
            shared.counters = parser.counters();
            shared.logs = parser.logs();
            shared.telemetry = parser.telemetry();
        }
    }

    // Best effort only: application unplug and shutdown remain recoverable.
    error.clear();
    (void)send_and_wait(port, parser, 2u, NXPC_DBG_CONTROL_SET_CHANNELS, 0u,
                        NXPC_DBG_STREAM_SOURCE_CAMERA, 0u, response, error);
    error.clear();
    (void)send_and_wait(port, parser, 3u, NXPC_DBG_CONTROL_CLOSE, 0u, 0u, 0u, response, error);
    publish_status(shared, "Viewer stopped", {}, false);
    return true;
}

void connection_worker(const Options &options, SharedState &shared,
                       const std::atomic<bool> &running)
{
    while (running.load())
    {
        (void)run_session(options, shared, running);

        std::string error;
        const std::vector<nxpc::host::HidDevice> rom_devices = nxpc::host::find_hid_devices(
            nxpc::host::kNxpCupUsbVid, nxpc::host::kMcxn947RomPid, error);
        {
            std::lock_guard<std::mutex> lock(shared.mutex);
            shared.rom_connected = error.empty() && (rom_devices.size() == 1u);
            if (shared.rom_connected && !shared.program_busy)
            {
                shared.status = "MCXN947 ROM connected";
                shared.error.clear();
            }
        }

        std::string requested_image;
        if (take_program_request(shared, requested_image))
        {
            if (!error.empty())
            {
                fail_program(shared, error);
            }
            else if (rom_devices.size() != 1u)
            {
                fail_program(shared, "expected exactly one MCXN947 ROM HID device; found " +
                                         std::to_string(rom_devices.size()));
            }
            else if (!run_programmer(requested_image, shared, error))
            {
                fail_program(shared, error);
            }
        }

        for (unsigned tick = 0u; running.load() && (tick < 10u); ++tick)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
}

void rgb565_to_rgba(const nxpc::host::Frame &frame, std::vector<uint8_t> &rgba)
{
    const size_t pixel_count = static_cast<size_t>(frame.width) * frame.height;
    rgba.assign(pixel_count * 4u, 255u);
    const size_t available = std::min(pixel_count, frame.pixels.size() / 2u);
    for (size_t index = 0u; index < available; ++index)
    {
        const uint16_t value = static_cast<uint16_t>(frame.pixels[index * 2u]) |
                               (static_cast<uint16_t>(frame.pixels[index * 2u + 1u]) << 8u);
        const uint8_t r5 = static_cast<uint8_t>((value >> 11u) & 0x1Fu);
        const uint8_t g6 = static_cast<uint8_t>((value >> 5u) & 0x3Fu);
        const uint8_t b5 = static_cast<uint8_t>(value & 0x1Fu);
        rgba[index * 4u + 0u] = static_cast<uint8_t>((r5 << 3u) | (r5 >> 2u));
        rgba[index * 4u + 1u] = static_cast<uint8_t>((g6 << 2u) | (g6 >> 4u));
        rgba[index * 4u + 2u] = static_cast<uint8_t>((b5 << 3u) | (b5 >> 2u));
    }
}

std::string telemetry_value(const nxpc::host::TelemetrySample &sample)
{
    switch (sample.value_type)
    {
    case NXPC_DBG_TELEMETRY_TYPE_I32:
        return std::to_string(static_cast<int32_t>(sample.value_bits));
    case NXPC_DBG_TELEMETRY_TYPE_U32:
        return std::to_string(sample.value_bits);
    case NXPC_DBG_TELEMETRY_TYPE_F32:
    {
        float value = 0.0f;
        std::memcpy(&value, &sample.value_bits, sizeof(value));
        char text[32]{};
        const char *format = (sample.units == "rpm") ? "%.0f" : "%.3f";
        std::snprintf(text, sizeof(text), format, static_cast<double>(value));
        return text;
    }
    case NXPC_DBG_TELEMETRY_TYPE_BOOL:
        return sample.value_bits != 0u ? "true" : "false";
    case NXPC_DBG_TELEMETRY_TYPE_TEXT:
        return sample.text_value;
    default:
        return "?";
    }
}

const char *log_level_name(uint8_t level)
{
    switch (level)
    {
    case NXPC_DBG_LOG_LEVEL_TRACE:
        return "TRACE";
    case NXPC_DBG_LOG_LEVEL_DEBUG:
        return "DEBUG";
    case NXPC_DBG_LOG_LEVEL_INFO:
        return "INFO";
    case NXPC_DBG_LOG_LEVEL_WARNING:
        return "WARN";
    case NXPC_DBG_LOG_LEVEL_ERROR:
        return "ERROR";
    default:
        return "?";
    }
}

std::string default_firmware_image_path()
{
    namespace fs = std::filesystem;
    const fs::path published_image =
        fs::path("out") / "artifacts" / "embedded" / "nxp_cup_core0.bin";

    std::error_code error;
    const fs::path working_directory = fs::current_path(error);
    if (!error)
    {
        const fs::path candidate = working_directory / published_image;
        if (fs::is_regular_file(candidate, error) && !error)
        {
            return candidate.string();
        }
    }

    std::string executable_error;
    const fs::path executable_path = nxpc::host::current_executable_path(executable_error);
    if (!executable_path.empty())
    {
        fs::path directory = executable_path.parent_path();
        for (size_t level = 0u; level < 8u; ++level)
        {
            error.clear();
            const fs::path candidate = directory / published_image;
            if (fs::is_regular_file(candidate, error) && !error)
            {
                return candidate.string();
            }

            const fs::path parent = directory.parent_path();
            if (parent == directory)
            {
                break;
            }
            directory = parent;
        }
    }

    return published_image.string();
}

int viewer_main(const Options &options)
{
    SDL_SetMainReady();
#if defined(_WIN32)
    (void)SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
#endif
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0)
    {
        throw std::runtime_error(std::string("SDL_Init failed: ") + SDL_GetError());
    }

    constexpr int display_index = 0;
    const float dpi_scale = display_dpi_scale(display_index);
    SDL_Rect usable_bounds{};
    const bool have_usable_bounds = SDL_GetDisplayUsableBounds(display_index, &usable_bounds) == 0;
    int initial_width = static_cast<int>((1000.0f * dpi_scale) + 0.5f);
    int initial_height = static_cast<int>((720.0f * dpi_scale) + 0.5f);
    if (have_usable_bounds)
    {
        initial_width = std::min(initial_width, static_cast<int>(usable_bounds.w * 0.95f));
        initial_height = std::min(initial_height, static_cast<int>(usable_bounds.h * 0.95f));
    }

    const uint32_t window_flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI |
                                  ((options.test_seconds > 0u) ? SDL_WINDOW_HIDDEN : 0u);
    SDL_Window *window =
        SDL_CreateWindow("NXP CUP TELEMETRY", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                         initial_width, initial_height, window_flags);
    if (window == nullptr)
    {
        const std::string error = SDL_GetError();
        SDL_Quit();
        throw std::runtime_error("SDL_CreateWindow failed: " + error);
    }

    SDL_Renderer *renderer =
        SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC | SDL_RENDERER_ACCELERATED);
    if (renderer == nullptr)
    {
        const std::string error = SDL_GetError();
        SDL_DestroyWindow(window);
        SDL_Quit();
        throw std::runtime_error("SDL_CreateRenderer failed: " + error);
    }

    float font_rasterizer_density = 1.0f;
#if defined(__APPLE__)
    // The SDL_Renderer ImGui backend scales clip rectangles for Retina output,
    // but SDL_RenderGeometryRaw coordinates only receive that same transform
    // when the renderer scale is set. Keep ImGui layout in macOS points and
    // let SDL apply the point-to-pixel transform to both geometry and clips.
    int window_width = 0;
    int window_height = 0;
    int output_width = 0;
    int output_height = 0;
    SDL_GetWindowSize(window, &window_width, &window_height);
    if ((SDL_GetRendererOutputSize(renderer, &output_width, &output_height) == 0) &&
        (window_width > 0) && (window_height > 0))
    {
        const float renderer_scale_x = static_cast<float>(output_width) / window_width;
        const float renderer_scale_y = static_cast<float>(output_height) / window_height;
        if (SDL_RenderSetScale(renderer, renderer_scale_x, renderer_scale_y) != 0)
        {
            const std::string error = SDL_GetError();
            SDL_DestroyRenderer(renderer);
            SDL_DestroyWindow(window);
            SDL_Quit();
            throw std::runtime_error("SDL_RenderSetScale failed: " + error);
        }
        font_rasterizer_density = std::max(renderer_scale_x, renderer_scale_y);
    }
#endif

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    ImFontConfig font_config;
    font_config.SizePixels = kUiFontSizePixels * dpi_scale;
    font_config.RasterizerDensity = font_rasterizer_density;
    io.Fonts->AddFontDefault(&font_config);
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes((kUiFontSizePixels / kImGuiDefaultFontSizePixels) * dpi_scale);
    ImGui_ImplSDL2_InitForSDLRenderer(window, renderer);
    ImGui_ImplSDLRenderer2_Init(renderer);

    SharedState shared;
    std::atomic<bool> running{true};
    std::thread worker(connection_worker, std::cref(options), std::ref(shared), std::cref(running));

    SDL_Texture *texture = nullptr;
    int texture_width = 0;
    int texture_height = 0;
    uint64_t rendered_generation = 0u;
    std::vector<uint8_t> rgba;
    nxpc::host::Frame display_frame;
    std::array<char, 1024> image_path{};
    const std::string default_image = default_firmware_image_path();
    std::snprintf(image_path.data(), image_path.size(), "%s", default_image.c_str());
    double stream_fps = 0.0;
    uint64_t rate_frame_count = 0u;
    uint64_t rate_session = 0u;
    uint32_t displayed_last_log_id = 0u;
    uint64_t displayed_log_session = 0u;
    std::vector<nxpc::host::TelemetrySample> telemetry_rows;
    auto fps_epoch = std::chrono::steady_clock::now();
    const auto test_deadline = fps_epoch + std::chrono::seconds(options.test_seconds);

    bool quit = false;
    while (!quit)
    {
        if ((options.test_seconds > 0u) && (std::chrono::steady_clock::now() >= test_deadline))
        {
            quit = true;
        }
        SDL_Event event{};
        while (SDL_PollEvent(&event) != 0)
        {
            ImGui_ImplSDL2_ProcessEvent(&event);
            if (event.type == SDL_QUIT)
            {
                quit = true;
            }
        }

        std::string status;
        std::string error;
        std::string port;
        bool connected = false;
        uint64_t connection_count = 0u;
        bool rom_connected = false;
        bool program_busy = false;
        bool program_succeeded = false;
        std::string program_status;
        std::string program_detail;
        std::string program_error;
        nxpc_dbg_control_hello_response_t hello{};
        nxpc::host::ParserCounters counters;
        std::vector<nxpc::host::LogRecord> logs;
        std::vector<nxpc::host::TelemetrySample> telemetry;
        {
            std::lock_guard<std::mutex> lock(shared.mutex);
            status = shared.status;
            error = shared.error;
            port = shared.port;
            connected = shared.connected;
            connection_count = shared.connection_count;
            rom_connected = shared.rom_connected;
            program_busy = shared.program_busy;
            program_succeeded = shared.program_succeeded;
            program_status = shared.program_status;
            program_detail = shared.program_detail;
            program_error = shared.program_error;
            hello = shared.hello;
            counters = shared.counters;
            logs = shared.logs;
            telemetry = shared.telemetry;
            if (shared.frame.generation > rendered_generation)
            {
                display_frame = shared.frame;
            }
        }

        update_telemetry_rows(telemetry_rows, telemetry);

        if (!connected && (texture != nullptr))
        {
            SDL_DestroyTexture(texture);
            texture = nullptr;
            texture_width = 0;
            texture_height = 0;
        }

        if (display_frame.generation > rendered_generation)
        {
            rendered_generation = display_frame.generation;
            if ((display_frame.pixel_format == NXPC_DBG_PIXEL_FORMAT_RGB565_LE) &&
                (display_frame.width > 0u) && (display_frame.height > 0u))
            {
                if ((texture == nullptr) || (texture_width != display_frame.width) ||
                    (texture_height != display_frame.height))
                {
                    if (texture != nullptr)
                    {
                        SDL_DestroyTexture(texture);
                    }
                    texture_width = display_frame.width;
                    texture_height = display_frame.height;
                    texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32,
                                                SDL_TEXTUREACCESS_STREAMING, texture_width,
                                                texture_height);
                }
                rgb565_to_rgba(display_frame, rgba);
                if (texture != nullptr)
                {
                    SDL_UpdateTexture(texture, nullptr, rgba.data(), texture_width * 4);
                }
            }
        }

        const auto now = std::chrono::steady_clock::now();
        const double fps_seconds = std::chrono::duration<double>(now - fps_epoch).count();
        if (connection_count != rate_session)
        {
            rate_session = connection_count;
            rate_frame_count = counters.frames;
            stream_fps = 0.0;
            fps_epoch = now;
        }
        else if (fps_seconds >= 1.0)
        {
            const uint64_t frame_delta = (counters.frames >= rate_frame_count)
                                             ? (counters.frames - rate_frame_count)
                                             : counters.frames;
            const double measured_fps = static_cast<double>(frame_delta) / fps_seconds;
            stream_fps =
                (stream_fps == 0.0) ? measured_fps : ((stream_fps * 0.75) + (measured_fps * 0.25));
            rate_frame_count = counters.frames;
            fps_epoch = now;
        }

        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        SDL_RenderClear(renderer);

        ImGui_ImplSDLRenderer2_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui::NewFrame();

        const ImVec2 display_size = ImGui::GetIO().DisplaySize;
        const float margin = 10.0f * dpi_scale;
        const float minimum_camera_width = 320.0f * dpi_scale;
        const float minimum_camera_height = 200.0f * dpi_scale;
        const float sidebar_width = std::min(340.0f * dpi_scale, display_size.x * 0.36f);
        const float camera_width =
            std::max(minimum_camera_width, display_size.x - sidebar_width - (3.0f * margin));
        const float panel_height = std::max(250.0f * dpi_scale, display_size.y - (2.0f * margin));
        const float status_height = std::max(260.0f * dpi_scale, panel_height * 0.44f);
        const float program_height = std::max(170.0f * dpi_scale, panel_height * 0.27f);
        const float camera_title_height =
            ImGui::GetFontSize() + (2.0f * ImGui::GetStyle().FramePadding.y);
        const float camera_height = (camera_width / kCameraAspectRatio) + camera_title_height;
        CameraAspectConstraint camera_constraint{camera_title_height, minimum_camera_width,
                                                 minimum_camera_height};

        ImGui::SetNextWindowPos(ImVec2(margin, margin), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(camera_width, camera_height), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSizeConstraints(
            ImVec2(minimum_camera_width, minimum_camera_height + camera_title_height),
            ImVec2(FLT_MAX, FLT_MAX), constrain_camera_aspect, &camera_constraint);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));
        ImGui::Begin("Camera", nullptr,
                     ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
        if (connected && (texture != nullptr) && (texture_width > 0) && (texture_height > 0))
        {
            const ImVec2 available = ImGui::GetContentRegionAvail();
            const float scale = std::min(available.x / static_cast<float>(texture_width),
                                         available.y / static_cast<float>(texture_height));
            const ImVec2 image_size(static_cast<float>(texture_width) * scale,
                                    static_cast<float>(texture_height) * scale);
            const ImVec2 cursor = ImGui::GetCursorPos();
            ImGui::SetCursorPos(
                ImVec2(cursor.x + std::max(0.0f, (available.x - image_size.x) * 0.5f),
                       cursor.y + std::max(0.0f, (available.y - image_size.y) * 0.5f)));
            ImGui::Image(reinterpret_cast<ImTextureID>(texture), image_size);
        }
        else
        {
            ImGui::SetWindowFontScale(1.5f);
            ImGui::TextWrapped("VIDEO DISCONNECTED");
            ImGui::SetWindowFontScale(1.0f);
            ImGui::Spacing();
            ImGui::TextWrapped("%s", status.c_str());
            if (!error.empty())
            {
                ImGui::TextWrapped("%s", error.c_str());
            }
        }
        ImGui::End();
        ImGui::PopStyleVar();

        const float sidebar_x = camera_width + 2.0f * margin;
        ImGui::SetNextWindowPos(ImVec2(sidebar_x, margin), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(sidebar_width, status_height), ImGuiCond_FirstUseEver);
        ImGui::Begin("NXP Cup status");
        if (connected)
        {
            ImGui::TextColored(ImVec4(0.35f, 1.0f, 0.45f, 1.0f), "%s", status.c_str());
            ImGui::Text("%s  %u x %u RGB565", port.c_str(), hello.frame_width, hello.frame_height);
            ImGui::Text("USB stream %.1f FPS", stream_fps);
        }
        else
        {
            ImGui::TextColored(ImVec4(1.0f, 0.35f, 0.35f, 1.0f), "%s", status.c_str());
            if (!error.empty())
            {
                ImGui::TextWrapped("%s", error.c_str());
            }
        }
        ImGui::Separator();
        ImGui::Text("Successful connections %llu",
                    static_cast<unsigned long long>(connection_count));
        ImGui::Text("Frames %llu", static_cast<unsigned long long>(counters.frames));
        ImGui::TextDisabled("Telemetry values (%zu)", telemetry_rows.size());
        const ImGuiTableFlags telemetry_table_flags =
            ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg | ImGuiTableFlags_Resizable |
            ImGuiTableFlags_ScrollY | ImGuiTableFlags_SizingStretchProp;
        if (ImGui::BeginTable("Telemetry values", 3, telemetry_table_flags, ImVec2(0.0f, 0.0f)))
        {
            ImGui::TableSetupScrollFreeze(0, 1);
            ImGui::TableSetupColumn("Name", ImGuiTableColumnFlags_WidthStretch, 0.54f);
            ImGui::TableSetupColumn("Value", ImGuiTableColumnFlags_WidthStretch, 0.29f);
            ImGui::TableSetupColumn("Units", ImGuiTableColumnFlags_WidthStretch, 0.17f);
            ImGui::TableHeadersRow();
            for (const nxpc::host::TelemetrySample &sample : telemetry_rows)
            {
                const std::string value = telemetry_value(sample);
                ImGui::TableNextRow();
                ImGui::TableSetColumnIndex(0);
                ImGui::TextUnformatted(sample.name.c_str());
                ImGui::TableSetColumnIndex(1);
                ImGui::TextUnformatted(value.c_str());
                ImGui::TableSetColumnIndex(2);
                ImGui::TextUnformatted(sample.units.c_str());
            }
            ImGui::EndTable();
        }
        ImGui::End();

        ImGui::SetNextWindowPos(ImVec2(sidebar_x, status_height + 2.0f * margin),
                                ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(sidebar_width, program_height), ImGuiCond_FirstUseEver);
        ImGui::Begin("Program firmware");
        ImGui::TextWrapped("Build first, then select the generated nxp_cup_core0.bin image.");
        const ImGuiStyle &style = ImGui::GetStyle();
        const float browse_button_width =
            ImGui::CalcTextSize("Browse...").x + (2.0f * style.FramePadding.x);
        const float available_program_width = ImGui::GetContentRegionAvail().x;
        const float minimum_path_width = 80.0f * dpi_scale;
        const bool browse_fits_inline =
            available_program_width >=
            (minimum_path_width + style.ItemSpacing.x + browse_button_width);
        if (browse_fits_inline)
        {
            ImGui::SetNextItemWidth(available_program_width - style.ItemSpacing.x -
                                    browse_button_width);
        }
        else
        {
            ImGui::SetNextItemWidth(-FLT_MIN);
        }
        ImGui::InputText("##Image", image_path.data(), image_path.size());
        if (browse_fits_inline)
        {
            ImGui::SameLine();
        }
        if (ImGui::Button("Browse...", ImVec2(browse_button_width, 0.0f)))
        {
            std::string selected_path = image_path.data();
            std::string dialog_error;
            if (nxpc::host::choose_firmware_image(selected_path, dialog_error))
            {
                std::snprintf(image_path.data(), image_path.size(), "%s", selected_path.c_str());
            }
            else if (!dialog_error.empty())
            {
                std::lock_guard<std::mutex> lock(shared.mutex);
                shared.program_error = dialog_error;
            }
        }
        const bool enter_isp_supported =
            connected && ((hello.capability_flags & NXPC_DBG_CAPABILITY_ENTER_ISP) != 0u);
        const bool target_available = enter_isp_supported || rom_connected;
        const bool can_program = target_available && !program_busy && (image_path[0] != '\0');
        ImGui::BeginDisabled(!can_program);
        if (ImGui::Button("Program and reconnect", ImVec2(-1.0f, 0.0f)))
        {
            std::lock_guard<std::mutex> lock(shared.mutex);
            shared.program_image_path = image_path.data();
            shared.program_requested = true;
            shared.program_busy = true;
            shared.program_waiting_reconnect = false;
            shared.program_succeeded = false;
            shared.program_status = "Programming request queued";
            shared.program_detail.clear();
            shared.program_error.clear();
        }
        ImGui::EndDisabled();

        if (!target_available && !program_busy)
        {
            ImGui::TextWrapped("Connect one NXP Cup runtime device or one MCXN947 ROM device.");
        }
        if (program_succeeded)
        {
            ImGui::TextColored(ImVec4(0.35f, 1.0f, 0.45f, 1.0f), "%s", program_status.c_str());
        }
        else
        {
            ImGui::TextWrapped("%s", program_status.c_str());
        }
        if (!program_detail.empty())
        {
            ImGui::TextWrapped("%s", program_detail.c_str());
        }
        if (!program_error.empty())
        {
            ImGui::TextColored(ImVec4(1.0f, 0.35f, 0.35f, 1.0f), "Error: %s",
                               program_error.c_str());
        }
        ImGui::End();

        const float debug_y = status_height + program_height + 3.0f * margin;
        ImGui::SetNextWindowPos(ImVec2(sidebar_x, debug_y), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(
            ImVec2(sidebar_width, std::max(120.0f, display_size.y - debug_y - margin)),
            ImGuiCond_FirstUseEver);
        ImGui::Begin("Debug log");
        ImGui::TextDisabled("Firmware NXPC_DBG_LOG_TEXT (%zu retained)", logs.size());
        ImGui::Separator();
        ImGui::BeginChild("Debug log records", ImVec2(0.0f, 0.0f));
        for (const nxpc::host::LogRecord &record : logs)
        {
            ImGui::TextWrapped(
                "%8lu  %-5s  [%s]  %s", static_cast<unsigned long>(record.timestamp_ms),
                log_level_name(record.level), record.category.c_str(), record.text.c_str());
        }
        const uint32_t last_log_id = logs.empty() ? 0u : logs.back().record_id;
        if ((last_log_id != displayed_last_log_id) || (connection_count != displayed_log_session))
        {
            ImGui::SetScrollHereY(1.0f);
            displayed_last_log_id = last_log_id;
            displayed_log_session = connection_count;
        }
        ImGui::EndChild();
        ImGui::End();

        ImGui::Render();
        ImGui_ImplSDLRenderer2_RenderDrawData(ImGui::GetDrawData(), renderer);
        SDL_RenderPresent(renderer);
    }

    running.store(false);
    if (worker.joinable())
    {
        worker.join();
    }
    bool test_passed = true;
    if (options.test_seconds > 0u)
    {
        std::lock_guard<std::mutex> lock(shared.mutex);
        test_passed = (shared.counters.frames > 0u) && (shared.counters.malformed == 0u);
        std::printf("viewer_test=%s connections=%llu frames=%llu malformed=%llu\n",
                    test_passed ? "ok" : "failed",
                    static_cast<unsigned long long>(shared.connection_count),
                    static_cast<unsigned long long>(shared.counters.frames),
                    static_cast<unsigned long long>(shared.counters.malformed));
    }
    if (texture != nullptr)
    {
        SDL_DestroyTexture(texture);
    }
    ImGui_ImplSDLRenderer2_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return test_passed ? 0 : 2;
}

} // namespace

int main(int argc, char **argv)
{
    try
    {
        return viewer_main(parse_args(argc, argv));
    }
    catch (const std::exception &exception)
    {
        std::fprintf(stderr, "error: %s\n", exception.what());
        return 1;
    }
}
