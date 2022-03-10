// Copyright (C) 2022 Intel Corporation

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom
// the Software is furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
// OR OTHER DEALINGS IN THE SOFTWARE.

#include "pch.h"
#include "VRSScreenshot.h"
#include "ReadbackBuffer.h"
#include "ColorBuffer.h"
#include "RootSignature.h"
#include "PipelineState.h"
#include "GraphicsCore.h"
#include "CommandContext.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "Util/stb_image_write.h"

#include "../Core/CompiledShaders/VRSScreenshot_RGB_CS.h"
#include "../Core/CompiledShaders/VRSScreenshot_RGB2_CS.h"

using namespace Graphics;

namespace Screenshot
{
    ReadbackBuffer readback = {};
    ReadbackBuffer vrsreadback = {};
    ColorBuffer tempBuffer = {};
    RootSignature screenshot_RootSig = {};
    ComputePSO convertDataCS(L"Convert Data");
    int sourceWidth = 0;
    int sourceHeight = 0;
    int vrsWidth = 0;
    int vrsHeight = 0;

    void Initialize(ColorBuffer& source, ColorBuffer& vrsBuffer);
    void ConvertData(ColorBuffer& source, CommandContext& context);
    void WriteToFile(const char* filename, int width, int height, int comp, const void* data, int stride);
    void Shutdown();
}

void Screenshot::Initialize(ColorBuffer& source, ColorBuffer& vrsBuffer)
{
    sourceWidth = (int)source.GetWidth();
    sourceHeight = (int)source.GetHeight();
    readback.Create(L"Readback Screenshot", sourceWidth * sourceHeight, sizeof(uint32_t));

    vrsWidth = (int)vrsBuffer.GetWidth();
    vrsHeight = (int)vrsBuffer.GetHeight();
    vrsreadback.Create(L"VRS Readback", vrsWidth * vrsHeight, sizeof(uint8_t));

    tempBuffer.Create(L"Temporary Color Buffer", sourceWidth, sourceHeight, 1, DXGI_FORMAT_R8G8B8A8_UNORM);

    screenshot_RootSig.Reset(1, 0);
    screenshot_RootSig[0].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 2);
    screenshot_RootSig.Finalize(L"Conversion_VRS");

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(screenshot_RootSig); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    if (g_bTypedUAVLoadSupport_R11G11B10_FLOAT)
    {
        CreatePSO(convertDataCS, g_pVRSScreenshot_RGB2_CS);
    }
    else
    {
        CreatePSO(convertDataCS, g_pVRSScreenshot_RGB_CS);
    }
}

void Screenshot::ConvertData(ColorBuffer& source, CommandContext& context)
{


    D3D12_CPU_DESCRIPTOR_HANDLE Pass1UAVs[] =
    {
        source.GetUAV(),
        tempBuffer.GetUAV()
    };
    context.GetComputeContext().SetRootSignature(screenshot_RootSig);
    context.GetComputeContext().SetDynamicDescriptors(0, 0, _countof(Pass1UAVs), Pass1UAVs);
    context.GetComputeContext().TransitionResource(source, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    context.GetComputeContext().TransitionResource(tempBuffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    context.GetComputeContext().SetPipelineState(convertDataCS);
    context.GetComputeContext().Dispatch2D(sourceWidth, sourceHeight);
}

void Screenshot::WriteToFile(const char* filename, int width, int height, int comp, const void* data, int stride)
{
    if (stbi_write_png(filename, width, height, comp, data, stride) == 0)
    {
        printf("Unable to write texture");
    }
}

void Screenshot::Shutdown()
{
    readback.Unmap();
    readback.Destroy();
    vrsreadback.Unmap();
    vrsreadback.Destroy();
    tempBuffer.Destroy();
}

void Screenshot::TakeScreenshotAndExportVRSBuffer(const char* filename, ColorBuffer& source, const char* vrsfilename, ColorBuffer& vrsBuffer, CommandContext& context, bool exportBuffer)
{
    Initialize(source, vrsBuffer);
    ConvertData(source, context);
    uint32_t sourceRowPitchInBytes = context.ReadbackTexture(readback, tempBuffer);

    uint32_t vrsRowPitchInBytes = context.ReadbackTexture(vrsreadback, vrsBuffer);
    context.Finish(true);
    uint8_t* vrsreadbackptr = (uint8_t*)vrsreadback.Map();

    WriteToFile(filename, sourceWidth, sourceHeight, 4, readback.Map(), sourceRowPitchInBytes);

    if (exportBuffer)
    {
        WriteToFile(vrsfilename, vrsWidth, vrsHeight, 1, vrsreadbackptr, vrsRowPitchInBytes);
    }
    Shutdown();
}
