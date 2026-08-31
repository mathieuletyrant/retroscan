# retroscan

CLI macOS (Swift, zéro dépendance, zéro driver) pour scanner depuis une
imprimante Brother en réseau, recadrer automatiquement les images et y
embarquer des métadonnées.

Testé avec une Brother MFC-1910W. Fonctionne avec les modèles Brother qui
exposent le service Bonjour `_scanner._tcp` (port 54921, le protocole des
backends SANE `brscan`) — aucun driver Brother n'est nécessaire.

## Build

```sh
swift build -c release
cp .build/release/retroscan /usr/local/bin/   # optionnel
```

## Usage

```sh
retroscan                          # scan couleur 300 dpi, crop auto, dans le dossier courant
retroscan --list                   # liste les scanners du réseau
retroscan -r 600 -m gray -o ~/Documents/Scans
retroscan -t "Vacances 1995" -D 1995 -k photos,famille -a "Mathieu"
retroscan -c photos                # force la découpe photo par photo
retroscan -R none                  # désactive la rotation automatique
```

Avec `--title` (ou `--name`), les fichiers sortent en `Vacances 1995-1.jpg`,
`-2.jpg`, … et la numérotation **continue d'un scan à l'autre** dans le même
dossier : idéal pour numériser un album par fournées de 3-4 photos sur la
vitre. Sans titre, chaque scan reçoit une base horodatée `scan-<timestamp>`.

`retroscan --help` pour toutes les options.

## Ce que fait le crop `auto`

1. Plusieurs photos posées sur la vitre → détection des régions (composantes
   connexes sur fond blanc) et **un fichier par photo**.
2. Un seul document détecté (Vision `VNDetectDocumentSegmentationRequest`) →
   recadrage avec correction de perspective.
3. Sinon → simple rognage des marges blanches.

Les pages multiples du chargeur (ADF) sortent en fichiers `-p1`, `-p2`, …

## Détection par Segment Anything (SAM 2) sur la puce Apple

```sh
retroscan --sam        # télécharge les modèles Core ML (~78 Mo, une fois)
```

Avec `--sam`, la détection de photos s'appuie sur **Segment Anything 2**
(conversion Core ML officielle d'Apple, exécutée sur le GPU/Neural Engine).
La détection classique localise grossièrement chaque tirage, puis SAM en
délimite le contour — y compris les bords invisibles aux seuils de
luminance, comme un ciel délavé ou une nappe blanche contre le blanc de la
vitre. Les modèles sont mis en cache dans
`~/Library/Application Support/retroscan/`.

C'est un mode d'appoint, pas le défaut : le masque de SAM est en 256×256
(≈ 7 px de quantification sur un A4 à 300 dpi), donc la détection classique
(luminance + gradient) recadre en général plus juste. Réserve `--sam` aux
pages où une photo à bord très clair se fait mal découper — ou pose une
feuille sombre sur les photos, voir ci-dessous.

## Astuce : photos à bords très clairs

Une photo dont le bord est quasi blanc (ciel délavé, nappe blanche…) peut se
confondre avec le blanc de la vitre, même pour la détection par gradient. La
parade imparable : poser une **feuille sombre** (papier noir, chemise foncée)
sur les photos avant de fermer le capot, en couvrant toute la vitre.
`retroscan` détecte automatiquement la couleur du fond et la découpe devient
triviale, bords blancs compris.

`RETROSCAN_DEBUG=1 retroscan …` affiche le niveau de fond détecté et les
régions trouvées, utile pour diagnostiquer une découpe surprenante
(à combiner avec `--input fichier.jpg` pour rejouer sans scanner).

## Rotation automatique

`--rotate auto` (défaut) : détection de visages Vision dans les 4 orientations,
pondérée par l'angle de roulis — les photos de personnes sont remises dans le
bon sens. Sans visage détecté, l'image reste telle que scannée.
`--rotate 90|180|270` pour forcer, `none` pour désactiver.

## Métadonnées embarquées

Toujours : date de scan (EXIF DateTimeDigitized), marque/modèle du scanner et
logiciel (TIFF), résolution DPI. En option : `--title` (IPTC ObjectName),
`--keywords` (IPTC), `--author` (TIFF Artist + IPTC Byline), `--description`
(EXIF UserComment + TIFF ImageDescription + IPTC Caption), et `--date` — la
date de **prise de vue** de la photo d'origine (`1995`, `1995-07` ou
`1995-07-14`), écrite en EXIF DateTimeOriginal + IPTC DateCreated : c'est elle
que Photos et consorts utilisent pour classer les images.

## Notes protocole (MFC-1910W)

- Bannière `+OK 200` à la connexion sur le port 54921.
- Query : `ESC I \n R=x,y \n M=mode \n 0x80` → `0x00 <len:2 LE> <csv> 0x00`
  (résolution, largeur mm/px, hauteur mm/px).
- Scan : `ESC X` avec `M=CGRAY` (= **couleur** 24 bits JPEG, contre-intuitif),
  `C=JPEG`, `A=0,0,w,h`, `D=SIN`. Le mode gris matériel (`GRAY64`) utilise une
  compression RLE — le gris est produit localement à la place.
- Flux : blocs `0x64` (en-tête 12 octets, longueur aux octets 10-11 LE, données
  JPEG), `0x82` fin de page, `0x80` fin de session, `0xc2` chargeur vide,
  `0xc3` bourrage, `0xc4` capot ouvert.
- Attention : une commande de scan invalide (ex. `M=C24BIT`) gèle le service
  de scan de l'imprimante pendant ~1 minute.
