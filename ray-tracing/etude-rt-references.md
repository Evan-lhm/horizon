# Étude : comment font les autres rendus ray tracing de Minecraft

Lu le 2026-11-11. On n'a **copié aucun code** : ce fichier ne garde que des idées, des méthodes et des valeurs de réglage, réécrites avec nos mots. Pour les projets sous GPL ou LGPL, on ne reprend jamais leur code dans Horizon : on code nous-mêmes à partir de ces notes.

| Projet | Licence | Peut-on reprendre du code ? |
|---|---|---|
| Bevy Solari (bevyengine/bevy) | MIT / Apache-2.0 | Oui, en citant la source |
| Radiance + MCVR + Shaderpack-Advanced | GPL-3.0 (MCVR : « other ») | Non : idées et réglages seulement |
| Caustica-RTX, Caustica-Rework | LGPL-3.0 | Non : idées et réglages seulement |
| SHaRC (NVIDIA, embarqué dans Radiance) | Propriétaire NVIDIA | Non |
| mega-minecraft | Aucune licence | Non |
| rtx-remix-minecraft | Apache-2.0 | Oui, mais c'est RTX Remix qui fait le rendu : peu de shaders à reprendre |

## 1. Le point commun : un cache de lumière dans l'espace

Les **trois** rendus avancés font la même chose : Bevy Solari (son « world cache »), Radiance (SHaRC de NVIDIA) et, dans une autre forme, Caustica (un vrai path tracing jusqu'à 4 rebonds, débruité par DLSS).

**Le principe :**
- Une table de hachage en mémoire GPU. Une cellule correspond à une position arrondie et une normale arrondie.
- La taille des cellules grandit avec la distance à la caméra (niveaux de détail en puissances de 2, Solari).
- Chaque image, quelques rayons partent des cellules actives. Ce qu'ils touchent est lu dans la même table, ce qui donne **plusieurs rebonds** accumulés d'une image à l'autre.
- Une cellule non consultée pendant environ 10 images est libérée (Solari).
- Le point de lecture est décalé au hasard dans le plan de la surface, pour estomper la grille (Solari).

**Pour nous :** c'est la réponse au problème des intérieurs et des sous-bois trop sombres. Aujourd'hui on n'a qu'un rebond, calculé depuis l'écran. Un monde en blocs se prête très bien aux cellules. On s'appuie sur le code de **Solari** (MIT), pas sur SHaRC.

## 2. Exposition automatique (Caustica)

C'est la version la plus aboutie des trois. Valeurs par défaut :

| Réglage | Valeur | Ce que ça veut dire |
|---|---|---|
| Clé (`key`) | 0,18 | Gris moyen visé |
| Adaptation vers le sombre | 2,0 s | Lente, comme l'œil |
| Adaptation vers le clair | 0,4 s | Rapide |
| Percentiles mesurés | 50 % à 95 % | On ignore la moitié la plus sombre et les 5 % les plus clairs |
| Poids au centre | σ = 0,35, plancher 0,15 | Le centre de l'image compte plus |
| Part maximale du ciel | 25 % | Le ciel ne fausse pas la mesure |
| Part maximale des blocs lumineux | 10 % | La lave ou les torches non plus |
| Pas d'échantillonnage | 1 pixel sur 2 | |
| Plage | environ 20 EV (du sable à midi au ciel étoilé) | Nous : environ 2 EV (×0,75 à ×3) |

**Méthode :** un histogramme de 256 cases en log2 de luminance, sur l'image déjà débruitée (sur une image bruitée, la moyenne logarithmique est faussée). Ensuite : moyenne entre les percentiles, clé, bornes, puis **lissage en EV (échelle logarithmique)**.

Leur note explique pourquoi : lisser en échelle linéaire rend l'adaptation asymétrique. Vers le clair, presque tout l'écart est franchi en une image ; vers le sombre, l'approche est très lente. **Notre version lisse en linéaire** : c'est à corriger, et ça explique en partie l'effet « minime ».

**Pour nous, sans changer d'architecture :**
1. lisser en log2 au lieu de linéaire ;
2. mesurer le ciel et les blocs lumineux à part, avec un plafond ;
3. élargir la plage, en gardant le jeu normal comme repère pour l'extérieur.

## 3. Lumière des blocs (Caustica, Radiance)

- **Caustica :** chaque bloc lumineux est une vraie source de lumière, un petit rectangle. Elles sont rangées par section, avec une table de tirage proportionnelle à la puissance. Le tirage se fait en temps constant : un mélange entre les sources proches (par section) et toutes les autres. Les pixels choisissent parmi ces candidats (RIS / ReSTIR).
- **Le masque d'émission** est déduit de la texture : luminance du texel à la puissance 3, plancher 0,1. Seuls les texels clairs émettent : la flamme d'une torche, pas son bâton. On pourrait le calculer en plus de notre table `ray_material`.
- **Radiance (ReSTIR DI) :** 8 candidats au départ (16 juste après une désocclusion), 2 voisins réutilisés dans un rayon de 24 pixels, zone de recherche de 2 sections à l'horizontale et 1 à la verticale.
- **Solari :** des « tuiles de lumières » pré-tirées chaque image, dans lesquelles chaque pixel pioche.

## 4. Soleil, lune et ciel (Radiance, Caustica)

- **Radiance :**
  - soleil `(1, 1, 1)`, lune `(0.016, 0.02, 0.04)`. La lune vaut environ 1/40 du soleil et tire sur le bleu. **La nôtre en vaut environ 1/5.**
  - les rebonds du soleil sont multipliés par 2, ceux de la lune par 8 : un choix artistique pour éclaircir les intérieurs et la nuit sans relever la lumière directe ;
  - lumière de fond minimale `0.1 × 0.001`.
- **Caustica :** ciel physique avec tables précalculées (transmittance, diffusion multiple, vue du ciel). La couleur du soleil et de la lune sort de la transmittance de l'atmosphère.

## 5. Eau (Caustica, Radiance)

- **L'eau fait partie de la scène tracée,** traitée comme un matériau transparent qui réfracte. Les rayons traversent l'eau, puis le verre.
- **Absorption de Beer-Lambert par canal,** à partir de la teinte du biome. Caustica : densité 0,1 et plancher d'absorption `(0.015, 0.010, 0.008)` par bloc. Radiance : couleur `(0.0, 0.48, 0.65)` et absorption 0,22 par bloc.
- **Vagues (Caustica) :**
  - 10 ondes, de 14 m à 0,38 m de longueur d'onde (chacune 1,5 fois plus courte), pente 0,3 ;
  - crêtes pointues : profil `exp(S·(sin φ − 1))` ;
  - vraie dispersion ω = √(g·k) : la houle longue avance vite, le clapotis court presque sur place ;
  - direction du vent avec un étalement ;
  - seule la normale s'incline, la surface reste plate.
- **Caustiques calculées depuis les mêmes vagues** (Caustica).

**Pour nous :** notre essai d'absorption a échoué faute de réfraction et de teinte de biome. Il faut d'abord **mettre l'eau dans la scène tracée** (ticket « Water in the ray-traced scene » du fork). Notre petit champ de vagues (2 sinus) pourrait déjà gagner la dispersion et les crêtes pointues.

## 6. Feuilles et herbe

- **Caustica :** transmission à travers les surfaces fines, avec une phase de Henyey-Greenstein : la lumière passe à travers la feuille, plus fort vers le soleil.
- **Nous :** les feuilles laissent passer la lumière colorée (commit 46d559919), sans dépendre de la direction. On pourrait ajouter ce pic quand on regarde vers le soleil.

## 7. Débruitage et performance

- **Caustica :** 1 échantillon par pixel, DLSS Ray Reconstruction obligatoire pour une image propre.
- **Radiance :** DLSS RR sur NVIDIA, sinon **NRD** (débruiteurs NVIDIA open source), avec un mode « damier à mi-cadence » où chaque image ne trace qu'un pixel sur deux.
- **Pour nous :** wgpu ne donne pas accès à DLSS RR. Le damier est une idée de performance simple à tester.

## Ce que je propose, par ordre d'intérêt

1. **Exposition : lissage en log2** et ciel mesuré à part. Petit, et ça corrige l'effet « minime ».
2. **Lune plus faible et bleutée,** avec un rebond renforcé la nuit (idées de Radiance). Petit.
3. **Cache de lumière à la Solari** (plusieurs rebonds). Gros, mais c'est le plus gros gain visuel.
4. **Eau dans la scène tracée,** puis absorption, puis vagues à dispersion. Gros.
5. **Blocs lumineux en vraies sources** avec ReSTIR. Gros.
