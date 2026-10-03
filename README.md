# PhotoStacks

Zoekt reeksen tussen Olympus/OM System `.ORF` bestanden (focus bracketing, belichtingsbracketing/HDR, ProCap en
serieopnamen) en zet ze per stack in `<map>/<soortmap>/<eerste>-<laatste> (<aantal>)/` als relatieve symlinks naar
de originelen. Soortmappen: `FocusStacks`, `HDRStacks`, `ProCap` en `Series`; een soortmap wordt alleen gemaakt als
er stacks van die soort zijn.
Originelen worden nooit gewijzigd of overschreven; alleen op expliciet verzoek (met bevestiging) gaat een origineel
naar de Prullenmand.

## Gebruik
- Start `build/PhotoStacks.app`, kies een map (knop, slepen op het venster of op het app-icoon) en klik **Maak stacks**.
  Komen er meerdere soorten voor, dan filtert de keuze bovenin (Alle / Focus / HDR / ProCap / Serie) het overzicht.
- HDR-reeksen openen in Photomatix Pro: knop **Photomatix** per stack (RAW of, als ze er zijn, de DxO-TIFFs).
  ProCap en series hebben geen app-knop: kies de beste in het voorbeeldvenster en haal de rest uit de stack of
  stuur ze naar de Prullenmand.
- Openen in Helicon Focus: knop **Helicon** per stack, of rechtsklik → *Open RAW/TIFF in Helicon Focus*.
  Dubbelklik op een stack klapt hem uit of in.
  Bestaat de stack-map al, dan worden de links geopend, anders de originelen. Een rij kan ook als map naar
  Helicon of Finder gesleept worden (nadat de stack-map is aangemaakt).
- Belichting (HDR): na het scannen meet de app op de achtergrond van elke HDR-foto hoeveel procent van de
  sensorpixels over- of onderbelicht is, op de ruwe sensordata zoals FastRawViewer (niet op een gerenderd beeld).
  Overbelicht = op het sensormaximum (4094–4095), onderbelicht = meer dan 10 stops daaronder (de ruisvloer).
  De stackregel toont **Hoog** (overbelicht in de donkerste foto) en **Schaduw** (onderbelicht in de lichtste
  foto): groen als de reeks het hele bereik dekt, oranje < 1%, rood daarboven. Uitgeklapt staat per foto de
  belichting t.o.v. Shot 1 (uit sluitertijd, diafragma en ISO, dus ook in M-stand) met % over en % onder.
  Per foto bekijken: `PhotoStacks --cli <map> --exposure`; drempels in `ExposureAnalyzer.swift`.
- Scherpte (focus, ProCap en series; niet bij HDR, daar verschilt de belichting per foto): na het scannen meet de
  app op de achtergrond elke stack-foto (alleen lezen) en toont in de kolom
  **Onscherp** de foto's waarop niets scherp is; rechtsklik → *Toon onscherpe foto's in Finder*. Per vak van een
  24×18-raster wordt elke foto vergeleken met de scherpste foto van de stack in datzelfde vak (na aftrek van de
  ruisvloer). Haalt een foto in geen enkel detailvak 25% daarvan, dan is hij onscherp. Drempels staan in
  `SharpnessAnalyzer.swift`; per foto bekijken: `PhotoStacks --cli <map> --sharpness`.
- Elke stack heeft een kleine thumbnail (de eerste foto van de stack); klik erop om hem groot te bekijken.
  De kolom Scherpte toont per stack een grafiekje van de scherpte per foto. Uit- en inklappen met de chevron of
  → / ←; ⌘O kiest een map, ⌘R scant opnieuw.
- Foto's per stack: klap een stack open voor alle foto's met scherpte-balkje (rood < 25%, oranje < 50%).
  **Bekijk** of dubbelklik opent het voorbeeldvenster (←/→ bladeren). Zoomen: knijpen met twee vingers op het
  trackpad (tot 800%), ⌘+ / ⌘−, Z of klik = passend ↔ 100%. 100% is één pixel van de RAW; zodra je verder inzoomt
  dan de ingebouwde preview (3200 px) aankan, laadt de volledige RAW (± 0,5 s, buurfoto's worden voorgeladen).
  Zoom en positie blijven staan bij bladeren, om dezelfde plek in opeenvolgende foto's te vergelijken:
  - **Uit stack** (⌫): link weg, onthouden in `FocusStacks/.uitgesloten` (voor alle soorten); terug met *Terug in stack*.
    In het overzicht kan ⌫ ook voor meerdere geselecteerde foto's.
  - **Prullenmand** (⌘⌫): na bevestiging gaan het .ORF en bijbestanden met exact dezelfde naam
    (.xmp, .on1, .JPG, .ORI …) naar de Prullenmand (terug te zetten via Finder). Nooit definitief verwijderen.
  - **Deze + volgende** (⇧⌘⌫, aparte knop): idem voor deze foto en alle foto's die erna komen in dezelfde stack
    (handig voor een onscherpe staart); andere stacks blijven ongemoeid.
  - Bestaan de soortmappen al, dan worden links en mapnamen meteen bijgewerkt.
- DxO PhotoLab-TIFFs: exporteer je de foto's van een stack als TIFF naar dezelfde map (bv. `OM1R5855_DxO.tif`),
  dan komen er links naar in `<soortmap>/<stack>/TIFF/`. Herkend worden TIFFs met exact de fotonaam
  (`OM1R5855.tif`) en TIFFs die met de fotonaam beginnen en "DxO" in de naam hebben (andere programma's, zoals
  `_Nik`, tellen niet mee); bij meerdere versies de nieuwste.
  De stack toont "TIFF x/y"; de Helicon- of Photomatix-knop krijgt een menu RAW/TIFF en opent standaard TIFF als élke foto er een
  heeft. Nieuwe exports worden opgepikt zodra je terugschakelt naar PhotoStacks. Een foto naar de Prullenmand
  neemt ook zijn DxO-TIFF(s) mee.
- Opnieuw draaien houdt de soortmappen bij: bestaande links blijven staan, een stack-map wordt hernoemd als de
  stack veranderd is (bv. foto verwijderd), kapotte links van de app zelf (`<naam>.ORF -> ../../<naam>.ORF`
  zonder origineel) worden opgeruimd en mappen die daarna leeg zijn (op `.DS_Store` na) verdwijnen.
  Eigen bestanden in de soortmappen en andere links blijven altijd staan.

## Herkenning
Drive Mode uit de MakerNotes (via exiftool), `<modus>, Shot N` (eventueel met `; Anti-shock` e.d. erachter):

| Modus | Soort | Map |
|---|---|---|
| `Focus Bracketing` | Focus | `FocusStacks` |
| `AE Bracketing`, `AE Auto Bracketing` (HDR-menu) | HDR | `HDRStacks` |
| `ProCap`, `ProCap SH1/SH2/H/L` | ProCap | `ProCap` |
| `Sequential`, `Sequential SH1/SH2/H/L` | Serie | `Series` |

WB-, FL-, ISO- en MF-bracketing worden niet herkend. Foto's worden op bestandsnummer gesorteerd; een stack loopt door
zolang de modus gelijk blijft (AE en AE Auto zijn verschillend) en het Shot-nummer stijgt. Verwijderde foto's (gaten)
mogen, zolang bestandsnummer − Shot-nummer gelijk blijft; zo blijven ook uitgedunde bursts bij elkaar. Ontbrekende
shots worden alleen bij focus en HDR gemeld. Stacks van 1 foto worden genegeerd.

## Bouwen
Vereist: Command Line Tools (Swift 6) en [exiftool](https://exiftool.org).

    ./build.sh          # maakt build/PhotoStacks.app
    swift test          # unit tests

Testmodus zonder venster: `build/PhotoStacks.app/Contents/MacOS/PhotoStacks --cli <map> [--dry-run]`
