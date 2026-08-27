#include "nxpc_host_core.hpp"

#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#include <hidsdi.h>
#include <setupapi.h>
#elif defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#else
#error "nxpc_host_core supports Windows and macOS only"
#endif

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <sstream>
#include <utility>

namespace nxpc::host
{
namespace
{

constexpr std::array<uint8_t, 4> kMagic = {'A', 'V', 'C', 'U'};
constexpr uint32_t kPacketPayloadMaxBytes = (16u * 1024u) - NXPC_DBG_PACKET_HEADER_BYTES;
constexpr uint32_t kFrameMaxBytes = 4u * 1024u * 1024u;
constexpr uint16_t kKnownPacketFlags = NXPC_DBG_PACKET_FLAG_RESPONSE | NXPC_DBG_PACKET_FLAG_MORE |
                                       NXPC_DBG_PACKET_FLAG_PAYLOAD_CRC32 |
                                       NXPC_DBG_PACKET_FLAG_DROPPED_BEFORE;
constexpr uint32_t kKnownChunkFlags =
    NXPC_DBG_RUI_CHUNK_FRAME_START | NXPC_DBG_RUI_CHUNK_FRAME_END | NXPC_DBG_RUI_CHUNK_STALE_OK;
constexpr size_t kRetainedRecords = 128u;

#if defined(_WIN32)
std::string win32_error(const std::string &operation)
{
    const DWORD code = GetLastError();
    LPSTR message = nullptr;
    (void)FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                             FORMAT_MESSAGE_IGNORE_INSERTS,
                         nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                         reinterpret_cast<LPSTR>(&message), 0u, nullptr);

    std::ostringstream out;
    out << operation << " failed (win32 " << code << ")";
    if (message != nullptr)
    {
        std::string detail(message);
        while (!detail.empty() && ((detail.back() == '\r') || (detail.back() == '\n')))
        {
            detail.pop_back();
        }
        if (!detail.empty())
        {
            out << ": " << detail;
        }
        LocalFree(message);
    }
    return out.str();
}
#endif

std::string upper_copy(std::string text)
{
    std::transform(text.begin(), text.end(), text.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return text;
}

#if defined(_WIN32)
std::string registry_string_property(HDEVINFO devices, SP_DEVINFO_DATA &info, DWORD property)
{
    std::array<char, 2048> buffer{};
    DWORD type = 0u;
    DWORD bytes = 0u;
    if (!SetupDiGetDeviceRegistryPropertyA(devices, &info, property, &type,
                                           reinterpret_cast<PBYTE>(buffer.data()),
                                           static_cast<DWORD>(buffer.size()), &bytes))
    {
        return {};
    }

    if (type == REG_MULTI_SZ)
    {
        std::string output;
        const size_t count = std::min<size_t>(bytes, buffer.size());
        for (size_t index = 0u; index < count; ++index)
        {
            if (buffer[index] == '\0')
            {
                if (!output.empty() && (output.back() != ' '))
                {
                    output.push_back(' ');
                }
            }
            else
            {
                output.push_back(buffer[index]);
            }
        }
        while (!output.empty() && (output.back() == ' '))
        {
            output.pop_back();
        }
        return output;
    }

    return std::string(buffer.data());
}

std::string port_name_for_device(HDEVINFO devices, SP_DEVINFO_DATA &info)
{
    HKEY key = SetupDiOpenDevRegKey(devices, &info, DICS_FLAG_GLOBAL, 0u, DIREG_DEV, KEY_READ);
    if (key == INVALID_HANDLE_VALUE)
    {
        return {};
    }

    std::array<char, 64> port{};
    DWORD type = 0u;
    DWORD bytes = static_cast<DWORD>(port.size());
    const LONG result = RegQueryValueExA(key, "PortName", nullptr, &type,
                                         reinterpret_cast<LPBYTE>(port.data()), &bytes);
    RegCloseKey(key);
    if ((result != ERROR_SUCCESS) || (type != REG_SZ) || (port[0] == '\0'))
    {
        return {};
    }
    return std::string(port.data());
}

bool parse_vid_pid(const std::string &hardware_id, uint16_t &vid, uint16_t &pid)
{
    const std::string upper = upper_copy(hardware_id);
    const size_t vid_at = upper.find("VID_");
    const size_t pid_at = upper.find("PID_");
    if ((vid_at == std::string::npos) || (pid_at == std::string::npos) ||
        ((vid_at + 8u) > upper.size()) || ((pid_at + 8u) > upper.size()))
    {
        return false;
    }

    char *end = nullptr;
    const unsigned long parsed_vid = std::strtoul(upper.c_str() + vid_at + 4u, &end, 16);
    if ((end != (upper.c_str() + vid_at + 8u)) || (parsed_vid > 0xFFFFul))
    {
        return false;
    }
    end = nullptr;
    const unsigned long parsed_pid = std::strtoul(upper.c_str() + pid_at + 4u, &end, 16);
    if ((end != (upper.c_str() + pid_at + 8u)) || (parsed_pid > 0xFFFFul))
    {
        return false;
    }

    vid = static_cast<uint16_t>(parsed_vid);
    pid = static_cast<uint16_t>(parsed_pid);
    return true;
}

std::string instance_id_for_device(HDEVINFO devices, SP_DEVINFO_DATA &info)
{
    std::array<char, 1024> value{};
    DWORD required = 0u;
    if (!SetupDiGetDeviceInstanceIdA(devices, &info, value.data(), static_cast<DWORD>(value.size()),
                                     &required))
    {
        return {};
    }
    return std::string(value.data());
}

std::string normalize_port_name(const std::string &port_name)
{
    if (port_name.rfind("\\\\.\\", 0u) == 0u)
    {
        return port_name;
    }
    return "\\\\.\\" + port_name;
}
#elif defined(__APPLE__)
std::string posix_error(const std::string &operation)
{
    return operation + " failed: " + std::strerror(errno);
}

std::string cf_string(CFTypeRef value)
{
    if ((value == nullptr) || (CFGetTypeID(value) != CFStringGetTypeID()))
    {
        return {};
    }
    const auto string = static_cast<CFStringRef>(value);
    const CFIndex length = CFStringGetLength(string);
    const CFIndex bytes = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::vector<char> buffer(static_cast<size_t>(bytes));
    if (!CFStringGetCString(string, buffer.data(), bytes, kCFStringEncodingUTF8))
    {
        return {};
    }
    return std::string(buffer.data());
}

uint32_t cf_number(CFTypeRef value)
{
    if ((value == nullptr) || (CFGetTypeID(value) != CFNumberGetTypeID()))
    {
        return 0u;
    }
    uint32_t result = 0u;
    (void)CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &result);
    return result;
}

CFTypeRef registry_property(io_registry_entry_t service, CFStringRef key)
{
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault,
                                           kIORegistryIterateRecursively |
                                               kIORegistryIterateParents);
}

std::string registry_string(io_registry_entry_t service, CFStringRef key)
{
    CFTypeRef value = registry_property(service, key);
    const std::string result = cf_string(value);
    if (value != nullptr)
    {
        CFRelease(value);
    }
    return result;
}

uint32_t registry_number(io_registry_entry_t service, CFStringRef key)
{
    CFTypeRef value = registry_property(service, key);
    const uint32_t result = cf_number(value);
    if (value != nullptr)
    {
        CFRelease(value);
    }
    return result;
}

std::string usb_hardware_id(uint16_t vid, uint16_t pid)
{
    std::ostringstream out;
    out << "VID_" << std::uppercase << std::hex;
    out.width(4);
    out.fill('0');
    out << vid << "&PID_";
    out.width(4);
    out << pid;
    return out.str();
}

int serial_fd(void *handle)
{
    return static_cast<int>(reinterpret_cast<intptr_t>(handle) - 1);
}

void *serial_handle(int fd)
{
    return reinterpret_cast<void *>(static_cast<intptr_t>(fd) + 1);
}
#endif

template <typename T> void append_object(std::vector<uint8_t> &bytes, const T &object)
{
    const auto *first = reinterpret_cast<const uint8_t *>(&object);
    bytes.insert(bytes.end(), first, first + sizeof(object));
}

template <typename T> void retain_bounded(std::vector<T> &records)
{
    if (records.size() > kRetainedRecords)
    {
        records.erase(records.begin(), records.begin() + static_cast<std::ptrdiff_t>(
                                                             records.size() - kRetainedRecords));
    }
}

} // namespace

std::vector<SerialDevice> list_serial_devices(std::string &error)
{
#if defined(_WIN32)
    error.clear();
    std::vector<SerialDevice> result;

    GUID ports_guid{};
    DWORD required = 0u;
    if (!SetupDiClassGuidsFromNameA("Ports", &ports_guid, 1u, &required) || (required == 0u))
    {
        error = win32_error("SetupDiClassGuidsFromNameA(Ports)");
        return result;
    }

    HDEVINFO devices = SetupDiGetClassDevsA(&ports_guid, nullptr, nullptr, DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE)
    {
        error = win32_error("SetupDiGetClassDevsA(Ports)");
        return result;
    }

    for (DWORD index = 0u;; ++index)
    {
        SP_DEVINFO_DATA info{};
        info.cbSize = sizeof(info);
        if (!SetupDiEnumDeviceInfo(devices, index, &info))
        {
            if (GetLastError() != ERROR_NO_MORE_ITEMS)
            {
                error = win32_error("SetupDiEnumDeviceInfo");
            }
            break;
        }

        SerialDevice device;
        device.port_name = port_name_for_device(devices, info);
        if (device.port_name.empty())
        {
            continue;
        }
        device.friendly_name = registry_string_property(devices, info, SPDRP_FRIENDLYNAME);
        if (device.friendly_name.empty())
        {
            device.friendly_name = registry_string_property(devices, info, SPDRP_DEVICEDESC);
        }
        device.hardware_id = registry_string_property(devices, info, SPDRP_HARDWAREID);
        device.instance_id = instance_id_for_device(devices, info);
        (void)parse_vid_pid(device.hardware_id, device.vid, device.pid);
        result.push_back(std::move(device));
    }

    SetupDiDestroyDeviceInfoList(devices);
    return result;
#elif defined(__APPLE__)
    error.clear();
    std::vector<SerialDevice> result;
    CFMutableDictionaryRef matching = IOServiceMatching(kIOSerialBSDServiceValue);
    if (matching == nullptr)
    {
        error = "IOServiceMatching(IOSerialBSDClient) failed";
        return result;
    }
    CFDictionarySetValue(matching, CFSTR(kIOSerialBSDTypeKey), CFSTR(kIOSerialBSDAllTypes));

    io_iterator_t iterator = IO_OBJECT_NULL;
    const kern_return_t status =
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (status != KERN_SUCCESS)
    {
        error = "IOServiceGetMatchingServices(serial) failed: " + std::to_string(status);
        return result;
    }

    for (io_object_t service = IOIteratorNext(iterator); service != IO_OBJECT_NULL;
         service = IOIteratorNext(iterator))
    {
        SerialDevice device;
        CFTypeRef path = IORegistryEntryCreateCFProperty(service, CFSTR(kIOCalloutDeviceKey),
                                                         kCFAllocatorDefault, 0u);
        device.port_name = cf_string(path);
        if (path != nullptr)
        {
            CFRelease(path);
        }
        if (!device.port_name.empty())
        {
            device.friendly_name = registry_string(service, CFSTR("USB Product Name"));
            if (device.friendly_name.empty())
            {
                device.friendly_name = registry_string(service, CFSTR(kIOTTYDeviceKey));
            }
            device.vid = static_cast<uint16_t>(registry_number(service, CFSTR("idVendor")));
            device.pid = static_cast<uint16_t>(registry_number(service, CFSTR("idProduct")));
            device.hardware_id = usb_hardware_id(device.vid, device.pid);
            device.instance_id = registry_string(service, CFSTR("USB Serial Number"));
            if (device.instance_id.empty())
            {
                uint64_t registry_id = 0u;
                if (IORegistryEntryGetRegistryEntryID(service, &registry_id) == KERN_SUCCESS)
                {
                    device.instance_id = "IOService:" + std::to_string(registry_id);
                }
            }
            result.push_back(std::move(device));
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return result;
#endif
}

std::vector<SerialDevice> find_serial_devices(uint16_t vid, uint16_t pid, std::string &error)
{
    const std::vector<SerialDevice> devices = list_serial_devices(error);
    std::vector<SerialDevice> matches;
    if (!error.empty())
    {
        return matches;
    }
    for (const SerialDevice &device : devices)
    {
        if ((device.vid == vid) && (device.pid == pid))
        {
            matches.push_back(device);
        }
    }
    return matches;
}

bool select_unique_runtime_port(const std::string &requested_port, SerialDevice &selected,
                                std::string &error)
{
    const std::vector<SerialDevice> devices = list_serial_devices(error);
    if (!error.empty())
    {
        return false;
    }

    if (!requested_port.empty())
    {
        for (const SerialDevice &device : devices)
        {
            if (upper_copy(device.port_name) == upper_copy(requested_port))
            {
                if ((device.vid != kNxpCupUsbVid) || (device.pid != kNxpCupRuntimePid))
                {
                    error = requested_port +
                            " is not an NXP Cup runtime device (expected VID_1FC9/PID_0094)";
                    return false;
                }
                selected = device;
                return true;
            }
        }
        error = "requested port " + requested_port + " is not present";
        return false;
    }

    std::vector<SerialDevice> matches;
    for (const SerialDevice &device : devices)
    {
        if ((device.vid == kNxpCupUsbVid) && (device.pid == kNxpCupRuntimePid))
        {
            matches.push_back(device);
        }
    }

    if (matches.empty())
    {
        error = "no NXP Cup runtime CDC device found (VID_1FC9/PID_0094)";
        return false;
    }
    if (matches.size() != 1u)
    {
        std::ostringstream message;
        message << matches.size() << " NXP Cup runtime devices found; select one with --port:";
        for (const SerialDevice &device : matches)
        {
            message << " " << device.port_name;
        }
        error = message.str();
        return false;
    }

    selected = matches.front();
    return true;
}

std::vector<HidDevice> list_hid_devices(std::string &error)
{
#if defined(_WIN32)
    error.clear();
    std::vector<HidDevice> result;
    GUID hid_guid{};
    HidD_GetHidGuid(&hid_guid);
    HDEVINFO devices =
        SetupDiGetClassDevsA(&hid_guid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devices == INVALID_HANDLE_VALUE)
    {
        error = win32_error("SetupDiGetClassDevsA(HID)");
        return result;
    }

    for (DWORD index = 0u;; ++index)
    {
        SP_DEVICE_INTERFACE_DATA interface_data{};
        interface_data.cbSize = sizeof(interface_data);
        if (!SetupDiEnumDeviceInterfaces(devices, nullptr, &hid_guid, index, &interface_data))
        {
            if (GetLastError() != ERROR_NO_MORE_ITEMS)
            {
                error = win32_error("SetupDiEnumDeviceInterfaces(HID)");
            }
            break;
        }

        DWORD required = 0u;
        (void)SetupDiGetDeviceInterfaceDetailA(devices, &interface_data, nullptr, 0u, &required,
                                               nullptr);
        if (required < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_A))
        {
            continue;
        }
        std::vector<uint8_t> storage(required);
        auto *detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_A *>(storage.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_A);
        SP_DEVINFO_DATA info{};
        info.cbSize = sizeof(info);
        if (!SetupDiGetDeviceInterfaceDetailA(devices, &interface_data, detail, required, nullptr,
                                              &info))
        {
            error = win32_error("SetupDiGetDeviceInterfaceDetailA(HID)");
            break;
        }

        HidDevice device;
        device.device_path = detail->DevicePath;
        device.friendly_name = registry_string_property(devices, info, SPDRP_FRIENDLYNAME);
        if (device.friendly_name.empty())
        {
            device.friendly_name = registry_string_property(devices, info, SPDRP_DEVICEDESC);
        }
        device.hardware_id = registry_string_property(devices, info, SPDRP_HARDWAREID);
        device.instance_id = instance_id_for_device(devices, info);
        if (!parse_vid_pid(device.device_path, device.vid, device.pid))
        {
            (void)parse_vid_pid(device.hardware_id, device.vid, device.pid);
        }
        result.push_back(std::move(device));
    }

    SetupDiDestroyDeviceInfoList(devices);
    return result;
#elif defined(__APPLE__)
    error.clear();
    std::vector<HidDevice> result;
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (manager == nullptr)
    {
        error = "IOHIDManagerCreate failed";
        return result;
    }
    IOHIDManagerSetDeviceMatching(manager, nullptr);

    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (devices != nullptr)
    {
        const CFIndex count = CFSetGetCount(devices);
        std::vector<const void *> values(static_cast<size_t>(count));
        CFSetGetValues(devices, values.data());
        for (const void *value : values)
        {
            auto device_ref = static_cast<IOHIDDeviceRef>(const_cast<void *>(value));
            HidDevice device;
            device.vid = static_cast<uint16_t>(
                cf_number(IOHIDDeviceGetProperty(device_ref, CFSTR(kIOHIDVendorIDKey))));
            device.pid = static_cast<uint16_t>(
                cf_number(IOHIDDeviceGetProperty(device_ref, CFSTR(kIOHIDProductIDKey))));
            device.friendly_name =
                cf_string(IOHIDDeviceGetProperty(device_ref, CFSTR(kIOHIDProductKey)));
            const std::string serial =
                cf_string(IOHIDDeviceGetProperty(device_ref, CFSTR(kIOHIDSerialNumberKey)));
            const uint32_t location =
                cf_number(IOHIDDeviceGetProperty(device_ref, CFSTR(kIOHIDLocationIDKey)));
            device.hardware_id = usb_hardware_id(device.vid, device.pid);
            device.instance_id = !serial.empty() ? serial : "IOHID:" + std::to_string(location);
            device.device_path = device.instance_id;
            result.push_back(std::move(device));
        }
        CFRelease(devices);
    }
    CFRelease(manager);
    return result;
#endif
}

std::vector<HidDevice> find_hid_devices(uint16_t vid, uint16_t pid, std::string &error)
{
    const std::vector<HidDevice> devices = list_hid_devices(error);
    std::vector<HidDevice> matches;
    if (!error.empty())
    {
        return matches;
    }
    for (const HidDevice &device : devices)
    {
        if ((device.vid == vid) && (device.pid == pid))
        {
            matches.push_back(device);
        }
    }
    return matches;
}

SerialPort::SerialPort() : handle_(nullptr)
{
}

SerialPort::~SerialPort()
{
    close();
}

bool SerialPort::open(const std::string &port_name, uint32_t baud, uint32_t rx_buffer_bytes,
                      std::string &error)
{
    close();
#if defined(_WIN32)
    HANDLE handle =
        CreateFileA(normalize_port_name(port_name).c_str(), GENERIC_READ | GENERIC_WRITE, 0u,
                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE)
    {
        error = win32_error("open " + port_name);
        return false;
    }

    if (!SetupComm(handle, rx_buffer_bytes, 4096u))
    {
        error = win32_error("SetupComm");
        CloseHandle(handle);
        return false;
    }

    DCB dcb{};
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(handle, &dcb))
    {
        error = win32_error("GetCommState");
        CloseHandle(handle);
        return false;
    }
    dcb.BaudRate = baud;
    dcb.ByteSize = 8u;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary = TRUE;
    dcb.fParity = FALSE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDtrControl = DTR_CONTROL_ENABLE;
    dcb.fRtsControl = RTS_CONTROL_ENABLE;
    if (!SetCommState(handle, &dcb))
    {
        error = win32_error("SetCommState");
        CloseHandle(handle);
        return false;
    }

    COMMTIMEOUTS timeouts{};
    timeouts.ReadIntervalTimeout = MAXDWORD;
    timeouts.ReadTotalTimeoutConstant = 50u;
    timeouts.WriteTotalTimeoutConstant = 1000u;
    if (!SetCommTimeouts(handle, &timeouts))
    {
        error = win32_error("SetCommTimeouts");
        CloseHandle(handle);
        return false;
    }

    (void)EscapeCommFunction(handle, SETDTR);
    (void)EscapeCommFunction(handle, SETRTS);
    handle_ = handle;
    return clear_input(error);
#elif defined(__APPLE__)
    (void)rx_buffer_bytes;
    const int fd = ::open(port_name.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
    {
        error = posix_error("open " + port_name);
        return false;
    }

    termios options{};
    if (tcgetattr(fd, &options) != 0)
    {
        error = posix_error("tcgetattr");
        ::close(fd);
        return false;
    }
    cfmakeraw(&options);
    options.c_cflag |= CLOCAL | CREAD;
    options.c_cflag &= static_cast<tcflag_t>(~(PARENB | CSTOPB | CSIZE));
    options.c_cflag |= CS8;
    if (cfsetspeed(&options, static_cast<speed_t>(baud)) != 0)
    {
        error = posix_error("cfsetspeed");
        ::close(fd);
        return false;
    }
    if (tcsetattr(fd, TCSANOW, &options) != 0)
    {
        error = posix_error("tcsetattr");
        ::close(fd);
        return false;
    }

    int modem_bits = TIOCM_DTR | TIOCM_RTS;
    (void)ioctl(fd, TIOCMBIS, &modem_bits);
    handle_ = serial_handle(fd);
    return clear_input(error);
#endif
}

int SerialPort::read(uint8_t *buffer, uint32_t buffer_bytes, std::string &error)
{
    if (handle_ == nullptr)
    {
        error = "serial port is not open";
        return -1;
    }
#if defined(_WIN32)
    DWORD received = 0u;
    if (!ReadFile(reinterpret_cast<HANDLE>(handle_), buffer, buffer_bytes, &received, nullptr))
    {
        error = win32_error("ReadFile");
        return -1;
    }
    return static_cast<int>(received);
#elif defined(__APPLE__)
    pollfd descriptor{serial_fd(handle_), POLLIN, 0};
    int poll_result = 0;
    do
    {
        poll_result = poll(&descriptor, 1u, 50);
    } while ((poll_result < 0) && (errno == EINTR));
    if (poll_result < 0)
    {
        error = posix_error("poll");
        return -1;
    }
    if (poll_result == 0)
    {
        error.clear();
        return 0;
    }
    if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0)
    {
        error = "serial port disconnected";
        return -1;
    }

    ssize_t received = 0;
    do
    {
        received = ::read(descriptor.fd, buffer, buffer_bytes);
    } while ((received < 0) && (errno == EINTR));
    if ((received < 0) && ((errno == EAGAIN) || (errno == EWOULDBLOCK)))
    {
        error.clear();
        return 0;
    }
    if (received < 0)
    {
        error = posix_error("read");
        return -1;
    }
    error.clear();
    return static_cast<int>(received);
#endif
}

bool SerialPort::write_all(const uint8_t *data, uint32_t data_bytes, std::string &error)
{
    if (handle_ == nullptr)
    {
        error = "serial port is not open";
        return false;
    }
#if defined(_WIN32)
    uint32_t offset = 0u;
    while (offset < data_bytes)
    {
        DWORD written = 0u;
        const DWORD chunk = static_cast<DWORD>(data_bytes - offset);
        if (!WriteFile(reinterpret_cast<HANDLE>(handle_), data + offset, chunk, &written, nullptr))
        {
            error = win32_error("WriteFile");
            return false;
        }
        if (written == 0u)
        {
            error = "serial write made no progress";
            return false;
        }
        offset += written;
    }
    error.clear();
    return true;
#elif defined(__APPLE__)
    uint32_t offset = 0u;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (offset < data_bytes)
    {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline)
        {
            error = "serial write timed out";
            return false;
        }
        const auto remaining =
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
        pollfd descriptor{serial_fd(handle_), POLLOUT, 0};
        int poll_result = 0;
        do
        {
            poll_result = poll(&descriptor, 1u, static_cast<int>(std::max<int64_t>(1, remaining)));
        } while ((poll_result < 0) && (errno == EINTR));
        if (poll_result < 0)
        {
            error = posix_error("poll");
            return false;
        }
        if (poll_result == 0)
        {
            error = "serial write timed out";
            return false;
        }
        if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0)
        {
            error = "serial port disconnected";
            return false;
        }

        ssize_t written = 0;
        do
        {
            written = ::write(descriptor.fd, data + offset, data_bytes - offset);
        } while ((written < 0) && (errno == EINTR));
        if ((written < 0) && ((errno == EAGAIN) || (errno == EWOULDBLOCK)))
        {
            continue;
        }
        if (written < 0)
        {
            error = posix_error("write");
            return false;
        }
        if (written == 0)
        {
            error = "serial write made no progress";
            return false;
        }
        offset += static_cast<uint32_t>(written);
    }
    error.clear();
    return true;
#endif
}

bool SerialPort::clear_input(std::string &error)
{
    if (handle_ == nullptr)
    {
        error = "serial port is not open";
        return false;
    }
#if defined(_WIN32)
    if (!PurgeComm(reinterpret_cast<HANDLE>(handle_), PURGE_RXCLEAR))
    {
        error = win32_error("PurgeComm");
        return false;
    }
#elif defined(__APPLE__)
    if (tcflush(serial_fd(handle_), TCIFLUSH) != 0)
    {
        error = posix_error("tcflush");
        return false;
    }
#endif
    error.clear();
    return true;
}

void SerialPort::close()
{
    if (handle_ != nullptr)
    {
#if defined(_WIN32)
        CloseHandle(reinterpret_cast<HANDLE>(handle_));
#elif defined(__APPLE__)
        (void)::close(serial_fd(handle_));
#endif
        handle_ = nullptr;
    }
}

bool SerialPort::is_open() const
{
    return handle_ != nullptr;
}

struct StreamParser::Impl
{
    std::vector<uint8_t> buffer;
    size_t cursor = 0u;
    std::vector<ControlResponse> responses;
    Frame assembling;
    uint32_t assembling_offset = 0u;
    bool assembling_active = false;
    Frame latest;
    bool have_latest = false;
    nxpc_dbg_stats_report_t latest_stats{};
    bool have_stats = false;
    std::vector<LogRecord> log_records;
    std::vector<TelemetrySample> telemetry_samples;
    ParserCounters count;
    std::string error;

    void set_error(const std::string &message)
    {
        error = message;
        ++count.malformed;
    }

    void compact()
    {
        if (cursor > 0u)
        {
            buffer.erase(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(cursor));
            cursor = 0u;
        }
    }

    size_t find_magic() const
    {
        const auto first = buffer.begin() + static_cast<std::ptrdiff_t>(cursor);
        const auto found = std::search(first, buffer.end(), kMagic.begin(), kMagic.end());
        return (found == buffer.end()) ? std::string::npos
                                       : static_cast<size_t>(found - buffer.begin());
    }

    void parse_frame(const nxpc_dbg_packet_header_t &header, const uint8_t *payload,
                     uint32_t payload_bytes)
    {
        if (payload_bytes <= sizeof(nxpc_dbg_rui_write_frame_buffer_raw_t))
        {
            set_error("frame payload is too small");
            return;
        }

        nxpc_dbg_rui_write_frame_buffer_raw_t chunk{};
        std::memcpy(&chunk, payload, sizeof(chunk));
        const uint32_t data_bytes = payload_bytes - static_cast<uint32_t>(sizeof(chunk));
        const bool multiplication_safe =
            (chunk.width != 0u) &&
            (static_cast<uint32_t>(chunk.height) <=
             (std::numeric_limits<uint32_t>::max() / static_cast<uint32_t>(chunk.width) / 2u));
        const uint32_t geometry_bytes =
            multiplication_safe ? static_cast<uint32_t>(chunk.width) * chunk.height * 2u : 0u;
        const bool valid =
            (chunk.total_frame_bytes > 0u) && (chunk.total_frame_bytes <= kFrameMaxBytes) &&
            (geometry_bytes == chunk.total_frame_bytes) &&
            (chunk.pixel_format == NXPC_DBG_PIXEL_FORMAT_RGB565_LE) && (chunk.buffer_id == 0u) &&
            (chunk.byte_offset < chunk.total_frame_bytes) &&
            (data_bytes <= (chunk.total_frame_bytes - chunk.byte_offset)) &&
            ((chunk.chunk_flags & ~kKnownChunkFlags) == 0u) && (header.arg0 == chunk.frame_id) &&
            (header.arg1 == chunk.byte_offset) && (header.arg2 == data_bytes);
        if (!valid)
        {
            set_error("invalid frame chunk");
            assembling_active = false;
            return;
        }

        if ((chunk.chunk_flags & NXPC_DBG_RUI_CHUNK_FRAME_START) != 0u)
        {
            assembling = Frame{};
            assembling.frame_id = chunk.frame_id;
            assembling.width = chunk.width;
            assembling.height = chunk.height;
            assembling.pixel_format = chunk.pixel_format;
            assembling.pixels.resize(chunk.total_frame_bytes);
            assembling_offset = 0u;
            assembling_active = true;
        }

        if (!assembling_active || (assembling.frame_id != chunk.frame_id) ||
            (assembling_offset != chunk.byte_offset) ||
            (assembling.pixels.size() != chunk.total_frame_bytes))
        {
            set_error("non-contiguous frame chunk");
            assembling_active = false;
            return;
        }

        std::memcpy(assembling.pixels.data() + chunk.byte_offset, payload + sizeof(chunk),
                    data_bytes);
        assembling_offset += data_bytes;
        ++count.frame_chunks;

        if ((chunk.chunk_flags & NXPC_DBG_RUI_CHUNK_FRAME_END) != 0u)
        {
            if (assembling_offset != assembling.pixels.size())
            {
                set_error("frame ended before all bytes arrived");
                assembling_active = false;
                return;
            }
            assembling.generation = latest.generation + 1u;
            latest = std::move(assembling);
            have_latest = true;
            assembling_active = false;
            ++count.frames;
        }
    }

    void parse_packet(const nxpc_dbg_packet_header_t &header, const uint8_t *payload,
                      uint32_t payload_bytes)
    {
        if ((header.flags & NXPC_DBG_PACKET_FLAG_DROPPED_BEFORE) != 0u)
        {
            ++count.dropped_before;
        }

        if (((header.flags & NXPC_DBG_PACKET_FLAG_RESPONSE) != 0u) &&
            ((header.msg_id & 0xFFFFFF00u) == NXPC_DBG_MSG_CLASS_CONTROL))
        {
            ControlResponse response;
            response.msg_id = header.msg_id;
            response.request_sequence = header.arg0;
            response.status = header.arg1;
            response.detail = header.arg2;
            response.payload.assign(payload, payload + payload_bytes);
            responses.push_back(std::move(response));
            ++count.controls;
            return;
        }

        if (header.msg_id == NXPC_DBG_RUI_WRITE_FRAME_BUFFER_RAW)
        {
            parse_frame(header, payload, payload_bytes);
            return;
        }

        if (header.msg_id == NXPC_DBG_STATS_REPORT)
        {
            if (payload_bytes != sizeof(latest_stats))
            {
                set_error("invalid stats payload size");
                return;
            }
            std::memcpy(&latest_stats, payload, sizeof(latest_stats));
            have_stats = true;
            ++count.stats;
            return;
        }

        if (header.msg_id == NXPC_DBG_LOG_TEXT)
        {
            if (payload_bytes < sizeof(nxpc_dbg_log_record_t))
            {
                set_error("log payload is too small");
                return;
            }
            nxpc_dbg_log_record_t wire{};
            std::memcpy(&wire, payload, sizeof(wire));
            const uint32_t expected =
                static_cast<uint32_t>(sizeof(wire)) + wire.category_bytes + wire.text_bytes;
            if ((expected != payload_bytes) || (wire.level > NXPC_DBG_LOG_LEVEL_ERROR))
            {
                set_error("invalid log payload");
                return;
            }
            LogRecord record;
            record.timestamp_ms = wire.timestamp_ms;
            record.record_id = wire.record_id;
            record.level = wire.level;
            const char *category = reinterpret_cast<const char *>(payload + sizeof(wire));
            record.category.assign(category, category + wire.category_bytes);
            const char *text = category + wire.category_bytes;
            record.text.assign(text, text + wire.text_bytes);
            log_records.push_back(std::move(record));
            retain_bounded(log_records);
            ++count.logs;
            return;
        }

        if (header.msg_id == NXPC_DBG_TELEMETRY_SCALAR)
        {
            if (payload_bytes < sizeof(nxpc_dbg_telemetry_scalar_t))
            {
                set_error("telemetry payload is too small");
                return;
            }
            nxpc_dbg_telemetry_scalar_t wire{};
            std::memcpy(&wire, payload, sizeof(wire));
            const bool text_value = wire.value_type == NXPC_DBG_TELEMETRY_TYPE_TEXT;
            const uint32_t text_bytes = text_value ? wire.value_bits : 0u;
            const uint32_t expected = static_cast<uint32_t>(sizeof(wire)) + wire.name_bytes +
                                      wire.units_bytes + text_bytes;
            const bool type_valid = (wire.value_type >= NXPC_DBG_TELEMETRY_TYPE_I32) &&
                                    (wire.value_type <= NXPC_DBG_TELEMETRY_TYPE_TEXT);
            const bool text_valid =
                !text_value ||
                ((text_bytes > 0u) && (text_bytes <= NXPC_DBG_TELEMETRY_TEXT_MAX_BYTES) &&
                 (wire.units_bytes == 0u));
            if ((expected != payload_bytes) || !type_valid || !text_valid ||
                (wire.name_bytes == 0u))
            {
                set_error("invalid telemetry payload");
                return;
            }
            TelemetrySample sample;
            sample.timestamp_ms = wire.timestamp_ms;
            sample.sample_id = wire.sample_id;
            sample.value_bits = wire.value_bits;
            sample.value_type = wire.value_type;
            const char *name = reinterpret_cast<const char *>(payload + sizeof(wire));
            sample.name.assign(name, name + wire.name_bytes);
            const char *units = name + wire.name_bytes;
            sample.units.assign(units, units + wire.units_bytes);
            if (text_value)
            {
                const char *text = units + wire.units_bytes;
                sample.text_value.assign(text, text + text_bytes);
            }
            telemetry_samples.push_back(std::move(sample));
            retain_bounded(telemetry_samples);
            ++count.telemetry;
            return;
        }

        ++count.unknown;
    }

    void parse()
    {
        while ((buffer.size() - cursor) >= NXPC_DBG_PACKET_HEADER_BYTES)
        {
            const size_t magic_at = find_magic();
            if (magic_at == std::string::npos)
            {
                const size_t unread = buffer.size() - cursor;
                const size_t keep = std::min<size_t>(unread, kMagic.size() - 1u);
                count.resync_bytes += unread - keep;
                cursor += unread - keep;
                return;
            }
            if (magic_at > cursor)
            {
                count.resync_bytes += magic_at - cursor;
                cursor = magic_at;
            }
            if ((buffer.size() - cursor) < NXPC_DBG_PACKET_HEADER_BYTES)
            {
                return;
            }

            nxpc_dbg_packet_header_t header{};
            std::memcpy(&header, buffer.data() + cursor, sizeof(header));
            const bool header_valid = (header.magic == NXPC_DBG_MAGIC) &&
                                      (header.version == NXPC_DBG_VERSION) &&
                                      (header.header_bytes == NXPC_DBG_PACKET_HEADER_BYTES) &&
                                      ((header.flags & ~kKnownPacketFlags) == 0u) &&
                                      (header.payload_length <= kPacketPayloadMaxBytes);
            if (!header_valid)
            {
                set_error("invalid AVCU packet header");
                ++cursor;
                continue;
            }

            const size_t packet_bytes =
                NXPC_DBG_PACKET_HEADER_BYTES + static_cast<size_t>(header.payload_length);
            if ((buffer.size() - cursor) < packet_bytes)
            {
                return;
            }
            const uint8_t *payload = buffer.data() + cursor + NXPC_DBG_PACKET_HEADER_BYTES;
            parse_packet(header, payload, header.payload_length);
            ++count.packets;
            cursor += packet_bytes;
        }
    }
};

StreamParser::StreamParser() : impl_(std::make_unique<Impl>())
{
}
StreamParser::~StreamParser() = default;
StreamParser::StreamParser(StreamParser &&) noexcept = default;
StreamParser &StreamParser::operator=(StreamParser &&) noexcept = default;

void StreamParser::feed(const uint8_t *data, size_t data_bytes)
{
    if ((data == nullptr) || (data_bytes == 0u))
    {
        return;
    }
    if ((impl_->cursor > (impl_->buffer.size() / 2u)) || (impl_->cursor > (1024u * 1024u)))
    {
        impl_->compact();
    }
    impl_->buffer.insert(impl_->buffer.end(), data, data + data_bytes);
    impl_->parse();
    if ((impl_->cursor > (impl_->buffer.size() / 2u)) || (impl_->cursor > (1024u * 1024u)))
    {
        impl_->compact();
    }
}

bool StreamParser::take_control_response(uint32_t msg_id, uint32_t request_sequence,
                                         ControlResponse &response)
{
    const auto found = std::find_if(impl_->responses.begin(), impl_->responses.end(),
                                    [&](const ControlResponse &candidate)
                                    {
                                        return (candidate.msg_id == msg_id) &&
                                               (candidate.request_sequence == request_sequence);
                                    });
    if (found == impl_->responses.end())
    {
        return false;
    }
    response = std::move(*found);
    impl_->responses.erase(found);
    return true;
}

bool StreamParser::latest_frame(uint64_t after_generation, Frame &frame) const
{
    if (!impl_->have_latest || (impl_->latest.generation <= after_generation))
    {
        return false;
    }
    frame = impl_->latest;
    return true;
}

bool StreamParser::latest_stats(nxpc_dbg_stats_report_t &stats) const
{
    if (!impl_->have_stats)
    {
        return false;
    }
    stats = impl_->latest_stats;
    return true;
}

const std::vector<LogRecord> &StreamParser::logs() const
{
    return impl_->log_records;
}

const std::vector<TelemetrySample> &StreamParser::telemetry() const
{
    return impl_->telemetry_samples;
}

const ParserCounters &StreamParser::counters() const
{
    return impl_->count;
}

const std::string &StreamParser::last_error() const
{
    return impl_->error;
}

nxpc_dbg_packet_header_t make_control_request(uint32_t request_sequence, uint32_t msg_id,
                                              uint32_t arg0, uint32_t arg1, uint32_t arg2)
{
    nxpc_dbg_packet_header_t packet{};
    packet.magic = NXPC_DBG_MAGIC;
    packet.version = NXPC_DBG_VERSION;
    packet.header_bytes = NXPC_DBG_PACKET_HEADER_BYTES;
    packet.msg_id = msg_id;
    packet.sequence = request_sequence;
    packet.arg0 = arg0;
    packet.arg1 = arg1;
    packet.arg2 = arg2;
    return packet;
}

bool send_control_request(SerialPort &port, uint32_t request_sequence, uint32_t msg_id,
                          uint32_t arg0, uint32_t arg1, uint32_t arg2, std::string &error)
{
    const nxpc_dbg_packet_header_t request =
        make_control_request(request_sequence, msg_id, arg0, arg1, arg2);
    return port.write_all(reinterpret_cast<const uint8_t *>(&request), sizeof(request), error);
}

bool wait_for_control_response(SerialPort &port, StreamParser &parser, uint32_t msg_id,
                               uint32_t request_sequence, uint32_t timeout_ms,
                               ControlResponse &response, std::string &error)
{
    std::array<uint8_t, 64u * 1024u> buffer{};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline)
    {
        if (parser.take_control_response(msg_id, request_sequence, response))
        {
            return true;
        }
        const int received = port.read(buffer.data(), static_cast<uint32_t>(buffer.size()), error);
        if (received < 0)
        {
            return false;
        }
        if (received > 0)
        {
            parser.feed(buffer.data(), static_cast<size_t>(received));
        }
    }

    std::ostringstream message;
    message << "timeout waiting for control response 0x" << std::hex << msg_id << std::dec
            << " request " << request_sequence;
    error = message.str();
    return false;
}

bool decode_hello(const ControlResponse &response, nxpc_dbg_control_hello_response_t &hello,
                  std::string &error)
{
    if (response.status != NXPC_DBG_CONTROL_STATUS_OK)
    {
        error = "HELLO was rejected with status " + std::to_string(response.status);
        return false;
    }
    if (response.payload.size() != sizeof(hello))
    {
        error =
            "HELLO response payload has unexpected size " + std::to_string(response.payload.size());
        return false;
    }
    std::memcpy(&hello, response.payload.data(), sizeof(hello));
    error.clear();
    return true;
}

bool run_core_self_test(std::string &error)
{
    StreamParser parser;
    nxpc_dbg_control_hello_response_t hello_payload{};
    hello_payload.capability_flags = NXPC_DBG_CAPABILITY_FRAMED_CONTROL |
                                     NXPC_DBG_CAPABILITY_CAMERA_FRAMES |
                                     NXPC_DBG_CAPABILITY_NAMED_TELEMETRY;
    hello_payload.max_packet_bytes = 16u * 1024u;
    hello_payload.frame_width = 320u;
    hello_payload.frame_height = 200u;
    hello_payload.pixel_format = NXPC_DBG_PIXEL_FORMAT_RGB565_LE;
    hello_payload.session_id = 0x12345678u;

    nxpc_dbg_packet_header_t hello_header = make_control_request(9u, NXPC_DBG_CONTROL_HELLO);
    hello_header.flags = NXPC_DBG_PACKET_FLAG_RESPONSE;
    hello_header.payload_length = sizeof(hello_payload);
    hello_header.arg0 = 9u;
    hello_header.arg1 = NXPC_DBG_CONTROL_STATUS_OK;

    std::vector<uint8_t> hello_packet;
    append_object(hello_packet, hello_header);
    append_object(hello_packet, hello_payload);
    const std::array<uint8_t, 5> garbage = {0x00u, 0x41u, 0x56u, 0x00u, 0xFFu};
    parser.feed(garbage.data(), garbage.size());
    parser.feed(hello_packet.data(), 7u);
    parser.feed(hello_packet.data() + 7u, hello_packet.size() - 7u);

    ControlResponse response;
    nxpc_dbg_control_hello_response_t decoded{};
    if (!parser.take_control_response(NXPC_DBG_CONTROL_HELLO, 9u, response) ||
        !decode_hello(response, decoded, error) || (decoded.session_id != hello_payload.session_id))
    {
        if (error.empty())
        {
            error = "fragmented HELLO self-test failed";
        }
        return false;
    }

    constexpr uint32_t frame_bytes = 320u * 200u * 2u;
    std::vector<uint8_t> expected(frame_bytes);
    for (uint32_t index = 0u; index < frame_bytes; ++index)
    {
        expected[index] = static_cast<uint8_t>((index * 17u) & 0xFFu);
    }

    uint32_t offset = 0u;
    uint32_t sequence = 10u;
    while (offset < frame_bytes)
    {
        const uint32_t data_bytes = std::min<uint32_t>(8000u, frame_bytes - offset);
        nxpc_dbg_rui_write_frame_buffer_raw_t chunk{};
        chunk.frame_id = 42u;
        chunk.byte_offset = offset;
        chunk.total_frame_bytes = frame_bytes;
        chunk.width = 320u;
        chunk.height = 200u;
        chunk.pixel_format = NXPC_DBG_PIXEL_FORMAT_RGB565_LE;
        chunk.chunk_flags =
            ((offset == 0u) ? NXPC_DBG_RUI_CHUNK_FRAME_START : 0u) |
            (((offset + data_bytes) == frame_bytes) ? NXPC_DBG_RUI_CHUNK_FRAME_END : 0u);
        nxpc_dbg_packet_header_t header{};
        header.magic = NXPC_DBG_MAGIC;
        header.version = NXPC_DBG_VERSION;
        header.header_bytes = NXPC_DBG_PACKET_HEADER_BYTES;
        header.msg_id = NXPC_DBG_RUI_WRITE_FRAME_BUFFER_RAW;
        header.sequence = sequence++;
        header.payload_length = sizeof(chunk) + data_bytes;
        header.arg0 = chunk.frame_id;
        header.arg1 = offset;
        header.arg2 = data_bytes;
        std::vector<uint8_t> packet;
        append_object(packet, header);
        append_object(packet, chunk);
        packet.insert(packet.end(), expected.begin() + offset,
                      expected.begin() + offset + data_bytes);
        for (size_t at = 0u; at < packet.size(); at += 113u)
        {
            const size_t block = std::min<size_t>(113u, packet.size() - at);
            parser.feed(packet.data() + at, block);
        }
        offset += data_bytes;
    }

    Frame frame;
    if (!parser.latest_frame(0u, frame) || (frame.frame_id != 42u) || (frame.pixels != expected) ||
        (parser.counters().malformed != 0u))
    {
        error = "fragmented frame self-test failed: " + parser.last_error();
        return false;
    }
    error.clear();
    return true;
}

} // namespace nxpc::host
