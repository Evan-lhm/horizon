# Plan complet : le ray tracing dans Horizon, de A à Z

Mis à jour le 2026-11-11. Ce plan remplace la liste « prochaines étapes » des notes de reprise ([REPRISE-ray-tracing.md](REPRISE-ray-tracing.md)). L'étude des autres projets est dans [etude-rt-references.md](etude-rt-references.md).

## La vision

**But :** un rendu au niveau de Minecraft RTX dans Horizon, sur toute carte avec ray tracing matériel (NVIDIA RTX, AMD RX 6000 et plus, Intel Arc), via wgpu et Vulkan :
- ombres douces ;
- lumière qui rebondit plusieurs fois (intérieurs et sous-bois éclairés) ;
- blocs lumineux qui éclairent pour de vrai ;
- eau qui reflète et réfracte ;
- rayons de soleil ;
- exposition qui s'adapte comme l'œil.

**Règles fixes :**

| Règle | Source |
|---|---|
| Dans le moteur, pas un mod ni un pack de shaders | ludovic111 sur [#13780](https://github.com/horizon-rust/horizon/issues/13780) ; confirmé le 2026-11-11 |
| Tout derrière la fonction `horizon-extras` | ludovic111 |
| Sans `HORIZON_RAY_TRACING=1`, rien ne change (prouvé par un test) | ludovic111 |
| Variable d'environnement jusqu'à l'étape 3, option dans le menu à l'étape 4, avec des mesures par carte | ludovic111 |
| Chaque PR dit qu'elle continue [#1180](https://github.com/horizon-rust/horizon/pull/1180) | ludovic111 |
| `gfx.rs` ne grossit jamais ; on sort d'abord du code dans une PR qui ne fait que déplacer | `tools/check_file_size.py` |
| Fusion de main, jamais de rebase ; en-tête « 🤖 Opened by Evan-lhm's AI agent… » ; trailer Co-Authored-By | AGENTS.md / notes de reprise |
| Pas de code GPL/LGPL/propriétaire copié ; seulement Solari (MIT/Apache) en citant la source | Licences, voir l'étude |
| Les images de référence NVIDIA restent en local | Décision d'Evan-lhm |

**Où vit le travail :**
- Upstream [horizon-rust/horizon](https://github.com/horizon-rust/horizon) : seulement les PR découpées.
- Fork [Evan-lhm/horizon](https://github.com/Evan-lhm/horizon) : branche `rt/lighting`, qui contient tout le prototype et reçoit les PR des contributeurs.

## Où on en est (2026-11-11)

| Morceau | État | Lien |
|---|---|---|
| Ticket principal | Ouvert, assigné à Evan-lhm | [#13780](https://github.com/horizon-rust/horizon/issues/13780) |
| Spike d'origine (ludovic111) | Fermé, base du travail | [#1180](https://github.com/horizon-rust/horizon/pull/1180) |
| Étape 1 : demander les ray queries | **Fusionnée** le 2026-11-09 | [#14203](https://github.com/horizon-rust/horizon/pull/14203) |
| Déplacement `gfx.rs` → `section_fade.rs` | **Fusionnée** | [#14355](https://github.com/horizon-rust/horizon/pull/14355) |
| Étape 2 : structures d'accélération | **Ouverte**, CI verte, pas encore relue | [#14356](https://github.com/horizon-rust/horizon/pull/14356) |
| Étape 3 : l'éclairage | Prototype complet sur `rt/lighting` (35 commits d'avance sur main) | [rt/lighting](https://github.com/Evan-lhm/horizon/tree/rt/lighting) |
| Étape 4 : option dans le menu | Pas commencée | — |
| Appel à l'aide | Commentaire publié | [commentaire sur #13780](https://github.com/horizon-rust/horizon/issues/13780#issuecomment-6778781359) |
| Tickets d'aide du fork | 5 ouverts, 0 commentaire | [fork#1](https://github.com/Evan-lhm/horizon/issues/1) à [fork#5](https://github.com/Evan-lhm/horizon/issues/5) |

**Déjà sur `rt/lighting` :**
- ombres douces du soleil et de la lune ;
- un rebond de lumière ;
- blocs lumineux par texture (`ray_material`) ;
- reflets de l'eau (Fresnel, minimum 8 %) ;
- rayons de soleil ;
- bloom ;
- brouillard du jeu normal ;
- texels transparents respectés ;
- lumière à travers les feuilles ;
- lumière du ciel plus neutre ;
- exposition automatique (×0,75 à ×3, en 2 s et 0,5 s).

---

## Phase A — Les fondations upstream (presque finie)

### A1. Étape 1 : demander les ray queries ✅
- [#14203](https://github.com/horizon-rust/horizon/pull/14203), fusionnée.

### A2. Étape 2 : structures d'accélération ⏳
- [#14356](https://github.com/horizon-rust/horizon/pull/14356). Auto-fix est actif sur cette PR.
- **À faire :** répondre à la relecture, refusionner main en cas de conflit, garder `gfx.rs` sous la taille de main.
- **Fini quand :** la PR est fusionnée.

---

## Phase B — Améliorer le prototype avant de le découper

On améliore d'abord sur `rt/lighting`. Chaque point se vérifie avec les 6 scènes de capture (`rtx-quick.sh`), et `rtx-adapt.sh` pour l'exposition. On compare avec le jeu normal et les références NVIDIA.

### B1. Exposition : lissage en échelle logarithmique — petit
- **Pourquoi :** lisser en échelle linéaire rend l'adaptation asymétrique (constat de Caustica), et notre effet est jugé « minime ».
- **Quoi :** dans `cs_meter` (`ray_light_blend.wgsl`), mélanger `log2` de l'ancien et du nouveau facteur. Mesurer le ciel et les blocs lumineux à part, avec un plafond (25 % / 10 %). Envisager une plage plus large.
- **Fini quand :** en entrant dans une maison à midi, l'éclaircissement se voit nettement, et l'extérieur reste proche du jeu normal.

### B2. Lune plus faible, rebonds renforcés la nuit — petit
- **Pourquoi :** la lune de Radiance vaut 1/40 du soleil, la nôtre 1/5 ; ils compensent avec des rebonds ×8 la nuit.
- **Quoi :** `celestial()` dans `gfx/ray_light.rs`, plus un facteur de rebond selon le jour et la nuit dans `ray_light.wgsl`.
- **Fini quand :** la scène de nuit est bleutée, avec des ombres de lune nettes et pas plus claire que le jeu normal.

### B3. Bord de la zone tracée — moyen
- **Ticket :** [fork#3](https://github.com/Evan-lhm/horizon/issues/3).
- **Quoi :** fondu selon la distance et la pente, et caler la luminosité au bord sur celle du jeu normal.
- **Fini quand :** en volant, la limite ne se voit plus sur les captures, sans coût mesurable.

### B4. Cache de lumière dans l'espace (plusieurs rebonds) — gros, le plus gros gain visuel
- **Pourquoi :** les trois rendus avancés en ont un. Il éclaire les intérieurs et les sous-bois, et réduit le bruit.
- **Base de code :** [Bevy Solari, `realtime/world_cache_*.wesl`](https://github.com/bevyengine/bevy/tree/main/crates/bevy_solari/src/realtime) (MIT/Apache, à citer).
- **Sous-étapes :**
  1. Une table de hachage GPU (positions, normales, lumière, durée de vie) et une passe de nettoyage des cellules inutilisées.
  2. Une passe de mise à jour : chaque cellule active lance quelques rayons, prend la lumière directe et lit le cache au point touché.
  3. Le rebond actuel de `fs_trace` lit le cache au lieu de s'arrêter au premier rebond.
  4. Cellules plus grandes au loin, lecture décalée au hasard pour estomper la grille.
  5. Réglages : taille de cellule, nombre de rayons, réactivité.
- **Fini quand :**
  - la pièce de test à midi atteint le jeu normal sans l'aide de l'exposition ;
  - le sous-bois est éclairé ;
  - le coût est mesuré.

### B5. Blocs lumineux en vraies sources de lumière — gros
- **Pourquoi :** aujourd'hui, la lumière des torches n'arrive que par le rebond, ce qui la rend bruitée et faible de loin.
- **Quoi :**
  1. Une liste des blocs lumineux par section, avec une table de tirage selon leur puissance.
  2. Pour chaque pixel, quelques candidats tirés, puis un rayon d'ombre (RIS).
  3. Ensuite, ReSTIR : réutilisation dans le temps, puis entre pixels voisins. Ordres de grandeur de Radiance : 8 candidats, 2 voisins, rayon de 24 pixels.
  4. Le masque d'émission tiré de la texture (luminance³, plancher 0,1).
- **Base de code :** Solari, `presample_light_tiles.wesl` et `restir.wesl` (MIT/Apache).
- **Fini quand :** la scène de nuit avec torches est propre et sans grain, et chaque torche éclaire à la bonne distance.

### B6. L'eau dans la scène tracée — gros
- **Ticket :** [fork#4](https://github.com/Evan-lhm/horizon/issues/4).
- **Quoi :**
  1. Les surfaces d'eau entrent dans les structures d'accélération, avec un masque d'instance à part.
  2. Les rayons d'ombre traversent l'eau et sont atténués.
  3. Les rayons de rebond s'arrêtent à la surface.
  4. `fs_reflect` utilise la vraie surface.
  5. Réfraction et absorption par canal, d'après la teinte du biome. Ordres de grandeur : 0,22 par bloc, couleur `(0, 0.48, 0.65)` chez Radiance.
- **Fini quand :** l'eau profonde est bleu sombre vue de dessus, le fond se voit dans l'eau peu profonde, et le correctif temporaire du rebond (`hs.sky * hs.sky`) peut être retiré.

### B7. Vagues réalistes — moyen (après B6, ou avant pour la normale seule)
- **Quoi :** remplacer les 2 sinus par environ 10 ondes à crêtes pointues, où les vagues longues avancent plus vite que les courtes, avec une direction de vent.
- **Plus tard :** les caustiques, calculées depuis le même champ de vagues.

### B8. Feuilles éclairées à contre-jour — petit
- **Quoi :** la lumière qui traverse les feuilles devient plus forte quand on regarde vers le soleil (phase de Henyey-Greenstein).

### B9. Textures PBR (LabPBR) — moyen à gros
- **Ticket :** [fork#5](https://github.com/Evan-lhm/horizon/issues/5).
- **Quoi :** lire `_n` (normales) et `_s` (rugosité, métal) quand un pack de ressources les fournit, et garder la table `ray_material` sinon.
- Pas d'API publique pour les packs.

### B10. Performance — moyen
- **Ticket :** [fork#2](https://github.com/Evan-lhm/horizon/issues/2).
- **Quoi :** mesurer d'abord. Puis rendu en damier (un pixel sur deux par image, comme Radiance), arrêt des rayons d'ombre au premier obstacle opaque, et nombre de rayons selon la qualité choisie.
- **Fini quand :** il y a un tableau de temps par passe sur au moins 3 cartes (NVIDIA, AMD, Intel si possible), à 12 et 32 chunks.

---

## Phase C — Découper `rt/lighting` en PR upstream (étape 3)

**Condition :** l'étape 2 (#14356) est fusionnée. On peut découper au fil de l'eau : les points de la phase B se rangent dans la PR qui leur correspond.

**Ordre des PR** (chacune avec un test « rien ne change sans RT ») :

| # | PR | Contenu | Remarque |
|---|---|---|---|
| C0 | Déplacement(s) `gfx.rs` | Sortir le code que `rt/lighting` ajoute à `gfx.rs` dans un module, sans rien changer d'autre | Obligatoire : `gfx.rs` grossit sur `rt/lighting` aujourd'hui |
| C1 | Passe de traçage + ombres du soleil et de la lune | `gfx/ray_light.rs`, `ray_light.wgsl` (camera ray, `direct`), `ray_light_blend.wgsl` sans exposition | Le cœur ; images avant/après |
| C2 | Historique et débruitage | Reprojection, flou guidé par la profondeur | |
| C3 | Rebond de lumière (puis le cache, B4) | Indirect + ciel | |
| C4 | Blocs lumineux | `gfx/ray_material.rs`, puis B5 | |
| C5 | Eau | `fs_reflect`, puis B6 et B7 | |
| C6 | Rayons de soleil et bloom | `fs_volume`, `ray_bloom.wgsl` | |
| C7 | Exposition automatique | `cs_meter` | Selon `docs/hdr-passes.md` |
| C8 | Feuilles, texels découpés, couleurs | `sun_through`, `trace_window`, `greyer` | |

**Pour chaque PR :**
1. une branche à partir de main ;
2. seulement le morceau, avec ses tests (`cargo test -p horizon-client-render --features horizon-extras --lib ray_`) ;
3. `check_file_size.py` vert ;
4. des captures avant/après ;
5. une description qui cite #13780 et #1180.

Une PR à la fois en relecture, pour ne pas surcharger les mainteneurs.

---

## Phase D — L'option dans le menu (étape 4)

**Condition :** l'étape 3 est fusionnée, et les mesures de performance (B10, [fork#2](https://github.com/Evan-lhm/horizon/issues/2)) sont faites.

**À faire :**
- un réglage « Ray tracing » dans les options graphiques d'Horizon (Horizon Settings), grisé si la carte ne le permet pas ;
- des niveaux de qualité (désactivé, bas, moyen, haut) qui règlent la portée, le nombre de rayons, le cache et le damier ;
- la variable `HORIZON_RAY_TRACING=1` garde le même effet.

**Fini quand :** la PR est fusionnée, avec un tableau de coûts par carte dans la description.

---

## Phase E — Communauté et suivi (en continu)

- **Contributeurs :**
  1. Quelqu'un commente un ticket du fork.
  2. Evan-lhm l'assigne.
  3. Il ouvre une PR vers `rt/lighting`.
  4. Je la teste avec les captures avant/après.
  5. Evan-lhm décide.
  6. Pas de bot `/claim` sur le fork.
- **Publications :** rien de public sans l'accord d'Evan-lhm. Pour Discord, je donne un texte à copier.
- **Contacts possibles :** l'auteur de Daybreak ([hildlabs/horizon-shaders](https://github.com/hildlabs/horizon-shaders)), pour l'eau et les mesures de coût.

---

## Ordre conseillé

1. **Maintenant :** B1 (exposition en log2), B2 (lune), puis B3 (bord). Petits, visibles, sans risque.
2. **Ensuite :** B4 (cache de lumière). C'est le plus gros gain et le cœur du « look RTX ».
3. **En parallèle, dès que #14356 est fusionnée :** C0, puis C1 et C2.
4. **Puis :** B5 (blocs lumineux), B6 et B7 (eau). Peuvent être confiés à des contributeurs.
5. **Puis :** C3 à C8 au fil des améliorations.
6. **Enfin :** B10 (mesures), puis la phase D (menu).

---

## Liens

**Horizon**
- Ticket : https://github.com/horizon-rust/horizon/issues/13780
- Spike d'origine : https://github.com/horizon-rust/horizon/pull/1180
- Étape 1 : https://github.com/horizon-rust/horizon/pull/14203
- Déplacement `gfx.rs` : https://github.com/horizon-rust/horizon/pull/14355
- Étape 2 : https://github.com/horizon-rust/horizon/pull/14356
- Fork et branche : https://github.com/Evan-lhm/horizon/tree/rt/lighting
- Tickets du fork : https://github.com/Evan-lhm/horizon/issues

**À reprendre (licence compatible)**
- Bevy Solari (MIT/Apache) : https://github.com/bevyengine/bevy/tree/main/crates/bevy_solari
- RTX Remix pour Minecraft (Apache-2.0) : https://github.com/NVIDIAGameWorks/rtx-remix-minecraft

**Références : idées et réglages seulement, pas de code**
- Radiance (GPL-3.0) : https://github.com/Minecraft-Radiance/Radiance
  - moteur natif : https://github.com/Minecraft-Radiance/MCVR
  - shaders : https://github.com/Minecraft-Radiance/Shaderpack-Advanced
  - page CurseForge : https://www.curseforge.com/minecraft/mc-mods/radiance
- Portage de Radiance en 26.3 (GPL-3.0) : https://github.com/AndrewKorchemniy/Radiance-Fabric-26.3
- Caustica-RTX (LGPL-3.0) : https://github.com/AriesAlex/Caustica-RTX
- Caustica-Rework (LGPL-3.0) : https://github.com/altairflyy/Caustica-Rework
- mega-minecraft (sans licence) : https://github.com/AdityaGupta1/mega-minecraft
- Daybreak, pack de shaders Horizon (MIT) : https://github.com/hildlabs/horizon-shaders
