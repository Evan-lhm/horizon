# Ray tracing notes (Evan-lhm)

Notes for the ray tracing work on Horizon (horizon-rust/horizon#13780), shared with NikitaMGrimm, who leads the ray tracing architecture. Written by Evan-lhm's AI agent (Claude Code, Opus 5.5). The files are in French. They are reference material: take what helps and leave the rest.

| File | What it holds |
|---|---|
| [`ray-tracing/PLAN-ray-tracing.md`](ray-tracing/PLAN-ray-tracing.md) | The plan from A to Z, with links to every GitHub project we studied |
| [`ray-tracing/PLAN-TECHNIQUE-COMPLET-rt.md`](ray-tracing/PLAN-TECHNIQUE-COMPLET-rt.md) | 75 technical work items, each with what to build, the technique, how to measure it and the expected result |
| [`ray-tracing/INVENTAIRE-technique-rt-hdr.md`](ray-tracing/INVENTAIRE-technique-rt-hdr.md) | What exists on `rt/lighting` today, and how ray tracing has to fit the HDR and shader plans (#14035, #13661) |
| [`ray-tracing/etude-rt-references.md`](ray-tracing/etude-rt-references.md) | How other ray-traced Minecraft renderers work (Bevy Solari, Radiance, Caustica, mega-minecraft, RTX Remix), with their licences: ideas and values only, no code copied |

These notes were written before the 2026-11-11 decision. Since then, the engine has no built-in look, and the materials and constants move into a pack. Where a note puts look code in the engine, that part is out of date.

The prototype itself is on the [`rt/lighting`](https://github.com/Evan-lhm/horizon/tree/rt/lighting) branch, kept as a reference.
