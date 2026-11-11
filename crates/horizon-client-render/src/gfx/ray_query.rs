//! Hardware ray queries, only on request (#13780, after the #1180 spike): `HORIZON_RAY_TRACING=1`
//! at startup asks the device for wgpu's `EXPERIMENTAL_RAY_QUERY` when the GPU has it. Nothing
//! draws with it yet. Without the variable, and in a build without `horizon-extras` (a Horizon
//! extra, docs/layers.md), the device is opened exactly as before.

/// The lighting traced through them (step 3).
#[path = "ray_light.rs"]
mod ray_light;
/// Per-sprite glow and gloss.
#[path = "ray_material.rs"]
mod ray_material;
/// The terrain's acceleration structures (step 2).
#[path = "ray_scene.rs"]
pub(in crate::gfx) mod ray_scene;

/// The ray query feature.
const RAY_QUERY: wgpu::Features = wgpu::Features::EXPERIMENTAL_RAY_QUERY;

/// Whether `device` was opened with ray queries.
pub(in crate::gfx) fn on(device: &wgpu::Device) -> bool {
    device.features().contains(RAY_QUERY)
}

/// What buffers that BLAS builds read need on top of their own usage: nothing without ray
/// queries, so the off path's buffers are main's.
pub(in crate::gfx) fn blas_input(device: &wgpu::Device) -> wgpu::BufferUsages {
    if on(device) {
        wgpu::BufferUsages::BLAS_INPUT
    } else {
        wgpu::BufferUsages::empty()
    }
}

/// Whether the player asked for ray tracing (the device needs the feature from its creation).
fn requested() -> bool {
    quality() != Quality::Off
}

/// How much ray tracing the player asked for: `HORIZON_RAY_TRACING` today (`1` is medium, or
/// `low`, `medium`, `high`), the menu's option later (step D).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::gfx) enum Quality {
    Off,
    Low,
    Medium,
    High,
}

impl Quality {
    fn parse(var: Option<&str>) -> Self {
        if !cfg!(feature = "horizon-extras") {
            return Self::Off;
        }
        match var.map(str::to_ascii_lowercase).as_deref() {
            Some("low") => Self::Low,
            Some("1" | "medium") => Self::Medium,
            Some("high") => Self::High,
            _ => Self::Off,
        }
    }

    /// The chunks the traced scene spans, `medium` being the default's.
    pub(in crate::gfx) fn reach(self, medium: i32) -> i32 {
        match self {
            Self::Off | Self::Medium => medium,
            Self::Low => medium / 2,
            Self::High => medium * 3 / 2,
        }
    }
}

pub(in crate::gfx) fn quality() -> Quality {
    Quality::parse(std::env::var("HORIZON_RAY_TRACING").ok().as_deref())
}

/// Whether `HORIZON_RAY_TRACING` set to `var` asks for ray tracing: only in a `horizon-extras`
/// build.
#[cfg(test)]
fn asked(var: Option<&str>) -> bool {
    Quality::parse(var) != Quality::Off
}

/// The features to request on `adapter`: ray queries, when asked for and offered.
pub(super) fn features(adapter: &wgpu::Adapter) -> wgpu::Features {
    let features = pick(requested(), adapter.features());
    if requested() {
        let info = adapter.get_info();
        if features.is_empty() {
            log::warn!(
                "Horizon renderer: ray tracing asked for, but {} on {:?} has no hardware ray \
                 queries; it stays off",
                info.name,
                info.backend
            );
        } else {
            log::info!(
                "Horizon renderer: ray queries on ({} on {:?})",
                info.name,
                info.backend
            );
        }
    }
    features
}

fn pick(requested: bool, offered: wgpu::Features) -> wgpu::Features {
    if requested {
        offered & RAY_QUERY
    } else {
        wgpu::Features::empty()
    }
}

/// The device's opt-in to `features`' experimental ones.
pub(super) fn experimental(features: wgpu::Features) -> wgpu::ExperimentalFeatures {
    if features.contains(RAY_QUERY) {
        horizon_hdr::experimental_features()
    } else {
        wgpu::ExperimentalFeatures::disabled()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_an_extras_build_asks_for_ray_tracing() {
        assert_eq!(asked(Some("1")), cfg!(feature = "horizon-extras"));
        assert!(!asked(None));
        assert!(!asked(Some("0")));
    }

    #[test]
    fn ray_quality_maps_to_reach() {
        if cfg!(feature = "horizon-extras") {
            assert_eq!(Quality::parse(Some("1")), Quality::Medium);
            assert_eq!(Quality::parse(Some("High")), Quality::High);
            assert_eq!(Quality::parse(Some("low")), Quality::Low);
        }
        assert_eq!(Quality::parse(Some("off")), Quality::Off);
        assert_eq!(Quality::Medium.reach(8), 8);
        assert!(Quality::Low.reach(8) < 8 && Quality::High.reach(8) > 8);
    }

    #[test]
    fn ray_queries_only_when_asked_and_offered() {
        let all = wgpu::Features::all();
        assert_eq!(pick(true, all), RAY_QUERY);
        assert!(pick(false, all).is_empty());
        assert!(pick(true, all - RAY_QUERY).is_empty());
        assert!(!experimental(wgpu::Features::empty()).is_enabled());
    }
}
