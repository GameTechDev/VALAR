//#define OPTIMIZED_ATOMIC
#define OPTIMIZED_SLM
#define SUPPORT_TYPED_UAV_LOADS 1

#ifdef OPTIMIZED_ATOMIC
	#include "VRSContrastAdaptiveCS_optimized_atomic.hlsli"
#else
	#ifdef OPTIMIZED_SLM
		#include "VRSContrastAdaptiveCS_optimized_slm.hlsli"
	#else
		#include "VRSContrastAdaptiveCS_unoptimized.hlsli"
	#endif
#endif