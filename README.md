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
- Mapboom: links staat een boom van mappen onder een startmap die je zelf kiest (knop bovenaan de zijbalk of ⌘O;
  een map die je op de app sleept buiten de boom wordt de nieuwe startmap). Elke map klapt apart open of dicht
  (chevron, of → / ←); een map aanklikken analyseert hem op reeksen. Startmap en geopende mappen worden onthouden.
  Verborgen mappen en de uitvoermappen van de app (FocusStacks, HDRStacks, ProCap, Series) staan niet in de boom.
- Instellingen (⌘,): per rol de app die gebruikt wordt: **focusstacks** (standaard Helicon Focus), **HDR-stacks**
  (standaard Photomatix Pro) en **resultaatfoto's** (de blauwe badge in de kolom Status; standaard DxO PhotoLab).
  *Kies…* opent een paneel in /Applications, *Standaard* zet de oorspronkelijke app terug. De keuze wordt onthouden;
  een gekozen app die ontbreekt wordt oranje gemeld en de knop is dan grijs. Helicon Focus krijgt de stackmap
  als argument (het negeert "open documenten"), elke andere app krijgt de bestanden van de stack. De knop
  *DxO PhotoLab* voor de originelen (.ORF) blijft PhotoLab.
- Openen in Helicon Focus: knop **Helicon** per stack, of rechtsklik → *Open RAW/TIFF in Helicon Focus*.
  Dubbelklik op een stack klapt hem uit of in.
  Bestaat de stack-map al, dan worden de links geopend, anders de originelen. Een rij kan ook als map naar
  Helicon of Finder gesleept worden (nadat de stack-map is aangemaakt).
- Belichting (HDR): na het scannen meet de app op de achtergrond van elke HDR-foto hoeveel procent van de
  sensorpixels over- of onderbelicht is, op de ruwe sensordata zoals FastRawViewer (niet op een gerenderd beeld).
  Overbelicht = op het sensormaximum (4094–4095), onderbelicht = meer dan 10 stops daaronder (de ruisvloer).
  In de meetkolom toont de stackregel ☀ (overbelicht in de donkerste foto) en ☾ (onderbelicht in de lichtste
  foto): groen als de reeks het hele bereik dekt, oranje < 1%, rood daarboven. Uitgeklapt staat per foto de
  belichting t.o.v. Shot 1 (uit sluitertijd, diafragma en ISO, dus ook in M-stand) met % over en % onder; het
  voorbeeldvenster toont hetzelfde.
  Per foto bekijken: `PhotoStacks --cli <map> --exposure`; drempels in `ExposureAnalyzer.swift`.
- Scherpte (focus, ProCap en series; niet bij HDR, daar verschilt de belichting per foto): na het scannen meet de
  app op de achtergrond elke stack-foto (alleen lezen) en toont in de meetkolom hoeveel foto's **onscherp** zijn
  (niets scherp); rechtsklik → *Toon onscherpe foto's in Finder*. Per vak van een
  24×18-raster wordt elke foto vergeleken met de scherpste foto van de stack in datzelfde vak (na aftrek van de
  ruisvloer). Haalt een foto in geen enkel detailvak 25% daarvan, dan is hij onscherp. Drempels staan in
  `SharpnessAnalyzer.swift`; per foto bekijken: `PhotoStacks --cli <map> --sharpness`.
- Elke stack heeft een kleine thumbnail (de eerste foto van de stack, of de stacked JPG van de camera, zie
  hieronder); klik erop om hem groot te bekijken.
  Scherpte en belichting delen één meetkolom (elke reeks heeft er één van); de kop volgt het soortfilter:
  *Scherpte*, *Belichting* of *Scherpte / belichting*. Per focus-, ProCap- of seriestack staat daar een grafiekje
  van de scherpte per foto. De kolom Status gaat over de bestanden: de stacked JPG van de camera, DxO-TIFF's,
  ontbrekende shots en foto's die uit de stack zijn gehaald. Uit- en inklappen met de chevron of
  → / ←; ⌘O kiest een map, ⌘R scant opnieuw.
- Stacked JPG van de camera: stackt de camera zelf (focus stacking in de camera), dan bewaart hij naast de
  .ORF-bestanden één JPG met het resultaat (MakerNotes → Stacked Image: Focus-stacked). Heeft een focusstack zo'n
  JPG, dan is dat beeld de thumbnail en de hoverpreview van de stack, staat hij vooraan in het voorbeeldvenster
  (→ gaat verder naar de losse foto's, ← terug; bij de JPG zelf zijn *Uit stack* en *Prullenmand* niet
  beschikbaar) en toont de kolom Status een teal badge **Stacked JPG**. De JPG krijgt het bestandsnummer direct na de laatste shot: dat van
  Shot 1 plus het aantal beelden uit de tag (de shots OM1R5855–OM1R5862 geven OM1R5863.JPG). Alleen een JPG met dat
  nummer, met de tag Focus-stacked en hetzelfde aantal beelden telt; de camera-JPG's van losse shots en kopieën van
  andere programma's (`OM1R5863_NIK.JPG`) tellen niet. De JPG staat niet in de stack-map (anders stackt Helicon hem
  mee) en gaat niet mee naar de Prullenmand als je de foto's of de hele stack weggooit. De controle draait bij het
  scannen en leest alleen de tag van de JPG's op de plek waar er een kan staan. In de CLI staat hij als
  `stacked JPG …`.
- JPG's van losse foto's: het pijltje naast de prullenbak van een stack heeft *Alleen JPG's van losse foto's naar
  Prullenmand…* (ook in het contextmenu). Dat zijn de JPG's die de camera naast elke foto bewaart (zelfde naam als de
  .ORF); herkend aan de MakerNotes: Drive Mode gelijk aan die van de foto (`Focus Bracketing, Shot 3`) en Stacked Image
  "No". De stacked JPG van de camera (Drive Mode Sequential, Stacked Image Focus-stacked) en de .ORF-bestanden blijven staan.
  Dat ze er zijn zie je subtiel: de grijze regel onder de stacknaam eindigt op `15 JPG` (of `12/15 JPG`), uitgeklapte
  foto's krijgen een grijze tag `JPG` in de kolom Status en het menu-item toont het aantal en is grijs als er geen
  zijn. De JPG's worden op de achtergrond gezocht (alleen nieuwe bestanden worden gelezen) en bij het terugkeren in
  de app ververst.
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
- Resultaten van Helicon Focus, Photomatix Pro en Luminar Neo: staat er naast de originelen al een afbeelding die een van beide
  programma's van de stack maakte, dan toont de kolom Status een blauwe badge **Helicon**, **Photomatix** of **Luminar Neo** (met ×n bij
  meer afbeeldingen; de tooltip noemt de bestanden; klik op de badge om een van de afbeeldingen in DxO PhotoLab te openen). Herkend wordt aan de metadata (`ProcessingSoftware`, `Software`
  of `CreatorTool` bevat de programmanaam; het versienummer telt niet, en Helicons tag blijft staan als DxO
  PhotoLab het bestand opnieuw exporteert) en aan de naam: die begint met de naam van een foto uit de stack (Helicon
  noemt het resultaat soms naar de eerste, soms naar de laatste foto). Zonder bruikbare metadata, zoals bij `.hdr` en
  `.exr`, beslist de gebruikelijke naamgeving: `OM1R1409 11 (B,R4,S2).tif` (Helicon) en `OM1R1308_09_10_Optimizer.tif`
  (Photomatix). Luminar Neo (alleen focus- en HDR-stacks) wordt alleen aan `Software`/`CreatorTool` "Luminar Neo" herkend, ook bij een bestand dat precies de fotonaam heeft (`_OM16524.tiff`) of er direct een letter achter krijgt (`OM1R1916neo.jpeg`); "Luminar AI" telt niet. Resultaten in submappen of met een andere naam worden niet gevonden. De controle draait op de
  achtergrond bij het scannen en zodra je terugkeert in de app. In de CLI staan ze als `resultaat [Helicon] …`.
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
