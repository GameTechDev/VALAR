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

#include "DoFCommon.hlsli"

StructuredBuffer<uint> WorkQueue : register(t5);
RWTexture2D<uint> VRSShadingRateBuffer : register(u0);

void SetShadingRate(int2 st, uint rate)
{
    VRSShadingRateBuffer[st] = rate;
}

enum shadingRates
{
    SHADING_RATE_1X1 = 0x0,
    SHADING_RATE_1X2 = 0x1,
    SHADING_RATE_2X1 = 0x4,
    SHADING_RATE_2X2 = 0x5,
    SHADING_RATE_2X4 = 0x6,
    SHADING_RATE_4X2 = 0x9,
    SHADING_RATE_4X4 = 0xa,
};

[RootSignature(DoF_RootSig)]
[numthreads( 16, 16, 1 )]
void main( uint3 Gid : SV_GroupID, uint3 GTid : SV_GroupThreadID )
{
    uint TileCoord = WorkQueue[Gid.x];
    uint2 Tile = uint2(TileCoord & 0xFFFF, TileCoord >> 16);
    uint2 st = Tile * 16 + GTid.xy;

    //DstColor[st] = float3(0, 0, 1);
    SetShadingRate(st / ShadingRateTileSize, SHADING_RATE_1X1);
}
