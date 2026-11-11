# Inventaire technique : ray tracing et HDR

Fait le 2026-11-11, à partir du code de `rt/lighting` (fork Evan-lhm/horizon) et de `docs/hdr-passes.md`.

Le projet se fait en trois temps :
1. la base technique, pour que le ray tracing (RT) marche correctement avec le HDR ;
2. l'accès par les API ;
3. la version intégrée au jeu.

Légende : ✅ fait · 🟡 en partie fait ou à vérifier · ❌ à faire

---

## 0. Rester compatible avec les chantiers HDR et shaders (message de Ducky, 2026-11-09)

Lus le 2026-11-11 :
- #14035 : les packs de shaders sortent du moteur, derrière un point d'accroche neutre ;
- #14678 : l'étape a de #14035, ouverte ;
- #13661 : la spec HDR ;
- #13012 et `docs/layers.md` sur main : les trois couches.

### Ce que ça change pour le RT

| # | Constat | Conséquence pour nous |
|---|---|---|
| 0.1 | **Couches.** Le RT est aujourd'hui derrière `horizon-extras`, donc dans la couche Horizon. Cette couche va partir dans un autre dépôt, et elle n'aura pas le droit de toucher au moteur (`docs/layers.md`). | Le RT ne peut pas rester derrière `horizon-extras`. Découpage qui suit les règles : les ray queries, les BLAS/TLAS et la scène vont dans le **moteur**, comme le compositeur (« une capacité du pipeline que le chemin vanilla n'utilise pas, et qui ne fait rien sur ce chemin »). L'éclairage RT et son réglage vont dans la **plateforme**, comme le HDR. **À faire valider par ludovic** : c'est lui qui a dit « derrière horizon-extras ». |
| 0.2 | **Une seule sortie HDR.** `gfx/output.rs` et `frame_policy::horizon_tone_curve` décident seuls de l'image, de son encodage et de qui fait la courbe de ton, « jamais les deux » (#14035, #13661). | Le RT écrit de la lumière et ne fait jamais sa propre courbe de ton sur l'image flottante. Le `SHOULDER` du RT ne sert qu'en SDR 8 bits, là où il n'y a pas de courbe : à confirmer avec Ducky. |
| 0.3 | **Un seul pic** (#13578) : le monde est réglé pour 1000 nits avec un blanc papier à 203 (`SCENE_PEAK` = 1000/203). Les valeurs d'affichage viennent de `EffectiveOutput` et ne sont jamais recalculées. | La lumière RT doit être bloquée à `SCENE_PEAK` et lire `paper_white` et `peak` dans `EffectiveOutput` / `FrameState`, sans valeurs à elle. |
| 0.4 | **Mélange linéaire** (#13730) : les passes du monde d'Horizon se compilent avec `FRAME_LINEAR` quand un pack le demande. | La fusion RT doit suivre `FRAME_LINEAR` au lieu de deviner le gamma d'après le format (`encodes(format)` dans `ray_light.rs`). |
| 0.5 | **HDR Lighting** (#14416) : les surfaces restent au blanc papier, et seules les sources de lumière et le soleil dépassent. | Notre exposition automatique éclaircit les surfaces jusqu'à ×3. **Conflit possible** : à régler avec Ducky. |
| 0.6 | **L'étape 5 du HDR** supprimera l'image 16 bits et les marques dans l'alpha. | Le RT ne doit pas s'appuyer sur ces marques. Le halo RT et la brillance HDR des sources : décider avant que les marques disparaissent. |
| 0.7 | **Les points d'accroche** de #14035 : avant et après chaque couche du monde, `world_post`, `reset_history`. | Le RT s'insère déjà au même endroit (après le terrain opaque, puis après le translucide, dans `gfx.rs`). On pourrait se brancher sur ces points plutôt que d'ajouter du code à `gfx.rs`, et vider notre historique dans `reset_history`. Le point d'accroche n'accepte qu'un seul pipeline, celui des packs : il faut décider si le RT est un second utilisateur ou s'il reste interne au moteur. |
| 0.8 | **Le RT avec un pack actif.** Les points d'accroche peuvent dire « j'ai dessiné cette couche ». | Décider : RT coupé sous un pack, ou laissé actif sous un pack. |
| 0.9 | **Ordre de fusion.** #13578, #13738, #13730, #13742, #13839, #14416 et #14418 touchent tous `gfx.rs`, et la plupart `terrain.wgsl`. Le RT touche les deux : il ajoute du code à `terrain.wgsl` dans `ray_scene`. | Faire C0, qui sort le code RT de `gfx.rs`, tôt. Ensuite, fusionner main souvent. N'envoyer les PR C qui touchent `terrain.wgsl` ou la fusion qu'après #13578 → #13738 → #13730. |
| 0.10 | **Génération d'images avec le HDR** (#14418). | Tester le RT avec, puisque notre historique repose sur les images précédentes. |
| 0.11 | **Les mods** vont dans arismoko/horizon (#14198). Le point d'accroche est interne et n'est jamais montré aux mods. | Un accès au RT pour les mods ne passerait pas par ce point d'accroche. |

### Docs à faire lire à tout agent qui touche au RT

`docs/layers.md`, `docs/graphics.md`, `docs/hdr-passes.md`, `docs/design/hdr-linear-light.md`, `docs/api/shaders.md`, `shaders-reference-0.2.md`.

Code à connaître :
- `horizon-shader-api` et `horizon-shaders` ;
- dans `gfx/` : `pack*.rs`, `native*.rs`, `output.rs`, `frame_policy.rs`, `world_post.rs`, `frame_gen.rs`, `external.rs` (#14678).

Contrôle : `tools/test_frame_identity_parity.py`.

---

## Temps 1 : la base technique

### 1. Accès au matériel

| Sujet | État | Détail |
|---|---|---|
| Demander les ray queries à wgpu | ✅ | Étape 1, #14203, fusionnée. Seulement avec `horizon-extras` et `HORIZON_RAY_TRACING`. |
| Structures d'accélération (BLAS/TLAS) | 🟡 | Étape 2, #14356 : CI verte, en attente de relecture. |
| Joueurs sans RT non touchés | ✅ | Pas de scène, pas d'usage RT sur les buffers. |
| Cartes AMD et Intel | ❌ | Testé seulement sur une RTX 5070 Ti. |
| Perte du GPU, manque de mémoire | ❌ | Il faut un repli propre vers le rendu normal, et un budget mémoire pour les BLAS. |

### 2. La scène tracée (`gfx/ray_scene.rs`)

| Sujet | État | Détail |
|---|---|---|
| Une BLAS par section, une TLAS autour de la caméra | ✅ | Portée de 4, 8 ou 12 chunks selon la qualité. |
| Mise à jour quand les chunks changent | ✅ | |
| Eau dans la scène | ❌ | B6. Nécessaire pour la réfraction et l'absorption. |
| Entités, main, blocs animés | ❌ | Non tracés : ils gardent la lumière vanilla. |
| Verre et blocs translucides | 🟡 | Les feuilles laissent passer la lumière. Le verre n'est pas traversé. |

### 3. Les matériaux (`gfx/ray_material.rs`)

| Sujet | État | Détail |
|---|---|---|
| Table de matériaux par bloc | ✅ | |
| Masque d'émission tiré des textures | 🟡 | B5, première partie. |
| Textures PBR (LabPBR) | ❌ | B9. |

### 4. Les passes de lumière (`gfx/ray_light.rs`, `ray_light*.wgsl`, `ray_bloom.wgsl`)

| Sujet | État | Détail |
|---|---|---|
| Trace : soleil, ciel, un rebond, ombres | ✅ | |
| Accumulation d'une image à l'autre | ✅ | Historique en `Rgba16Float`, mélangé en espace pondéré par le ton (`c / (1 + m)`), comme le demande la règle 3 du HDR. |
| Fusion avec l'image et fondu en bord de zone | ✅ | `ray_light_blend.wgsl`. Le bord reste à harmoniser (B3). |
| Reflets sur l'eau (Fresnel) | ✅ | |
| Halo (bloom) des lumières tracées | ✅ | Voir le point 5. |
| Exposition automatique | ✅ | Voir le point 5. |
| Cache de lumière, plusieurs rebonds | ❌ | B4 : le plus gros gain visuel, à adapter de Bevy Solari (licence MIT). |
| Blocs lumineux en vraies sources (ReSTIR) | ❌ | B5. |

### 5. RT et HDR : ce qu'il faut régler ensemble

**C'est la partie à voir avec le responsable du HDR.**

| Sujet | État | Ce qui se passe aujourd'hui | À décider ou faire |
|---|---|---|---|
| Place dans l'image | ✅ | La lumière RT est posée sur le monde (étape 1 de `hdr-passes.md`), avant `world_post`, TAA et la courbe de ton. | Confirmer que c'est le bon endroit. |
| Format de l'image | ✅ | Le RT lit le format du monde. Il ré-encode en gamma 2.2 si besoin (`ENCODE`) et laisse la lumière dépasser 1 sur l'image flottante. | |
| **Exposition** | 🟡 | Le RT a la sienne : une constante `EXPOSURE = 0.3`, multipliée par une adaptation automatique (×0,75 à ×3, de jour seulement). Le HDR a sa propre calibration et sa courbe de ton. | **Il faut un seul responsable de l'exposition.** Garder celle du RT pour sa lumière, ou en faire une exposition globale dans `Hdr` ? |
| **Courbe de ton** | 🟡 | Sans courbe de ton HDR, le RT applique son propre adoucissement des hautes lumières (`SHOULDER`), sinon l'image saturerait. Avec la courbe HDR, le RT la laisse faire. | Vérifier qu'il n'y a jamais les deux à la fois. Peut-être s'appuyer sur `Hdr::tonemap` partout. |
| **Halo des lumières** | 🟡 | Le RT ajoute son halo. Le HDR repère les sources de lumière dans l'alpha (`hdr_light.wgsl`, `hdr_stats.rs`) pour les faire briller. | Éviter qu'une torche brille deux fois. Choisir qui fait le halo. |
| Alpha conservé | ✅ | La fusion et le halo gardent l'alpha du monde (règle 6). | |
| Pas de NaN ni de valeurs négatives | 🟡 | `max(…, 0)` à la sortie. | Ajouter un test, ou un garde-fou contre les NaN de l'historique. |
| Historique effacé quand l'image change | 🟡 | Règle 7. | Vérifier que l'historique RT est bien effacé quand on active le HDR, les dégradés lisses ou un pack de shaders. |
| TAA et décalage de caméra | 🟡 | Le RT utilise la caméra décalée (jitter) de l'image. | Tester RT + TAA + HDR en mouvement près des torches, de la lave et du soleil (méthode de `hdr-passes.md`). |
| Génération d'images | ❌ | Coupée avec la sortie HDR pour l'instant (#12989). | À tester avec le RT plus tard. |
| Captures d'écran | 🟡 | Règle 8. | Vérifier qu'une capture `-hdr.png` avec RT atteint bien environ 1000 nits au soleil, et ne plafonne pas à 203. |
| Rendu identique avec RT coupé | 🟡 | | Passer `tools/test_frame_identity_parity.py` sur chaque PR. |
| Lune, ciel et nuit | 🟡 | Valeurs choisies à l'œil (lune ×0,15, rebond ×2,5 la nuit). | À caler sur les luminances de référence du HDR (`hdr_light_reference.txt`). |

### 6. Intégration au code et aux règles du dépôt

| Sujet | État | Détail |
|---|---|---|
| `gfx.rs` ne doit pas grossir | ❌ | `rt/lighting` le fait grossir (+163/−79). C0 : sortir ce code de `gfx.rs` après la fusion de #14356. |
| Découper `rt/lighting` en petites PR | ❌ | C1 à C8, dans `PLAN-ray-tracing.md`. |
| Tests | 🟡 | 20 tests `ray_`, dont la validation des shaders. Il manque des tests sans GPU RT pour la CI (repli, réglages). |
| Packs de shaders | 🟡 | Le WGSL du RT n'a pas d'équivalent GLSL (`gfx.rs`, vers la ligne 14072). Il faut décider ce qui se passe quand un pack est actif : RT coupé, ou RT sous le pack. |

### 7. Performance

| Sujet | État | Détail |
|---|---|---|
| Qualité basse, moyenne, haute | 🟡 | `HORIZON_RAY_TRACING=low|medium|high`, qui ne change pour l'instant que la portée. |
| Mesure du coût par passe | ❌ | Requêtes de temps GPU, pour savoir ce que coûte chaque passe. |
| Tracer un pixel sur deux (damier) | ❌ | B10, idée tirée de Radiance. |
| Budget mémoire des BLAS | ❌ | Voir le point 1. |

---

## Temps 2 : l'accès par les API

**À valider avec ludovic d'abord.** Sa consigne était « pas d'API de pack de shaders » pour l'instant.

| Ce qu'on pourrait ouvrir | Prérequis |
|---|---|
| La lumière RT avant fusion (texture flottante, sans albedo) | Format figé et documenté |
| Le G-buffer : albedo, normale, profondeur | Déjà calculés pour le RT |
| La valeur d'exposition et les paramètres (soleil, ciel, brouillard) | Un seul responsable de l'exposition (point 5) |
| La TLAS, pour que les packs fassent leurs propres rayons | WGSL seulement (GLSL n'a pas de ray queries), règles de version comme `[frame]` dans l'API 0.2 |
| Un mode « linéaire » (`blend = "linear"`, prévu par le HDR mais pas encore servi) | Côté HDR |

---

## Temps 3 : la version intégrée au jeu

| Sujet | État | Détail |
|---|---|---|
| Option dans le menu Graphismes (Off / Basse / Moyenne / Haute) | ❌ | Étape D. Grisée si la carte n'a pas de RT. |
| Sauvegarde du réglage (`horizon-graphics.txt`) | ❌ | |
| Documentation joueur (`docs/graphics.md`) | ❌ | |
| Valeurs par défaut | ❌ | Off par défaut au début. |
| Suivi | 🟡 | Ticket #13780. Mentionner #12989 (HDR) dans chaque PR qui touche à l'image. |

---

## Questions

**Pour ludovic :**
1. Le RT peut-il quitter `horizon-extras` ? La capacité irait dans le moteur, comme le compositeur, et l'éclairage dans la plateforme, comme le HDR (point 0.1).
2. Le RT doit-il se brancher sur les points d'accroche de #14035 ? Leur emplacement ne prend qu'un seul pipeline (point 0.7).

**Pour Ducky (HDR) :**
1. La lumière RT est-elle bien juste du « monde » pour la sortie HDR ? On la bloque à `SCENE_PEAK` et on lit les valeurs d'affichage dans `FrameState`.
2. En SDR, sans courbe de ton, le RT peut-il garder son petit adoucissement (`SHOULDER`) ?
3. L'exposition automatique du RT (×0,75 à ×3 sur les surfaces) va-t-elle contre HDR Lighting (#14416) ? Faut-il la plafonner au blanc papier ?
4. Le halo des lumières : celui du RT, ou la brillance HDR des sources, sachant que les marques dans l'alpha vont disparaître à l'étape 5 ?
5. Faut-il caler le soleil, la lune et les torches du RT sur `hdr_light_reference.txt` ?
