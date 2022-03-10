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
    "RootConstants(b0, num32BitConstants=8), " \
    "DescriptorTable(UAV(u0, numDescriptors = 3)),"

cbuffer CB0 : register(b0)
{
    uint2 TextureSize;
    uint ShadingRateTileSize;
    uint TestMode;
    bool DrawGrid;
    float SensitivityThreshold;
    float EnvLuma;
    float K;
}

enum ComputeTestModes
{
    Color, 
    GroupID, 
    GroupIndex, 
    GroupThreadID, 
    DispatchThreadID, 
    Velocity,
    Luma, 
    LogLuma,  
    AvgTileLuma, 
    MSELumaX,
    MSELumaY,
    MSELumaXY,
    WaveLane,
};

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

RWTexture2D<packed_velocity_t> VelocityBuffer : register(u2);

groupshared uint slmLumaSum;
groupshared uint slmLumaSumX;
groupshared uint slmLumaSumY;
groupshared uint slmVelocityMin;

groupshared float avgTileLuma;
groupshared float avgTileLumaX;
groupshared float avgTileLumaY;

groupshared float jnd_threshold;
groupshared float avgErrorX;
groupshared float avgErrorY;

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

    float3 ColorN = FetchColor(N);
    float3 ColorNE = FetchColor(NE);
    float3 ColorE = FetchColor(E);
    float3 ColorSE = FetchColor(SE);
    float3 ColorS = FetchColor(S);
    float3 ColorSW = FetchColor(SW);
    float3 ColorW = FetchColor(W);
    float3 ColorNW = FetchColor(NW);

    float LumaN = RGBToLuminance(ColorN);
    float LumaNE = RGBToLuminance(ColorNE);
    float LumaE = RGBToLuminance(ColorE);
    float LumaSE = RGBToLuminance(ColorSE);
    float LumaS = RGBToLuminance(ColorS);
    float LumaSW = RGBToLuminance(ColorSW);
    float LumaW = RGBToLuminance(ColorW);
    float LumaNW = RGBToLuminance(ColorNW);

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

float ComputeHalfRateVelocityError(float v)
{
    // Satifying Equation 20. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
    return pow(1.0 / (1.0 + pow(1.05 * v, 3.10)), 0.35);
}

float ComputeQuarterRateVelocityError(float v)
{
    // Satifying Equation 21. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
    return K * pow(1.0 / (1.0 + pow(0.55 * v, 2.41)), 0.49);
}

[RootSignature(VRS_RootSig)]
[numthreads(GROUP_THREAD_X, GROUP_THREAD_Y, 1)]
void main(uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex, uint3 GTid : SV_GroupThreadID, uint3 DTid : SV_DispatchThreadID)
{
    if (GI == 0)
    {
        slmLumaSum = 0;
        slmLumaSumX = 0;
        slmLumaSumY = 0;
        slmVelocityMin = UINT32_MAX;

        avgTileLuma = 0;
        avgTileLumaX = 0;
        avgTileLumaY = 0;

        jnd_threshold = 0;
        avgErrorX = 0;
        avgErrorY = 0;
    }

    GroupMemoryBarrierWithGroupSync();

    const uint2 PixelCoord = DTid.xy;

    // Fetch Colors from Color Buffer UAV
    const float3 color = FetchColor(PixelCoord);
    const float3 colorXMinusOne = FetchColor(uint2(PixelCoord.x - 1, PixelCoord.y));
    const float3 colorYMinusOne = FetchColor(uint2(PixelCoord.x, PixelCoord.y - 1));

    // Convert RGB to luminance values
    const float pixelLuma = RGBToLuminance(color * color);
    const float pixelLumaXMinusOne = RGBToLuminance(colorXMinusOne * colorXMinusOne);
    const float pixelLumaYMinusOne = RGBToLuminance(colorYMinusOne * colorYMinusOne);

    // Local Wave Sum Accumulators
    float localWaveLumaSum = WaveActiveSum(pixelLuma);
    float localWaveLumaSumX = 0;
    float localWaveLumaSumY = 0;
    float localWaveVelocityMin = 0;

    float totalTileLuma = 0;
    float totalTileLumaX = 0;
    float totalTileLumaY = 0;
    float minTileVelocity = 0;

    float velocityHError = 1.0;
    float velocityQError = K;
    uint xRate = 0;
    uint yRate = 0;

   // if (UseWeberFechner)
    {
        // Use Weber Fechner to create brightness sensitivity divisor.
   //     float avgNeighborLuma = ComputeMinNeighborLuminance(PixelCoord);
   //     float BRIGHTNESS_SENSITIVITY = WeberFechnerConstant * (1.0 - saturate(avgNeighborLuma * 50.0 - 2.5));

        // When using Weber-Fechner Law https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law
   //     localWaveLumaSumX = WaveActiveSum(abs(pixelLuma - pixelLumaXMinusOne) / (min(pixelLuma, pixelLumaXMinusOne) + BRIGHTNESS_SENSITIVITY));

        // When using Weber-Fechner Law https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law
   //     localWaveLumaSumY = WaveActiveSum(abs(pixelLuma - pixelLumaYMinusOne) / (min(pixelLuma, pixelLumaYMinusOne) + BRIGHTNESS_SENSITIVITY));
    }
    //else
    {
        // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        localWaveLumaSumX = WaveActiveSum(abs(pixelLuma - pixelLumaXMinusOne) / 2.0);

        // Satifying Equation 2. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        localWaveLumaSumY = WaveActiveSum(abs(pixelLuma - pixelLumaYMinusOne) / 2.0);
    }

    //if (UseMotionVectors)
    {
        const float3 velocity = UnpackVelocity(VelocityBuffer[PixelCoord]);
        localWaveVelocityMin = WaveActiveMin(length(velocity));
    }

    GroupMemoryBarrierWithGroupSync();

    if (WaveIsFirstLane())
    {
        // Convert to float to 2^16 integer range and Interlock add values
        InterlockedAdd(slmLumaSum, localWaveLumaSum * (float)UINT16_MAX);
        InterlockedAdd(slmLumaSumX, localWaveLumaSumX * (float)UINT16_MAX);
        InterlockedAdd(slmLumaSumY, localWaveLumaSumY * (float)UINT16_MAX);
        InterlockedMin(slmVelocityMin, localWaveVelocityMin * (float)UINT16_MAX);
    }

    GroupMemoryBarrierWithGroupSync();

    if (GI == 0) 
    {
        // Convert SLM values from 2^16 integer range to float.
        totalTileLuma = slmLumaSum / (float)UINT16_MAX;
        totalTileLumaX = slmLumaSumX / (float)UINT16_MAX;
        totalTileLumaY = slmLumaSumY / (float)UINT16_MAX;
        minTileVelocity = slmVelocityMin / (float)UINT16_MAX;

        // Compute Average Luminance of Current Tile
        avgTileLuma = totalTileLuma / (float)NUM_THREADS;
        avgTileLumaX = totalTileLumaX / (float)NUM_THREADS;
        avgTileLumaY = totalTileLumaY / (float)NUM_THREADS;

        // Satifying Equation 15 http://leiy.cc/publications/nas/nas-pacmcgit.pdf
        jnd_threshold = SensitivityThreshold * (avgTileLuma + EnvLuma);

        // Compute the MSE error for Luma X/Y derivatives
        avgErrorX = sqrt(avgTileLumaX);
        avgErrorY = sqrt(avgTileLumaY);

        xRate = D3D12_AXIS_SHADING_RATE_2X;
        yRate = D3D12_AXIS_SHADING_RATE_2X;

        // Motion Vector based velocity compensation.
        velocityHError = 1.0;
        velocityQError = K;

        //if (UseMotionVectors)
        {
            // Satifying Equation 20. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            velocityHError = pow(1.0 / (1.0 + pow(1.05 * minTileVelocity, 3.10)), 0.35);

            // Satifying Equation 21. http://leiy.cc/publications/nas/nas-pacmcgit.pdf
            velocityQError = K * pow(1.0 / (1.0 + pow(0.55 * minTileVelocity, 2.41)), 0.49);
        }

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
    }

    GroupMemoryBarrierWithGroupSync();

    if (DrawGrid && (GTid.x  == 0 || GTid.y == 0 || GTid.x == (ShadingRateTileSize) || GTid.y == (ShadingRateTileSize))) {
        SetColor(PixelCoord, float3(0.0, 0.0, 0.0));
        return;
    }

    if (TestMode == Color)
    {
        SetColor(PixelCoord, color);
    }
    //else if (TestMode == Velocity)
    //{
    //    //const float3 velocity = UnpackVelocity(VelocityBuffer[PixelCoord]);
    //    const float magnitude = minTileVelocity;
    //    //SetColor(PixelCoord, float3(abs(velocity.x), abs(velocity.y), abs(velocity.z)));

    //    float halfRate = ComputeHalfRateVelocityError(magnitude);
    //    float quarterRate = ComputeQuarterRateVelocityError(magnitude);

    //    float jnd_threshold = SensitivityThreshold * (avgTileLuma + EnvLuma);
    //    float avgErrorX = sqrt(avgTileLumaX);

    //    if (halfRate * avgErrorX >= jnd_threshold)
    //    {
    //        //1x1
    //        //SetColor(PixelCoord, color);
    //    }
    //    else if ((quarterRate * avgErrorX) < jnd_threshold)
    //    {
    //        //4x4
    //        SetColor(PixelCoord, float3(1.0, 0.0, 0.0));
    //    }
    //    else
    //    {
    //        //2x2
    //        SetColor(PixelCoord, float3(0.0, 1.0, 0.0));
    //    }

    //    //SetColor(PixelCoord, float3(magnitude, magnitude, magnitude));
    //}
    else if (TestMode == MSELumaX)
    {
        if (avgErrorX >= jnd_threshold)
        {
            //1x1
            SetColor(PixelCoord, color);
        }
        else if ((K * avgErrorX) < jnd_threshold)
        {
            //4x4
            SetColor(PixelCoord, float3(1.0, 0.0, 0.0));
        }
        else
        {
            //2x2
            SetColor(PixelCoord, float3(0.0, 1.0, 0.0));
        }
    }
    else if (TestMode == MSELumaY)
    {
        if (avgErrorY >= jnd_threshold)
        {
            //1x1
            SetColor(PixelCoord, color);
        }
        else if ((K * avgErrorY) < jnd_threshold)
        {
            //4x4
            SetColor(PixelCoord, float3(1.0, 0.0, 0.0));
        }
        else
        {
            //2x2
            SetColor(PixelCoord, float3(0.0, 1.0, 0.0));
        }
    }
    else if (TestMode == MSELumaXY)
    {

        if (avgErrorX >= jnd_threshold)
        {
            //1x1
            //SetColor(PixelCoord, color);
        }
        else if ((K * avgErrorX) < jnd_threshold)
        {
            //4x4
            SetColor(PixelCoord, float3(1.0, 0.0, 0.0));
        }
        else
        {
            //2x2
            SetColor(PixelCoord, float3(0.0, 1.0, 0.0));
        }

        if (avgErrorY >= jnd_threshold)
        {
            //1x1
            //SetColor(PixelCoord, color);
        }
        else if ((K * avgErrorY) < jnd_threshold)
        {
            //4x4
            SetColor(PixelCoord, float3(1.0, 0.0, 0.0));
        }
        else
        {
            //2x2
            SetColor(PixelCoord, float3(0.0, 1.0, 0.0));
        }
    }
    else if (TestMode == AvgTileLuma)
    {
        SetColor(PixelCoord, avgTileLuma);
    }
    else if (TestMode == Luma)
    {
        SetColor(PixelCoord, RGBToLuminance(color));
    }
    else if (TestMode == LogLuma)
    {
        SetColor(PixelCoord, RGBToLogLuminance(color));
    }
    else if (TestMode == GroupIndex)
    {
        SetColor(PixelCoord, float3((float)GI / NUM_THREADS, (float)GI / NUM_THREADS, (float)GI / NUM_THREADS));
    }
    else if (TestMode == DispatchThreadID)
    {
        /* Dispatch Thread Coordinates*/
        float r = (float)PixelCoord.r / (float)TextureSize.r;
        float g = (float)PixelCoord.g / (float)TextureSize.g;
        float b = 0.0;
        //float b = (float)PixelCoord.b / (float)TextureSize.b;
        SetColor(PixelCoord, float3(r, g, b));
    }
    else if (TestMode == GroupThreadID)
    {
        /* Group Thread ID Coordinates*/
        SetColor(PixelCoord, GTid / (float)ShadingRateTileSize);
    }
    else if (TestMode == GroupID)
    {
        float r = (float)Gid.r / (float)TextureSize.r;
        float  g = (float)Gid.g / (float)TextureSize.g;
        //b = (float)Gid.b / (float)TextureSize.b;
        float b = 0.0;
        SetColor(PixelCoord, float3(r, g, b));
    }
    else if (TestMode == WaveLane)
    {
        uint waveLane = WaveGetLaneIndex();
        SetColor(PixelCoord, float3(float(waveLane) / 255.00f, float(waveLane) / 255.00f, float(waveLane) / 255.00f));
    }
}
