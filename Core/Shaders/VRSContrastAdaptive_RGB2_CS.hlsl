#define OPTIMIZED
#define SUPPORT_TYPED_UAV_LOADS 1

#ifdef OPTIMIZED
	#include "VRSContrastAdaptiveCS_optimized.hlsli"
#else
	#include "VRSContrastAdaptiveCS_unoptimized.hlsli"
#endif