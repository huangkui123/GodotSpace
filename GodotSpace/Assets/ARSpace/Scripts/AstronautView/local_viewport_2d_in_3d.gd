extends "res://Assets/ARSpace/Scripts/SpatialWindows/spatial_viewport_2d_in_3d.gd"

## The astronaut monitor remains the one intentionally local spatial window.
## The shared adapter is reused only for safe XR input; its sibling controller
## is configured as LOCAL_GROUND_VR and never registers network state.
