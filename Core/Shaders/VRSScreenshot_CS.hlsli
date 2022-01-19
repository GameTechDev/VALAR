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