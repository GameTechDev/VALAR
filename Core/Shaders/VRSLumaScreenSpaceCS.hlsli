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

#include "VRSCommon.hlsli"

#define VRS_RootSig \
    "RootFlags(0), " \
    "RootConstants(b0, num32BitConstants=8), " \
    "DescriptorTable(UAV(u0, numDescriptors = 4))," \
    "DescriptorTable(SRV(t0, numDescriptors = 1)),"

cbuffer CB0 : register(b0)
{
    float2 RcpTextureSize;
    uint ShadingRateTileSize;
    float k;// Provided in http://leiy.cc/publications/nas/nas-pacmcgit.pdf for quarter rate shading
    float SensitivityThreshold;
    float EnvLuma;
    bool UsePrecomputedLuma;
    bool UseLinearLuma;
    //float ContrastThreshold;    // default = 0.2, lower is more expensive
    //float SubpixelRemoval;        // default = 0.75, lower blurs less
    //uint2 StartPixel;
}

// If pre-computed, source luminance as a texture, otherwise write it out for Pass2
Texture2D<float> LumaSRV : register(t0);
RWTexture2D<float> LumaUAV : register(u2);
RWTexture2D<float> VelocityUAV : register(u3);

#if SUPPORT_TYPED_UAV_LOADS
    RWTexture2D<float3> PostEffectsImage : register(u1);
    float3 FetchColor(int2 st) { return PostEffectsImage[st]; }
    void SetColor(int2 st, float3 rgb)
    {
        PostEffectsImage[st] = rgb;
    }
#else
    #include "PixelPacking_R11G11B10.hlsli"
    RWTexture2D<uint> PostEffectsImage : register(u1);
    float3 FetchColor(int2 st) { return Unpack_R11G11B10_FLOAT(PostEffectsImage[st]); }
    void SetColor(int2 st, float3 rgb)
    {
        PostEffectsImage[st] = Pack_R11G11B10_FLOAT(rgb);
    }
#endif

groupshared float gs_LumaCache[ROW_WIDTH * ROW_WIDTH];

// Probably move these to CB
//static const uint THREAD_COUNT = 64;

//static const float k = 2.13; // Provided in http://leiy.cc/publications/nas/nas-pacmcgit.pdf for quarter rate shading
//static const  float sensitivity_threshold = 0.15f;
//static const float env_luma = 1.0f;// 0.05f;
//Texture2D<uint> InputBuf : register(t0);
//RWTexture2D<uint> Result : register(u0);

//groupshared uint tile_rate;



// Enable half rate shading rate when the per-tile error < threshold.
// The threshold is a "Just Noticable Difference Threshold":
// threshold = sensitivity_scale * base_luminance
// sensitivity_scale is a constant
// base_luminance depends on the luminance level
// 
// Quarter rate shading's error estimator ='s 2.13 * The half rate error
// Use quarter rate shading when this estimator is < the threshold
// 

[RootSignature(VRS_RootSig)]
[numthreads(GROUP_THREAD_X, GROUP_THREAD_Y, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    uint2 PixelCoord = DTid.xy;
    float3 color = FetchColor(PixelCoord);

    if (UsePrecomputedLuma)
    {
        // Load 4 lumas per thread into LDS (but only those needed to fill our pixel cache)
        if (max(GTid.x, GTid.y) < ROW_WIDTH / 2)
        {
            int2 ThreadUL = uint2(GI % ROW_WIDTH, GI / ROW_WIDTH) + Gid.xy * ShadingRateTileSize - BOUNDARY_SIZE;
            float4 Luma4 = LumaSRV.Gather(LinearSampler, ThreadUL * RcpTextureSize);
            uint LoadIndex = (GTid.x + GTid.y * ROW_WIDTH) * 2;
            gs_LumaCache[LoadIndex] = Luma4.w;
            gs_LumaCache[LoadIndex + 1] = Luma4.z;
            gs_LumaCache[LoadIndex + ROW_WIDTH] = Luma4.x;
            gs_LumaCache[LoadIndex + ROW_WIDTH + 1] = Luma4.y;
        }
    }
    else
    {
        // Because we can't use Gather() on RGB, we make each thread read two pixels (but= only those needed).
        if (GI < ROW_WIDTH * ROW_WIDTH / 2)
        {
            uint LdsCoord = GI;
            //int2 UavCoord = StartPixel + uint2(GI % ROW_WIDTH, GI / ROW_WIDTH) + Gid.xy * 1 - BOUNDARY_SIZE;
            int2 UavCoord = /*StartPixel +*/ uint2(GI % ROW_WIDTH, GI / ROW_WIDTH) + Gid.xy * ShadingRateTileSize - BOUNDARY_SIZE;
            float Luma1 = UseLinearLuma ? RGBToLuminance(FetchColor(UavCoord)) : RGBToLogLuminance(FetchColor(UavCoord));
            LumaUAV[UavCoord] = Luma1;
            gs_LumaCache[LdsCoord] = Luma1;
            LdsCoord += ROW_WIDTH * ROW_WIDTH / 2;
            UavCoord += int2(0, ROW_WIDTH / 2);
            float Luma2 = UseLinearLuma ? RGBToLuminance(FetchColor(UavCoord)) : RGBToLogLuminance(FetchColor(UavCoord));
            LumaUAV[UavCoord] = Luma2;
            gs_LumaCache[LdsCoord] = Luma2;
        }
    }

    GroupMemoryBarrierWithGroupSync();

    uint CenterIdx = (GTid.x + BOUNDARY_SIZE) + (GTid.y + BOUNDARY_SIZE) * ROW_WIDTH;

    // Load the ordinal and center luminances
    float lumaN = gs_LumaCache[CenterIdx - ROW_WIDTH];
    float lumaW = gs_LumaCache[CenterIdx - 1];
    float lumaM = gs_LumaCache[CenterIdx];
    float lumaE = gs_LumaCache[CenterIdx + 1];
    float lumaS = gs_LumaCache[CenterIdx + ROW_WIDTH];

    // Contrast threshold test
    //float rangeMax = max(max(lumaN, lumaW), max(lumaE, max(lumaS, lumaM)));
    //float rangeMin = min(min(lumaN, lumaW), min(lumaE, min(lumaS, lumaM)));
    //float range = rangeMax - rangeMin;
    //  if (range < ContrastThreshold)
    //      return;

      // Load the corner luminances
    float lumaNW = gs_LumaCache[CenterIdx - ROW_WIDTH - 1];
    float lumaNE = gs_LumaCache[CenterIdx - ROW_WIDTH + 1];
    float lumaSW = gs_LumaCache[CenterIdx + ROW_WIDTH - 1];
    float lumaSE = gs_LumaCache[CenterIdx + ROW_WIDTH + 1];

    // Pre-sum a few terms so the results can be reused
    float lumaNS = lumaN + lumaS;
    float lumaWE = lumaW + lumaE;
    float lumaNWSW = lumaNW + lumaSW;
    float lumaNESE = lumaNE + lumaSE;
    float lumaSWSE = lumaSW + lumaSE;
    float lumaNWNE = lumaNW + lumaNE;

    // Compute horizontal and vertical contrast; Sobel Filter
    float edgeHorz = abs(lumaNWSW - 2.0 * lumaW) + abs(lumaNS - 2.0 * lumaM) * 2.0 + abs(lumaNESE - 2.0 * lumaE);
    float edgeVert = abs(lumaSWSE - 2.0 * lumaS) + abs(lumaWE - 2.0 * lumaM) * 2.0 + abs(lumaNWNE - 2.0 * lumaN);

    // Average neighbor luma Horizontal & Vertical
    float avgNeighborLumaX = (lumaWE + lumaNWSW + lumaNESE + lumaM) / 7.0;
    float avgNeighborLumaY = (lumaNS + lumaNWSW + lumaNESE + lumaM) / 7.0;
    float avgNeighborLuma = ((lumaNS + lumaWE) * 2.0 + lumaNWSW + lumaNESE + lumaM) / 13.0;

    // Also compute local contrast in the 3x3 region.  This can identify standalone pixels that alias.
    
    //float subpixelShift = saturate(pow(smoothstep(0, 1, abs(avgNeighborLuma - lumaM) / range), 2) * SubpixelRemoval * 2);

    float NegGrad = (edgeHorz >= edgeVert ? lumaN : lumaW) - lumaM;
    float PosGrad = (edgeHorz >= edgeVert ? lumaS : lumaE) - lumaM;
    uint GradientDir = abs(PosGrad) >= abs(NegGrad) ? 1 : 0;
    //uint Subpix = uint(subpixelShift * 254.0) & 0xFE;

    float jnd_threshold = SensitivityThreshold * (avgNeighborLuma + EnvLuma);
    float jnd_thresholdX = SensitivityThreshold * (avgNeighborLumaX + EnvLuma);
    float jnd_thresholdY = SensitivityThreshold * (avgNeighborLumaY + EnvLuma);
    
    //float avgError = sqrt(avgNeighborLuma);
    float avgErrorX = sqrt(avgNeighborLumaX);
    float avgErrorY = sqrt(avgNeighborLumaY);

    const uint2 tile = Gid.xy;
    uint rate = SHADING_RATE_1X1;
    uint xRate = D3D12_AXIS_SHADING_RATE_1X;
    uint yRate = D3D12_AXIS_SHADING_RATE_1X;

    if (avgErrorX >= jnd_threshold)
    {
        xRate = D3D12_AXIS_SHADING_RATE_1X;
    }
    else if ((k * avgErrorX) < jnd_threshold)
    {
        xRate = D3D12_AXIS_SHADING_RATE_4X;
    }
    else
    {
        xRate = D3D12_AXIS_SHADING_RATE_2X;
    }

    if (avgErrorY >= jnd_threshold)
    {
        yRate = D3D12_AXIS_SHADING_RATE_1X;
    }
    else if ((k * avgErrorY) < jnd_threshold)
    {
        yRate = D3D12_AXIS_SHADING_RATE_4X;
    }
    else
    {
        yRate = D3D12_AXIS_SHADING_RATE_2X;
    }

    // Velocity Rates
    //float halfRate = pow(1.0 / (1.0 + pow(1.05 * v, 3.10)), 0.35);
    //float quarterRate = 2.13 * pow(1.0 / (1.0 + pow(0.55 * v, 2.14)), 0.49);

    // ToDo: does this need to loop over tiles?
    // Seperate x, Y Shading rates
    //const uint2 tile = Gid.xy;
    //uint rate = 0;
    //uint xRate = 0;
    //uint yRate = 0;

    //if (avgError >= jnd_threshold)
    //{
    //    // Full shading rate
    //    rate = SHADING_RATE_1X1;
    //}
    //else if ((k * avgError) < jnd_threshold)
    //{
    //    if (GradientDir)
    //    {
    //        xRate = D3D12_AXIS_SHADING_RATE_4X;
    //        yRate = D3D12_AXIS_SHADING_RATE_2X;
    //    }
    //    else
    //    {
    //        xRate = D3D12_AXIS_SHADING_RATE_2X;
    //        yRate = D3D12_AXIS_SHADING_RATE_4X;
    //    }

    //    rate = D3D12_MAKE_COARSE_SHADING_RATE(xRate, yRate);
    //}
    //else
    //{
    //    if (GradientDir)
    //    {
    //        xRate = D3D12_AXIS_SHADING_RATE_2X;
    //        yRate = D3D12_AXIS_SHADING_RATE_1X;
    //    }
    //    else
    //    {
    //        xRate = D3D12_AXIS_SHADING_RATE_1X;
    //        yRate = D3D12_AXIS_SHADING_RATE_2X;
    //    }

    //    rate = D3D12_MAKE_COARSE_SHADING_RATE(xRate, yRate);
    //}

    GroupMemoryBarrierWithGroupSync();

    if (GI == 0)
    {
        rate = D3D12_MAKE_COARSE_SHADING_RATE(xRate, yRate);
        SetShadingRate(tile, rate); 
    } 
}
