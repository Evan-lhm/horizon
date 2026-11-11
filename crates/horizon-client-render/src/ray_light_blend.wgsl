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
    // x, y: the horizontal distance the lighting fades out over; z: how far rays go; w: the
    // seconds since last frame.
    fade: vec4<f32>,
    // The fog's colour (linear) and strength.
    fog_color: vec4<f32>,
    // The fog's start and end: spherical, then cylindrical.
    fog: vec4<f32>,
}
@group(0) @binding(2) var<uniform> params: Params;
// This frame's albedo: `light` is divided by it.
@group(0) @binding(3) var albedo: texture_2d<f32>;

// terrain.wgsl's `apply_fog` on linear light, for a point `dist` away along unit `dir`.
fn fogged(col: vec3<f32>, dist: f32, dir: vec3<f32>) -> vec3<f32> {
    let cyl = dist * max(length(dir.xz), abs(dir.y));
    let f = max(linear_fog(dist, params.fog.x, params.fog.y), linear_fog(cyl, params.fog.z, params.fog.w));
    // Mix in gamma space like vanilla's `apply_fog` (a linear mix greys out dark backlit terrain); HDR stays unclamped.
    let g = vec3<f32>(1.0 / 2.2);
    return pow(mix(pow(max(col, vec3<f32>(0.0)), g), pow(params.fog_color.rgb, g), f * params.fog_color.a), vec3<f32>(2.2));
}
fn linear_fog(d: f32, start: f32, end: f32) -> f32 {
    if d <= start { return 0.0; }
    if d >= end { return 1.0; }
    return (d - start) / (end - start);
}
// 1 for a target holding gamma-encoded colour.
override ENCODE: f32 = 0.0;
// 1 when no tone curve follows (Hdr::tonemap only runs on the float frame): values over 1 would clip.
override SHOULDER: f32 = 0.0;
// Linear light times this: 1.0 is paper white (docs/hdr-passes.md), no tone curve.
const EXPOSURE: f32 = 0.3;

// The eye's adaptation, which `cs_meter` keeps: EXPOSURE times it (0 before the first frame).
@group(0) @binding(4) var<storage, read> adapted: array<f32>;
@group(0) @binding(5) var<storage, read_write> meter: array<f32>;
// The exposure brings the traced light's average towards KEY, by day only and between
// MIN_LIFT (open noon, about 1.6) and MAX_LIFT (indoors, under trees): stepping into the
// shade starts dark and comes up. The night stays as it is.
const KEY: f32 = 1.0;
const MIN_LIFT: f32 = 0.75;
const MAX_LIFT: f32 = 3.0;
var<workgroup> sums: array<vec2<f32>, 256>;

// One workgroup: the log-average of 64x64 traced pixels, eased into `meter` frame by frame.
@compute @workgroup_size(16, 16)
fn cs_meter(@builtin(local_invocation_index) i: u32, @builtin(local_invocation_id) id: vec3<u32>) {
    let size = vec2<u32>(textureDimensions(light));
    var s = vec2(0.0);
    for (var y = 0u; y < 4u; y++) {
        for (var x = 0u; x < 4u; x++) {
            let px = (id.xy * 4u + vec2(x, y)) * size / 64u + size / 128u;
            let c = textureLoad(light, px, 0);
            if c.a > 0.0 {
                s += vec2(log(dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)) + 0.001), 1.0);
            }
        }
    }
    sums[i] = s;
    for (var n = 128u; n > 0u; n >>= 1u) {
        workgroupBarrier();
        if i < n { sums[i] += sums[i + n]; }
    }
    if i == 0u && sums[0].y >= 64.0 {
        let day = params.sky.w;
        let want = clamp(KEY / exp(sums[0].x / sums[0].y), mix(1.0, MIN_LIFT, day), mix(1.0, MAX_LIFT, day));
        // Seconds to adapt: slower into the shade than back into the sun, as eyes do.
        let tau = select(0.5, 2.0, want > meter[0]);
        // Eased in stops (log2), as the eye does: equal steps up and down the scale.
        let eased = exp2(mix(log2(max(meter[0], 0.001)), log2(want), 1.0 - exp(-params.fade.w / tau)));
        meter[0] = select(want, eased, meter[0] > 0.0);
    }
}

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
    // Gone after a few samples: the blur smears the texture along with the noise.
    let spread = 2.0 / ((1.0 + c.a) * (1.0 + c.a));
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
    var col = max(fogged(sum / weight * textureLoad(albedo, px, 0).rgb * EXPOSURE * select(1.0, adapted[0], adapted[0] > 0.0), a.x, dir), vec3(0.0));
    if SHOULDER > 0.5 {
        // Soft shoulder on the brightest channel, the hue kept: per channel it would grey
        // bright colours (sunlit sand, grass). Linear up to the knee, then easing into 1.
        let k = 0.75;
        let m = max(col.r, max(col.g, col.b));
        if m > k {
            let d = (m - k) / (1.0 - k);
            col *= (k + (1.0 - k) * d / (1.0 + d)) / m;
        }
    }
    if ENCODE > 0.5 { col = pow(col, vec3(1.0 / 2.2)); }
    return vec4(col, a.y);
}
