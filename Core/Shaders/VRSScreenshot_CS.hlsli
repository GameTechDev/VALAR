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

#include "ShaderUtility.hlsli"

#define Screenshot_RootSig \
    "RootFlags(0), " \
    "DescriptorTable(UAV(u0, numDescriptors = 2))"


#if SUPPORT_TYPED_UAV_LOADS
RWTexture2D<float3> SrcImage : register(u0);
float3 FetchColor(int2 st) { return SrcImage[st]; }
#else
#include "PixelPacking_R11G11B10.hlsli"
RWTexture2D<uint> SrcImage : register(u0);
float3 FetchColor(int2 st) { return Unpack_R11G11B10_FLOAT(SrcImage[st]); }
#endif

RWTexture2D<float4> DstImage : register(u1);


[RootSignature(Screenshot_RootSig)]
[numthreads(8, 8, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    uint2 PixelCoord = DTid.xy;
    float3 color = FetchColor(PixelCoord);
    float3 tonemap = ApplyDisplayProfile(color, DISPLAY_PLANE_FORMAT);
    DstImage[PixelCoord] = float4(tonemap, 1);
}