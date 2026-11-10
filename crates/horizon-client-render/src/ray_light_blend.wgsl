// Blends the traced light (ray_light.wgsl) over the world's colour (gfx/ray_light.rs): a
// small edge-aware blur while a pixel's history is young, and the fade out
// before the traced area ends. Pixels without traced light keep vanilla's.
@group(0) @binding(0) var light: texture_2d<f32>;
@group(0) @binding(1) var aux: texture_2d<f32>;
// ray_light.wgsl's, the same buffer.
struct Params {
    // Clip space to camera-relative space, this frame (jittered).
    inverse_view_proj: mat4x4<f32>,
    // The TLAS's space to last frame's clip space.
    prev_clip: mat4x4<f32>,
    // Towards the sun or moon.
    light_dir: vec4<f32>,
    // Its colour times its strength.
    light_color: vec4<f32>,
    // The sky's colour overhead, linear; w: daylight.
    sky: vec4<f32>,
    // The fog's colour, the sky's at the horizon.
    horizon: vec4<f32>,
    // The camera in the TLAS's space; w: the frame's number, for noise.
    camera: vec4<f32>,
    // Last frame's camera; w: 1 when the history holds it.
    prev_camera: vec4<f32>,
    // x, y: the horizontal distance the lighting fades out over; z: how far rays go.
    fade: vec4<f32>,
    // The fog's colour (linear) and strength.
    fog_color: vec4<f32>,
    // The fog's start and end: spherical, then cylindrical.
    fog: vec4<f32>,
}
@group(0) @binding(2) var<uniform> params: Params;

// terrain.wgsl's `apply_fog` on linear light, for a point `dist` away along unit `dir`.
fn fogged(col: vec3<f32>, dist: f32, dir: vec3<f32>) -> vec3<f32> {
    let cyl = dist * max(length(dir.xz), abs(dir.y));
    let f = max(linear_fog(dist, params.fog.x, params.fog.y), linear_fog(cyl, params.fog.z, params.fog.w));
    return mix(col, params.fog_color.rgb, f * params.fog_color.a);
}
fn linear_fog(d: f32, start: f32, end: f32) -> f32 {
    if d <= start { return 0.0; }
    if d >= end { return 1.0; }
    return (d - start) / (end - start);
}
// 1 for a target holding gamma-encoded colour.
override ENCODE: f32 = 0.0;
// Linear light times this: 1.0 is paper white (docs/hdr-passes.md), no tone curve.
const EXPOSURE: f32 = 0.4;

@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let uv = vec2(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}

@fragment fn fs_blend(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let px = vec2<i32>(frag.xy);
    let c = textureLoad(light, px, 0);
    if c.a <= 0.0 { return vec4(0.0); }
    let a = textureLoad(aux, px, 0);
    let size = vec2<i32>(textureDimensions(light));
    // Neighbours at about the same distance, weighted less as the history fills.
    var sum = c.rgb;
    var weight = 1.0;
    let spread = 1.0 / sqrt(c.a);
    for (var y = -2; y <= 2; y++) {
        for (var x = -2; x <= 2; x++) {
            let q = clamp(px + vec2(x, y), vec2(0), size - 1);
            if (x == 0 && y == 0) { continue; }
            let n = textureLoad(light, q, 0);
            let nd = textureLoad(aux, q, 0).x;
            if n.a <= 0.0 { continue; }
            let w = spread * exp(-abs(nd - a.x) / (0.01 * a.x + 0.03)) / f32(1 + abs(x) + abs(y));
            sum += n.rgb * w;
            weight += w;
        }
    }
    // The pixel's direction from the camera, for the cylindrical fog.
    let ndc = vec2((frag.x / f32(size.x)) * 2.0 - 1.0, 1.0 - (frag.y / f32(size.y)) * 2.0);
    let p4 = params.inverse_view_proj * vec4(ndc, 1.0, 1.0);
    let dir = normalize(p4.xyz / p4.w);
    var col = max(fogged(sum / weight * EXPOSURE, a.x, dir), vec3(0.0));
    if ENCODE > 0.5 { col = pow(col, vec3(1.0 / 2.2)); }
    return vec4(col, a.y);
}
