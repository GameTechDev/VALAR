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
#include "PixelPacking_Velocity.hlsli"

#define VRS_RootSig \
    "RootFlags(0), " \
    "RootConstants(b0, num32BitConstants=10), " \
    "DescriptorTable(UAV(u0, numDescriptors = 3))," \

cbuffer CB0 : register(b0)
{
    uint3 TextureSize;
    uint ShadingRateTileSize;
    float SensitivityThreshold;
    float EnvLuma;
    float K;
    float WeberFechnerConstant;
    bool UseWeberFechner;
    bool UseMotionVectors;
}

SamplerState LinearSampler : register(s0);

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

RWTexture2D<uint> VelocityBuffer : register(u2);

groupshared uint2 pixelCoordCache[NUM_THREADS];
groupshared float pixelLumaCache[NUM_THREADS];
groupshared float pixelLumaCacheDerivX[NUM_THREADS];
groupshared float pixelLumaCacheDerivY[NUM_THREADS];
groupshared float pixelVelocityCache[NUM_THREADS];

float ComputeAvgNeighborLuminance(uint2 PixelCoord)
{
    float totalLuma = 0.0;
    float avgLuma = 0.0;
    uint neighborCount = 0;

    [unroll] for (int y = 0; y < 4; y++)
    {
        [branch] if ((PixelCoord.y + y) < TextureSize.y)
        {
            uint2 neighbor = uint2(PixelCoord.x, PixelCoord.y + y);
            float3 color = FetchColor(neighbor);
            totalLuma = totalLuma + RGBToLuminance(color);

            neighbor = uint2(PixelCoord.x - 1, PixelCoord.y + y);
            color = FetchColor(neighbor);
            totalLuma = totalLuma + RGBToLuminance(color);

            neighborCount = neighborCount + 2;
        }
    }

    avgLuma = totalLuma / (float)neighborCount;

    return avgLuma;
}

[RootSignature(VRS_RootSig)]
[numthreads(GROUP_THREAD_X, GROUP_THREAD_Y, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    const uint2 PixelCoord = DTid.xy;

    // Fetch Colors from Color Buffer UAV
    const float3 color = FetchColor(PixelCoord);
    float3 colorXMinusOne;

    [branch] if (UseWeberFechner && PixelCoord.y % 2 == 0)
    {
        colorXMinusOne = FetchColor(uint2(PixelCoord.x + 1, PixelCoord.y));
    }
    else
    {
        colorXMinusOne = FetchColor(uint2(PixelCoord.x - 1, PixelCoord.y));;
    }

    const float3 colorYMinusOne = FetchColor(uint2(PixelCoord.x, PixelCoord.y - 1));

    // Convert RGB to luminance values
    const float pixelLuma = RGBToLuminance(color * color);
    const float pixelLumaXMinusOne = RGBToLuminance(colorXMinusOne * colorXMinusOne);
    const float pixelLumaYMinusOne = RGBToLuminance(colorYMinusOne * colorYMinusOne);

    // Local Variables for Weber-Fechner
    float avgNeighborLuma = 0.0;
    float BRIGHTNESS_SENSITIVITY = 0.0;

    // Luma Derivatives X/Y for Current Pixel
    float lumaDerivX = 0.0;
    float lumaDerivY = 0.0;

    // Cache some Data
    pixelCoordCache[GI] = PixelCoord;
    pixelLumaCache[GI] = pixelLuma;

    [branch] if (UseWeberFechner)
    {
        // Use Weber Fechner to create brightness sensitivity divisor.
        avgNeighborLuma = ComputeAvgNeighborLuminance(PixelCoord);
        BRIGHTNESS_SENSITIVITY = WeberFechnerConstant * (1.0 - saturate(avgNeighborLuma * 50.0 - 2.5));
    }

    [branch] if (PixelCoord.x > 0)
    {
        const float A = pixelLuma;
        const float B = pixelLumaXMinusOne;

        [branch] if (UseWeberFechner)
        {
            // When using Weber-Fechner Law https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law
            lumaDerivX = abs(A - B) / (min(A, B) + BRIGHTNESS_SENSITIVITY);
        }
        else
        {
            // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            lumaDerivX = abs(A - B) / 2.0;
        }

        // Store the X Luma Derivative
        pixelLumaCacheDerivX[GI] = lumaDerivX;
    }

    [branch] if (PixelCoord.y > 0)
    {
        const float A = pixelLuma;
        const float B = pixelLumaYMinusOne;

        [branch] if (UseWeberFechner)
        {
            // When using Weber-Fechner Law https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law
            lumaDerivY = abs(A - B) / (min(A, B) + BRIGHTNESS_SENSITIVITY);
        }
        else
        {
            // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            lumaDerivY = abs(A - B) / 2.0;
        }

        // Store the Y Luma Derivative
        pixelLumaCacheDerivY[GI] = lumaDerivY;
    }

    //if (UseMotionVectors)
    {
        const float3 velocity = UnpackVelocity(VelocityBuffer[PixelCoord]);
        pixelVelocityCache[GI] = length(velocity);
    }

    GroupMemoryBarrierWithGroupSync();

    [branch] if (GI == 0)
    {
        float totalTileLuma = 0.0;
        float totalTileLumaX = 0.0;
        float totalTileLumaY = 0.0;
        float minTileVelocity = 1000;

        for (int i = 0; i < NUM_THREADS; i++)
        {
            totalTileLuma = totalTileLuma + pixelLumaCache[i];

            if (pixelCoordCache[i].x > 0)
            {
                // Sum the X Luma Derivative
                totalTileLumaX = totalTileLumaX + pixelLumaCacheDerivX[i];
            }

            if (pixelCoordCache[i].y > 0)
            {
                // Sum the Y Luma Derivative
                totalTileLumaY = totalTileLumaY + pixelLumaCacheDerivY[i];
            }

            //if (UseMotionVectors)
            {
                const float magnitude = pixelVelocityCache[i];
                minTileVelocity = min(minTileVelocity, magnitude);
            }
        }

        // Compute Average Luminance of Current Tile
        const float avgTileLuma = totalTileLuma / (float)NUM_THREADS;

        // Correcting for N - 1 Columns
        const float avgTileLumaX = totalTileLumaX / (float)(NUM_THREADS - ShadingRateTileSize);

        // Correcting for N - 1 Rows
        const float avgTileLumaY = totalTileLumaY / (float)(NUM_THREADS - ShadingRateTileSize);

        // Satifying Equation 15 http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        const float jnd_threshold = SensitivityThreshold * (avgTileLuma + EnvLuma);

        // Compute the MSE error for Luma X/Y derivatives
        const float avgErrorX = sqrt(avgTileLumaX);
        const float avgErrorY = sqrt(avgTileLumaY);

        uint xRate = D3D12_AXIS_SHADING_RATE_2X;
        uint yRate = D3D12_AXIS_SHADING_RATE_2X;

        // Motion Vector based velocity compensation.
        float velocityHError = 1.0;
        float velocityQError = K;

        //if (UseMotionVectors)
        {
            // Satifying Equation 20. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            velocityHError = pow(1.0 / (1.0 + pow(1.05 * minTileVelocity, 3.10)), 0.35);

            // Satifying Equation 21. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            velocityQError = K * pow(1.0 / (1.0 + pow(0.55 * minTileVelocity, 2.41)), 0.49);
        }

        // Satifying Equation 16. For X http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        [branch] if ((velocityHError * avgErrorX) >= jnd_threshold)
        {
            xRate = D3D12_AXIS_SHADING_RATE_1X;
        }
        // Satifying Equation 14. For Qurter Rate Shading for X http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        else if ((velocityQError * avgErrorX) < jnd_threshold)
        {
            xRate = D3D12_AXIS_SHADING_RATE_4X;
        }

        // Satifying Equation 16 For Y http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        [branch] if ((velocityHError * avgErrorY) >= jnd_threshold)
        {
            // Logic to Prevent Invalid 4x1 shading Rate, converts to 4X2.
            yRate = (xRate == D3D12_AXIS_SHADING_RATE_4X ? D3D12_AXIS_SHADING_RATE_2X : D3D12_AXIS_SHADING_RATE_1X);
        }
        // Satifying Equation 14 For Qurter Rate Shading for Y http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        else if ((velocityQError * avgErrorY) < jnd_threshold)
        {
            // Logic to Prevent 4x4 Shading Rate and invalid 1X4, converts to 4x2 or 1x2.
            yRate = (xRate == D3D12_AXIS_SHADING_RATE_1X ? D3D12_AXIS_SHADING_RATE_2X : D3D12_AXIS_SHADING_RATE_4X);
        }

        SetShadingRate(Gid, D3D12_MAKE_COARSE_SHADING_RATE(xRate, yRate));
    }
}
