# DISCONTINUATION OF PROJECT #
This project will no longer be maintained by Intel.  
  
Intel has ceased development and contributions including, but not limited to, maintenance, bug fixes, new releases, or updates, to this project.  
  
Intel no longer accepts patches to this project.  
  
If you have an ongoing need to use this project, are interested in independently developing it, or would like to maintain patches for the open source software community, please create your own fork of this project.  



# VRS Tier 2 Velocity & Luminance Adaptive Rasterization with Microsoft Mini-Engine

In this example we demonstrate how to use Velocity and Luminance to define a screen space image to control rasterization with VRS Tier 2. The shading rate buffer is a render target that is 1/8th or 1/16th of total render target size depending on IHV implementation. By computing luminance of an 8x8 or 16x16 tile from G-Buffer render target we can define a shading rate in the shading rate buffer based on a 'Just Noticeable Difference' calculation derived from both tile luminance and tile velocity. 

### VRS/VRS Contrast Adaptive/

* **Sensitivity Threshold:** Threshold for determining the “Just Noticeable Difference” Common values include 0.25, 0.5, and 0.75 (Quality, Balanced, Performance). Higher values mean lower image quality and higher performance.
* **Quarter Rate Sensitivity:** Increases the aggressiveness for the 4x4,4x2,2x4, shading rates, higher values means lower quality and higher performance 
* **Env. Luma:** Global illumination value increases the overall LUMA during the “Just Noticeable Difference” algo. Higher values mean lower quality and higher performance.
* **Use Motion Vectors:** Enable to include motion vectors, you need to move around the scene to observe the behavior, there is a slight time cost when enabling this feature.
* **Use Weber-Fechner:** The default algorithm is an approximation but we can use a more precise algorithm known as Weber-Fechner, there is a time cost but comes with higher quality / precision. Test it in areas of high frequency content.
* **Weber-Fechner Constant:** It can probably help us dial in the Weber-Fechner precision but we haven’t tested it with values other than 1 in our testing. 

### VRS/VRS Debug/

* **Debug:** Shows Screen-space Debug Overlay
> * 1x1 is rendered as clear, 
> * 1x2/2x1 are rendered in blue with a white/black tick mark to indicate a vertical shading rate, 
> * 2x2 is rendered as a green square, 
> * 4x2/2x4 are rendered as orange/red with a white/black tick mark to indicate a vertical shading rate. 
> * 4x4 shading rates are rendered in magenta. 

### Command line options
`-vrs`  Enables or disables VRS, both Tier 1 and Tier 2  on (default), off  
`-overlay`  Toggles the debug overlay on, off (default)  
`-rate`  Sets the Tier 1 shading rate 1X1 (default), 1X2, 2X1, 2X2, 2X4, 4X2, 4X4 if additional shading rates are supported  
`-combiner1` Sets the first Tier 2 shading rate combiner passthrough (default), override, min, max, sum  
`-combiner2`  Sets the second Tier 2 shading rate combiner; defaults to override
