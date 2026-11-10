// Ray-traced lighting (gfx/ray_light.rs, #13780 step 3). For each pixel of the opaque world a
// ray from the camera finds its terrain face in the TLAS (gfx/ray_scene.rs) and reads it from
// the store the BLAS are built from: texture, tint and vanilla's baked light. The face is lit
// by the sun (or moon) through a soft traced shadow, one bounce of sky and sunlight off what a
// cosine-weighted ray meets, and its block light; the sample joins the pixel's reprojected
// history. Pixels the camera ray doesn't find (entities, the hand, untraced terrain) are left
// to vanilla's lighting.
enable wgpu_ray_query;

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
@group(0) @binding(0) var tlas: acceleration_structure;
@group(0) @binding(1) var depth: texture_depth_2d;
@group(0) @binding(2) var<uniform> params: Params;

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
// Every traced section's quads as `TerrainVertex` (six words: position, UV's two u16, layer and
// light, RGBA8 colour); a TLAS instance's custom data is its section's first quad.
@group(0) @binding(3) var<storage, read> store: array<u32>;
// Last frame's light (rgb, samples in a) and its points' distance from that camera (r).
@group(0) @binding(4) var hist_color: texture_2d<f32>;
@group(0) @binding(5) var hist_aux: texture_2d<f32>;
// The block sprite arrays, as terrain.wgsl binds them (`SPRITE_SPLIT` layers each).
@group(0) @binding(6) var sprites_0: texture_2d_array<f32>;
@group(0) @binding(7) var sprites_1: texture_2d_array<f32>;
@group(0) @binding(8) var sprites_2: texture_2d_array<f32>;
@group(0) @binding(9) var sprites_3: texture_2d_array<f32>;
@group(0) @binding(10) var sprites_4: texture_2d_array<f32>;
@group(0) @binding(11) var sprites_5: texture_2d_array<f32>;
@group(0) @binding(12) var sprites_6: texture_2d_array<f32>;
@group(0) @binding(13) var sprites_7: texture_2d_array<f32>;
// The world's depth with only its opaque part drawn (`fs_reflect`).
@group(0) @binding(14) var opaque_depth: texture_depth_2d;
// gfx/ray_material.rs's word per sprite layer: bits 0-7 emission, 8-15 roughness, 16 metal,
// 17 foliage.
@group(0) @binding(15) var<storage, read> materials: array<u32>;
override SPRITE_SPLIT: u32 = 2048u;
// 1 for a target holding gamma-encoded colour (`fs_reflect`).
override ENCODE: f32 = 0.0;
// ray_light_blend.wgsl's.
const EXPOSURE: f32 = 0.3;
// How much sunlight the air scatters per block (`fs_volume`).
const HAZE: f32 = 0.11;
// 1 when the sprites are sRGB textures (read back linear), 0 when they hold sRGB values as is.
override SRGB_SPRITES: f32 = 1.0;
// terrain.wgsl's `UV_STEPS`.
const UV_STEP: f32 = 1.0 / 32768.0;
// mesher.rs's `OPAQUE_LAYER`: a quad whose texels are all opaque.
const OPAQUE_LAYER: u32 = 0x8000u;
// Samples the history averages at most: about a second of a still view.
const MAX_HISTORY: f32 = 64.0;
const PI: f32 = 3.14159265;

@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let uv = vec2(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}

var<private> seed: u32;
fn rand() -> f32 {
    seed = seed * 747796405u + 2891336453u;
    var w = ((seed >> ((seed >> 28u) + 4u)) ^ seed) * 277803737u;
    w = (w >> 22u) ^ w;
    return f32(w) / 4294967296.0;
}

// A texel at mip 0, from whichever array holds `layer`.
fn texel(layer: u32, uv: vec2<f32>) -> vec4<f32> {
    let l = i32(layer % SPRITE_SPLIT);
    var size: vec2<u32>;
    switch layer / SPRITE_SPLIT {
        case 0u: { size = textureDimensions(sprites_0); }
        case 1u: { size = textureDimensions(sprites_1); }
        case 2u: { size = textureDimensions(sprites_2); }
        case 3u: { size = textureDimensions(sprites_3); }
        case 4u: { size = textureDimensions(sprites_4); }
        case 5u: { size = textureDimensions(sprites_5); }
        case 6u: { size = textureDimensions(sprites_6); }
        default: { size = textureDimensions(sprites_7); }
    }
    let t = clamp(vec2<i32>(fract(uv) * vec2<f32>(size)), vec2(0), vec2<i32>(size) - 1);
    switch layer / SPRITE_SPLIT {
        case 0u: { return textureLoad(sprites_0, t, l, 0); }
        case 1u: { return textureLoad(sprites_1, t, l, 0); }
        case 2u: { return textureLoad(sprites_2, t, l, 0); }
        case 3u: { return textureLoad(sprites_3, t, l, 0); }
        case 4u: { return textureLoad(sprites_4, t, l, 0); }
        case 5u: { return textureLoad(sprites_5, t, l, 0); }
        case 6u: { return textureLoad(sprites_6, t, l, 0); }
        default: { return textureLoad(sprites_7, t, l, 0); }
    }
}

fn word(v: u32, i: u32) -> u32 {
    return store[v * 6u + i];
}
fn corner_pos(v: u32) -> vec3<f32> {
    return vec3(bitcast<f32>(word(v, 0u)), bitcast<f32>(word(v, 1u)), bitcast<f32>(word(v, 2u)));
}
fn corner_uv(v: u32) -> vec2<f32> {
    let w = word(v, 3u);
    return vec2(f32(w & 0xffffu), f32(w >> 16u)) * UV_STEP;
}

// A hit triangle's three corners in the store and its barycentric weights. Quad q's triangles
// are corners (0, 1, 2) and (0, 2, 3) (gfx.rs's `quad_indices`).
struct Tri {
    v: vec3<u32>,
    w: vec3<f32>,
}
fn tri(custom: u32, prim: u32, b: vec2<f32>) -> Tri {
    let v0 = (custom + prim / 2u) * 4u;
    let odd = (prim & 1u) == 1u;
    return Tri(vec3(v0, v0 + select(1u, 2u, odd), v0 + select(2u, 3u, odd)),
        vec3(1.0 - b.x - b.y, b.x, b.y));
}
fn tri_uv(t: Tri) -> vec2<f32> {
    return corner_uv(t.v.x) * t.w.x + corner_uv(t.v.y) * t.w.y + corner_uv(t.v.z) * t.w.z;
}

// Whether a face stops the ray where it crosses it: always for an opaque quad, else where its
// sprite is opaque, as terrain.wgsl's cutout test keeps texels from alpha 0.5 up.
fn kept(c: RayIntersection) -> bool {
    let t = tri(c.instance_custom_data, c.primitive_index, c.barycentrics);
    let layer = word(t.v.x, 4u) & 0xffffu;
    if (layer & OPAQUE_LAYER) != 0u { return true; }
    return texel(layer, tri_uv(t)).a >= 0.5;
}

fn trace_ray(origin: vec3<f32>, dir: vec3<f32>, far: f32, closest: bool) -> RayIntersection {
    var rq: ray_query;
    let flags = select(RAY_FLAG_TERMINATE_ON_FIRST_HIT, RAY_FLAG_NONE, closest);
    rayQueryInitialize(&rq, tlas, RayDesc(flags, 0xffu, 0.0, far, origin, dir));
    while rayQueryProceed(&rq) {
        if kept(rayQueryGetCandidateIntersection(&rq)) {
            rayQueryConfirmIntersection(&rq);
        }
    }
    return rayQueryGetCommittedIntersection(&rq);
}

fn linear(c: vec3<f32>) -> vec3<f32> {
    return select(pow(c, vec3(2.2)), c, SRGB_SPRITES > 0.5);
}

// Vanilla's directional shade, which the mesher baked into the vertex colour.
fn face_shade(n: vec3<f32>) -> f32 {
    let a = abs(n);
    if a.y > 0.5 { return select(0.5, 1.0, n.y > 0.0); }
    return select(0.8, 0.6, a.x > 0.5);
}

struct Surf {
    p: vec3<f32>,
    n: vec3<f32>,
    albedo: vec3<f32>,
    // Vanilla's sky and block light at the point, 0 to 1.
    sky: f32,
    block: f32,
    // How much the face glows (times its albedo), how rough it is (1: diffuse), 1 for metal.
    emission: f32,
    rough: f32,
    metal: f32,
    // The normal the sun lights: straight up for foliage, matte from every side.
    ln: vec3<f32>,
}
fn surface(h: RayIntersection, origin: vec3<f32>, dir: vec3<f32>) -> Surf {
    let t = tri(h.instance_custom_data, h.primitive_index, h.barycentrics);
    let a = corner_pos(t.v.x);
    var n = normalize(cross(corner_pos(t.v.y) - a, corner_pos(t.v.z) - a));
    if dot(n, dir) > 0.0 { n = -n; }
    let layer = word(t.v.x, 4u) & 0x7fffu;
    let tex = texel(layer, tri_uv(t)).rgb;
    let color = unpack4x8unorm(word(t.v.x, 5u)) * t.w.x + unpack4x8unorm(word(t.v.y, 5u)) * t.w.y
        + unpack4x8unorm(word(t.v.z, 5u)) * t.w.z;
    let l = vec3(word(t.v.x, 4u) >> 16u, word(t.v.y, 4u) >> 16u, word(t.v.z, 4u) >> 16u);
    let sky = dot(vec3<f32>(l & vec3(0xffu)), t.w) / 240.0;
    let block = dot(vec3<f32>(l >> vec3(8u)), t.w) / 240.0;
    // The tint and ambient occlusion stay; the shade gives way to the traced light.
    let tint = min(color.rgb / face_shade(n), vec3(1.0));
    var m = 255u << 8u;
    if layer < arrayLength(&materials) { m = materials[layer]; }
    return Surf(origin + dir * h.t, n, linear(tex) * linear(tint), sky, block,
        f32(m & 0xffu) / 255.0 * 6.0, f32((m >> 8u) & 0xffu) / 255.0, f32((m >> 16u) & 1u),
        select(n, vec3(0.0, 1.0, 0.0), (m & 0x20000u) != 0u));
}

fn basis(n: vec3<f32>, l: vec3<f32>) -> vec3<f32> {
    let s = select(-1.0, 1.0, n.z >= 0.0);
    let a = -1.0 / (s + n.z);
    let b = n.x * n.y * a;
    let t = vec3(1.0 + s * n.x * n.x * a, s * b, -s * n.x);
    let u = vec3(b, s + n.y * n.y * a, -n.y);
    return t * l.x + u * l.y + n * l.z;
}
fn cosine_dir(n: vec3<f32>) -> vec3<f32> {
    let r = sqrt(rand());
    let phi = 2.0 * PI * rand();
    return basis(n, vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - r * r))));
}
// A direction within `angle` radians of `d`: the sun's disc, for soft shadows.
fn cone_dir(d: vec3<f32>, angle: f32) -> vec3<f32> {
    let r = angle * sqrt(rand());
    let phi = 2.0 * PI * rand();
    return normalize(basis(d, vec3(r * cos(phi), r * sin(phi), 1.0)));
}

// The sky's light from direction `d`, from vanilla's sky and fog colours.
fn sky_radiance(d: vec3<f32>) -> vec3<f32> {
    // Vanilla's night sky is near black, so add a bluish ambient that fades out by day.
    let night = (1.0 - params.sky.w) * vec3(0.08, 0.13, 0.27);
    // The open sky overhead lights shadows bluer than the hazy horizon does.
    let zenith = params.sky.rgb * 0.9 + night;
    let horizon = params.horizon.rgb * 0.6 + night;
    if d.y < 0.0 { return horizon * 0.3; }
    return mix(horizon, zenith, sqrt(d.y));
}

// Torches, lamps and lava, as vanilla's block light measures them.
fn block_glow(level: f32) -> vec3<f32> {
    return vec3(1.0, 0.68, 0.38) * pow(level, 4.0) * 3.0;
}

fn random_unit_vector() -> vec3<f32> {
    let z = rand() * 2.0 - 1.0;
    let phi = 2.0 * PI * rand();
    let r = sqrt(max(0.0, 1.0 - z * z));
    return vec3(r * cos(phi), r * sin(phi), z);
}

// The sun or moon reaching point `p` of normal `n`, through a soft shadow.
fn direct(p: vec3<f32>, n: vec3<f32>) -> vec3<f32> {
    let l = cone_dir(params.light_dir.xyz, 0.02);
    let ndl = dot(n, l);
    if ndl <= 0.0 { return vec3(0.0); }
    let open = trace_ray(p, l, params.fade.z, false).kind == RAY_QUERY_INTERSECTION_NONE;
    return params.light_color.rgb * ndl * select(0.0, 1.0, open);
}

// Light in the tone-weighted space history blends in, and back.
fn tone(c: vec3<f32>) -> vec3<f32> { return c / (1.0 + max(c.r, max(c.g, c.b))); }
fn untone(c: vec3<f32>) -> vec3<f32> {
    let m = min(max(c.r, max(c.g, c.b)), 0.999);
    return max(c, vec3(0.0)) / (1.0 - m);
}

struct Out {
    // Linear light, and the samples it averages (0: vanilla's lighting stays).
    @location(0) color: vec4<f32>,
    // The point's distance from the camera, and how much the traced light shows.
    @location(1) aux: vec2<f32>,
}

@fragment fn fs_trace(@builtin(position) frag: vec4<f32>) -> Out {
    let none = Out(vec4(0.0), vec2(0.0));
    let size = vec2<f32>(textureDimensions(depth));
    let px = vec2<i32>(frag.xy);
    let d = textureLoad(depth, px, 0);
    // Reversed depth: 0 is the sky.
    if d <= 0.0 { return none; }
    let ndc = vec2((frag.x / size.x) * 2.0 - 1.0, 1.0 - (frag.y / size.y) * 2.0);
    let p4 = params.inverse_view_proj * vec4(ndc, d, 1.0);
    let p = p4.xyz / p4.w;
    let dist = length(p);
    let fade = 1.0 - smoothstep(params.fade.x, params.fade.y, length(p.xz));
    if fade <= 0.0 { return none; }
    seed = (u32(px.x) * 1973u + u32(px.y) * 9277u + u32(params.camera.w) * 26699u) | 1u;
    let cam = params.camera.xyz;
    let dir = p / dist;
    let h = trace_ray(cam, dir, dist * 1.03 + 0.3, true);
    if h.kind == RAY_QUERY_INTERSECTION_NONE || abs(h.t - dist) > 0.02 * dist + 0.1 {
        return none;
    }
    let s = surface(h, cam, dir);
    let x = s.p + s.n * (0.002 + dist * 0.0004);
    var light = direct(x, s.ln) + block_glow(s.block);
    // One bounce: the sky, or the sun, sky and emission on the face the ray meets.
    let gd = cosine_dir(s.n);
    let g = trace_ray(x, gd, params.fade.z, true);
    if g.kind == RAY_QUERY_INTERSECTION_NONE {
        light += sky_radiance(gd);
    } else {
        let hs = surface(g, x, gd);
        let hx = hs.p + hs.n * 0.003;
        light += hs.albedo * (direct(hx, hs.ln) + sky_radiance(vec3(0.0, 1.0, 0.0)) * hs.sky * 0.6 + hs.emission);
    }
    light += vec3(0.01);
    var col = s.albedo * light + s.albedo * s.emission;
    if s.rough < 0.99 {
        // One specular ray, blended in by Schlick's Fresnel; metal has no diffuse part.
        var r = reflect(dir, s.n);
        let rp = normalize(r + s.rough * s.rough * random_unit_vector());
        if dot(rp, s.n) > 0.0 { r = rp; }
        let sh = trace_ray(x, r, params.fade.z, true);
        // The sky as vanilla colours it, in the traced light's units.
        var spec = mix(params.horizon.rgb, params.sky.rgb, sqrt(max(r.y, 0.0))) / EXPOSURE
            + params.light_color.rgb * pow(max(dot(r, params.light_dir.xyz), 0.0), 800.0) * 20.0;
        if sh.kind != RAY_QUERY_INTERSECTION_NONE { spec = seen(surface(sh, x, r)); }
        let c = max(dot(-dir, s.n), 0.0);
        let f0 = mix(vec3(0.04), s.albedo, s.metal);
        let fr = f0 + (vec3(1.0) - f0) * pow(1.0 - c, 5.0);
        // Metal keeps a little of its block light diffusely, so torches warm it at night.
        col = s.albedo * light * (vec3(1.0) - fr) * (1.0 - s.metal) + spec * fr
            + s.albedo * (s.emission + block_glow(s.block) * s.metal * 0.5);
    }
    col = min(col, vec3(16.0));
    // The history at this point last frame, unless it was another surface then.
    var count = 1.0;
    var out = col;
    let prev = params.prev_clip * vec4(s.p, 1.0);
    if params.prev_camera.w > 0.0 && prev.w > 0.0 {
        let pn = prev.xy / prev.w;
        let puv = vec2(pn.x * 0.5 + 0.5, 0.5 - pn.y * 0.5);
        if all(puv >= vec2(0.0)) && all(puv < vec2(1.0)) {
            let pp = vec2<i32>(puv * size);
            let hc = textureLoad(hist_color, pp, 0);
            let hd = textureLoad(hist_aux, pp, 0).x;
            let expected = length(s.p - params.prev_camera.xyz);
            if hc.a > 0.0 && abs(hd - expected) < 0.02 * expected + 0.06 {
                count = min(hc.a + 1.0, MAX_HISTORY);
                // Tone-weighted (docs/hdr-passes.md, rule 3), so a few bright samples don't win.
                out = untone(mix(tone(max(hc.rgb, vec3(0.0))), tone(col), 1.0 / count));
            }
        }
    }
    return Out(vec4(out, count), vec2(length(s.p - cam), fade));
}

// What a reflected ray sees of face `s`: its sun, sky and block light, without a bounce.
fn seen(s: Surf) -> vec3<f32> {
    let x = s.p + s.n * 0.003;
    let sky = sky_radiance(vec3(0.0, 1.0, 0.0)) * (0.15 + 0.85 * s.sky);
    return s.albedo * (direct(x, s.ln) + block_glow(s.block) + sky + s.emission);
}

// Reflections on water, after translucent terrain: where the world's depth stands in front of
// the opaque depth, on a horizontal surface at still water's height (8/9 of a block) seen from
// above, a ray off a gently rippled surface finds the terrain or the sky, blended in by
// Fresnel's law (Schlick's).
@fragment fn fs_reflect(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let size = vec2<f32>(textureDimensions(depth));
    let px = vec2<i32>(frag.xy);
    let d = textureLoad(depth, px, 0);
    let o = textureLoad(opaque_depth, px, 0);
    let ndc = vec2((frag.x / size.x) * 2.0 - 1.0, 1.0 - (frag.y / size.y) * 2.0);
    let p4 = params.inverse_view_proj * vec4(ndc, d, 1.0);
    let p = p4.xyz / p4.w;
    // The surface's slope, before any branch.
    let g = normalize(cross(dpdy(p), dpdx(p)));
    // Reversed depth: nearer is larger. Water's top, drawn 0.001 under 8/9 of a block, seen
    // from above.
    let y = fract(p.y + params.camera.y);
    if d <= o + 0.000001 || p.y >= 0.0 || abs(g.y) < 0.9 || abs(y - 0.8879) > 0.03 {
        return vec4(0.0);
    }
    // Past the traced area the water still mirrors the sky.
    let fade = 1.0 - smoothstep(params.fade.x, params.fade.y, length(p.xz));
    seed = (u32(px.x) * 1973u + u32(px.y) * 9277u + u32(params.camera.w) * 26699u) | 1u;
    let v = normalize(p);
    let w = p.xz + params.camera.xz;
    let time = params.camera.w * 0.04;
    let slope = vec2(
        sin(w.x * 1.7 + time) + 0.5 * sin(w.y * 2.9 - time * 1.3),
        cos(w.y * 1.9 + time * 0.8) + 0.5 * cos(w.x * 2.3 - time));
    let n = normalize(vec3(slope.x * 0.025, 1.0, slope.y * 0.025));
    var r = reflect(v, n);
    r.y = abs(r.y);
    let origin = p + params.camera.xyz + vec3(0.0, 0.02, 0.0);
    // The sky as vanilla colours it (already the picture's own brightness), and the sun's
    // glint; or what the ray meets, lit as the traced light is.
    let sun = pow(max(dot(r, params.light_dir.xyz), 0.0), 1500.0) * 30.0;
    var col = mix(params.horizon.rgb, params.sky.rgb, sqrt(r.y))
        + params.light_color.rgb * sun * EXPOSURE;
    if fade > 0.0 {
        let h = trace_ray(origin, r, params.fade.z, true);
        if h.kind != RAY_QUERY_INTERSECTION_NONE {
            col = mix(col, seen(surface(h, origin, r)) * EXPOSURE, fade);
        }
    }
    // Schlick's Fresnel for water, with a floor so it reads from above as well.
    let fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(-v, n), 0.0), 5.0);
    var out = max(fogged(col, length(p), v), vec3(0.0));
    if ENCODE > 0.5 { out = pow(out, vec3(1.0 / 2.2)); }
    return vec4(out, clamp(0.3 + 0.7 * fresnel, 0.0, 1.0));
}

// Sunlight the air scatters towards the camera, through the traced shadows: shafts between
// trees, through windows and over ridges. Added over the finished world after translucent
// terrain, along the camera ray as far as the traced area holds (24 shadow rays, their start
// jittered per pixel and frame).
@fragment fn fs_volume(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    if params.sky.w <= 0.02 { return vec4(0.0); }
    let size = vec2<f32>(textureDimensions(depth));
    let px = vec2<i32>(frag.xy);
    // Reversed depth: the sky, 0, marches as far as the traced area goes.
    let d = max(textureLoad(depth, px, 0), 0.0000001);
    let ndc = vec2((frag.x / size.x) * 2.0 - 1.0, 1.0 - (frag.y / size.y) * 2.0);
    let p4 = params.inverse_view_proj * vec4(ndc, d, 1.0);
    let p = p4.xyz / p4.w;
    let dir = normalize(p);
    // The nearest 32 blocks: beams in a room or a forest, without veiling the distance.
    let far = min(length(p), 32.0);
    // Interleaved gradient noise, moved each frame.
    let jitter = fract(52.9829189 * fract(dot(frag.xy, vec2(0.06711056, 0.00583715))
        + params.camera.w * 0.618034));
    let dt = far / 24.0;
    var open = 0.0;
    // Whether the far end of the march, the backdrop, is sunlit.
    var last = 0.0;
    for (var i = 0; i < 24; i++) {
        let q = params.camera.xyz + dir * ((f32(i) + jitter) * dt);
        if trace_ray(q, params.light_dir.xyz, params.fade.z, false).kind
            == RAY_QUERY_INTERSECTION_NONE {
            open += dt;
            last = 1.0;
        } else {
            last = 0.0;
        }
    }
    // A shaft is the lit part of a ray that also crosses shadow: open air stays clear.
    let lit = open / max(far, 0.001);
    open *= smoothstep(0.0, 0.35, 1.0 - lit);
    // Henyey-Greenstein: a forward-scattering haze.
    let g = 0.6;
    let mu = dot(dir, params.light_dir.xyz);
    let phase = (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    // Beams show against shade: faint over sunlit ground, none over the sky.
    let air = select(mix(1.0, 0.25, last), 0.0, textureLoad(depth, px, 0) <= 0.0);
    var out = params.light_color.rgb * phase * HAZE * open * EXPOSURE * params.sky.w * air;
    if ENCODE > 0.5 { out = pow(out, vec3(1.0 / 2.2)) * 0.5; }
    return vec4(max(out, vec3(0.0)), 0.0);
}
