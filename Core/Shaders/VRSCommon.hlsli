#define BOUNDARY_SIZE 1
#define ROW_WIDTH (8 + BOUNDARY_SIZE * 2)

#define D3D12_SHADING_RATE_X_AXIS_SHIFT 2
#define D3D12_SHADING_RATE_VALID_MASK 3
#define D3D12_MAKE_COARSE_SHADING_RATE(x,y) ((x) << D3D12_SHADING_RATE_X_AXIS_SHIFT | (y))
#define D3D12_GET_COARSE_SHADING_RATE_X_AXIS(x) (((x) >> D3D12_SHADING_RATE_X_AXIS_SHIFT) & D3D12_SHADING_RATE_VALID_MASK)
#define D3D12_GET_COARSE_SHADING_RATE_Y_AXIS(y) ((y) & D3D12_SHADING_RATE_VALID_MASK)

#ifdef GENUINE_INTEL
    #define GROUP_THREAD_X 8
    #define GROUP_THREAD_Y 8
    #define NUM_THREADS 64
#else
    #define NUM_THREADS 256
    #define GROUP_THREAD_X 16
    #define GROUP_THREAD_Y 16
#endif

#define UINT16_MAX 65536
#define UINT32_MAX 4294967295

RWTexture2D<uint> VRSShadingRateBuffer : register(u0);

enum ShadingRates
{
    SHADING_RATE_1X1 = 0x0,
    SHADING_RATE_1X2 = 0x1,
    SHADING_RATE_2X1 = 0x4,
    SHADING_RATE_2X2 = 0x5,
    SHADING_RATE_2X4 = 0x6,
    SHADING_RATE_4X2 = 0x9,
    SHADING_RATE_4X4 = 0xa,
};

enum ShadingRateAxis
{
    D3D12_AXIS_SHADING_RATE_1X = 0,
    D3D12_AXIS_SHADING_RATE_2X = 0x1,
    D3D12_AXIS_SHADING_RATE_4X = 0x2
};

uint GetShadingRate(int2 st)
{
    return VRSShadingRateBuffer[st];
}

void SetShadingRate(int2 st, uint rate)
{
    VRSShadingRateBuffer[st] = rate;
}

bool IsIndicatorPosition(uint2 PixelCoord, uint TileSize)
{
    return ((PixelCoord.x % TileSize == 4 && PixelCoord.y % TileSize == 4) ||
            (PixelCoord.x % TileSize == 4 && PixelCoord.y % TileSize == 3) ||
            (PixelCoord.x % TileSize == 3 && PixelCoord.y % TileSize == 4) ||
            (PixelCoord.x % TileSize == 3 && PixelCoord.y % TileSize == 3));
}

bool IsInsideCircle(uint cx, uint cy, uint r, uint x, uint y) {
    // https://www.tutorialspoint.com/find-if-a-point-lies-inside-a-circle-in-cplusplus
    int dist = (x - cx) * (x - cx) + (y - cy) * (y - cy);
    return (dist <= r * r);
}

float RGBToLeiLuminance(float3 LinearRGB)
{
    return dot(LinearRGB, float3(0.299, 0.587, 0.114));
}

float RGBToLogLuminance(float3 LinearRGB)
{
    float Luma = dot(LinearRGB, float3(0.212671, 0.715160, 0.072169));
    return log2(1 + Luma * 15) / 4;
}

float RGBToLuminance(float3 LinearRGB)
{
    return dot(LinearRGB, float3(0.212671, 0.715160, 0.072169));
    
}