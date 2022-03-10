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
    "RootConstants(b0, num32BitConstants=3), " \
    "DescriptorTable(UAV(u0, numDescriptors = 2))"

cbuffer CB0 : register(b0)
{
    uint ShadingRateTileSize;
    bool BlendMask;
    bool DrawGrid;
}

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

[RootSignature(VRS_RootSig)]
[numthreads(GROUP_THREAD_X, GROUP_THREAD_Y, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    // VRS Debug Grid
    uint2 PixelCoord = DTid.xy;
    float3 color = { 0.2, 0.2, 0.2 };
    float3 result = { 1.0, 1.0, 1.0 };
    
    uint CurrShadingRate = VRSShadingRateBuffer[PixelCoord / ShadingRateTileSize];

    if (DrawGrid && (GTid.x == 0 || GTid.y == 0 || GTid.x == (ShadingRateTileSize) || GTid.y == (ShadingRateTileSize)))
    {
        result = float3(0.0, 0.0, 0.0);
        SetColor(PixelCoord, result);
        return;
    }

    if (CurrShadingRate == SHADING_RATE_1X1)
    {
        // White
        result = FetchColor(PixelCoord);
        SetColor(PixelCoord, result);
        return;
    }

    if ((CurrShadingRate == SHADING_RATE_1X2 || CurrShadingRate == SHADING_RATE_2X4) && IsIndicatorPosition(PixelCoord, ShadingRateTileSize))
    {
        SetColor(PixelCoord, float3(1.0, 1.0, 1.0));
        return;
    }
    
    if (CurrShadingRate == SHADING_RATE_1X2)
    {
        // Blue
        result = float3(1.0, 1.0, 6.0);        
    }
    else if (CurrShadingRate == SHADING_RATE_2X1)
    {
        // Blue
        result = float3(1.0, 1.0, 6.0);
    }
    else if (CurrShadingRate == SHADING_RATE_2X2)
    {
        // Green
        result = float3(1.0, 6.0, 1.0);
    }
    else if (CurrShadingRate == SHADING_RATE_4X4)
    {
        // Red
        result = float3(3.0, 1.0, 3.0);
    }
    else if (CurrShadingRate == SHADING_RATE_2X4)
    {
        // Brownish
        result = float3(6.0, 1.0, 1.0);
    }
    else if (CurrShadingRate == SHADING_RATE_4X2)
    {
        // Brownish
        result = float3(6.0, 1.0, 1.0);
    }

    if (BlendMask)
    {
        color = FetchColor(PixelCoord);
    }

    SetColor(PixelCoord, color * result);
}
