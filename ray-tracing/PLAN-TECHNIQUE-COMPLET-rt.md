# Plan technique complet : ray tracing dans Horizon

Écrit le 2026-11-11. Il couvre **toute la partie technique**, c'est-à-dire ce qui doit exister et marcher avant d'ouvrir des API aux packs et avant de mettre l'option dans le menu.

Documents liés :
- `PLAN-ray-tracing.md` : le résumé de A à Z et les liens ;
- `INVENTAIRE-technique-rt-hdr.md` : l'état actuel et la compatibilité HDR et shaders ;
- `etude-rt-references.md` : ce qu'on a appris des autres rendus.

## Comment lire chaque fiche

Chaque chantier a un code (par exemple `L4`) et cinq rubriques :

- **Créer** : ce qui doit exister à la fin (fichiers, passes, structures, tests).
- **Technique** : comment le faire, avec la méthode et ses paramètres de départ.
- **Mesurer** : l'outil et la mesure qui prouvent que ça marche.
- **Résultat attendu** : la condition chiffrée pour dire « fini ». Les chiffres marqués *(à valider)* sont des propositions de départ. On les fixe après la première mesure de référence (`M3`, `M8`).
- **Dépend de** : ce qui doit être fait avant.

**Règles communes à tous les chantiers :**
1. Ray tracing coupé, l'image reste identique au pixel près (`tools/test_frame_identity_parity.py`).
2. Les règles de `docs/hdr-passes.md` s'appliquent : lumière au-dessus de 1 conservée, pas de NaN, alpha intact, historique effacé quand l'image change.
3. `gfx.rs` ne grossit pas, et un fichier de plus de 3000 lignes ne grossit pas (`tools/check_file_size.py`).
4. On respecte les couches (`tools/check_layers.py`, `docs/layers.md`).
5. Aucun code copié de projets GPL, LGPL, propriétaires ou sans licence. Le code de Bevy Solari (MIT/Apache) peut être adapté, en le citant.
6. On n'envoie à l'upstream que de petites PR. Au-delà de 500 lignes, il faut d'abord une spec (règle « Large pull requests » de CONTRIBUTING).

---

# Partie 0 : définir le résultat attendu

Avant de construire, on fixe ce que veut dire « le ray tracing marche ». **Six familles de critères**, toutes mesurables avec le banc de mesure (partie 1).

| Famille | Ce qu'on veut | Mesure | Cible |
|---|---|---|---|
| **Neutralité** | Sans RT, rien ne change | Frame identity, toutes sessions | Identique au pixel près, obligatoire |
| **Justesse** | La lumière ressemble à la vraie lumière | Écart avec une image de référence convergée (voir `M4`), métrique FLIP | FLIP moyen ≤ 0,08 caméra fixe après 1 s *(à valider)* |
| **Stabilité** | Peu de bruit, pas de scintillement, pas de traînées | Variance d'une image à l'autre caméra fixe ; FLIP en mouvement | Voir `M5` et `D1` à `D5` |
| **Fidélité à Minecraft** | Dehors en plein jour, on reconnaît le jeu | Luminosité médiane par scène, comparée au jeu normal | Dehors à midi : ±10 % du jeu normal. Nuit : ±15 %. Intérieurs : plus clairs que le jeu normal, jamais plus sombres que la référence convergée |
| **Performance** | Jouable | Temps GPU par passe (`M3`), FPS et 1 % les plus bas (`tools/graphics_bench.py`) | Total des passes RT ≤ 6 ms en 1440p qualité Haute sur RTX 5070 Ti, ≤ 8 ms en 1080p Moyenne sur une carte de la classe RTX 3060 ou RX 6700 *(à valider)* |
| **Robustesse** | Jamais de plantage à cause du RT | Tests de panne forcée (`A4`), matrice de cartes (`A6`) | Toute panne fait revenir au rendu normal, avec un message dans le journal |

**Scènes de référence** (déjà utilisées dans `rtx-quick.sh`, à rendre officielles dans `M1`) :
1. pièce au coucher du soleil ;
2. maison la nuit ;
3. mer au coucher du soleil ;
4. forêt le matin ;
5. sous une plateforme ;
6. plein air à midi.

À ajouter :
7. grotte avec torches ;
8. Nether ;
9. End ;
10. sous l'eau ;
11. pluie ;
12. verre teinté ;
13. lave ;
14. beaucoup de lumières (village de nuit).

---

# Partie 1 : le banc de mesure, à construire en premier

Sans lui, on règle à l'œil. Tous les autres chantiers en dépendent.

### M1. La bibliothèque de scènes
- **Créer :** `tools/rt_scenes.py`, ou une extension de `tools/graphics_bench.py`. Il décrit les 14 scènes : graine 7, position, angle, heure, météo, dimension, et les blocs à poser si besoin.
- **Technique :**
  - `horizon-ctl` pour se téléporter, régler l'heure, poser des blocs et prendre des captures ;
  - un rendu hors écran (offscreen) pour ne pas dépendre de la fenêtre ;
  - `HORIZON_STILL=1` pour une scène figée.
  - Les images contiennent des textures Minecraft : on ne les commit pas. On compare toujours deux builds, comme le fait frame identity.
- **Mesurer :** relancer deux fois la même scène.
- **Résultat attendu :** deux lancements donnent la même image au pixel près avec RT coupé. Avec RT actif, l'écart est sous le bruit (`M5`). Une scène se capture en moins de 20 s.
- **Dépend de :** rien.

### M2. Les mesures d'image
- **Créer :** un module Python de mesures, avec un test qui vérifie chaque mesure sur des images synthétiques.
- **Mesures à fournir :**
  - luminance médiane et moyenne géométrique, sur l'image entière et par zone (moitié basse, centre) ;
  - histogramme en EV (log2) ;
  - part de pixels noirs (< 2/255) et brûlés (> 253/255) ;
  - teinte moyenne, pour juger d'une nuit bleutée ;
  - écart FLIP ou SSIM entre deux images ;
  - comptage des NaN et infinis dans une capture flottante (`-hdr.png`, ou un dump `Rgba16Float`).
- **Technique :** NumPy et Pillow, plus FLIP de NVIDIA (licence BSD-3, utilisé comme outil seulement, jamais dans le jeu).
- **Résultat attendu :** chaque mesure a un test. Le rapport sort en tableau texte, et en JSON pour comparer automatiquement.

### M3. Le temps GPU par passe
- **Créer :** le minutage de chaque passe RT : construction des BLAS, TLAS, trace, mesure d'exposition, fusion, halo, reflets, et plus tard cache et ReSTIR. Il s'affiche dans F3 et se lit par `horizon-ctl`.
- **Technique :** étendre `gfx/timing.rs`, qui minute déjà l'image entière avec des requêtes de temps relues quelques images plus tard. On ajoute des `timestamp_writes` au début et à la fin de chaque passe RT, puis une moyenne glissante sur 120 images.
- **Mesurer :** comparer avec la différence de temps d'image RT actif / RT coupé.
- **Résultat attendu :** la somme des passes est à ±10 % de cette différence. Le coût par passe est publié pour les 14 scènes.

### M4. L'image de référence convergée (la « vérité »)
- **Créer :** un mode de développement, par exemple `HORIZON_RT_REFERENCE=1`. Caméra figée, il accumule des milliers d'échantillons, avec 4 rebonds ou plus, sans débruitage ni cache, puis il capture.
- **Technique :**
  - le même traceur, avec plus de rebonds et une accumulation sans limite d'historique ;
  - pas d'exposition automatique : on utilise celle du réglage, fixe.
  - C'est la référence pour juger du biais du cache (`L4`), du bruit (`D*`) et des lumières (`L5`).
- **Mesurer :** l'écart entre 2048 et 4096 échantillons doit être négligeable.
- **Résultat attendu :** FLIP(2048, 4096) ≤ 0,01 sur les 14 scènes.

### M5. Bruit et stabilité
- **Créer :** une capture de N images successives, caméra fixe (`horizon-ctl screenshot-sequence`), et le calcul de la variance par pixel.
- **Mesurer :**
  - le bruit après 1 s caméra fixe ;
  - le bruit sur l'image qui suit un changement brusque, par exemple une porte qui s'ouvre ;
  - le scintillement, c'est-à-dire la proportion de pixels dont la luminance varie de plus de 5 % d'une image à l'autre.
- **Résultat attendu :** scintillement ≤ 1 % des pixels caméra fixe *(à valider)*.

### M6. Mouvement et traînées
- **Créer :** des trajets de caméra fixes, par exemple tourner sur place, avancer dans un couloir, passer d'une ombre au soleil. On capture en séquence.
- **Mesurer :** FLIP entre chaque image en mouvement et la référence convergée du même point de vue, pour 4 points du trajet.
- **Résultat attendu :** pas de traînée visible derrière les bords en mouvement (FLIP local ≤ 0,15 sur les bords *(à valider)*), et aucune lumière qui « colle » au mauvais endroit.

### M7. Mesures HDR
- **Créer :** des captures `-hdr.png` avec `HORIZON_HDR_FRAME=float` et `HORIZON_HDR_OUTPUT=pq`, puis la lecture du bloc `cLLI` (pixel le plus clair, en nits) et de la luminance des surfaces.
- **Résultat attendu :**
  - soleil visible : environ 1000 nits, et jamais plafonné à 203 ;
  - surfaces éclairées : au blanc papier (203 nits) ou en dessous, si on suit HDR Lighting (#14416, à confirmer avec Ducky) ;
  - aucun NaN.

### M8. La mesure de départ
- **Créer :** un rapport « état 0 » : les 14 scènes, toutes les mesures, RT coupé et RT actif, sur la RTX 5070 Ti.
- **Résultat attendu :** les chiffres *(à valider)* de ce plan sont remplacés par des cibles réalistes, calculées à partir de cet état.

### M9. Les tests automatiques
- **Créer :**
  - **tests purs** (sans GPU), pour chaque fonction de calcul : hachage du cache, taille des cellules, lecture de la qualité, courbe d'exposition, tirage des lumières ;
  - **validation des shaders par naga** : existe déjà (`the_shaders_validate`) ;
  - **tests GPU** qui ne tournent que si la carte a des ray queries, et se passent sinon.
- **Technique :** vérifier si le Vulkan logiciel de la CI (lavapipe) gère les ray queries. **À vérifier**, dans les versions récentes de Mesa. Sinon, les tests GPU RT ne tournent qu'en local ou sur une machine dédiée.
- **Résultat attendu :** chaque chantier de ce plan ajoute au moins un test, et la CI reste verte sans GPU RT.

---

# Partie 2 : le socle matériel et l'architecture

### A1. Demander les ray queries ✅ (#14203)

### A2. Structures d'accélération 🟡 (#14356, en relecture)
- **Résultat attendu :** fusionnée. Les buffers ne prennent l'usage d'entrée BLAS que sur une carte qui a le RT.

### A3. La bonne couche (moteur + plateforme)
- **Créer :**
  - dans le **moteur** : `gfx/ray/`, un dossier pour le RT. Il contient la scène, les matériaux, les passes de lumière, le cache, les lumières et l'exposition, et ne fait rien sur le chemin vanilla, comme le compositeur.
  - dans la **plateforme** : le réglage (qualité), son nom dans les options et la lecture de l'environnement. C'est la place du HDR.
  - Le `cfg(feature = "horizon-extras")` actuel est retiré du code moteur.
- **Technique :** des déplacements purs de fichiers, dans des PR séparées de tout changement de comportement. L'accord de ludovic est demandé avant.
- **Mesurer :** `check_layers.py`, `check_file_size.py`, frame identity.
- **Résultat attendu :** plus aucun lien entre le RT et `horizon-extras`. Les vérifications de couches et de taille passent. `gfx.rs` a perdu des lignes.
- **Dépend de :** la réponse de ludovic, et la fusion de A2.

### A4. Pannes et repli
- **Créer :**
  - des « error scopes » wgpu (`OutOfMemory`, `Validation`) autour de la construction des structures et de la création des pipelines ;
  - en cas d'échec, le RT se coupe pour la session, avec un message dans le journal et une ligne dans F3 ;
  - une variable de test, par exemple `HORIZON_RT_FAIL=build|pipeline|oom`, qui provoque chaque panne.
- **Technique :**
  - `device.push_error_scope` / `pop_error_scope` ;
  - un budget mémoire (`A5`) vérifié avant chaque construction ;
  - sur une perte du GPU, on reconstruit sans RT.
- **Mesurer :** un test par type de panne.
- **Résultat attendu :** chaque panne forcée garde le jeu en marche et le rendu passe au normal en moins d'une image. Aucune panne ne fait planter le jeu.

### A5. Budget et compte de mémoire
- **Créer :** un compteur des octets des BLAS, de la TLAS et des buffers RT (cache, historique, halo). Il s'affiche dans F3.
- **Technique :**
  - pour les BLAS et la TLAS, les tailles que wgpu donne avant construction ;
  - pour les textures, largeur × hauteur × octets par pixel.
- **Mesurer :** les 14 scènes à chaque niveau de qualité.
- **Résultat attendu :** ≤ 512 Mo en Moyenne et ≤ 1 Go en Haute *(à valider après M8)*. Au-dessus du budget, la portée diminue toute seule au lieu de planter.

### A6. Toutes les marques de cartes
- **Créer :**
  - au démarrage, une ligne de journal avec la carte, le pilote, le backend (Vulkan ou DX12) et les capacités RT ;
  - une procédure pour testeurs bénévoles : un script qui capture les 14 scènes et le rapport M3.
- **Matrice minimale :**
  - NVIDIA RTX 20 et 40/50 ;
  - AMD RX 6000 et 7000/9000 ;
  - Intel Arc ;
  - Windows en Vulkan et en DX12, et Linux en Vulkan ;
  - Mac, si wgpu le permet : **à vérifier**.
- **Mesurer :** les mêmes scènes sur chaque carte, comparées à la RTX 5070 Ti.
- **Résultat attendu :** sur chaque carte, l'image est à FLIP ≤ 0,05 de la RTX 5070 Ti caméra fixe, et aucune ne plante. Les différences de performance sont notées.

### A7. Le choix du backend
- **Créer :** des tests en Vulkan et en DX12 sous Windows, puis le choix d'un backend par défaut pour le RT si l'un est meilleur.
- **Résultat attendu :** les deux donnent la même image (FLIP ≤ 0,02). On garde le plus rapide et le plus stable.

---

# Partie 3 : la scène tracée

### S1. Une BLAS par section (existe, à mesurer et optimiser)
- **Créer :** des réglages de construction (priorité au tracé rapide pour les sections stables, à la construction rapide pour celles qui changent souvent) et la mesure du temps de construction.
- **Technique :**
  - les drapeaux de construction de wgpu ;
  - le compactage des structures si wgpu le propose (**à vérifier** dans la version utilisée) ;
  - la construction étalée sur plusieurs images, avec une limite de N sections par image.
- **Mesurer :** M3 (temps de construction par image), A5 (mémoire), le temps pour charger toute la portée.
- **Résultat attendu :** la construction ne prend jamais plus de 1 ms par image en jeu normal *(à valider)*. Après une téléportation, toute la portée est construite en moins de 3 s.

### S2. La TLAS autour de la caméra (existe)
- **Créer :** une mise à jour qui ne reconstruit que si des instances changent, et le compte des instances.
- **Résultat attendu :** coût de la TLAS ≤ 0,3 ms par image à 12 chunks *(à valider)*.

### S3. Les changements de blocs
- **Créer :** quand un bloc change, seule sa section est reconstruite, en priorité si elle est près de la caméra.
- **Mesurer :** poser un bloc devant la caméra et compter les images avant que son ombre apparaisse.
- **Résultat attendu :** l'ombre apparaît en 2 images au plus, et la lumière s'est stabilisée en moins de 0,5 s.

### S4. Les catégories de géométrie
- **Créer :** des drapeaux par géométrie ou par instance (opaque, découpé comme les feuilles et l'herbe, eau, verre, feuillage) avec le masque d'instance de la TLAS. Les rayons choisissent ce qu'ils voient.
- **Technique :**
  - le masque d'instance (8 bits) et l'index personnalisé ;
  - pour les blocs découpés, on n'accepte un triangle candidat qu'après avoir lu l'alpha de la texture (boucle de candidats de la ray query) ;
  - les blocs opaques sont marqués opaques, pour le chemin rapide du matériel.
- **Mesurer :** la scène forêt (ombres des feuilles), la scène herbe, et le coût M3.
- **Résultat attendu :** les ombres des feuilles et de l'herbe suivent la forme de la texture, pas un carré plein. Le surcoût du test alpha reste sous 20 % de la trace *(à valider)*.

### S5. L'eau dans la scène (B6)
- **Créer :** la surface de l'eau dans les BLAS, comme géométrie à part (catégorie eau), avec sa hauteur réelle (niveaux d'eau, écoulements).
- **Technique :** reprendre le maillage d'eau du jeu. La surface est marquée non opaque pour que les rayons d'ombre puissent la traverser.
- **Mesurer :** la scène mer et la scène sous l'eau.
- **Résultat attendu :** les rayons touchent l'eau et la réfraction devient possible (`L10`). Les reflets actuels gardent leur qualité.

### S6. Verre et blocs translucides
- **Créer :** le verre et le verre teinté dans la scène. Ils laissent passer la lumière, teintée par leur couleur.
- **Technique :** un rayon d'ombre qui traverse le verre multiplie sa transmission par la couleur du verre, avec une profondeur limitée (4 surfaces au plus).
- **Mesurer :** la scène du verre teinté.
- **Résultat attendu :** la lumière du soleil passe à travers le verre teinté et colore le sol. Le verre clair ne fait pas d'ombre noire.

### S7. Entités, main, blocs animés
- **Créer, en deux temps :**
  1. elles **reçoivent** la lumière tracée, en lisant le cache de lumière (`L4`) à leur position ;
  2. plus tard, elles **font de l'ombre** : une boîte simplifiée par entité, ou des BLAS dynamiques pour les entités proches.
- **Technique :**
  - pour le temps 1, une lecture du cache dans le shader des entités, derrière un réglage ;
  - pour le temps 2, des boîtes dans une BLAS dédiée, reconstruite à chaque image, si wgpu gère les AABB : **à vérifier**. Sinon, des boîtes en triangles.
- **Mesurer :** un mouton sous un arbre, ou un joueur dans une pièce sombre.
- **Résultat attendu :** temps 1 : une entité dans une pièce sombre est aussi sombre que les murs autour d'elle, à ±20 % près. Temps 2 : une entité au soleil fait une ombre.

### S8. Pistons, blocs qui tombent, blocs-entités (coffres, panneaux)
- **Créer :** une règle pour chacun. Au départ, on les traite comme des entités (S7). Les blocs-entités fixes entrent dans la BLAS de leur section.
- **Résultat attendu :** aucun « trou » d'ombre ou de lumière autour de ces blocs.

### S9. Le bord de la zone tracée (B3)
- **Créer :** un fondu propre entre le RT et le rendu normal au bord de la portée, et une lumière RT qui rejoint la luminosité du rendu normal à cette distance.
- **Technique :** mélanger les deux sur une bande de 1 à 2 chunks, et caler l'exposition du RT pour que la luminance au bord soit la même que celle du rendu normal.
- **Mesurer :** la luminance de part et d'autre du bord, sur 6 scènes.
- **Résultat attendu :** l'écart de luminance au bord est ≤ 5 %, et on ne voit pas de ligne en tournant la caméra.

### S10. Dimensions et changement de monde
- **Créer :** le vidage complet de la scène, de l'historique et du cache quand on change de dimension ou de monde, ou quand on se reconnecte.
- **Résultat attendu :** aucune lumière d'un monde ne reste dans l'autre, et aucune fuite de mémoire après 20 allers-retours (A5 revient à la même valeur).

---

# Partie 4 : les matériaux

### Mat1. La table des matériaux par bloc (existe)
- **Créer :** les valeurs de chaque bloc : réflexion, émission, transmission, rugosité. Elle est reconstruite quand le pack de ressources change.
- **Résultat attendu :** changer de pack de ressources met la table à jour sans redémarrer.

### Mat2. Lire la texture au point touché
- **Créer :** la lecture des coordonnées de texture et de la couleur du texel au point touché par le rayon, pour les rebonds colorés et le test alpha (S4).
- **Technique :** l'index du triangle et les coordonnées barycentriques de la ray query, puis les UV du sommet, puis la lecture dans l'atlas.
- **Résultat attendu :** un mur rouge renvoie une lumière rouge sur le sol (vérifié sur une scène dédiée).

### Mat3. Le masque d'émission (B5, début fait)
- **Technique :** luminance du texel à la puissance 3, plancher 0,1 (idée de Caustica, réécrite par nous). Seuls les pixels clairs émettent.
- **Résultat attendu :** la flamme d'une torche émet, son bâton non. Une lanterne éclaire autour d'elle.

### Mat4. La teinte de biome au point touché
- **Créer :** la couleur de biome (herbe, feuilles, eau) disponible pour les rayons.
- **Technique :** une petite texture de teintes autour de la caméra, ou la teinte rangée dans le sommet.
- **Résultat attendu :** les rebonds sur de l'herbe de marais sont verdâtres, et l'eau prend la couleur de son biome (L10).

### Mat5. Textures PBR (LabPBR) (B9)
- **Créer :** la lecture des textures `_n` (normale) et `_s` (spéculaire) des packs de ressources au format LabPBR 1.3 : rugosité, métal, émission, porosité.
- **Technique :** des atlas parallèles à l'atlas de couleur, chargés seulement si le pack les fournit.
- **Mesurer :** un pack LabPBR libre de droits, avec ses scènes.
- **Résultat attendu :** avec un pack PBR, les métaux reflètent et les surfaces ont du relief. Sans pack PBR, rien ne change.

---

# Partie 5 : le transport de la lumière

### L1. Soleil et lune, ombres douces (existe, à vérifier)
- **Technique :** un rayon vers un point tiré au hasard dans le disque du soleil (rayon angulaire d'environ 0,5°), ce qui donne des ombres nettes au pied et floues au loin.
- **Mesurer :** M4 (comparaison avec la référence) sur la scène de la plateforme.
- **Résultat attendu :** la pénombre s'élargit avec la distance, comme sur la référence.

### L2. La lumière du ciel
- **Technique :** des directions tirées en cosinus sur la demi-sphère, avec la couleur du ciel à l'horizon et au zénith.
- **Résultat attendu :** sous la plateforme, l'ombre est bleutée par le ciel. Écart avec la référence ≤ 10 % en luminance.

### L3. Un rebond (existe)
- **Résultat attendu :** il est remplacé ou complété par le cache (L4) sans rupture de luminosité.

### L4. Le cache de lumière dans l'espace (B4), le plus gros gain visuel
- **Créer :**
  - une table de hachage sur le GPU : des cellules indexées par position arrondie et normale arrondie ;
  - une passe de mise à jour, où les cellules actives tirent des rayons et lisent la table là où ces rayons arrivent, ce qui fait plusieurs rebonds au fil des images ;
  - une passe de nettoyage, qui libère les cellules non lues depuis environ 10 images ;
  - une lecture depuis l'écran, décalée au hasard dans le plan de la surface.
- **Technique :** adapter le « world cache » de Bevy Solari (MIT, cité en tête du fichier) :
  - une clé de 32 bits et une somme de contrôle, avec sondage linéaire en cas de collision ;
  - la taille des cellules grandit avec la distance, par puissances de 2 (environ 0,25 bloc près de la caméra, plusieurs blocs loin) ;
  - 2^18 à 2^20 cellules (de 4 à 16 Mo) ;
  - un mélange temporel par cellule, avec un plafond d'échantillons pour réagir aux changements.
  - Dans un monde de blocs, la grille peut s'aligner sur les blocs.
- **Mesurer :**
  - les 14 scènes contre la référence convergée à 4 rebonds (M4), surtout les intérieurs ;
  - le taux de lectures qui trouvent leur cellule ;
  - le coût M3 ;
  - la stabilité M5.
- **Résultat attendu :**
  - pièce et maison : la luminance médiane est à ±15 % de la référence convergée *(à valider)* ;
  - pas de grille visible (FLIP local ≤ 0,05 contre la référence sur une scène de mur uni) ;
  - au moins 95 % des lectures trouvent leur cellule après 1 s ;
  - coût ≤ 1,5 ms en Moyenne *(à valider)* ;
  - après une porte ouverte, la lumière se stabilise en moins de 1 s.
- **Dépend de :** M4, Mat2.

### L5. Les blocs lumineux en vraies sources (B5)
- **Créer :**
  - une liste des sources de lumière (blocs avec émission), par section ;
  - une table de tirage proportionnelle à la puissance ;
  - un choix de lumière par pixel, avec des rayons d'ombre.
- **Technique, par étapes :**
  1. une liste par section, construite avec la BLAS ;
  2. des « tuiles de lumières » pré-tirées à chaque image, où chaque pixel pioche (idée Solari) ;
  3. du RIS avec 8 candidats, 16 après une désocclusion ;
  4. ReSTIR DI : réutilisation temporelle, puis spatiale avec 2 voisins dans un rayon d'environ 24 pixels (valeurs de départ tirées de Radiance, réécrites par nous).
  - Sans source tracée, l'éclairage vanilla des blocs sert de repli.
- **Mesurer :** la grotte avec torches et le village de nuit (100 lumières ou plus), contre la référence. Bruit M5 et coût M3.
- **Résultat attendu :**
  - les ombres des torches existent et sont douces ;
  - le bruit près des torches après 1 s ne dépasse pas celui du soleil de jour ;
  - le coût ne grandit pas avec le nombre de lumières (100 et 1000 lumières : moins de 20 % d'écart) ;
  - les lumières lointaines ne disparaissent pas d'un coup.

### L6. Le lien avec la lumière vanilla
- **Créer :** des règles claires de passage entre la lumière vanilla des blocs (niveaux 0 à 15) et la lumière RT, au bord de la portée et pour les entités.
- **Résultat attendu :** une torche éclaire autant juste avant le bord de la portée que juste après, à ±10 % près.

### L7. Nuit, lune et étoiles
- **Créer :** des valeurs de lune et de ciel nocturne calées sur les luminances de référence du HDR (`hdr_light_reference.txt`), au lieu des réglages à l'œil actuels (lune ×0,15, rebond ×2,5).
- **Mesurer :** la scène de la maison la nuit, et la teinte moyenne.
- **Résultat attendu :** luminosité médiane à ±15 % du jeu normal, teinte nettement plus bleue que le jour, et pas de bruit visible sur les surfaces éclairées par la lune.

### L8. Nether et End
- **Créer :**
  - dans le Nether, pas de soleil ni de ciel : la lumière vient de la lave, du feu, de la pierre lumineuse et du brouillard coloré ;
  - dans l'End, une lumière ambiante violette et pas de soleil.
- **Résultat attendu :** les deux dimensions ont une luminosité médiane à ±20 % du jeu normal, sans zone toute noire.

### L9. Météo et effets du jeu, à faire marcher sans exception
- **Créer :** une règle pour chacun :
  - pluie et orage : soleil assombri, ciel gris ;
  - éclairs : un flash de lumière ;
  - sous l'eau : brouillard bleu et absorption ;
  - dans la lave : brouillard ;
  - effets **Vision nocturne**, **Cécité** et **Obscurité** ;
  - le réglage **Luminosité** du jeu (gamma) ;
  - le **brouillard** de distance et de biome ;
  - le monde vu de très haut et le vide.
- **Technique :** passer ces valeurs au RT par `Params`, avec les mêmes formules que vanilla quand c'est possible. Le brouillard existe déjà (`fogged`).
- **Mesurer :** une scène par effet, RT actif contre RT coupé.
- **Résultat attendu :** chaque effet donne le même ressenti qu'en vanilla. Par exemple, avec Vision nocturne, une grotte est aussi lisible qu'en vanilla, et la Cécité donne un écran aussi noir. Le réglage Luminosité change bien l'image.

### L10. Réfraction et absorption de l'eau (B6, suite de S5)
- **Créer :**
  - les rayons réfractés sous l'eau (loi de Snell, indice 1,33) ;
  - l'absorption selon la distance parcourue (Beer-Lambert par canal, à partir de la couleur du biome) ;
  - les reflets par Fresnel (existe).
- **Technique :** valeurs de départ comme Radiance : couleur (0 ; 0,48 ; 0,65) et absorption 0,22 par bloc, réécrites et ajustées.
- **Mesurer :** la scène mer et la scène sous l'eau.
- **Résultat attendu :** le fond est visible près du bord, puis l'eau devient bleu profond avec la profondeur. Elle n'est ni grise ni noire, de jour comme de nuit (l'essai du 2026-11-11 a échoué sur ce point). La couleur suit le biome.

### L11. Vagues (B7, début fait)
- **Technique :**
  - 10 ondes de 14 m à 0,38 m de longueur d'onde ;
  - crêtes pointues ;
  - vitesse qui dépend de la longueur d'onde (la houle va vite, le clapotis presque pas) ;
  - seule la normale bouge.
- **Résultat attendu :** les reflets bougent naturellement, sans motif qui se répète visiblement sur 20 blocs.

### L12. Feuilles à contre-jour (B8, début fait)
- **Résultat attendu :** une feuille vue face au soleil s'éclaire nettement plus que vue de dos, sans dépasser la luminance du ciel.

### L13. Reflets autres que l'eau
- **Créer :** des reflets sur le verre, la glace, les blocs polis et les métaux en PBR (Mat5), avec une rugosité qui floute le reflet.
- **Résultat attendu :** la glace et le verre reflètent le ciel et les blocs. Une surface rugueuse ne reflète pas comme un miroir.

### L14. Caustiques et rayons de lumière (plus tard, optionnel)
- **Créer :** des caustiques sous l'eau à partir des mêmes vagues, et des rayons de lumière dans le brouillard.
- **Résultat attendu :** coût ≤ 0,5 ms chacun, désactivables.

---

# Partie 6 : débruitage et lien entre les images

### D1. L'accumulation dans le temps (existe)
- **Créer :**
  - la reprojection avec la caméra de l'image précédente (existe) ;
  - le rejet de l'historique quand la profondeur ou la normale change (désocclusion) ;
  - un plafond d'historique (environ 1 s, existe).
- **Mesurer :** M5 et M6.
- **Résultat attendu :** aucune traînée derrière un bord qui bouge. L'historique est rejeté sur les zones qui apparaissent, et seulement là.

### D2. Le filtre spatial
- **Créer :** le remplacement du petit flou 5×5 actuel par un filtre « à trous » en plusieurs passes, guidé par la variance (méthode SVGF publiée), qui respecte les bords (profondeur, normale).
- **Mesurer :** M4 contre la référence, et la netteté des textures.
- **Résultat attendu :** caméra fixe à 1 s, FLIP ≤ 0,08 contre la référence. Juste après une désocclusion, l'image n'est ni plus bruitée ni plus floue qu'aujourd'hui. Les textures restent nettes, car on filtre la lumière sans albedo, ce qui existe déjà.

### D3. Effacer l'historique au bon moment
- **Créer :** l'effacement quand :
  - la taille change ;
  - le HDR change ;
  - les dégradés lisses changent ;
  - un pack s'active ;
  - le monde ou la dimension change ;
  - on se téléporte (plus de N blocs d'un coup).
- **Technique :** brancher sur `reset_history` du point d'accroche de #14035 si on l'utilise, sinon sur les mêmes évènements.
- **Résultat attendu :** aucune image ne mélange deux états (test par évènement).

### D4. Le lien avec le TAA, l'upscaler et l'échelle de rendu
- **Créer :**
  - le RT tracé à la résolution interne ;
  - le décalage de caméra (jitter) partagé avec le TAA ;
  - un passage correct dans l'upscaler (`world_post.rs`).
- **Mesurer :** M6 avec TAA actif, et avec une échelle de rendu de 50 %.
- **Résultat attendu :** pas de double flou ni de scintillement en plus avec le TAA, et une image cohérente à toutes les échelles.

### D5. La réactivité aux changements
- **Mesurer :** le nombre d'images pour que la lumière se stabilise après une torche posée, une porte ouverte, un nuage, ou le passage du jour à la nuit en accéléré.
- **Résultat attendu :** stable en moins de 0,5 s après une torche posée, et pas de lumière « fantôme » qui reste plus de 1 s.

### D6. Tracer un pixel sur deux (B10)
- **Créer :** une option où chaque image ne trace qu'un pixel sur deux en damier. L'autre moitié vient de l'image précédente.
- **Résultat attendu :** coût de la trace −40 % ou plus, et FLIP ≤ 0,02 de plus qu'en pleine résolution caméra fixe.

---

# Partie 7 : exposition et image, avec le HDR

**À décider avec Ducky** avant de coder (voir `INVENTAIRE-technique-rt-hdr.md`, section 0).

### E1. Qui gère l'exposition
- **Créer :** une décision écrite :
  - soit le RT garde son exposition pour sa propre lumière ;
  - soit une exposition commune passe dans la sortie HDR.
- **Résultat attendu :** une seule exposition s'applique à un pixel.

### E2. Mesurer la lumière comme l'œil (si l'exposition reste au RT)
- **Créer :** le remplacement de la moyenne logarithmique actuelle par un histogramme de 256 cases en log2, mesuré sur l'image débruitée.
- **Technique, idées de Caustica réécrites :**
  - on ne garde que la tranche entre 50 et 95 % de l'histogramme ;
  - le centre de l'image compte plus ;
  - le ciel compte pour 25 % au plus, les blocs lumineux pour 10 % au plus ;
  - le lissage se fait en EV (existe déjà) ;
  - 2 s vers le sombre, 0,4 à 0,5 s vers le clair (existe).
- **Mesurer :** `rtx-adapt.sh` (entrée dans la pièce à midi) et M2.
- **Résultat attendu :** en entrant dans une pièce à midi, 90 % de l'adaptation est faite en 2 s. Un écran à moitié rempli de ciel ne fait pas tout noircir. Une torche au centre ne fait pas tout noircir. On respecte la règle HDR Lighting (#14416) si elle est retenue.

### E3. La courbe de ton
- **Créer :** sur l'image flottante, aucune courbe de ton dans le RT : c'est la sortie HDR qui décide. En SDR 8 bits, on garde le petit adoucissement (`SHOULDER`) si Ducky est d'accord.
- **Mesurer :** M7, et la part de pixels brûlés (M2).
- **Résultat attendu :** jamais deux courbes de ton sur le même pixel. En SDR, moins de 2 % de pixels brûlés à midi en plein air.

### E4. Respect du pic et des valeurs d'affichage
- **Créer :** la lumière RT bloquée à `SCENE_PEAK`, en gardant sa teinte. Les valeurs `paper_white` et `peak` sont lues dans `EffectiveOutput` / `FrameState`.
- **Dépend de :** #13578.
- **Résultat attendu :** soleil visible à environ 1000 nits dans le `-hdr.png`, et aucune valeur RT au-dessus du pic.

### E5. Le mélange linéaire
- **Créer :** la fusion du RT suit `FRAME_LINEAR`, au lieu de deviner le gamma à partir du format.
- **Dépend de :** #13730.
- **Résultat attendu :** sous un pack 0.2 en mélange linéaire, la même scène donne la même lumière qu'en mélange gamma, à FLIP ≤ 0,02.

### E6. Le halo
- **Créer :** une décision : le halo du RT, la brillance HDR des sources, ou un seul halo commun. L'autre est retiré.
- **Résultat attendu :** une torche ne brille qu'une fois, et le halo garde la lumière au-dessus de 1.

### E7. Les captures
- **Créer :** les captures d'écran, les enregistrements et les streams passent par la conversion HDR vers SDR (`Hdr::sdr_screenshot`), RT compris.
- **Résultat attendu :** la capture SDR ressemble à l'écran, et le `-hdr.png` garde le pic.

---

# Partie 8 : intégration au pipeline

### I1. Sortir le RT de `gfx.rs` (C0)
- **Technique :** un déplacement pur vers `gfx/ray/`, seul dans sa PR.
- **Résultat attendu :** `gfx.rs` perd au moins les lignes que le RT avait ajoutées (+163/−79 sur `rt/lighting`), et frame identity reste identique.

### I2. Les points d'accroche
- **Créer :** une décision avec ludovic :
  - soit le RT se branche sur les points de #14035 (après le terrain opaque, après le translucide) ;
  - soit il garde des appels internes au moteur, aux mêmes endroits.
- **Résultat attendu :** aucun code RT n'est ajouté dans le corps de `Renderer::render`, seulement des appels d'une ligne.

### I3. Le RT avec un pack de shaders actif
- **Créer :** une règle. Au départ, le RT se coupe quand un pack dessine lui-même le monde (`pack_lights` / `lifts_world`), avec un message. On rouvrira la question pour l'API (temps 2).
- **Résultat attendu :** aucun pack ne plante ou ne s'affiche mal avec le RT activé.

### I4. Génération d'images (#14418)
- **Créer :** des tests du RT avec la génération d'images.
- **Résultat attendu :** les images générées ne montrent ni traînée ni scintillement de plus qu'avec le RT coupé (M6).

### I5. Écran partagé
- **Créer :** un historique, un cache de lecture et une exposition **par vue**. La scène (les BLAS) est partagée si les vues sont dans le même monde.
- **Résultat attendu :** deux joueurs dans des lieux différents ont chacun une lumière juste, sans que l'un influence l'autre.

### I6. Changement de pack de ressources, de taille, de réglages
- **Créer :** la reconstruction des matériaux, des textures RT et des pipelines au bon moment, sans fuite.
- **Résultat attendu :** 20 changements de suite laissent la mémoire (A5) au même niveau.

### I7. Conflits avec les PR HDR et shaders
- **Créer :** fusionner main dans la branche RT chaque jour, et attendre #13578 → #13738 → #13730 avant les PR qui touchent la fusion ou `terrain.wgsl`.
- **Résultat attendu :** aucune PR RT ne bloque une PR HDR, et l'inverse.

---

# Partie 9 : performance

### P1. Le budget par passe
- **Créer :** un tableau de budget, en ms et par qualité, rempli avec M3 et M8.
- **Résultat attendu :** chaque passe a son budget, vérifié avant chaque PR.

### P2. Les niveaux de qualité
- **Créer :** ce que change chaque niveau :

| Réglage | Basse | Moyenne | Haute |
|---|---|---|---|
| Portée tracée | 4 chunks | 8 | 12 |
| Rebonds (cache) | 1 | cache | cache + plus de rayons |
| Lumières (L5) | vanilla | RIS | ReSTIR |
| Trace | damier (D6) | pleine | pleine |
| Reflets | eau | eau + verre | tout + rugosité |

*(à valider)*

- **Résultat attendu :** chaque niveau tient son budget de temps (partie 0) sur la carte de sa classe.

### P3. Le temps CPU
- **Créer :** la mesure du temps CPU passé à préparer les BLAS et leurs envois. La préparation se fait hors du fil principal, avec le maillage.
- **Mesurer :** `tools/graphics_bench.py`, qui mesure déjà la part CPU.
- **Résultat attendu :** le RT ajoute ≤ 0,5 ms CPU par image *(à valider)*.

### P4. La régularité
- **Mesurer :** le 1 % des images les plus lentes (`graphics_bench.py`), en jeu normal et en vol rapide.
- **Résultat attendu :** le 1 % le plus lent ne baisse pas de plus de 15 % par rapport à la moyenne quand on active le RT.

### P5. Le réglage automatique (plus tard)
- **Créer :** un niveau proposé selon la carte, à partir de la matrice A6.
- **Résultat attendu :** chaque carte de la matrice reçoit le niveau qui tient 60 images/s.

---

# Partie 10 : qualité et livraison

### Q1. La spec RT upstream
- **Créer :** une issue de spec, comme #13661 pour le HDR. Elle couvre :
  - les couches (A3) ;
  - les points d'accroche (I2) ;
  - le lien avec le HDR (partie 7) ;
  - l'ordre des PR ;
  - les mesures de ce plan.
  - Elle est obligatoire pour les PR de plus de 500 lignes.
- **Résultat attendu :** validée par ludovic et Ducky, ou sans objection pendant le délai prévu.

### Q2. La note de conception
- **Créer :** `docs/design/ray-tracing.md`, sur le modèle de `docs/design/hdr-linear-light.md` : principes, passes, valeurs, tests. Avec les crédits Solari.
- **Résultat attendu :** un nouvel agent ou contributeur peut reprendre le travail en la lisant.

### Q3. Les règles d'une passe RT
- **Créer :** une section dans `docs/hdr-passes.md`, ou un fichier à part, qui liste ce que toute passe RT doit respecter (partie 7, D3, A4).

### Q4. Le découpage en PR (C1 à C8, voir `PLAN-ray-tracing.md`)
- **Pour chaque PR :**
  - `tools/pr_ready.py` vert ;
  - frame identity identique avec RT coupé ;
  - des captures avant/après pour ce qui se voit ;
  - #12989 cité si l'image change ;
  - l'en-tête « 🤖 Opened by Evan-lhm's AI agent ».

### Q5. Licences et crédits
- **Créer :** un commentaire de crédit en tête de chaque fichier adapté de Solari, et une ligne dans la note de conception.

---

# Ordre de construction

1. **Mesurer d'abord :** M1, M2, M3, M8, puis M4, M5, M6, M7, M9.
2. **Socle :** A2 fusionnée, A3 (avec l'accord de ludovic), I1, A4, A5, A6.
3. **Scène :** S4, S3, S1, S2, S10, S9.
4. **Matériaux :** Mat2, Mat3, Mat4.
5. **Lumière, le gros du visuel :** L4 (cache), puis L5 (lumières), puis S5 + L10 (eau), puis L7, L8, L9.
6. **Image propre :** D1 à D5, puis la partie 7 avec Ducky (après #13578 et #13730).
7. **Intégration :** I2 à I7.
8. **Performance :** P1 à P4, puis D6.
9. **Finitions :** S6, S7, S8, L11 à L14, Mat5.
10. **Livraison :** Q1 (la spec, dès que la partie 0 est chiffrée), Q2 à Q5, et les PR au fil de l'eau.

## Pour les agents (Fable ou autres)

- **Un chantier par agent,** avec sa fiche complète copiée dans la consigne.
- **Le temps à prévoir :** une compilation prend plus de 2 minutes. Un chantier de taille moyenne prend au moins 45 minutes, un gros chantier comme L4 ou L5 plusieurs heures.
- **Le banc de mesure (partie 1) doit exister avant,** et l'agent rend ses mesures « avant » et « après ».
- **Des chantiers indépendants peuvent tourner en parallèle,** chacun dans sa copie du dépôt, avec son propre dossier de compilation. Exemples : M1–M3 avec A4–A5, ou L4 avec S4.
- **Lectures obligatoires :** `docs/layers.md`, `docs/hdr-passes.md`, `docs/design/hdr-linear-light.md`, `docs/graphics.md`, `docs/api/shaders.md`, et ce plan.
