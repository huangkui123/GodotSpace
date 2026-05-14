# SpatialCalibration

`SpatialCalibration` integrates the PicoSpatialAnchor receiver into GodotSpace as a server-side spatial calibration panel.

## Runtime Flow

1. Start GodotSpace server and client as usual.
2. The server enters `ARSpace.scn`; `SpatialCalibrationBootstrap` mounts the calibration panel only in the server process.
3. Install and start the companion helper at `res://companion_app/pico_spatial_anchor_helper`.
4. Point the helper to the server IP shown in the panel, port `8787`.
5. Click the PICO preview in the server panel, adjust depth, then confirm the calibration point.
6. Confirmed points are sent through `NetworkHandler.send_remote_annotation()` and shown in the client/VR process.

## Notes

- The original PicoSpatialAnchor OpenXR overlay is intentionally not used here. GodotSpace already runs a separate client process for XR streaming.
- This version uses the server virtual camera pose as the display basis. PICO metadata is still parsed and shown as debug/reference data, but it is not treated as the final alignment source.
- The `PSA2` frame protocol and `PAA1` acknowledgement protocol are unchanged.
