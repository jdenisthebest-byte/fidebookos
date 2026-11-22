# RADV compute shader sources

These are the sources used by the Android driver, not copies for a demo.
`../build_shaders.sh [OUT_DIR]` compiles all four modules, runs `spirv-val
--target-env vulkan1.0`, checks the glass push-constant ABI in the actual SPIR-V,
and generates `fidebook_mblur_spirv.h` from those validated binaries. It uses
cached host tools or the cached `gbos-radvbuild` container with `--network none`;
it never downloads, resets a source tree, or builds the Android driver.
`../build.sh --shaders-only [OUT_DIR]` is the equivalent entry point.

## Glass ABI

`glass_detect.comp` and `glass_apply.comp` include `glass_common.glsl`. The C
integration must use **exactly 32 bytes** for both pipeline ranges and uploads:

| Offset | GLSL / C type | Member |
| --- | --- | --- |
| 0 | `ivec2` / `int32_t[2]` | `dims` |
| 8 | `int` / `int32_t` | `ov_count` (0–3) |
| 12 | `int` / `int32_t` | `level` (1 subtle, 2 balanced, 3 expressive) |
| 16 | `int` / `int32_t` | `bg_valid` |
| 20 | `int` / `int32_t` | `bg_swizzle` (swap backdrop R/B if nonzero) |
| 24 | `int` / `int32_t` | `blur_px` (0 disables blur; clamped to 0–24 pixels) |
| 28 | `int` / `int32_t` | `reserved` (ignored; initialize to zero) |

The motion-blur estimator/apply modules retain their separate eight-byte
`ivec2 dims` push constants and original algorithm.

Detector bindings: 0–2 = premultiplied RGBA8 overlay storage images; 3 = box SSBO.
Dispatch exactly one 256-invocation workgroup. Apply bindings: 0 = real pre-glass
composition, 1–3 = the same ordered overlays, 4 = box SSBO, 5 = distinct output,
6 = backdrop image. Apply dispatch is `ceil(width/16), ceil(height/16), 1`.
Unused image descriptors must still be bound to valid, full-sized images.

The SSBO is 272 bytes: `uvec4 hdr` at 0 (`hdr.x` = count, at most 8), eight
`ivec4(x0,y0,x1,y1)` half-open rectangles at 16, then eight
`vec4(radius,bevel,kind,overlay_index)` records at 144. Kind 1 is a dock; kind 2
adds inner translucent-tile menisci. Synchronize detector writes before apply
reads. The driver must supply aligned images in the composition's coordinate
space and channel order; these shaders do not discover Android layer transforms.

## Backdrop safety contract

- For a translucent footprint, recover the scene only with inverse premultiplied
  SRC_OVER: `(u_comp.rgb - overlay_stack.rgb) / (1 - overlay_stack.a)`.
  All supplied overlays must actually match the real `u_comp` composition.
  Transmission below 0.42 is conservatively treated as non-invertible.
- **Current Android integration must set `bg_valid = 0`.** A raw app AHB or
  producer tag is not a validated, unoccluded, fully composed scene. Binding 6
  may hold a safe dummy, but must not be read on this path.
- Only a caller-proven, pixel-aligned scene may enable `bg_valid = 1`, and only
  recognized opaque taskbar carriers may use it. Unknown opaque pixels and
  foreground icons always pass through. An unavailable optical/blur texel
  invalidates the pixel's effect; there are no neighbour searches, guessed
  opaque-neighbour backdrops, fallback samples of the glass output, or history.
- Transparent holes, pixels outside the rounded SDF, opaque foreground and
  opaque taskbars without a validated scene preserve the original composition.
  Output alpha is always preserved. Do not alias output to any input.

The SDF meniscus, convex dome, Snell IOR 1.54, inner QS menisci and directional
Fresnel/specular rims remain. Dispersion is subtle (0.985/1/1.015), rather than
0.80/1/1.22. Optional blur uses a fixed five-tap cross, with centre-only chromatic
splitting: at most seven bilinear evaluations, independent of radius. Pixel
positions use centres (`p + 0.5`); bilinear integer-image reads subtract `0.5`
before `floor`/`fract`, then clamp at the image edges.

## Offline compute regression tests

Run `sh tools/radv-android/test_glass_shaders.sh` from the repository root. The
suite compiles these sources, dispatches the actual detector and apply SPIR-V
with the host Vulkan loader on CPU-only lavapipe by default, and checks readback.
It needs ons the actual detector and apply SPIR-V
with the host Vulkan loader on CPU-only lavapipe by default, and checks readback.
It needs only cached shader tools, a C compiler, Vulkan headers/loader, lavapipe,
and Python's standard library. `FIDEBOOK_TEST_VALIDATION=1` optionally requires
an already-installed Vulkan validation layer; SPIR-V validation always runs.

Fixtures cover changing/moving compositions across reused descriptor sets and
frames, no feedback, invalid-backdrop independence, outside/transparent holes,
sharp opaque icons, opaque-without-backdrop pass-through (also with a forced
apply box), unavailable sample footprints, known-scene opt-in/swizzle, clipped
SDFs, odd/tiny dimensions, output alpha, configurable blur and a scalar optical
coordinate oracle that rejects the previous half-pixel shift. Inputs and
readbacks stay under `build/radv-shader-tests/`.

**All test inputs are controlled synthetic scenes. This is not an Android app,
not evidence that Android scene capture works, and not a physical-target test.**
