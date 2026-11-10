//! Ray-traced lighting (#13780 step 3), drawn over the world once its opaque part is done.
//! `ray_light.wgsl` finds each pixel's terrain face again with a ray from the camera, reads its
//! texture, tint and light from the store the BLAS are built from, and lights it: the sun
//! through soft traced shadows, one bounce of sky and sunlight off the faces around it, and the
//! block light vanilla baked into its corners. Each frame adds one sample to the pixel's history
//! (reprojected, so the noise settles in a fraction of a second), and a second pass blends the
//! result over the vanilla-lit world, fading out before the traced area ends. Only under the
//! overworld's sky, without a shader pack.

use glam::{DVec3, Mat4, Vec3};

/// The sprite arrays `ray_light.wgsl` binds, as terrain.wgsl does.
const SPRITE_ARRAYS: u32 = 8;
/// How far rays go, in blocks.
const RAY_LENGTH: f32 = 160.0;
/// The history: linear light and its sample count, and the point's distance and fade.
const HISTORY: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const AUX: wgpu::TextureFormat = wgpu::TextureFormat::Rg32Float;

/// `ray_light.wgsl`'s `Params`.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Params {
    inverse_view_proj: [[f32; 4]; 4],
    prev_clip: [[f32; 4]; 4],
    light_dir: [f32; 4],
    light_color: [f32; 4],
    sky: [f32; 4],
    horizon: [f32; 4],
    camera: [f32; 4],
    prev_camera: [f32; 4],
    fade: [f32; 4],
    /// Vanilla's fog colour in linear light, and its strength.
    fog_color: [f32; 4],
    /// The fog's start and end: spherical, then cylindrical (terrain.wgsl's `globals.fog`).
    fog: [f32; 4],
}

/// The frames' history, two of each to read last frame's while writing this one's.
struct Targets {
    size: [u32; 2],
    /// The world colour's format: history is dropped when it changes.
    format: wgpu::TextureFormat,
    color: [wgpu::TextureView; 2],
    aux: [wgpu::TextureView; 2],
    /// The world's depth with only its opaque part: the reflections tell water by it.
    opaque: (wgpu::Texture, wgpu::TextureView),
}

pub(in crate::gfx) struct RayLight {
    layout: wgpu::BindGroupLayout,
    pipeline_layout: wgpu::PipelineLayout,
    module: wgpu::ShaderModule,
    params: wgpu::Buffer,
    /// `ray_material`'s word per sprite layer.
    materials: wgpu::Buffer,
    trace: Option<(u32, wgpu::RenderPipeline)>,
    composite: Option<(wgpu::TextureFormat, wgpu::RenderPipeline)>,
    /// Water's reflections and the light shafts, for the world's format and the sprites' split.
    reflect: Option<((wgpu::TextureFormat, u32), [wgpu::RenderPipeline; 2])>,
    targets: Option<Targets>,
    /// Which of the two targets this frame writes.
    current: usize,
    frame: u32,
    /// This frame draws (`set_frame`).
    armed: bool,
    /// Last frame's: clip from the TLAS's space, its camera there and its anchor.
    prev: Option<(Mat4, Vec3, (i32, i32))>,
}

impl RayLight {
    pub(in crate::gfx) fn new(device: &wgpu::Device) -> Self {
        let tex = |binding, sample_type| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type,
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let unfiltered = wgpu::TextureSampleType::Float { filterable: false };
        let mut entries = vec![
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::AccelerationStructure {
                    vertex_return: false,
                },
                count: None,
            },
            tex(1, wgpu::TextureSampleType::Depth),
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only: true },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            tex(4, unfiltered),
            tex(5, unfiltered),
            tex(14, wgpu::TextureSampleType::Depth),
            wgpu::BindGroupLayoutEntry {
                binding: 15,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only: true },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
        ];
        entries.extend(
            (6..6 + SPRITE_ARRAYS).map(|binding| wgpu::BindGroupLayoutEntry {
                ty: wgpu::BindingType::Texture {
                    sample_type: unfiltered,
                    view_dimension: wgpu::TextureViewDimension::D2Array,
                    multisampled: false,
                },
                ..tex(binding, unfiltered)
            }),
        );
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Ray-traced light"),
            entries: &entries,
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Ray-traced light"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Ray-traced light"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../ray_light.wgsl").into()),
        });
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Ray-traced light"),
            size: std::mem::size_of::<Params>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Self {
            layout,
            pipeline_layout,
            module,
            params,
            materials: material_buffer(device, &[super::ray_material::DEFAULT]),
            trace: None,
            composite: None,
            reflect: None,
            targets: None,
            current: 0,
            frame: 0,
            armed: false,
            prev: None,
        }
    }

    /// The sprite layers' materials (`ray_material`), after a resource reload.
    pub(in crate::gfx) fn set_materials(
        &mut self,
        device: &wgpu::Device,
        layers: &std::collections::BTreeMap<String, u32>,
    ) {
        let len = layers.values().max().map_or(1, |&m| m as usize + 1);
        let mut words = vec![super::ray_material::DEFAULT; len];
        for (name, &layer) in layers {
            words[layer as usize] = super::ray_material::material(name);
        }
        self.materials = material_buffer(device, &words);
    }

    /// This frame's view: `jittered` is its camera-relative clip-from-world, `anchor` the chunk
    /// column the TLAS is placed around and `reach` the chunks it spans; `sky`: the overworld's
    /// sky is drawn and no shader pack runs.
    #[allow(clippy::too_many_arguments)]
    pub(in crate::gfx) fn set_frame(
        &mut self,
        queue: &wgpu::Queue,
        anchor: Option<(i32, i32)>,
        reach: i32,
        jittered: Mat4,
        sun_angle_degrees: f32,
        camera: DVec3,
        sky: bool,
        colors: [[f32; 3]; 2],
        (fog_color, fog): ([f32; 4], [f32; 4]),
    ) {
        self.armed = false;
        let Some(anchor) = anchor.filter(|_| sky) else {
            self.prev = None;
            return;
        };
        let cam = Vec3::new(
            (camera.x - f64::from(anchor.0 * 16)) as f32,
            camera.y as f32,
            (camera.z - f64::from(anchor.1 * 16)) as f32,
        );
        let (light_dir, light_color, day) = celestial(sun_angle_degrees);
        // The sky's and the fog's colours, as vanilla draws them now, in linear light.
        let [zenith, horizon] = colors.map(|c| Vec3::from(c).powf(2.2));
        let clip = jittered * Mat4::from_translation(-cam);
        let prev = self.prev.filter(|p| p.2 == anchor);
        self.frame = self.frame.wrapping_add(1);
        let params = Params {
            inverse_view_proj: jittered.inverse().to_cols_array_2d(),
            prev_clip: prev.map_or(Mat4::IDENTITY, |p| p.0).to_cols_array_2d(),
            light_dir: [light_dir.x, light_dir.y, light_dir.z, 0.0],
            light_color,
            sky: [zenith.x, zenith.y, zenith.z, day],
            horizon: [horizon.x, horizon.y, horizon.z, 0.0],
            camera: [cam.x, cam.y, cam.z, (self.frame % 65536) as f32],
            prev_camera: prev.map_or([0.0; 4], |p| [p.1.x, p.1.y, p.1.z, 1.0]),
            fade: fade(reach),
            fog_color: {
                let c = Vec3::new(fog_color[0], fog_color[1], fog_color[2]).powf(2.2);
                [c.x, c.y, c.z, fog_color[3]]
            },
            fog,
        };
        queue.write_buffer(&self.params, 0, bytemuck::bytes_of(&params));
        self.prev = Some((clip, cam, anchor));
        self.armed = true;
    }

    /// Whether this frame draws it: the world pass then keeps its depth for it.
    pub(in crate::gfx) fn armed(&self) -> bool {
        self.armed
    }

    /// Lights `color`'s terrain from `depth` (the world's, its opaque part drawn) through
    /// `tlas`, reading the faces from `store`; `sprites` are the block sprite arrays, `split`
    /// layers each.
    #[allow(clippy::too_many_arguments)]
    pub(in crate::gfx) fn draw(
        &mut self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        tlas: &wgpu::Tlas,
        store: &wgpu::Buffer,
        color: &wgpu::TextureView,
        depth: &wgpu::TextureView,
        sprites: &[wgpu::TextureView],
        split: u32,
    ) {
        if !self.armed || sprites.is_empty() {
            return;
        }
        let size = [depth.texture().width(), depth.texture().height()];
        let format = color.texture().format();
        if self
            .targets
            .as_ref()
            .is_none_or(|t| t.size != size || t.format != format)
        {
            self.targets = Some(targets(device, size, format, depth.texture().format()));
        }
        let srgb_sprites = sprites[0].texture().format().is_srgb();
        if self.trace.as_ref().is_none_or(|(s, _)| *s != split) {
            let pipeline = self.trace_pipeline(device, split, srgb_sprites);
            self.trace = Some((split, pipeline));
        }
        if self.composite.as_ref().is_none_or(|(f, _)| *f != format) {
            self.composite = Some((format, composite_pipeline(device, format)));
        }
        let (Some(t), Some((_, trace)), Some((_, composite))) =
            (&self.targets, &self.trace, &self.composite)
        else {
            return;
        };
        let (cur, last) = (self.current, 1 - self.current);
        let texture = depth.texture();
        encoder.copy_texture_to_texture(
            texture.as_image_copy(),
            t.opaque.0.as_image_copy(),
            texture.size(),
        );
        let group = self.group(device, t, tlas, store, depth, sprites, last);
        {
            let target = |view| {
                Some(wgpu::RenderPassColorAttachment {
                    view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })
            };
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Ray-traced light"),
                color_attachments: &[target(&t.color[cur]), target(&t.aux[cur])],
                ..Default::default()
            });
            pass.set_pipeline(trace);
            pass.set_bind_group(0, &group, &[]);
            pass.draw(0..3, 0..1);
        }
        let blend_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Ray-traced light, blend"),
            layout: &composite.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&t.color[cur]),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&t.aux[cur]),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: self.params.as_entire_binding(),
                },
            ],
        });
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Ray-traced light, blend"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: color,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(composite);
        pass.set_bind_group(0, &blend_group, &[]);
        pass.draw(0..3, 0..1);
        drop(pass);
        self.current = last;
    }

    /// Reflections on water (`fs_reflect`), from `depth` with translucent terrain drawn, over
    /// `color`.
    #[allow(clippy::too_many_arguments)]
    pub(in crate::gfx) fn reflect(
        &mut self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        tlas: &wgpu::Tlas,
        store: &wgpu::Buffer,
        color: &wgpu::TextureView,
        depth: &wgpu::TextureView,
        sprites: &[wgpu::TextureView],
        split: u32,
    ) {
        if !self.armed || sprites.is_empty() || self.targets.is_none() {
            return;
        }
        let key = (color.texture().format(), split);
        if self.reflect.as_ref().is_none_or(|(k, _)| *k != key) {
            let srgb = sprites[0].texture().format().is_srgb();
            let pipelines = [
                self.reflect_pipeline(device, key.0, split, srgb, "fs_reflect", OVER),
                self.reflect_pipeline(device, key.0, split, srgb, "fs_volume", ADD),
            ];
            self.reflect = Some((key, pipelines));
        }
        let (Some(t), Some((_, pipelines))) = (&self.targets, &self.reflect) else {
            return;
        };
        let group = self.group(device, t, tlas, store, depth, sprites, self.current);
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Ray-traced reflections"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: color,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_bind_group(0, &group, &[]);
        for pipeline in pipelines {
            pass.set_pipeline(pipeline);
            pass.draw(0..3, 0..1);
        }
    }

    /// The bind group for `depth`, last frame's history (`history`) and this frame's opaque
    /// depth.
    #[allow(clippy::too_many_arguments)]
    fn group(
        &self,
        device: &wgpu::Device,
        t: &Targets,
        tlas: &wgpu::Tlas,
        store: &wgpu::Buffer,
        depth: &wgpu::TextureView,
        sprites: &[wgpu::TextureView],
        history: usize,
    ) -> wgpu::BindGroup {
        let view = wgpu::BindingResource::TextureView;
        let mut entries = vec![
            wgpu::BindGroupEntry {
                binding: 0,
                resource: tlas.as_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: view(depth),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: self.params.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 3,
                resource: store.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 4,
                resource: view(&t.color[history]),
            },
            wgpu::BindGroupEntry {
                binding: 5,
                resource: view(&t.aux[history]),
            },
            wgpu::BindGroupEntry {
                binding: 14,
                resource: view(&t.opaque.1),
            },
            wgpu::BindGroupEntry {
                binding: 15,
                resource: self.materials.as_entire_binding(),
            },
        ];
        for i in 0..SPRITE_ARRAYS as usize {
            entries.push(wgpu::BindGroupEntry {
                binding: 6 + i as u32,
                resource: view(&sprites[i.min(sprites.len() - 1)]),
            });
        }
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Ray-traced light"),
            layout: &self.layout,
            entries: &entries,
        })
    }

    fn reflect_pipeline(
        &self,
        device: &wgpu::Device,
        format: wgpu::TextureFormat,
        split: u32,
        srgb: bool,
        entry: &str,
        blend: wgpu::BlendState,
    ) -> wgpu::RenderPipeline {
        let constants = [
            ("SPRITE_SPLIT", f64::from(split)),
            ("SRGB_SPRITES", if srgb { 1.0 } else { 0.0 }),
            ("ENCODE", if encodes(format) { 1.0 } else { 0.0 }),
        ];
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Ray-traced reflections"),
            layout: Some(&self.pipeline_layout),
            vertex: wgpu::VertexState {
                module: &self.module,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &self.module,
                entry_point: Some(entry),
                compilation_options: wgpu::PipelineCompilationOptions {
                    constants: &constants,
                    ..Default::default()
                },
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(blend),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        })
    }

    fn trace_pipeline(
        &self,
        device: &wgpu::Device,
        split: u32,
        srgb: bool,
    ) -> wgpu::RenderPipeline {
        let constants = [
            ("SPRITE_SPLIT", f64::from(split)),
            ("SRGB_SPRITES", if srgb { 1.0 } else { 0.0 }),
        ];
        let target = |format| {
            Some(wgpu::ColorTargetState {
                format,
                blend: None,
                write_mask: wgpu::ColorWrites::ALL,
            })
        };
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Ray-traced light"),
            layout: Some(&self.pipeline_layout),
            vertex: wgpu::VertexState {
                module: &self.module,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &self.module,
                entry_point: Some("fs_trace"),
                compilation_options: wgpu::PipelineCompilationOptions {
                    constants: &constants,
                    ..Default::default()
                },
                targets: &[target(HISTORY), target(AUX)],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        })
    }
}

/// Blends the traced light over the world's colour in `format`.
fn material_buffer(device: &wgpu::Device, words: &[u32]) -> wgpu::Buffer {
    wgpu::util::DeviceExt::create_buffer_init(
        device,
        &wgpu::util::BufferInitDescriptor {
            label: Some("Ray-traced light materials"),
            contents: bytemuck::cast_slice(words),
            usage: wgpu::BufferUsages::STORAGE,
        },
    )
}

fn composite_pipeline(device: &wgpu::Device, format: wgpu::TextureFormat) -> wgpu::RenderPipeline {
    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("Ray-traced light, blend"),
        source: wgpu::ShaderSource::Wgsl(include_str!("../ray_light_blend.wgsl").into()),
    });
    let constants = [("ENCODE", if encodes(format) { 1.0 } else { 0.0 })];
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("Ray-traced light, blend"),
        layout: None,
        vertex: wgpu::VertexState {
            module: &module,
            entry_point: Some("vs_main"),
            compilation_options: Default::default(),
            buffers: &[],
        },
        fragment: Some(wgpu::FragmentState {
            module: &module,
            entry_point: Some("fs_blend"),
            compilation_options: wgpu::PipelineCompilationOptions {
                constants: &constants,
                ..Default::default()
            },
            targets: &[Some(wgpu::ColorTargetState {
                format,
                blend: Some(OVER),
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: Default::default(),
        depth_stencil: None,
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    })
}

fn targets(
    device: &wgpu::Device,
    size: [u32; 2],
    format: wgpu::TextureFormat,
    depth: wgpu::TextureFormat,
) -> Targets {
    let make = |format| {
        device
            .create_texture(&wgpu::TextureDescriptor {
                label: Some("Ray-traced light history"),
                size: wgpu::Extent3d {
                    width: size[0],
                    height: size[1],
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            })
            .create_view(&Default::default())
    };
    let opaque = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("Ray-traced light, opaque depth"),
        size: wgpu::Extent3d {
            width: size[0],
            height: size[1],
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: depth,
        usage: wgpu::TextureUsages::COPY_DST | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let view = opaque.create_view(&Default::default());
    Targets {
        size,
        format,
        color: [make(HISTORY), make(HISTORY)],
        aux: [make(AUX), make(AUX)],
        opaque: (opaque, view),
    }
}

/// Over the world's colour by alpha, keeping its alpha.
const OVER: wgpu::BlendState = wgpu::BlendState {
    color: wgpu::BlendComponent {
        src_factor: wgpu::BlendFactor::SrcAlpha,
        dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
        operation: wgpu::BlendOperation::Add,
    },
    alpha: wgpu::BlendComponent {
        src_factor: wgpu::BlendFactor::Zero,
        dst_factor: wgpu::BlendFactor::One,
        operation: wgpu::BlendOperation::Add,
    },
};

/// Added to the world's colour, keeping its alpha.
const ADD: wgpu::BlendState = wgpu::BlendState {
    color: wgpu::BlendComponent {
        src_factor: wgpu::BlendFactor::One,
        dst_factor: wgpu::BlendFactor::One,
        operation: wgpu::BlendOperation::Add,
    },
    alpha: wgpu::BlendComponent {
        src_factor: wgpu::BlendFactor::Zero,
        dst_factor: wgpu::BlendFactor::One,
        operation: wgpu::BlendOperation::Add,
    },
};

/// Whether a target in `format` holds gamma-encoded colour, as vanilla's does: every format
/// but sRGB ones, float frames included (docs/hdr-passes.md).
fn encodes(format: wgpu::TextureFormat) -> bool {
    !format.is_srgb()
}

/// Where the lighting fades out, horizontally from the camera (over the last two chunks the
/// TLAS surely spans whatever the camera's place in its own column), and how far rays go.
fn fade(reach: i32) -> [f32; 4] {
    let end = (reach.max(1) * 16) as f32;
    [(end - 32.0).max(0.0), end, RAY_LENGTH, 0.0]
}

/// Towards the sun, in world space, at vanilla's sun angle: it rises in the east (+x) at 270
/// degrees and is overhead at 0 (as the #1180 spike placed it).
fn sun_direction(degrees: f32) -> Vec3 {
    let a = degrees.to_radians();
    Vec3::new(-a.sin(), a.cos(), 0.0)
}

/// The light that casts shadows (the sun by day, the moon by night): towards it and its colour
/// times its strength; and daylight, 0 to 1.
fn celestial(sun_angle_degrees: f32) -> (Vec3, [f32; 4], f32) {
    let sun = sun_direction(sun_angle_degrees);
    let day = smoothstep(-0.12, 0.15, sun.y);
    // Warmer near the horizon.
    let low = 1.0 - smoothstep(0.0, 0.45, sun.y);
    let sun_color = Vec3::new(1.0, 0.93 - 0.25 * low, 0.82 - 0.45 * low) * 2.2 * day;
    let (dir, color) = if day > 0.02 {
        (sun, sun_color)
    } else {
        (-sun, Vec3::new(0.55, 0.65, 1.0) * 0.12)
    };
    (dir, [color.x, color.y, color.z, 0.0], day)
}

fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sun_rises_in_the_east_and_stands_overhead_at_noon() {
        assert!((sun_direction(0.0) - Vec3::Y).length() < 1e-6);
        assert!((sun_direction(270.0) - Vec3::X).length() < 1e-6);
    }

    #[test]
    fn the_moon_lights_the_night() {
        let (dir, color, day) = celestial(180.0);
        assert!(dir.y > 0.99 && color[0] < 0.2 && day < 0.01);
        let (dir, color, _) = celestial(0.0);
        assert!(dir.y > 0.99 && color[0] > 1.5);
    }

    #[test]
    fn the_shaders_validate() {
        for source in [
            include_str!("../ray_light.wgsl"),
            include_str!("../ray_light_blend.wgsl"),
        ] {
            let module = naga::front::wgsl::parse_str(source).unwrap();
            naga::valid::Validator::new(
                naga::valid::ValidationFlags::all(),
                naga::valid::Capabilities::all(),
            )
            .validate(&module)
            .unwrap();
        }
    }
}
