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
#include "VRS.h"
#include "Display.h"
#include "Camera.h"
#include "GraphicsCore.h"
#include "BufferManager.h"
#include "ReadbackBuffer.h"
#include "CommandContext.h"
#include "CommandListManager.h"
#include "Util/CommandLineArg.h"
#include "Utility.h"
#include "DepthOfField.h"
#include "GpuResource.h"

#include "CompiledShaders/VRSScreenSpace_RGB_CS.h"
#include "CompiledShaders/VRSScreenSpace_RGB2_CS.h"

#include "CompiledShaders/VRSFoveatedScreenSpace_RGB_CS.h"
#include "CompiledShaders/VRSFoveatedScreenSpace_RGB2_CS.h"

#include "CompiledShaders/VRSDepth_RGB_CS.h"
#include "CompiledShaders/VRSDepth_RGB2_CS.h"

#include "CompiledShaders/VRSComputeTest_RGB_CS.h"
#include "CompiledShaders/VRSComputeTest_RGB2_CS.h"

#include "CompiledShaders/VRSContrastAdaptive8x8_RGB_CS.h"
#include "CompiledShaders/VRSContrastAdaptive8x8_RGB2_CS.h"

#include "CompiledShaders/VRSContrastAdaptive16x16_RGB_CS.h"
#include "CompiledShaders/VRSContrastAdaptive16x16_RGB2_CS.h"

#include "CompiledShaders/VRSPostSingleEliminationCS.h"

using namespace Graphics;

namespace VRS
{
    D3D12_QUERY_DATA_PIPELINE_STATISTICS PipelineStatistics;
    ShadingRatePercents Percents;
    ReadbackBuffer VRSReadbackBuffer;
    BoolVar CalculatePercents("VRS/VRS Debug/Calculate %s", true);

    const char* VRSLabels[] = { "1X1", "1X2", "2X1", "2X2", "2X4", "4X2", "4X4" };
    const char* combiners[] = { "Passthrough", "Override", "Min", "Max", "Sum" };
    const char* modes[] = { "Quadrant (CPU)", "Checkerboard (CPU)", "Foveated (GPU)", "Depth LOD (GPU)", "Depth DoF (GPU)", "Compute Test (GPU)", "Contrast Adaptive (GPU)" };
    const char* computeTestModes[] = { "Target Color", "Group ID", "Group Index", "Group Thread ID", "Dispatch Thread ID", "Velocity", "Luma", "Log Luma", "Avg. Tile Luma", "MSE Luma X", "MSE Luma Y", "MSE Luma XY", "Wave Lane" };
    const char* vrsMaskModes[] = { "None", "Single Elim.", "Blur" };

    RootSignature Depth_RootSig;
    RootSignature Debug_RootSig;
    RootSignature Foveated_RootSig;
    RootSignature PostProcess_RootSig;
    RootSignature ComputeTest_RootSig;
    RootSignature ContrastAdaptive_RootSig;

    ComputePSO VRSDepthCS(L"VRS: Depth");
    ComputePSO VRSDebugScreenSpaceCS(L"VRS: Debug Screen Space");
    ComputePSO VRSFoveatedScreenSpaceCS(L"VRS: Foveated Screen Space");
    ComputePSO VRSPostSingleEliminationCS(L"VRS: Post Process (Single Elim.)");
    ComputePSO VRSComputeTestCS(L"VRS: Compute Test");
    ComputePSO VRSContrastAdaptiveCS(L"VRS: Contrast Adaptive");

    D3D12_VARIABLE_SHADING_RATE_TIER ShadingRateTier = {};
    UINT ShadingRateTileSize = 16;
    BOOL ShadingRateAdditionalShadingRatesSupported = {};

    BoolVar Enable("VRS/Enable", true);

    EnumVar VRSShadingRate("VRS/Tier 1 Shading Rate", 0, 7, VRSLabels);
    EnumVar ShadingRateCombiners1("VRS/1st Combiner", 0, 5, combiners);
    EnumVar ShadingRateCombiners2("VRS/2nd Combiner", 1, 5, combiners);
    
    EnumVar ShadingModes("VRS/Shading Mode", 6, 7, modes);
    
    NumVar FoveatedInnerRadius("VRS/VRS Foveated/Inner Radius", 30, 0.0f, 100, 1);
    NumVar FoveatedOuterRadius("VRS/VRS Foveated/Outer Radius", 50, 0.0f, 100, 1);

    NumVar FoveatedCenterOffsetX("VRS/VRS Foveated/Center Offset X", 0, -100, 100, 1);
    NumVar FoveatedCenterOffsetY("VRS/VRS Foveated/Center Offset Y", 0, -100, 100, 1);

    BoolVar FoveatedTrackMouse("VRS/VRS Foveated/Track Mouse", true);

    NumVar DepthLODNear("VRS/VRS Depth LOD/LOD Near", 0.2f, 0.0f, 1.0f, 0.01f);
    NumVar DepthLODFar("VRS/VRS Depth LOD/LOD Far", 0.5f, 0.0f, 1.0f, 0.01f);

    NumVar DepthCameraNear("VRS/VRS Depth LOD/Camera Near", 1.0f, 1.0f, 10000.0f, 1.0f);
    NumVar DepthCameraFar("VRS/VRS Depth LOD/Camera Far", 10000.0f, 1.0f, 10000.0f, 1.0f);

    BoolVar DepthDoFQuality("VRS/VRS Depth of Field/Low Quality", false);

    BoolVar DebugDraw("VRS/VRS Debug/Debug", true);
    BoolVar DebugDrawBlendMask("VRS/VRS Debug/Blend Mask", true);
    BoolVar DebugDrawDrawGrid("VRS/VRS Debug/Draw Grid", false);

    BoolVar MaskPostProcessSingleVN("VRS/VRS Post Process/Single Elim. Von Neumann", false);
    BoolVar MaskPostProcessSingleM("VRS/VRS Post Process/Single Elim. Moore", false);

    EnumVar ComputeTestMode("VRS/VRS Compute Test/Mode", 0, 13, computeTestModes);

    BoolVar ConstrastAdaptiveDynamic("VRS/VRS Contrast Adaptive/Dynamic Threshold", false);
    NumVar ConstrastAdaptiveDynamicFPS("VRS/VRS Contrast Adaptive/Dynamic Threshold FPS", 30, 15, 60, 1);
    NumVar ContrastAdaptiveK("VRS/VRS Contrast Adaptive/Quarter Rate Sensitivity", 2.13f, 0.0f, 10.0f, 0.01f);
    NumVar ContrastAdaptiveSensitivityThreshold("VRS/VRS Contrast Adaptive/Sensitivity Threshold", 0.15f, 0.0f, 1.0f, 0.01f);
    NumVar ContrastAdaptiveEnvLuma("VRS/VRS Contrast Adaptive/Env. Luma", 0.05f, 0.0f, 10.0f, 0.001f);
    NumVar ContrastAdaptiveWeberFechnerConstant("VRS/VRS Contrast Adaptive/Weber-Fechner Constant", 1.0f, 0.0f, 10.0f, 0.01f);
    BoolVar ContrastAdaptiveUseWeberFechner("VRS/VRS Contrast Adaptive/Use Weber-Fechner", false);
    BoolVar ContrastAdaptiveUseMotionVectors("VRS/VRS Contrast Adaptive/Use Motion Vectors", false);
}

void VRS::ParseCommandLine()
{
    // VRS on or off
    std::wstring enableVRS = {};
    bool foundArg = CommandLineArgs::GetString(L"vrs", enableVRS);
    if (foundArg && enableVRS.compare(L"off") == 0)
    {
        Enable = false;
    }

    // Debug draw
    std::wstring debugVRS = {};
    foundArg = CommandLineArgs::GetString(L"overlay", debugVRS);
    if (foundArg && debugVRS.compare(L"on") == 0)
    {
        DebugDraw = true;
    }

    // Tier 1 Shading Rate
    std::wstring shadingRateVRS = {};
    foundArg = CommandLineArgs::GetString(L"rate", shadingRateVRS);
    if (foundArg)
    {
        if (shadingRateVRS.compare(L"1X2") == 0)
        {
            VRSShadingRate = ShadingRates::OneXTwo;
        }
        else if (shadingRateVRS.compare(L"2X1") == 0)
        {
            VRSShadingRate = ShadingRates::TwoXOne;
        }
        else if (shadingRateVRS.compare(L"2X2") == 0)
        {
            VRSShadingRate = ShadingRates::TwoXTwo;
        }
        else if (shadingRateVRS.compare(L"2X4") == 0 && ShadingRateAdditionalShadingRatesSupported)
        {
            VRSShadingRate = ShadingRates::TwoXFour;
        }
        else if (shadingRateVRS.compare(L"4X2") == 0 && ShadingRateAdditionalShadingRatesSupported)
        {
            VRSShadingRate = ShadingRates::FourXTwo;
        }
        else if (shadingRateVRS.compare(L"4X4") == 0 && ShadingRateAdditionalShadingRatesSupported)
        {
            VRSShadingRate = ShadingRates::FourXFour;
        }
    }

    // Tier 2 Shading Rate Combiners
    std::wstring combiner1 = {};
    std::wstring combiner2 = {};
    foundArg = CommandLineArgs::GetString(L"combiner1", combiner1);
    if (foundArg)
    {
        ShadingRateCombiners1 = SetCombinerUI(combiner1);
    }
    foundArg = CommandLineArgs::GetString(L"combiner2", combiner2);
    if (foundArg)
    {
        ShadingRateCombiners2 = SetCombinerUI(combiner2);
    }

} 

void VRS::Initialize()
{
    if (!ShadingRateAdditionalShadingRatesSupported)
    {
        VRSShadingRate.SetListLength(4);
    }
    ParseCommandLine();

    Debug_RootSig.Reset(2, 0);
    Debug_RootSig[0].InitAsConstants(0, 3);
    Debug_RootSig[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 2);
    Debug_RootSig.Finalize(L"Debug_VRS");

    Foveated_RootSig.Reset(2, 0);
    Foveated_RootSig[0].InitAsConstants(0, 7);
    Foveated_RootSig[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 2);
    Foveated_RootSig.Finalize(L"Foveated_VRS");

    Depth_RootSig.Reset(3, 0);
    Depth_RootSig[0].InitAsConstants(0, 5);
    Depth_RootSig[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 2);
    Depth_RootSig[2].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 0, 1);
    Depth_RootSig.Finalize(L"Depth_VRS");

    PostProcess_RootSig.Reset(2, 0);
    PostProcess_RootSig[0].InitAsConstants(0, 2);
    PostProcess_RootSig[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 1);
    PostProcess_RootSig.Finalize(L"PostProcess_VRS");

    ComputeTest_RootSig.Reset(2, 0);
    ComputeTest_RootSig[0].InitAsConstants(0, 8);
    ComputeTest_RootSig[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 3);
    ComputeTest_RootSig.Finalize(L"ComputeTest_VRS");

    ContrastAdaptive_RootSig.Reset(2, 0);
    ContrastAdaptive_RootSig[0].InitAsConstants(0, 9);
    ContrastAdaptive_RootSig[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 3);
    ContrastAdaptive_RootSig.Finalize(L"ContrastAdaptive_VRS");

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(Debug_RootSig); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    if (g_bTypedUAVLoadSupport_R11G11B10_FLOAT)
    {
        CreatePSO(VRSDebugScreenSpaceCS, g_pVRSScreenSpace_RGB2_CS);
    }
    else
    {
        CreatePSO(VRSDebugScreenSpaceCS, g_pVRSScreenSpace_RGB_CS);
    }

#undef CreatePSO

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(Foveated_RootSig); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    if (g_bTypedUAVLoadSupport_R11G11B10_FLOAT)
    {
        CreatePSO(VRSFoveatedScreenSpaceCS, g_pVRSFoveatedScreenSpace_RGB2_CS);
    }
    else
    {
        CreatePSO(VRSFoveatedScreenSpaceCS, g_pVRSFoveatedScreenSpace_RGB_CS);
    }
#undef CreatePSO

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(Depth_RootSig); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    if (g_bTypedUAVLoadSupport_R11G11B10_FLOAT)
    {
        CreatePSO(VRSDepthCS, g_pVRSDepth_RGB2_CS);
    }
    else
    {
        CreatePSO(VRSDepthCS, g_pVRSDepth_RGB_CS);
    }
#undef CreatePSO

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(ComputeTest_RootSig); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    if (g_bTypedUAVLoadSupport_R11G11B10_FLOAT)
    {
        CreatePSO(VRSComputeTestCS, g_pVRSComputeTest_RGB2_CS);
    }
    else
    {
        CreatePSO(VRSComputeTestCS, g_pVRSComputeTest_RGB_CS);
    }
#undef CreatePSO

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(ContrastAdaptive_RootSig); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    if (IsVRSTierSupported(D3D12_VARIABLE_SHADING_RATE_TIER_2))
    {
        if (ShadingRateTileSize == 8)
        {
            if (g_bTypedUAVLoadSupport_R11G11B10_FLOAT)
            {
                CreatePSO(VRSContrastAdaptiveCS, g_pVRSContrastAdaptive8x8_RGB2_CS);
            }
            else
            {
                CreatePSO(VRSContrastAdaptiveCS, g_pVRSContrastAdaptive8x8_RGB_CS);
            }
        }
        else
        {
            if (g_bTypedUAVLoadSupport_R11G11B10_FLOAT)
            {
                CreatePSO(VRSContrastAdaptiveCS, g_pVRSContrastAdaptive16x16_RGB2_CS);
            }
            else
            {
                CreatePSO(VRSContrastAdaptiveCS, g_pVRSContrastAdaptive16x16_RGB_CS);
            }
        }
    }
#undef CreatePSO

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(PostProcess_RootSig); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    CreatePSO(VRSPostSingleEliminationCS, g_pVRSPostSingleEliminationCS);
#undef CreatePSO

    g_VRSTier2Buffer.SetClearColor(Color(D3D12_SHADING_RATE_1X1));
    VRSReadbackBuffer.Create(L"VRS Readback", g_VRSTier2Buffer.GetWidth() * g_VRSTier2Buffer.GetHeight(), sizeof(uint8_t));
}

void VRS::CheckHardwareSupport()
{
    // Check for VRS hardware support
    D3D12_FEATURE_DATA_D3D12_OPTIONS6 options = {};
    if (SUCCEEDED(g_Device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS6, &options, sizeof(options))))
    {
        ShadingRateTier = options.VariableShadingRateTier;

        if (ShadingRateTier >= D3D12_VARIABLE_SHADING_RATE_TIER_1)
        {
            ShadingRateAdditionalShadingRatesSupported = options.AdditionalShadingRatesSupported;
        }
        if (ShadingRateTier >= D3D12_VARIABLE_SHADING_RATE_TIER_2)
        {
            printf("Tier 2 VRS supported\n");
            ShadingRateTileSize = options.ShadingRateImageTileSize;
            printf("Tile size: %u\n", ShadingRateTileSize);
        }
    }
    else
    {
        // These values should be already set from the call above, but I set them again here just for clarification :)
        ShadingRateTier = D3D12_VARIABLE_SHADING_RATE_TIER_NOT_SUPPORTED;
        printf("VRS not supported on this hardware!\n");
        ShadingRateAdditionalShadingRatesSupported = 0;
        ShadingRateTileSize = 0;
    }

    D3D12_FEATURE_DATA_D3D12_OPTIONS10 options2 = {};
    if (SUCCEEDED(g_Device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS10, &options2, sizeof(options2))))
    {
        printf("VariableRateShadingSumCombiner: %d\nMeshShaderPerPrimitiveShading %d\n", options2.VariableRateShadingSumCombinerSupported, options2.MeshShaderPerPrimitiveShadingRateSupported);
    }
}

VRS::Combiners VRS::SetCombinerUI(std::wstring combiner )
{
    combiner = Utility::ToLower(combiner);
    if (combiner.compare(L"passthrough") == 0)
    {
        return Combiners::Passthrough;
    }
    else if (combiner.compare(L"override") == 0)
    {
        return Combiners::Override;
    }
    else if (combiner.compare(L"min") == 0)
    {
        return Combiners::Min;
    }
    else if (combiner.compare(L"max") == 0)
    {
        return Combiners::Max;
    }
    else if (combiner.compare(L"sum") == 0)
    {
        return Combiners::Sum;
    }
    else
    {
        printf("User did not enter valid shading rate combiner. Defaulting to passthrough.\n");
        return Combiners::Passthrough;
    }
}

VRS::ShadingMode VRS::GetShadingMode(const char* mode)
{
    VRS::ShadingMode selectedMode = VRS::ShadingMode::QuadrantCPU;

    if (!strcmp(mode, "Quadrant (CPU)"))
    {
        selectedMode = ShadingMode::QuadrantCPU;
    }
    else if (!strcmp(mode, "Checkerboard (CPU)"))
    {
        selectedMode = ShadingMode::CheckerboardCPU;
    }
    else if (!strcmp(mode, "Foveated (GPU)"))
    {
        selectedMode = ShadingMode::FoveatedGPU;
    }
    else if (!strcmp(mode, "Depth LOD (GPU)"))
    {
        selectedMode = ShadingMode::DepthLoDGPU;
    }
    else if (!strcmp(mode, "Depth DoF (GPU)"))
    {
        selectedMode = ShadingMode::DepthDoFGPU;
    }
    else if (!strcmp(mode, "Compute Test (GPU)"))
    {
        selectedMode = ShadingMode::ComputeTestGPU;
    }
    else if (!strcmp(mode, "Contrast Adaptive (GPU)"))
    {
        selectedMode = ShadingMode::ContrastAdaptiveGPU;
    }
    return selectedMode;
}

VRS::ComputeTestModes VRS::GetComputeTestMode(const char* mode)
{
   VRS::ComputeTestModes selectedMode = VRS::ComputeTestModes::GroupID;

   if (!strcmp(mode, "Group ID"))
    {
        selectedMode = ComputeTestModes::GroupID;
    }
    else if (!strcmp(mode, "Group Index"))
    {
        selectedMode = ComputeTestModes::GroupIndex;
    }
    else if (!strcmp(mode, "Group Thread ID"))
    {
        selectedMode = ComputeTestModes::GroupThreadID;
    }
    else if (!strcmp(mode, "Dispatch Thread ID"))
    {
        selectedMode = ComputeTestModes::DispatchThreadID;
    }
    else if (!strcmp(mode, "Target Color"))
    {
       selectedMode = ComputeTestModes::TargetColor;
    }
    else if (!strcmp(mode, "Luma"))
    {
       selectedMode = ComputeTestModes::Luma;
    }
    else if (!strcmp(mode, "Log Luma"))
    {
       selectedMode = ComputeTestModes::LogLuma;
    }
    else if (!strcmp(mode, "Avg. Tile Luma"))
    {
       selectedMode = ComputeTestModes::AvgTileLuma;
    }
    else if (!strcmp(mode, "Velocity"))
    {
       selectedMode = ComputeTestModes::Velocity;
    }
    else if (!strcmp(mode, "MSE Luma X"))
    {
       selectedMode = ComputeTestModes::MSELumaX;
    }
    else if (!strcmp(mode, "MSE Luma Y"))
    {
       selectedMode = ComputeTestModes::MSELumaY;
    }
    else if (!strcmp(mode, "MSE Luma XY"))
    {
       selectedMode = ComputeTestModes::MSELumaXY;
    }
    else if (!strcmp(mode, "Wave Lane"))
    {
       selectedMode = ComputeTestModes::WaveLane;
    }
    return selectedMode;
}

D3D12_SHADING_RATE_COMBINER VRS::GetCombiner(const char* combiner)
{
    if (strcmp(combiner, "Passthrough") == 0)
    {
        return D3D12_SHADING_RATE_COMBINER_PASSTHROUGH;
    }
    else if (strcmp(combiner, "Override") == 0)
    {
        return D3D12_SHADING_RATE_COMBINER_OVERRIDE;
    }
    else if (strcmp(combiner, "Min") == 0)
    {
        return D3D12_SHADING_RATE_COMBINER_MIN;
    }
    else if (strcmp(combiner, "Max") == 0)
    {
        return D3D12_SHADING_RATE_COMBINER_MAX;
    }
    else if (strcmp(combiner, "Sum") == 0)
    {
        return D3D12_SHADING_RATE_COMBINER_SUM;
    }
    else
    {
        printf("Could not retrieve shading rate combiner. Setting to passthrough.\n");
        return D3D12_SHADING_RATE_COMBINER_PASSTHROUGH;
    }
}

D3D12_SHADING_RATE VRS::GetCurrentTier1ShadingRate(EnumVar shadingRate)
{
    D3D12_SHADING_RATE rate = (D3D12_SHADING_RATE)-1;

    //Map to UI values in VRSShadingRate
    switch (shadingRate) {
    case 0:
        rate = D3D12_SHADING_RATE_1X1;
        break;
    case 1:
        rate = D3D12_SHADING_RATE_1X2;
        break;
    case 2:
        rate = D3D12_SHADING_RATE_2X1;
        break;
    case 3:
        rate = D3D12_SHADING_RATE_2X2;
        break;
    case 4:
        if(ShadingRateAdditionalShadingRatesSupported)
            rate = D3D12_SHADING_RATE_2X4;
        break;
    case 5:
        if (ShadingRateAdditionalShadingRatesSupported)
            rate = D3D12_SHADING_RATE_4X2;
        break;
    case 6:
        if (ShadingRateAdditionalShadingRatesSupported)
            rate = D3D12_SHADING_RATE_4X4;
        break;
    }

    if (rate == ((D3D12_SHADING_RATE)-1))
    {
        printf("User did not enter valid shading rate input or additional shading rates not supported. Defaulting to 1X1.\n");
        rate = D3D12_SHADING_RATE_1X1;
    }

    return rate;
}

void VRS::Shutdown(void) {
    VRSReadbackBuffer.Destroy();
}

bool VRS::IsVRSSupported() {
    bool isSupported = true;
    if (ShadingRateTier == D3D12_VARIABLE_SHADING_RATE_TIER_NOT_SUPPORTED) {
        isSupported = false;
    }

    return isSupported;
}

bool VRS::IsVRSRateSupported(D3D12_SHADING_RATE rate) {
    bool isRateSupported = true;
    if (ShadingRateTier == D3D12_VARIABLE_SHADING_RATE_TIER_NOT_SUPPORTED) {
        isRateSupported = false;
    }

    if (!ShadingRateAdditionalShadingRatesSupported && rate > D3D12_SHADING_RATE_2X2) {
        isRateSupported = false;
    }

    return isRateSupported;
}

bool VRS::IsVRSTierSupported(D3D12_VARIABLE_SHADING_RATE_TIER tier) {
    return (ShadingRateTier >= tier);
}

// ----------------------
// |         |          |
// |   1x1   |   1x2    |
// |---------|----------|
// |         |          |
// |   2x2   |   4x4    |
// ----------------------
std::vector<UINT8> VRS::GenerateVRSTextureData()
{
    const UINT VRSTextureWidth = (UINT)ceil((float)g_DisplayWidth / (float)ShadingRateTileSize);
    const UINT VRSTextureHeight = (UINT)ceil((float)g_DisplayHeight / (float)ShadingRateTileSize) + ShadingRateTileSize;
    const UINT VRSTextureSize = VRSTextureHeight * VRSTextureWidth;

    std::vector<UINT8> data(VRSTextureSize);

    const UINT heightMid = (UINT)ceil((float)VRSTextureHeight / 2.0f);
    const UINT widthMid = (UINT)ceil((float)VRSTextureWidth / 2.0f);

    VRS::ShadingMode mode = (VRS::ShadingMode)((int32_t)VRS::ShadingModes);

    for (UINT yy = 0; yy < VRSTextureHeight; yy++)
    {
        for (UINT xx = 0; xx < VRSTextureWidth; xx++)
        {
            UINT8 rate = {};
            switch (mode)
            {
            case ShadingMode::QuadrantCPU:
                if (xx < widthMid)
                {
                    if (yy < heightMid)
                    {
                        rate = D3D12_SHADING_RATE_1X1;
                    }
                    else
                    {
                        rate = D3D12_SHADING_RATE_2X2;
                    }
                }
                else
                {
                    if (yy < heightMid)
                    {
                        rate = D3D12_SHADING_RATE_1X2;
                    }
                    else
                    {
                        rate = D3D12_SHADING_RATE_4X4;
                    }
                }
                break;
            case ShadingMode::CheckerboardCPU:
                if ((xx + yy) % 2 == 0)
                {
                    rate = D3D12_SHADING_RATE_1X1;
                }
                else
                {
                    rate = D3D12_SHADING_RATE_2X2;
                }
                break;
            }

            data[(yy * VRSTextureWidth + xx)] = rate;
        }
    }
    return data;
}

void VRS::UploadTextureData(GpuResource& Dest, uint32_t NumSubresources, D3D12_SUBRESOURCE_DATA SubData[])
{
    UINT64 uploadBufferSize = GetRequiredIntermediateSize(Dest.GetResource(), 0, NumSubresources);

    CommandContext& InitContext = CommandContext::Begin();

    InitContext.TransitionResource(Dest, D3D12_RESOURCE_STATE_COPY_DEST, true);

    // copy data to the intermediate upload heap and then schedule a copy from the upload heap to the default texture
    DynAlloc mem = InitContext.ReserveUploadMemory(uploadBufferSize);
    UpdateSubresources(InitContext.GetCommandList(), Dest.GetResource(), mem.Buffer.GetResource(), 0, 0, NumSubresources, SubData);

    // Execute the command list and wait for it to finish so we can release the upload buffer
    InitContext.Finish(true);
}

void VRS::CreateSubresourceData()
{
    if (IsVRSTierSupported(D3D12_VARIABLE_SHADING_RATE_TIER_2))
    {
        std::vector<UINT8> texture = GenerateVRSTextureData();

        D3D12_SUBRESOURCE_DATA VRSTextureData = {};
        VRSTextureData.pData = &texture[0];
        VRSTextureData.RowPitch = (UINT)ceil((float)g_DisplayWidth / (float)ShadingRateTileSize);
        VRSTextureData.SlicePitch = VRSTextureData.RowPitch * ((UINT)ceil((float)g_DisplayHeight / (float)ShadingRateTileSize));

        UploadTextureData(g_VRSTier2Buffer, 1, &VRSTextureData);
    }
}

void VRS::Update()
{
    static float prevCenterX = 0.0f;
    static float prevCenterY = 0.0f;
    static bool wasTrackMouse = false;

    if (IsVRSTierSupported(D3D12_VARIABLE_SHADING_RATE_TIER_2))
    {
        VRS::ShadingMode mode = (VRS::ShadingMode)((int32_t)VRS::ShadingModes);

        if (mode == VRS::ShadingMode::QuadrantCPU)
        {
            VRS::CreateSubresourceData();
        }

        if (mode == VRS::ShadingMode::CheckerboardCPU)
        {
            VRS::CreateSubresourceData();
        }

        if(mode == VRS::ShadingMode::ContrastAdaptiveGPU)
        {
            if ((bool)ConstrastAdaptiveDynamic)
            {
                ContrastAdaptiveSensitivityThreshold = EngineProfiling::GetGpuTime() / (1000.0f / (float)ConstrastAdaptiveDynamicFPS);
            }
        }

        if ((bool)FoveatedTrackMouse)
        {
            POINT p;
            if (GetCursorPos(&p))
            {
                const UINT VRSTextureWidth = (UINT)ceil((float)g_DisplayWidth / (float)ShadingRateTileSize);
                const UINT VRSTextureHeight = (UINT)ceil((float)g_DisplayHeight / (float)ShadingRateTileSize);

                if (!wasTrackMouse)
                {
                    prevCenterX = (float)FoveatedCenterOffsetX;
                    prevCenterY = (float)FoveatedCenterOffsetY;
                    wasTrackMouse = true;
                }

                FoveatedCenterOffsetX = p.x / ShadingRateTileSize - (VRSTextureWidth / 2.0f);
                FoveatedCenterOffsetY = p.y / ShadingRateTileSize - (VRSTextureHeight / 2.0f);
            }

            ShowCursor(true);
        }
        else
        {
            if (wasTrackMouse)
            {
                FoveatedCenterOffsetX = prevCenterX;
                FoveatedCenterOffsetY = prevCenterY;

                wasTrackMouse = false;
            }
        }
    }
}

void VRS::Render(ComputeContext& Context)
{
    if (IsVRSTierSupported(D3D12_VARIABLE_SHADING_RATE_TIER_2))
    {
        VRS::ShadingMode mode = (VRS::ShadingMode)((int32_t)VRS::ShadingModes);

        if (mode == VRS::ShadingMode::DepthLoDGPU)
        {
            ScopedTimer _prof(L"VRS Depth", Context);
            ColorBuffer& Target = g_bTypedUAVLoadSupport_R11G11B10_FLOAT ? g_SceneColorBuffer : g_PostEffectsBuffer;
            D3D12_CPU_DESCRIPTOR_HANDLE Pass1UAVs[] =
            {
                g_VRSTier2Buffer.GetUAV(),
                Target.GetUAV(),
            };

            D3D12_CPU_DESCRIPTOR_HANDLE Pass1SRVs[] =
            {
                g_SceneDepthBuffer.GetDepthSRV()
            };

            Context.SetRootSignature(Depth_RootSig);
            Context.SetConstant(0, 0, ShadingRateTileSize);
            Context.SetConstant(0, 1, (float)DepthLODNear);
            Context.SetConstant(0, 2, (float)DepthLODFar);
            Context.SetConstant(0, 3, (float)DepthCameraNear);
            Context.SetConstant(0, 4, (float)DepthCameraFar);
            Context.SetDynamicDescriptors(1, 0, _countof(Pass1UAVs), Pass1UAVs);
            Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.TransitionResource(Target, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.SetDynamicDescriptors(2, 0, _countof(Pass1SRVs), Pass1SRVs);
            Context.TransitionResource(g_SceneDepthBuffer, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            Context.SetPipelineState(VRSDepthCS);
            Context.Dispatch((UINT)ceil((float)Target.GetWidth() / (float)ShadingRateTileSize),
                             (UINT)ceil((float)Target.GetHeight() / (float)ShadingRateTileSize));
        }
        else if (mode == VRS::ShadingMode::FoveatedGPU)
        { 
            ScopedTimer _prof(L"VRS Foveated", Context);
            const UINT VRSTextureWidth = (UINT)ceil((float)g_DisplayWidth / (float)ShadingRateTileSize);
            const UINT VRSTextureHeight = (UINT)ceil((float)g_DisplayHeight / (float)ShadingRateTileSize);

            ColorBuffer& Target = g_bTypedUAVLoadSupport_R11G11B10_FLOAT ? g_SceneColorBuffer : g_PostEffectsBuffer;
            D3D12_CPU_DESCRIPTOR_HANDLE Pass1UAVs[] =
            {
                g_VRSTier2Buffer.GetUAV(),
                Target.GetUAV(),
            };

            Context.SetRootSignature(Foveated_RootSig);
            Context.SetConstant(0, 0, ShadingRateTileSize);
            Context.SetConstant(0, 1, (int)FoveatedInnerRadius);
            Context.SetConstant(0, 2, (int)FoveatedOuterRadius);
            Context.SetConstant(0, 3, (int)FoveatedCenterOffsetX);
            Context.SetConstant(0, 4, (int)FoveatedCenterOffsetY);
            Context.SetConstant(0, 5, VRSTextureWidth);
            Context.SetConstant(0, 6, VRSTextureHeight);
            Context.SetDynamicDescriptors(1, 0, _countof(Pass1UAVs), Pass1UAVs);
            Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.TransitionResource(Target, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.SetPipelineState(VRSFoveatedScreenSpaceCS);
            Context.Dispatch((UINT)ceil((float)Target.GetWidth() / (float)ShadingRateTileSize),
                             (UINT)ceil((float)Target.GetHeight() / (float)ShadingRateTileSize));
        }
        else if (mode == VRS::ShadingMode::DepthDoFGPU)
        {
            DepthOfField::RenderVRSBuffer(Context, (bool)DepthDoFQuality);
        }
        else if (mode == ShadingMode::ComputeTestGPU)
        {
            VRS::ComputeTestModes computeTestMode = (VRS::ComputeTestModes)((int32_t)VRS::ComputeTestMode);

            ColorBuffer& Target = g_bTypedUAVLoadSupport_R11G11B10_FLOAT ? g_SceneColorBuffer : g_PostEffectsBuffer;

            D3D12_CPU_DESCRIPTOR_HANDLE Pass1UAVs[] =
            {
                g_VRSTier2Buffer.GetUAV(),
                Target.GetUAV(),
                g_VelocityBuffer.GetUAV()
            };

            Context.SetRootSignature(ComputeTest_RootSig);
            Context.SetConstant(0, 0, Target.GetWidth());
            Context.SetConstant(0, 1, Target.GetHeight());
            Context.SetConstant(0, 2, (UINT)ShadingRateTileSize);
            Context.SetConstant(0, 3, computeTestMode);
            Context.SetConstant(0, 4, (bool)DebugDrawDrawGrid);
            Context.SetConstant(0, 5, (float)ContrastAdaptiveSensitivityThreshold);
            Context.SetConstant(0, 6, (float)ContrastAdaptiveEnvLuma);
            Context.SetConstant(0, 7, (float)ContrastAdaptiveK);
            Context.SetDynamicDescriptors(1, 0, _countof(Pass1UAVs), Pass1UAVs);
            Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.TransitionResource(Target, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.TransitionResource(g_VelocityBuffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.SetPipelineState(VRSComputeTestCS);
            Context.Dispatch((UINT)ceil((float)Target.GetWidth() / (float)ShadingRateTileSize), 
                             (UINT)ceil((float)Target.GetHeight() / (float)ShadingRateTileSize));

            return;
        }
        else if (mode == ShadingMode::ContrastAdaptiveGPU)
        {
            ColorBuffer& Target = g_bTypedUAVLoadSupport_R11G11B10_FLOAT ? g_SceneColorBuffer : g_PostEffectsBuffer;

            D3D12_CPU_DESCRIPTOR_HANDLE Pass1UAVs[] =
            {
                g_VRSTier2Buffer.GetUAV(),
                Target.GetUAV(),
                g_VelocityBuffer.GetUAV()
            };

            Context.SetRootSignature(ContrastAdaptive_RootSig);
            Context.SetConstant(0, 0, Target.GetWidth());
            Context.SetConstant(0, 1, Target.GetHeight());
            Context.SetConstant(0, 2, ShadingRateTileSize);
            Context.SetConstant(0, 3, (float)ContrastAdaptiveSensitivityThreshold);
            Context.SetConstant(0, 4, (float)ContrastAdaptiveEnvLuma);
            Context.SetConstant(0, 5, (float)ContrastAdaptiveK);
            Context.SetConstant(0, 6, (float)ContrastAdaptiveWeberFechnerConstant);
            Context.SetConstant(0, 7, (bool)ContrastAdaptiveUseWeberFechner);
            Context.SetConstant(0, 8, (bool)ContrastAdaptiveUseMotionVectors);
            Context.SetDynamicDescriptors(1, 0, _countof(Pass1UAVs), Pass1UAVs);
            Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.TransitionResource(Target, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.TransitionResource(g_VelocityBuffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.SetPipelineState(VRSContrastAdaptiveCS);
            Context.Dispatch((UINT)ceil((float)Target.GetWidth() / (float)ShadingRateTileSize),
                             (UINT)ceil((float)Target.GetHeight() / (float)ShadingRateTileSize));
        }

        if ((bool)MaskPostProcessSingleVN || (bool)MaskPostProcessSingleM)
        {            
            ScopedTimer _prof(L"VRS Post Process Single Elimination", Context);
            D3D12_CPU_DESCRIPTOR_HANDLE Pass1UAVs[] =
            {
                g_VRSTier2Buffer.GetUAV(),
            };

            Context.SetRootSignature(PostProcess_RootSig);
            Context.SetConstant(0, 0, ShadingRateTileSize);
            Context.SetConstant(0, 1, (bool)MaskPostProcessSingleVN);
            Context.SetDynamicDescriptors(1, 0, _countof(Pass1UAVs), Pass1UAVs);
            Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.SetPipelineState(VRSPostSingleEliminationCS);
            Context.Dispatch2D((UINT)ceil((float)g_DisplayWidth / (float)ShadingRateTileSize),
                               (UINT)ceil((float)g_DisplayHeight / (float)ShadingRateTileSize));
        }

        if (DebugDraw)
        {
            ScopedTimer _prof(L"VRS Debug", Context);
            ColorBuffer& Target = g_bTypedUAVLoadSupport_R11G11B10_FLOAT ? g_SceneColorBuffer : g_PostEffectsBuffer;
            D3D12_CPU_DESCRIPTOR_HANDLE Pass1UAVs[] =
            {
                g_VRSTier2Buffer.GetUAV(),
                Target.GetUAV(),
            };

            Context.SetRootSignature(Debug_RootSig);
            Context.SetConstant(0, 0, ShadingRateTileSize);
            Context.SetConstant(0, 1, (bool)DebugDrawBlendMask);
            Context.SetConstant(0, 2, (bool)DebugDrawDrawGrid);
            Context.SetDynamicDescriptors(1, 0, _countof(Pass1UAVs), Pass1UAVs);
            Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.TransitionResource(Target, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Context.SetPipelineState(VRSDebugScreenSpaceCS);
            Context.Dispatch((UINT)ceil((float)Target.GetWidth() / (float)ShadingRateTileSize),
                             (UINT)ceil((float)Target.GetHeight() / (float)ShadingRateTileSize));
        }

        Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_SHADING_RATE_SOURCE, true);
    }
}

void VRS::CalculateShadingRatePercentages(CommandContext& Context)
{
    uint8_t* vrsreadbackptr = nullptr;
    uint32_t vrsRowPitchInBytes = 0;

    int vrsHeight = g_VRSTier2Buffer.GetHeight();
    int vrsWidth = g_VRSTier2Buffer.GetWidth();

    vrsRowPitchInBytes = Context.ReadbackTexture(VRSReadbackBuffer, g_VRSTier2Buffer);
    Context.TransitionResource(g_VRSTier2Buffer, D3D12_RESOURCE_STATE_SHADING_RATE_SOURCE, true);
    Context.Finish(true);
    
    Percents.num1x1 = 0;
    Percents.num1x2 = 0;
    Percents.num2x1 = 0;
    Percents.num2x2 = 0;
    Percents.num2x4 = 0;
    Percents.num4x2 = 0;
    Percents.num4x4 = 0;

    if (!(bool)VRS::Enable)
    {
        Percents.num1x1 = 100;
        return;
    }

    vrsreadbackptr = (uint8_t*)VRSReadbackBuffer.Map();

    int totalPixels = vrsHeight * vrsWidth;
    for (int yy = 0; yy < vrsHeight; yy++)
    {
        for (int xx = 0; xx < vrsWidth; xx++)
        {
            uint8_t currentPixel = vrsreadbackptr[yy * vrsRowPitchInBytes + xx];
            switch (currentPixel)
            {
            case D3D12_SHADING_RATE_1X1:
                Percents.num1x1++;
                break;
            case D3D12_SHADING_RATE_1X2:
                Percents.num1x2++;
                break;
            case D3D12_SHADING_RATE_2X1:
                Percents.num2x1++;
                break;
            case D3D12_SHADING_RATE_2X2:
                Percents.num2x2++;
                break;
            case D3D12_SHADING_RATE_2X4:
                Percents.num2x4++;
                break;
            case D3D12_SHADING_RATE_4X2:
                Percents.num4x2++;
                break;
            case D3D12_SHADING_RATE_4X4:
                Percents.num4x4++;
            }
        }
    }
    Percents.num1x1 = ((float)Percents.num1x1 / (float)totalPixels) * 100.0f;
    Percents.num1x2 = ((float)Percents.num1x2 / (float)totalPixels) * 100.0f;
    Percents.num2x1 = ((float)Percents.num2x1 / (float)totalPixels) * 100.0f;
    Percents.num2x2 = ((float)Percents.num2x2 / (float)totalPixels) * 100.0f;
    Percents.num2x4 = ((float)Percents.num2x4 / (float)totalPixels) * 100.0f;
    Percents.num4x2 = ((float)Percents.num4x2 / (float)totalPixels) * 100.0f;
    Percents.num4x4 = ((float)Percents.num4x4 / (float)totalPixels) * 100.0f;
    VRSReadbackBuffer.Unmap();
}