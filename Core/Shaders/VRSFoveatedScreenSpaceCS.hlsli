#include "VRSCommon.hlsli"

#define VRS_RootSig \
    "RootFlags(0), " \
    "RootConstants(b0, num32BitConstants=7), " \
    "DescriptorTable(UAV(u0, numDescriptors = 2))" \

cbuffer CB0 : register(b0)
{
    uint ShadingRateTileSize;
    uint FoveatedInnerRadius;
    uint FoveatedOuterRadius;
    uint FoveatedOffsetX;
    uint FoveatedOffsetY;
    uint VRSBufferWidth;
    uint VRSBufferHeight;
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
    uint2 PixelCoord = DTid.xy;
    float3 result = { 1.0, 1.0, 1.0 };
    uint widthMid = VRSBufferWidth / 2;
    uint heightMid = VRSBufferHeight / 2;

    if (IsInsideCircle(widthMid + FoveatedOffsetX, heightMid + FoveatedOffsetY, FoveatedInnerRadius, PixelCoord.x / ShadingRateTileSize, PixelCoord.y / ShadingRateTileSize))
    {
        SetShadingRate(PixelCoord / ShadingRateTileSize, SHADING_RATE_1X1);
        return;
    }

    if (IsInsideCircle(widthMid + FoveatedOffsetX, heightMid + FoveatedOffsetY, FoveatedOuterRadius, PixelCoord.x / ShadingRateTileSize, PixelCoord.y / ShadingRateTileSize))
    {
        SetShadingRate(PixelCoord / ShadingRateTileSize, SHADING_RATE_2X2);
        return;
    }

    SetShadingRate(PixelCoord / ShadingRateTileSize, SHADING_RATE_4X4);
   
}
