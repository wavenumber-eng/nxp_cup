#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "nxpc_viewer_platform.hpp"

namespace nxpc::host
{

bool choose_firmware_image(std::string &path, std::string &error)
{
    @autoreleasepool
    {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:YES];
        [panel setCanChooseDirectories:NO];
        [panel setAllowsMultipleSelection:NO];
        [panel setTitle:@"Select an NXP Cup firmware image"];
        UTType *binary_type = [UTType typeWithFilenameExtension:@"bin"];
        if (binary_type != nil)
        {
            [panel setAllowedContentTypes:@[ binary_type ]];
        }
        if (!path.empty())
        {
            NSString *existing = [NSString stringWithUTF8String:path.c_str()];
            if (existing != nil)
            {
                [panel
                    setDirectoryURL:[NSURL fileURLWithPath:[existing
                                                               stringByDeletingLastPathComponent]]];
            }
        }
        if ([panel runModal] != NSModalResponseOK)
        {
            error.clear();
            return false;
        }
        const char *selected = [[[panel URLs] firstObject] fileSystemRepresentation];
        if (selected == nullptr)
        {
            error = "firmware file dialog returned an invalid path";
            return false;
        }
        path = selected;
        error.clear();
        return true;
    }
}

std::filesystem::path current_executable_path(std::string &error)
{
    @autoreleasepool
    {
        NSURL *url = [[NSBundle mainBundle] executableURL];
        const char *path = [url fileSystemRepresentation];
        if (path == nullptr)
        {
            error = "cannot resolve viewer executable path";
            return {};
        }
        error.clear();
        return std::filesystem::u8path(path);
    }
}

} // namespace nxpc::host
