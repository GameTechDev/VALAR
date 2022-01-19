#include "VRSCommon.hlsli"

#define VRS_RootSig \
    "RootFlags(0), " \
    "RootConstants(b0, num32BitConstants=2), " \
    "DescriptorTable(UAV(u0, numDescriptors = 1))"

cbuffer CB0 : register(b0)
{
    uint ShadingRateTileSize;
    bool VonNeumannNeighborhood;
}

[RootSignature(VRS_RootSig)]
[numthreads(GROUP_THREAD_X, GROUP_THREAD_Y, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    uint2 C = DTid.xy;

    uint2 N = { C.x, C.y + 1 };
    uint2 E = { C.x + 1, C.y };
    uint2 W = { C.x - 1, C.y };
    uint2 S = { C.x, C.y - 1 };

    uint2 NE = { C.x + 1, C.y + 1 };
    uint2 NW = { C.x - 1, C.y + 1 };
    uint2 SE = { C.x + 1, C.y - 1 };
    uint2 SW = { C.x - 1, C.y - 1 };

    uint CRate = GetShadingRate(C);

    uint NRate = GetShadingRate(N);
    uint ERate = GetShadingRate(E);
    uint WRate = GetShadingRate(W);
    uint SRate = GetShadingRate(S);

    uint NWRate = GetShadingRate(NW);
    uint NERate = GetShadingRate(NE);
    uint SERate = GetShadingRate(SE);
    uint SWRate = GetShadingRate(SW);

    GroupMemoryBarrierWithGroupSync();

    if (VonNeumannNeighborhood)
    {
        if (NRate == SRate && NRate == ERate && NRate == WRate && NRate != CRate)
        {
            SetShadingRate(C, NRate);
        }
    }
    else
    {
        if (NRate == SRate && NRate == ERate && NRate == WRate && NRate == NERate && NRate == NWRate && NRate == SERate && NRate == SWRate && NRate != CRate)
        {
            SetShadingRate(C, NRate);
        }
    }
}
