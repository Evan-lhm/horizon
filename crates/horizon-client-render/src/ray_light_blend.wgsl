// Blends the traced light (ray_light.wgsl) over the world's colour (gfx/ray_light.rs): a
// small edge-aware blur while a pixel's history is young, a filmic curve, and the fade out
// before the traced area ends. Pixels without traced light keep vanilla's.
@group(0) @binding(0) var light: texture_2d<f32>;
@group(0) @binding(1) var aux: texture_2d<f32>;
// 1 for a target holding gamma-encoded colour.
override ENCODE: f32 = 0.0;
const EXPOSURE: f32 = 0.85;

@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let uv = vec2(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}

// Narkowicz's fit of ACES.
fn aces(x: vec3<f32>) -> vec3<f32> {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), vec3(0.0), vec3(1.0));
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
    var col = aces(sum / weight * EXPOSURE);
    if ENCODE > 0.5 { col = pow(col, vec3(1.0 / 2.2)); }
    return vec4(col, a.y);
}
