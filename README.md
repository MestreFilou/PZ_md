# Underground Base Excavation (Project Zomboid – Build 42)

Creusez des caves, tunnels et bases souterraines sur les niveaux Z négatifs, étayez-les au bois et gare aux éboulements.

## Installation

Copiez le dossier `UndergroundBaseExcavation/` de ce dépôt dans `~/Zomboid/mods/` (Windows : `C:\Users\<vous>\Zomboid\mods\`), puis activez le mod dans le menu Mods.

Structure Build 42 (les dossiers `42/` et `common/` sont obligatoires en B42) :

```
UndergroundBaseExcavation/
├── common/                         (vide, requis par B42)
└── 42/
    ├── mod.info
    ├── poster.png
    └── media/lua/
        ├── client/
        │   ├── ContextMenus/ISDigUndergroundMenu.lua   menu clic droit
        │   ├── TimedActions/ISDigTileAction.lua        creuser (accès, adjacent, plus profond)
        │   ├── TimedActions/ISBraceTileAction.lua      étayer / renforcer
        │   ├── TimedActions/ISUseShaftAction.lua       monter / descendre par le puits
        │   └── UndergroundClient.lua                   réception serveur, détection des pas
        ├── shared/
        │   ├── UndergroundUtils.lua                    configuration + utilitaires
        │   ├── UndergroundSystem.lua                   états des cases, éboulements
        │   └── Translate/EN/UI_EN.txt, FR/UI_FR.txt
        └── server/UndergroundCommands.lua              logique autoritaire (monde + ModData)
```

## Gameplay

| État | Signification | Comment |
|---|---|---|
| 0 | Sol non creusé (ou rempli par un éboulement) | – |
| 1 | Creusé, non étayé : risque d'éboulement | Pelle / pioche / pelle de tranchée |
| 2 | Étayé au bois : stable | Marteau + 2 planches + 4 clous |
| 3 | Renforcé : structure permanente | Marteau + 4 planches + 8 clous |

1. En surface, clic droit sur de l'herbe ou de la terre : **Creuser un accès souterrain**. Cela ouvre une case en Z = -1 reliée par un puits, puis **Descendre**.
2. Sous terre, clic droit n'importe où : **Excaver une case adjacente → Nord/Sud/Est/Ouest**, **Poser un étayage en bois**, **Renforcer la structure**, **Creuser le puits plus profond** (jusqu'à Z = -2, case étayée requise), **Remonter**.
3. Marcher sur une case non étayée ou creuser à côté déclenche un jet d'éboulement. Un éboulement blesse (coupures, fractures possibles), remplit la case de décombres et repousse le joueur vers une case libre. S'il n'y en a pas, il est coincé et doit **Dégager les décombres**.
4. Creuser coûte de l'endurance, de la fatigue, de la soif et de la faim, use l'outil, et va plus vite avec Forme + Force (Menuiserie pour l'étayage).

Tous les réglages (outils, matériaux, durées, probabilités, profondeur max, sprites, sons) sont dans `UndergroundUtils.Config`.

## Points à vérifier en jeu

- **Sprites** : le sol utilise une tuile de terre vanilla (`blends_natural_01_64`). Les murs de terre et les décombres (`underground_01_0`, `underground_01_1`) sont des **noms provisoires** : remplacez-les par des tuiles existantes de votre version, sinon ces objets seront invisibles (la logique fonctionne quand même).
- **Noms d'API** : Build 42 change encore d'une sous-version à l'autre (statistiques, sons, animations). Les appels sensibles sont protégés par `pcall` et les deux API de stats (`setFatigue` et `stats:set(CharacterStat...)`) sont gérées, mais un nom de son ou d'animation peut nécessiter un ajustement.
- **Multijoueur** : le flux client → serveur est en place (`sendClientCommand` / `OnClientCommand`, `ModData.transmit`), mais la création de cases souterraines côté client en MP n'a pas été testée.
- **Build 41** : non pris en charge (pas de niveaux négatifs).

Note : le cahier des charges plaçait les traductions dans `media/shared/Translate`. Le jeu les lit dans `media/lua/shared/Translate`, c'est donc là qu'elles sont.
