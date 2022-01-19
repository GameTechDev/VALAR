//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author:  James Stanard 
//

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

    //DstColor[st] = float3(0, 1, 0);
    SetShadingRate(st / ShadingRateTileSize, SHADING_RATE_2X2);
}
