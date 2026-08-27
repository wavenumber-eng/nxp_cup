#include "nxpc_host_core.hpp"
#include "nxpc_programmer.hpp"

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace
{

struct Options
{
    std::string command = "probe";
    std::string port;
    std::string image;
    std::string programmer;
    uint32_t baud = 115200u;
    uint32_t seconds = 2u;
    bool request_frame = false;
};

void usage()
{
#if defined(_WIN32)
    constexpr const char *tool_name = "nxpc_tool.exe";
#else
    constexpr const char *tool_name = "nxpc_tool";
#endif
    std::cout
        << "NXP Cup one-cable host protocol probe\n\n"
        << "usage:\n"
        << "  " << tool_name << " devices\n"
        << "  " << tool_name << " selftest\n"
        << "  " << tool_name << " probe [--port <device>] [--frame] [--seconds 2]\n"
        << "  " << tool_name << " enter-isp [--port <device>]\n\n"
        << "  " << tool_name << " program --image <nxp_cup_core0.bin> [--port <device>]\n"
        << "                       [--programmer <path>]\n\n"
        << "probe auto-selects only when exactly one VID_1FC9/PID_0094 CDC device is present.\n";
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
    int index = 1;
    if ((index < argc) && (argv[index][0] != '-'))
    {
        options.command = argv[index++];
    }

    while (index < argc)
    {
        const std::string argument = argv[index++];
        auto value = [&](const char *name) -> std::string
        {
            if (index >= argc)
            {
                throw std::runtime_error(std::string("missing value for ") + name);
            }
            return argv[index++];
        };

        if ((argument == "-h") || (argument == "--help"))
        {
            usage();
            std::exit(0);
        }
        if (argument == "--port")
        {
            options.port = value("--port");
        }
        else if (argument == "--image")
        {
            options.image = value("--image");
        }
        else if ((argument == "--programmer") || (argument == "--blhost"))
        {
            options.programmer = value(argument.c_str());
        }
        else if (argument == "--baud")
        {
            options.baud = parse_u32(value("--baud"), "--baud");
        }
        else if (argument == "--seconds")
        {
            options.seconds = parse_u32(value("--seconds"), "--seconds");
        }
        else if (argument == "--frame")
        {
            options.request_frame = true;
        }
        else
        {
            throw std::runtime_error("unknown argument: " + argument);
        }
    }

    if ((options.command != "probe") && (options.command != "devices") &&
        (options.command != "selftest") && (options.command != "enter-isp"))
    {
        if (options.command != "program")
        {
            throw std::runtime_error("unknown command: " + options.command);
        }
    }
    return options;
}

std::string usb_id(uint16_t vid, uint16_t pid)
{
    std::ostringstream out;
    out << "VID_" << std::uppercase << std::hex << std::setw(4) << std::setfill('0') << vid
        << "/PID_" << std::setw(4) << pid;
    return out.str();
}

void print_devices()
{
    std::string error;
    const std::vector<nxpc::host::SerialDevice> devices = nxpc::host::list_serial_devices(error);
    if (!error.empty())
    {
        throw std::runtime_error(error);
    }
    if (devices.empty())
    {
        std::cout << "No present serial devices.\n";
    }
    else
    {
        for (const nxpc::host::SerialDevice &device : devices)
        {
            std::cout << device.port_name << "  " << usb_id(device.vid, device.pid) << "  "
                      << device.friendly_name << "\n";
            std::cout << "  " << device.instance_id << "\n";
        }
    }

    const std::vector<nxpc::host::HidDevice> rom_devices =
        nxpc::host::find_hid_devices(nxpc::host::kNxpCupUsbVid, nxpc::host::kMcxn947RomPid, error);
    if (!error.empty())
    {
        throw std::runtime_error(error);
    }
    if (rom_devices.empty())
    {
        std::cout << "MCXN947 ROM HID: not present\n";
    }
    for (const nxpc::host::HidDevice &device : rom_devices)
    {
        std::cout << "ROM HID  " << usb_id(device.vid, device.pid) << "  " << device.friendly_name
                  << "\n";
        std::cout << "  " << device.instance_id << "\n";
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
        std::ostringstream out;
        out << value;
        return out.str();
    }
    case NXPC_DBG_TELEMETRY_TYPE_BOOL:
        return sample.value_bits != 0u ? "true" : "false";
    case NXPC_DBG_TELEMETRY_TYPE_TEXT:
        return sample.text_value;
    default:
        return "?";
    }
}

bool send_and_wait(nxpc::host::SerialPort &port, nxpc::host::StreamParser &parser,
                   uint32_t sequence, uint32_t msg_id, uint32_t arg0, uint32_t arg1, uint32_t arg2,
                   nxpc::host::ControlResponse &response, std::string &error)
{
    return nxpc::host::send_control_request(port, sequence, msg_id, arg0, arg1, arg2, error) &&
           nxpc::host::wait_for_control_response(port, parser, msg_id, sequence, 2000u, response,
                                                 error);
}

int probe(const Options &options)
{
    std::string error;
    nxpc::host::SerialDevice device;
    if (!nxpc::host::select_unique_runtime_port(options.port, device, error))
    {
        throw std::runtime_error(error);
    }

    std::cout << "device=" << device.port_name << " " << usb_id(device.vid, device.pid) << " "
              << device.friendly_name << "\n";

    nxpc::host::SerialPort port;
    if (!port.open(device.port_name, options.baud, 16u * 1024u * 1024u, error))
    {
        throw std::runtime_error(error);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    if (!port.clear_input(error))
    {
        throw std::runtime_error(error);
    }

    nxpc::host::StreamParser parser;
    nxpc::host::ControlResponse response;
    if (!send_and_wait(port, parser, 0u, NXPC_DBG_CONTROL_HELLO, 0u, 0u, 0u, response, error))
    {
        throw std::runtime_error(error);
    }

    nxpc_dbg_control_hello_response_t hello{};
    if (!nxpc::host::decode_hello(response, hello, error))
    {
        throw std::runtime_error(error);
    }
    std::cout << "hello=ok\n"
              << "session_id=" << hello.session_id << "\n"
              << "capabilities=0x" << std::hex << std::setw(8) << std::setfill('0')
              << hello.capability_flags << std::dec << std::setfill(' ') << "\n"
              << "max_packet_bytes=" << hello.max_packet_bytes << "\n"
              << "frame=" << hello.frame_width << "x" << hello.frame_height
              << " format=" << hello.pixel_format << "\n";

    uint32_t channels = NXPC_DBG_CHANNEL_LOGS | NXPC_DBG_CHANNEL_TELEMETRY;
    if (options.request_frame)
    {
        channels |= NXPC_DBG_CHANNEL_FRAMES | NXPC_DBG_CHANNEL_STATS;
    }
    if (!send_and_wait(port, parser, 1u, NXPC_DBG_CONTROL_SET_CHANNELS, channels,
                       NXPC_DBG_STREAM_SOURCE_CAMERA, 0u, response, error))
    {
        throw std::runtime_error(error);
    }
    if (response.status != NXPC_DBG_CONTROL_STATUS_OK)
    {
        throw std::runtime_error("SET_CHANNELS rejected with status " +
                                 std::to_string(response.status));
    }
    std::cout << "channels=0x" << std::hex << std::setw(8) << std::setfill('0') << channels
              << std::dec << std::setfill(' ') << "\n";

    std::vector<uint8_t> read_buffer(256u * 1024u);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(options.seconds);
    nxpc::host::Frame frame;
    while (std::chrono::steady_clock::now() < deadline)
    {
        const int received =
            port.read(read_buffer.data(), static_cast<uint32_t>(read_buffer.size()), error);
        if (received < 0)
        {
            throw std::runtime_error(error);
        }
        if (received > 0)
        {
            parser.feed(read_buffer.data(), static_cast<size_t>(received));
        }
        if (options.request_frame && parser.latest_frame(0u, frame))
        {
            break;
        }
    }

    if (send_and_wait(port, parser, 2u, NXPC_DBG_CONTROL_SET_CHANNELS, 0u,
                      NXPC_DBG_STREAM_SOURCE_CAMERA, 0u, response, error) &&
        (response.status != NXPC_DBG_CONTROL_STATUS_OK))
    {
        error = "stop SET_CHANNELS rejected with status " + std::to_string(response.status);
    }
    if (!error.empty())
    {
        throw std::runtime_error(error);
    }

    if (!send_and_wait(port, parser, 3u, NXPC_DBG_CONTROL_CLOSE, 0u, 0u, 0u, response, error))
    {
        throw std::runtime_error(error);
    }
    if (response.status != NXPC_DBG_CONTROL_STATUS_OK)
    {
        throw std::runtime_error("CLOSE rejected with status " + std::to_string(response.status));
    }

    const nxpc::host::ParserCounters &count = parser.counters();
    std::cout << "packets=" << count.packets << "\n"
              << "frames=" << count.frames << "\n"
              << "stats=" << count.stats << "\n"
              << "logs=" << count.logs << "\n"
              << "telemetry=" << count.telemetry << "\n"
              << "malformed=" << count.malformed << "\n"
              << "resync_bytes=" << count.resync_bytes << "\n";

    if (options.request_frame)
    {
        if (frame.pixels.empty())
        {
            std::cerr << "No complete camera frame received.\n";
            return 2;
        }
        std::cout << "camera_frame=ok id=" << frame.frame_id << " bytes=" << frame.pixels.size()
                  << "\n";
    }

    nxpc_dbg_stats_report_t stats{};
    if (parser.latest_stats(stats))
    {
        std::cout << "device_frames_completed=" << stats.frames_completed << "\n"
                  << "device_frames_dropped=" << stats.frames_dropped << "\n"
                  << "device_send_errors=" << stats.send_error_count << "\n";
    }
    for (const nxpc::host::LogRecord &record : parser.logs())
    {
        std::cout << "log[" << record.category << "]=" << record.text << "\n";
    }
    for (const nxpc::host::TelemetrySample &sample : parser.telemetry())
    {
        std::cout << "telemetry[" << sample.name << "]=" << telemetry_value(sample);
        if (!sample.units.empty())
        {
            std::cout << " " << sample.units;
        }
        std::cout << "\n";
    }

    std::cout << "probe=ok\n";
    return count.malformed == 0u ? 0 : 3;
}

int enter_isp(const Options &options)
{
    std::string error;
    nxpc::host::SerialDevice device;
    if (!nxpc::host::select_unique_runtime_port(options.port, device, error))
    {
        throw std::runtime_error(error);
    }

    std::cout << "runtime_device=" << device.port_name << " " << usb_id(device.vid, device.pid)
              << "\n";
    nxpc::host::SerialPort port;
    if (!port.open(device.port_name, options.baud, 16u * 1024u * 1024u, error))
    {
        throw std::runtime_error(error);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    if (!port.clear_input(error))
    {
        throw std::runtime_error(error);
    }

    nxpc::host::StreamParser parser;
    nxpc::host::ControlResponse response;
    if (!send_and_wait(port, parser, 0u, NXPC_DBG_CONTROL_HELLO, 0u, 0u, 0u, response, error))
    {
        throw std::runtime_error(error);
    }

    nxpc_dbg_control_hello_response_t hello{};
    if (!nxpc::host::decode_hello(response, hello, error))
    {
        throw std::runtime_error(error);
    }
    if ((hello.capability_flags & NXPC_DBG_CAPABILITY_ENTER_ISP) == 0u)
    {
        throw std::runtime_error("firmware does not advertise ENTER_ISP capability");
    }

    if (!send_and_wait(port, parser, 1u, NXPC_DBG_CONTROL_ENTER_ISP,
                       NXPC_DBG_ENTER_ISP_CONFIRMATION, 0u, 0u, response, error))
    {
        throw std::runtime_error(error);
    }
    if (response.status != NXPC_DBG_CONTROL_STATUS_OK)
    {
        throw std::runtime_error("ENTER_ISP rejected with status " +
                                 std::to_string(response.status));
    }
    std::cout << "enter_isp_ack=ok session_id=" << hello.session_id << "\n";
    port.close();

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline)
    {
        const std::vector<nxpc::host::HidDevice> rom_devices = nxpc::host::find_hid_devices(
            nxpc::host::kNxpCupUsbVid, nxpc::host::kMcxn947RomPid, error);
        if (!error.empty())
        {
            throw std::runtime_error(error);
        }
        if (rom_devices.size() > 1u)
        {
            throw std::runtime_error("multiple MCXN947 ROM HID devices found; refusing to guess");
        }
        if (rom_devices.size() == 1u)
        {
            std::cout << "rom_device=" << usb_id(rom_devices[0].vid, rom_devices[0].pid)
                      << "\nenter_isp=ok\n";
            return 0;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    throw std::runtime_error(
        "ENTER_ISP was acknowledged, but ROM HID did not appear within 5 seconds");
}

int program(const Options &options)
{
    if (options.image.empty())
    {
        throw std::runtime_error("program requires --image <nxp_cup_core0.bin>");
    }

    std::string error;
    nxpc::host::FirmwareImage image;
    if (!nxpc::host::validate_firmware_image(options.image, image, error))
    {
        throw std::runtime_error(error);
    }
    nxpc::host::ProgrammerTool programmer;
    if (!nxpc::host::resolve_programmer(options.programmer, programmer, error))
    {
        throw std::runtime_error(error);
    }
    std::cout << "image=" << image.path << "\n"
              << "bytes=" << image.bytes << "\n"
              << "sha256=" << image.sha256 << "\n"
              << "initial_sp=0x" << std::hex << image.initial_sp << "\n"
              << "reset_pc=0x" << image.reset_pc << std::dec << "\n"
              << "programmer_backend=" << nxpc::host::programmer_backend_name(programmer.backend)
              << "\n"
              << "programmer=" << programmer.path << "\n";

    const std::vector<nxpc::host::HidDevice> rom_devices =
        nxpc::host::find_hid_devices(nxpc::host::kNxpCupUsbVid, nxpc::host::kMcxn947RomPid, error);
    if (!error.empty())
    {
        throw std::runtime_error(error);
    }
    const std::vector<nxpc::host::SerialDevice> runtime_devices = nxpc::host::find_serial_devices(
        nxpc::host::kNxpCupUsbVid, nxpc::host::kNxpCupRuntimePid, error);
    if (!error.empty())
    {
        throw std::runtime_error(error);
    }
    if ((rom_devices.size() == 1u) && runtime_devices.empty())
    {
        std::cout << "target=existing_rom_hid\n";
    }
    else if (rom_devices.empty() && !runtime_devices.empty())
    {
        nxpc::host::SerialDevice selected_runtime;
        if (!nxpc::host::select_unique_runtime_port(options.port, selected_runtime, error))
        {
            throw std::runtime_error(error);
        }
        std::cout << "target=runtime_cdc\n";
        if (enter_isp(options) != 0)
        {
            return 1;
        }
    }
    else
    {
        throw std::runtime_error("expected exactly one runtime CDC or one ROM HID; runtime=" +
                                 std::to_string(runtime_devices.size()) +
                                 " rom=" + std::to_string(rom_devices.size()));
    }

    if (!nxpc::host::program_rom(
            programmer, image,
            [](nxpc::host::ProgramStage stage, const std::string &detail)
            {
                std::cout << "program_stage=" << nxpc::host::program_stage_name(stage)
                          << " detail=" << detail << "\n";
            },
            error))
    {
        throw std::runtime_error(error);
    }

    Options verification = options;
    verification.command = "probe";
    verification.request_frame = true;
    verification.seconds = 3u;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    std::string reconnect_error = "runtime CDC has not appeared";
    for (;;)
    {
        try
        {
            const int result = probe(verification);
            if (result == 0)
            {
                std::cout << "program=ok\n";
                return 0;
            }
            reconnect_error = "runtime verification returned " + std::to_string(result);
        }
        catch (const std::exception &exception)
        {
            reconnect_error = exception.what();
        }
        if (std::chrono::steady_clock::now() >= deadline)
        {
            throw std::runtime_error(
                "programming completed, but application did not become ready: " + reconnect_error);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }
}

} // namespace

int main(int argc, char **argv)
{
    try
    {
        const Options options = parse_args(argc, argv);
        if (options.command == "devices")
        {
            print_devices();
            return 0;
        }
        if (options.command == "selftest")
        {
            std::string error;
            if (!nxpc::host::run_core_self_test(error))
            {
                std::cerr << "selftest=failed: " << error << "\n";
                return 1;
            }
            if (!nxpc::host::run_programmer_self_test(error))
            {
                std::cerr << "selftest=failed: " << error << "\n";
                return 1;
            }
            std::cout << "selftest=ok\n";
            return 0;
        }
        if (options.command == "enter-isp")
        {
            return enter_isp(options);
        }
        if (options.command == "program")
        {
            return program(options);
        }
        return probe(options);
    }
    catch (const std::exception &exception)
    {
        std::cerr << "error: " << exception.what() << "\n";
        return 1;
    }
}
