//! What the ray-traced light knows of a sprite (#13780): how much it glows and how it shines.
//! Packed per sprite array layer for `ray_light.wgsl`: bits 0-7 emission, bits 8-15 roughness
//! (255: fully diffuse, the default), bit 16 metal.

/// A plain, diffuse sprite.
pub(super) const DEFAULT: u32 = 255 << 8;

const fn pack(emission: u32, rough: f32, metal: bool) -> u32 {
    emission | (((rough * 255.0) as u32) << 8) | ((metal as u32) << 16)
}

/// The material of the sprite named `name` (`minecraft:block/glowstone`); the namespace is ignored.
pub(super) fn material(name: &str) -> u32 {
    let path = name.split_once(':').map_or(name, |(_, p)| p);
    let Some(n) = path.strip_prefix("block/") else {
        return DEFAULT;
    };
    let glow = |e| pack(e, 1.0, false);
    let gloss = |r| pack(0, r, false);
    let metal = |r| pack(0, r, true);
    match n {
        "glowstone" | "sea_lantern" | "lava_still" | "lava_flow" | "torch" | "wall_torch"
        | "fire_0" | "fire_1" | "campfire_fire" | "beacon" => glow(255),
        "shroomlight"
        | "lantern"
        | "redstone_lamp_on"
        | "end_rod"
        | "ochre_froglight_side"
        | "ochre_froglight_top"
        | "verdant_froglight_side"
        | "verdant_froglight_top"
        | "pearlescent_froglight_side"
        | "pearlescent_froglight_top" => glow(230),
        "jack_o_lantern" => glow(220),
        "soul_torch" | "soul_lantern" | "soul_fire_0" | "soul_fire_1" | "soul_campfire_fire" => {
            glow(200)
        }
        "redstone_torch" => glow(150),
        "magma" => glow(120),
        "glow_lichen" | "sea_pickle" => glow(80),
        "crying_obsidian" => glow(70),
        "gold_block" => metal(0.25),
        "iron_block" | "netherite_block" => metal(0.35),
        "copper_block" | "cut_copper" => metal(0.4),
        "diamond_block" | "emerald_block" => gloss(0.15),
        "lapis_block" | "amethyst_block" => gloss(0.3),
        "ice" | "packed_ice" | "blue_ice" => gloss(0.08),
        "obsidian" => gloss(0.25),
        "prismarine_bricks" | "dark_prismarine" => gloss(0.35),
        _ if n.starts_with("quartz_") || n.starts_with("smooth_quartz") => gloss(0.35),
        _ if n.starts_with("polished_") => gloss(0.4),
        _ if n.ends_with("_glazed_terracotta") => gloss(0.3),
        _ => DEFAULT,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glowstone_glows_and_gold_shines() {
        let g = material("minecraft:block/glowstone");
        assert_eq!((g & 0xff, (g >> 8) & 0xff, g >> 16), (255, 255, 0));
        let m = material("modded:block/gold_block");
        assert_eq!(((m >> 8) & 0xff, m >> 16), (63, 1));
        assert_eq!(material("minecraft:block/stone"), DEFAULT);
    }
}
