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
    "RootConstants(b0, num32BitConstants=9), " \
    "DescriptorTable(UAV(u0, numDescriptors = 3))," \

cbuffer CB0 : register(b0) {
    uint2 TextureSize;
    uint ShadingRateTileSize;
    float SensitivityThreshold;
    float EnvLuma;
    float K;
    float WeberFechnerConstant;
    bool UseWeberFechner;
    bool UseMotionVectors;
}

#define USE_VELOCITY
#define USE_WEBER_FECHNER

#define H_SLOPE ((0.0468f - 1.0f) / (16.0f - 0.0f))
#define Q_SLOPE ((0.1629f - K) / (16.0f - 0.0f))
#define H_INTERCEPT 1.0f;
#define Q_INTERCEPT K;

#if SUPPORT_TYPED_UAV_LOADS
RWTexture2D<float3> PostEffectsImage : register(u1);
float3 FetchColor(int2 st) { return PostEffectsImage[st]; }
#else
#include "PixelPacking_R11G11B10.hlsli"
RWTexture2D<uint> PostEffectsImage : register(u1);
float3 FetchColor(int2 st) { return Unpack_R11G11B10_FLOAT(PostEffectsImage[st]); }
#endif

#ifdef USE_VELOCITY
RWTexture2D<uint> VelocityBuffer : register(u2);
groupshared float waveVelocityMin[64];
#endif

groupshared float waveLumaSum[64];
groupshared float waveLumaSumX[64];
groupshared float waveLumaSumY[64];

#ifdef USE_WEBER_FECHNER

groupshared float neighborhood[GROUP_THREAD_X][GROUP_THREAD_Y];

float ComputeMinNeighborLuminance(uint2 PixelCoord)
{
    float minLuma = 10000.0f;

    int x = PixelCoord.x;
    int y = PixelCoord.y;
    int xPlus1 = x + 1;
    int xMinus1 = x - 1;
    int yPlus1 = y + 1;
    int yMinus1 = y - 1;

    uint2 N = uint2(x, yMinus1);
    uint2 NE = uint2(xPlus1, yMinus1);
    uint2 E = uint2(xPlus1, y);
    uint2 SE = uint2(xPlus1, yPlus1);
    uint2 S = uint2(x, yPlus1);
    uint2 SW = uint2(xMinus1, yPlus1);
    uint2 W = uint2(x, yPlus1);
    uint2 NW = uint2(xMinus1, yMinus1);

    float LumaN = neighborhood[N.x][N.y];
    float LumaNE = neighborhood[NE.x][NE.y];
    float LumaE = neighborhood[E.x][E.y];
    float LumaSE = neighborhood[SE.x][SE.y];
    float LumaS = neighborhood[S.x][S.y];
    float LumaSW = neighborhood[SW.x][SW.y];
    float LumaW = neighborhood[W.x][W.y];
    float LumaNW = neighborhood[NW.x][NW.y];

    minLuma = min(minLuma, LumaN);
    minLuma = min(minLuma, LumaNE);
    minLuma = min(minLuma, LumaE);
    minLuma = min(minLuma, LumaSE);
    minLuma = min(minLuma, LumaS);
    minLuma = min(minLuma, LumaSW);
    minLuma = min(minLuma, LumaW);
    minLuma = min(minLuma, LumaNW);

    return minLuma;
}
#endif

[RootSignature(VRS_RootSig)]
[numthreads(GROUP_THREAD_X, GROUP_THREAD_Y, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    const uint2 PixelCoord = DTid.xy;
    const int waveLaneCount = WaveGetLaneCount();

    // Fetch Colors from Color Buffer UAV
    const float3 color          = FetchColor(PixelCoord);
    const float3 colorXMinusOne = FetchColor(uint2(PixelCoord.x - 1, PixelCoord.y));
    const float3 colorYMinusOne = FetchColor(uint2(PixelCoord.x, PixelCoord.y - 1));

    // Convert RGB to luminance values
    const float pixelLuma          = RGBToLuminance(color * color);
    const float pixelLumaXMinusOne = RGBToLuminance(colorXMinusOne * colorXMinusOne);
    const float pixelLumaYMinusOne = RGBToLuminance(colorYMinusOne * colorYMinusOne);


    // Local Wave Sum Accumulators
    float localWaveLumaSum      = WaveActiveSum(pixelLuma);
    float localWaveLumaSumX     = 0;
    float localWaveLumaSumY     = 0;
#ifdef USE_VELOCITY
    float localWaveVelocityMin  = 0;
#endif

#ifdef USE_WEBER_FECHNER
    if (UseWeberFechner)
    {
        neighborhood[GTid.x][GTid.y] = pixelLuma;

        GroupMemoryBarrierWithGroupSync();

        // Use Weber Fechner to create brightness sensitivity divisor.
        float minNeighborLuma = ComputeMinNeighborLuminance(GTid.xy);
        float BRIGHTNESS_SENSITIVITY = WeberFechnerConstant * (1.0 - saturate(minNeighborLuma * 50.0 - 2.5));

        // When using Weber-Fechner Law https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law
        localWaveLumaSumX = WaveActiveSum(abs(pixelLuma - pixelLumaXMinusOne) / (min(pixelLuma, pixelLumaXMinusOne) + BRIGHTNESS_SENSITIVITY));

        // When using Weber-Fechner Law https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law
        localWaveLumaSumY = WaveActiveSum(abs(pixelLuma - pixelLumaYMinusOne) / (min(pixelLuma, pixelLumaYMinusOne) + BRIGHTNESS_SENSITIVITY));
    }
    else
    {
        // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        localWaveLumaSumX = WaveActiveSum(abs(pixelLuma - pixelLumaXMinusOne) / 2.0);

        // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        localWaveLumaSumY = WaveActiveSum(abs(pixelLuma - pixelLumaYMinusOne) / 2.0);
    }
#else
    // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
    localWaveLumaSumX = WaveActiveSum(abs(pixelLuma - pixelLumaXMinusOne) / 2.0);

    // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
    localWaveLumaSumY = WaveActiveSum(abs(pixelLuma - pixelLumaYMinusOne) / 2.0);
#endif

#ifdef USE_VELOCITY
    if (UseMotionVectors)
    {
        const float3 velocity = UnpackVelocity(VelocityBuffer[PixelCoord]);
        localWaveVelocityMin = WaveActiveMin(length(velocity));
    }
#endif

    GroupMemoryBarrierWithGroupSync();
    
    if (WaveIsFirstLane())
    {
        waveLumaSum[GI / waveLaneCount] = localWaveLumaSum;
        waveLumaSumX[GI / waveLaneCount] = localWaveLumaSumX;
        waveLumaSumY[GI / waveLaneCount] = localWaveLumaSumY;
#ifdef USE_VELOCITY
        waveVelocityMin[GI / waveLaneCount] = localWaveVelocityMin;
#endif
    }

    GroupMemoryBarrierWithGroupSync();

    if (GI == 0)
    {
        float totalTileLuma   = 0;
        float totalTileLumaX  = 0;
        float totalTileLumaY  = 0;
#ifdef USE_VELOCITY
        float minTileVelocity = 10000;
#endif

        for (int i = 0; i < (NUM_THREADS / waveLaneCount); i++)
        {
            totalTileLuma += waveLumaSum[i];
            totalTileLumaX += waveLumaSumX[i];
            totalTileLumaY += waveLumaSumY[i];
#ifdef USE_VELOCITY
            minTileVelocity = min(minTileVelocity, waveVelocityMin[i]);
#endif
        }

        // Compute Average Luminance of Current Tile
        const float avgTileLuma = totalTileLuma / (float)NUM_THREADS;
        const float avgTileLumaX = totalTileLumaX / (float)NUM_THREADS;
        const float avgTileLumaY = totalTileLumaY / (float)NUM_THREADS;

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

#ifdef USE_VELOCITY
        if (UseMotionVectors)
        {
            
            // Satifying Equation 20. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            //velocityHError = pow(1.0 / (1.0 + pow(1.05 * minTileVelocity, 3.10)), 0.35);
            velocityHError = (H_SLOPE * minTileVelocity) + H_INTERCEPT;

            // Satifying Equation 21. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            //velocityQError = K * pow(1.0 / (1.0 + pow(0.55 * minTileVelocity, 2.41)), 0.49);
            velocityQError = (Q_SLOPE * minTileVelocity) + Q_INTERCEPT;
        }
#endif

        // Satifying Equation 16. For X http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        if ((velocityHError * avgErrorX) >= jnd_threshold)
        {
            xRate = D3D12_AXIS_SHADING_RATE_1X;
        }
        // Satifying Equation 14. For Qurter Rate Shading for X http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        else if ((velocityQError * avgErrorX) < jnd_threshold)
        {
            xRate = D3D12_AXIS_SHADING_RATE_4X;
        }

        // Satifying Equation 16 For Y http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        if ((velocityHError * avgErrorY) >= jnd_threshold)
        {
            // Logic to Prevent Invalid 4x1 shading Rate, converts to 4X2.
            yRate = (xRate ==   
                D3D12_AXIS_SHADING_RATE_4X ? 
                D3D12_AXIS_SHADING_RATE_2X : 
                D3D12_AXIS_SHADING_RATE_1X);
        }
        // Satifying Equation 14 For Qurter Rate Shading for Y http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        else if ((velocityQError * avgErrorY) < jnd_threshold)
        {
            // Logic to Prevent 4x4 Shading Rate and invalid 1X4, converts to 4x2 or 1x2.
            yRate = (xRate == 
                D3D12_AXIS_SHADING_RATE_1X ? 
                D3D12_AXIS_SHADING_RATE_2X : 
                D3D12_AXIS_SHADING_RATE_4X);
        }

        SetShadingRate(Gid.xy, D3D12_MAKE_COARSE_SHADING_RATE(xRate, yRate));
    }
}
