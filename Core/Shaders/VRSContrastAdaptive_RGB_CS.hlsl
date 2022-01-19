#define OPTIMIZED

#ifdef OPTIMIZED
	#include "VRSContrastAdaptiveCS_optimized.hlsli"
#else
	#include "VRSContrastAdaptiveCS_unoptimized.hlsli"
#endif