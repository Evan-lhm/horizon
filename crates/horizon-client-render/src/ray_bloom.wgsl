// Bloom around bright traced light (gfx/ray_light.rs `bloom`): a bright pass of this frame's
// traced light into a quarter-resolution target, a separable blur, and an additive composite
// over the world's colour.
@group(0) @binding(0) var src: texture_2d<f32>;
// The trace's aux (distance, fade), full size.
@group(0) @binding(1) var aux: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
// The trace's albedo: its light is divided by it (fs_bright only).
@group(0) @binding(3) var albedo: texture_2d<f32>;
// 1 for a target holding gamma-encoded colour.
override ENCODE: f32 = 0.0;
// Linear light times this, as ray_light_blend.wgsl's.
const EXPOSURE: f32 = 0.3;
// Light (after exposure) above this blooms, softly over KNEE either side.
const THRESHOLD: f32 = 0.7;
const KNEE: f32 = 0.25;
const STRENGTH: f32 = 1.0;
// Blur taps each side, and their spacing in quarter-resolution texels.
const TAPS: i32 = 6;
const STEP: f32 = 2.0;
const SIGMA: f32 = 3.0;

@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let uv = vec2(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}

// The part of one sample above the threshold, keeping its hue.
fn bright(c: vec4<f32>, alb: vec3<f32>, fade: f32) -> vec3<f32> {
    if c.a <= 0.0 { return vec3(0.0); }
    // Capped so one noisy sample does not flare.
    let l = min(c.rgb * alb * EXPOSURE, vec3(16.0));
    let m = max(l.x, max(l.y, l.z));
    let s = clamp(m - THRESHOLD + KNEE, 0.0, 2.0 * KNEE);
    let keep = s * s / (4.0 * KNEE) + max(m - THRESHOLD - KNEE, 0.0);
    return max(l, vec3(0.0)) * (keep / max(m, 1e-4)) * fade;
}

@fragment fn fs_bright(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let base = vec2<i32>(frag.xy) * 4;
    let size = vec2<i32>(textureDimensions(src));
    var sum = vec3(0.0);
    for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
            let q = min(base + vec2(x, y), size - 1);
            sum += bright(textureLoad(src, q, 0), textureLoad(albedo, q, 0).rgb, textureLoad(aux, q, 0).y);
        }
    }
    return vec4(sum / 16.0, 1.0);
}

fn blur(frag: vec2<f32>, dir: vec2<f32>) -> vec4<f32> {
    let texel = 1.0 / vec2<f32>(textureDimensions(src));
    var sum = vec3(0.0);
    var weight = 0.0;
    for (var i = -TAPS; i <= TAPS; i++) {
        let w = exp(-f32(i * i) / (2.0 * SIGMA * SIGMA));
        sum += textureSampleLevel(src, smp, (frag + dir * f32(i) * STEP) * texel, 0.0).rgb * w;
        weight += w;
    }
    return vec4(sum / weight, 1.0);
}
@fragment fn fs_blur_h(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    return blur(frag.xy, vec2(1.0, 0.0));
}
@fragment fn fs_blur_v(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    return blur(frag.xy, vec2(0.0, 1.0));
}

// Added to the world's colour, encoded as fs_volume's (ray_light.wgsl).
@fragment fn fs_add(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = frag.xy / vec2<f32>(textureDimensions(aux));
    var out = textureSampleLevel(src, smp, uv, 0.0).rgb * STRENGTH;
    if ENCODE > 0.5 { out = pow(out, vec3(1.0 / 2.2)) * 0.5; }
    return vec4(max(out, vec3(0.0)), 0.0);
}
