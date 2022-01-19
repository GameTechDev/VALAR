#include "VRSCommon.hlsli"

#define VRS_RootSig \
    "RootFlags(0), " \
    "RootConstants(b0, num32BitConstants=5), " \
    "DescriptorTable(UAV(u0, numDescriptors = 2))," \
    "DescriptorTable(SRV(t0, numDescriptors = 1)),"

cbuffer CB0 : register(b0)
{
    uint ShadingRateTileSize;
    float LODNear;
    float LODFar;
    float CameraNear;
    float CameraFar;
}

SamplerState LinearSampler : register(s0);
Texture2D Depth : register(t0);

float FetchDepth(int2 st) { return Depth[st].r; }

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

//
// Helper functions
//
float LinearizeDepth(uint2 st)
{
    float depth = Depth[st].r;
    float dist = 1.0 / (((CameraFar - CameraNear) / CameraNear) * depth + 1.0);
    return dist;
}

[RootSignature(VRS_RootSig)]
[numthreads(GROUP_THREAD_X, GROUP_THREAD_Y, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    const uint2 tile = Gid.xy;
    uint2 PixelCoord = DTid.xy;
    int2 UavCoord = uint2(GI % ROW_WIDTH, GI / ROW_WIDTH) + Gid.xy * ShadingRateTileSize - BOUNDARY_SIZE;
    float d = LinearizeDepth(UavCoord);

    if (d >= LODFar)
    {
       SetShadingRate(tile, SHADING_RATE_4X4);
       return;
    }

    if (d >= LODNear)
    {
        SetShadingRate(tile, SHADING_RATE_2X2);
        return;
    }

    SetShadingRate(tile, SHADING_RATE_1X1);
}
