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

#pragma once

class ColorBuffer;
class BoolVar;
class NumVar;
class NumVar;
class ComputeContext;
class GpuResource;

#define QUERY_PSINVOCATIONS

namespace Math { class Camera; }

namespace VRS
{
    extern BoolVar Enable;
    extern BoolVar DebugDraw;
    extern BoolVar DebugDrawBlendMask;
    extern BoolVar DebugDrawDrawGrid;
    extern EnumVar VRSShadingRate;
    extern EnumVar ShadingRateCombiners1;
    extern EnumVar ShadingRateCombiners2;
    extern EnumVar ShadingModes;
    extern BoolVar CalculatePercents;

    extern NumVar ContrastAdaptiveK;
    extern NumVar ContrastAdaptiveSensitivityThreshold;
    extern NumVar ContrastAdaptiveEnvLuma;
    extern NumVar ContrastAdaptiveWeberFechnerConstant;
    extern BoolVar ContrastAdaptiveUseWeberFechner;
    extern BoolVar ContrastAdaptiveUseMotionVectors;

    extern D3D12_VARIABLE_SHADING_RATE_TIER ShadingRateTier;
    extern UINT ShadingRateTileSize;
    extern BOOL ShadingRateAdditionalShadingRatesSupported;
    extern D3D12_QUERY_DATA_PIPELINE_STATISTICS PipelineStatistics;

    struct ShadingRatePercents
    {
        float num1x1 = 0;
        float num2x2 = 0;
        float num1x2 = 0;
        float num2x1 = 0;
        float num2x4 = 0;
        float num4x2 = 0;
        float num4x4 = 0;
    };
    extern ShadingRatePercents Percents;

    enum ShadingRates
    {
        OneXOne, 
        OneXTwo, 
        TwoXOne, 
        TwoXTwo, 
        TwoXFour, 
        FourXTwo, 
        FourXFour
    };

    enum Combiners
    {
        Passthrough, 
        Override, 
        Min, 
        Max, 
        Sum
    };

    enum ShadingMode
    {
        QuadrantCPU, 
        CheckerboardCPU, 
        FoveatedGPU, 
        DepthLoDGPU, 
        DepthDoFGPU, 
        ComputeTestGPU,
        ContrastAdaptiveGPU,
    };

    enum ComputeTestModes
    {
        TargetColor, 
        GroupID, 
        GroupIndex, 
        GroupThreadID, 
        DispatchThreadID, 
        Velocity, 
        Luma, 
        LogLuma, 
        AvgTileLuma,  
        MSELumaX, 
        MSELumaY,
        MSELumaXY,
        WaveLane,
    };

    void Initialize(void);
    void CheckHardwareSupport(void);
    void ParseCommandLine(void);
    void Update();
    void Render(ComputeContext& Context);
    void Shutdown(void);
    
    Combiners SetCombinerUI(std::wstring);
    D3D12_SHADING_RATE_COMBINER GetCombiner(const char*);
    D3D12_SHADING_RATE GetCurrentTier1ShadingRate(EnumVar);

    bool IsVRSSupported();
    bool IsVRSRateSupported(D3D12_SHADING_RATE rate);
    bool IsVRSTierSupported(D3D12_VARIABLE_SHADING_RATE_TIER tier);

    std::vector<UINT8> GenerateVRSTextureData();
    void CreateSubresourceData();
    void UploadTextureData(GpuResource& Dest, uint32_t NumSubresources, D3D12_SUBRESOURCE_DATA SubData[]);

    ShadingMode GetShadingMode(const char*);
    ComputeTestModes GetComputeTestMode(const char* mode);

    void CalculateShadingRatePercentages(CommandContext& Context);

} // namespace VRS
