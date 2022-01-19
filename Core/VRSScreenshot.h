#pragma once

class ColorBuffer;
class CommandContext;

namespace Screenshot
{
    void TakeScreenshotAndExportVRSBuffer(const char* filename, ColorBuffer& source, const char* vrsfilename, ColorBuffer& vrsBuffer, CommandContext& context, bool exportBuffer);
}