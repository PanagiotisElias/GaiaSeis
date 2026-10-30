# GaiaSeis: Τροφοδοσία της λύσης μετατόπισης πραγματικού χρόνου στο SeisComP

Πώς περνά η ροή μετατόπισης 10 Hz ενός σταθμού GaiaSeis σε ένα σύστημα SeisComP
μέσω SeedLink. Στην ίδια κεραία του Πανεπιστημίου Πατρών υπάρχουν δύο σταθμοί:
**UPC10Z** (σε παραγωγή από 22/10/2026, κωδικός σταθμού
`UPC10`) και **UPA10Z** (κωδικός `UPA10`, ο σταθμός
παραγωγής έως τις 22/10/2026). Χρησιμοποιήστε αυτόν που εκπέμπει· οι εντολές
δίνονται για τον UPC10 με τον UPA10 σε παρένθεση. GaiaSeis 0.4.2, SeisComP 5 ή 6.
Γράφτηκε 06/10/2026, ενημερώθηκε 22/10/2026.

> **Η διεύθυνση SeedLink (`<seedlink-host>:18000`) δίνεται στους καταναλωτές ξεχωριστά· είναι προσωρινή μέχρι την εγκατάσταση αποκλειστικού διακομιστή ringserver, και τότε αλλάζει μόνο το όνομα του διακομιστή.**

## 1. Τι παρέχει το GaiaSeis

Το GaiaSeis γράφει τη λύση του ως miniSEED και προωθεί κάθε εγγραφή σε έναν
`ringserver` που τρέχει δίπλα του. Ο ringserver είναι ο διακομιστής SeedLink· το
SeisComP συνδέεται σε αυτόν όπως σε οποιαδήποτε άλλη πηγή SeedLink.

| στοιχείο | UPC10Z (παραγωγή από 22/10/2026) | UPA10Z |
|---|---|---|
| Διακομιστής SeedLink | ο υπολογιστής του GaiaSeis, θύρα 18000 (`<seedlink-host>:18000`)· δέχεται μόνο τα δίκτυα του τμήματος και localhost | ίδιος |
| Δίκτυο, σταθμός, location | `CL`, `UPC10`, κενό | `CL`, `UPA10`, κενό |
| Δέκτης | Topcon NET-G5, ενσωματωμένος caster NTRIP, mount `B` | Topcon NET-G5, ενσωματωμένος caster NTRIP, mount `B` |
| Κατάσταση | εκπέμπει, SSR απενεργοποιημένο, `CL.UPC10` στο SeedLink και στο `mseed2/` | δεν εκπέμπει από 22/10/2026 13:21 UTC· ο `CL.UPA10` σταμάτησε τότε |
| Κανάλια | `LNN` βορράς, `LNE` ανατολή, `LNZ` κατακόρυφο | ίδια |
| Ρυθμός δειγματοληψίας | 10 Hz (ένα δείγμα ανά επιλυμένη εποχή) | ίδιος |
| Κωδικοποίηση | miniSEED 2.4, εγγραφές 512 byte, δείγματα INT32, big-endian | ίδια |
| Μονάδες | counts· 1 count = 0,1 µm. Counts × 10⁻⁷ = μέτρα μετατόπισης ανά εποχή | ίδιες |
| Χρονοσήμανση | UTC (τα δευτερόλεπτα διαφοράς GPS–UTC αφαιρούνται πριν τη σήμανση) | ίδια |
| Μέγεθος | μετατόπιση από εποχή σε εποχή της βαριομετρικής λύσης, δηλαδή ταχύτητα × 0,1 s· ολοκληρώστε για αλλαγή θέσης | ίδιο |
| Κενά | μια εποχή που λείπει ή έχει ακυρωθεί κλείνει την εγγραφή· το SeisComP βλέπει πραγματικό κενό, όχι χρονικά μετατοπισμένο ίχνος | ίδια |
| Επανάληψη | ο ringserver κρατά δακτύλιο δίσκου 1 GiB (περίπου μία ημέρα με το τρέχον ένα-δείγμα-ανά-εγγραφή, 2,5 ημέρες με flush 1 s)· πελάτης που επανασυνδέεται συνεχίζει από τον αριθμό ακολουθίας | ίδια |

Κάθε στιγμή υπάρχει μόνο μία από τις δύο ροές (μία συνεδρία GaiaSeis σε παραγωγή).
Καταναλωτής που θέλει και τις δύο εγγράφεται και στους δύο σταθμούς· όποιος δεν
εκπέμπει απλώς δεν παραδίδει τίποτα. Οι ενσωματωμένοι casters των δεκτών
υποβαθμίζονται με κάθε επιπλέον πελάτη, γι' αυτό μη συνδέετε ποτέ δεύτερο πελάτη
NTRIP στον δέκτη που χρησιμοποιεί η παραγωγή· η πλευρά SeedLink δεν έχει τέτοιο όριο.

**Προσωρινή διάταξη.** Ο ringserver τρέχει προς το παρόν στο ίδιο μηχάνημα
με το GaiaSeis (`<seedlink-host>:18000`). Αυτό είναι προσωρινό,
έως ότου εγκατασταθεί αποκλειστικός διακομιστής ringserver. Τότε το GaiaSeis θα
προωθεί τις εγγραφές του στον νέο διακομιστή μέσω DataLink (πεδία προφίλ
`datalink_host` / `datalink_port`), η διεύθυνση SeedLink των ενοτήτων 2 και 4
αλλάζει στον νέο διακομιστή και κάθε πελάτης πρέπει να επανακατευθυνθεί· οι
κωδικοί σταθμών, τα κανάλια, οι μονάδες και το inventory μένουν ίδια. Κρατήστε
τη διεύθυνση SeedLink σε ένα ρυθμιζόμενο σημείο στην πλευρά του καταναλωτή,
ώστε η μετάβαση να είναι αλλαγή μίας γραμμής.

Η ροή δεδομένων υπάρχει μόνο όσο το GaiaSeis εκπέμπει. Ο ringserver παραμένει
ενεργός ανεξάρτητα, ως υπηρεσία χρήστη systemd (`gaiaseis-ringserver`).

## 2. Γρήγορος έλεγχος πριν αγγίξετε το SeisComP

Από μηχάνημα των δικτύων του τμήματος (από 23/10/2026 ο ringserver δέχεται συνδέσεις μόνο από τα δίκτυα του τμήματος και localhost, `AcceptIP` στη ρύθμισή του· κάθε άλλη διεύθυνση απορρίπτεται κατά τη σύνδεση):

```
python3 tools/seedlink_check.py <seedlink-host> 18000 30 CL UPC10     # ή CL UPA10
```

Τυπώνει τις εγγραφές καθώς φτάνουν και τελειώνει με `OK: all three channels
streaming`. Με εγκατεστημένο SeisComP ο ίδιος έλεγχος είναι:

```
slinktool -Q -S CL_UPC10 <seedlink-host>:18000      # ή CL_UPA10
```

Με ObsPy:

```python
from obspy.clients.seedlink.basic_client import Client
c = Client("<seedlink-host>", 18000)
print(c.get_info(level="station"))
```

## 3. Inventory

Το SeisComP δεν δρομολογεί, δεν εμφανίζει και δεν αρχειοθετεί ροή για την οποία
δεν έχει inventory. Δημιουργήστε τον σταθμό μία φορά με ένα μικρό αρχείο
StationXML ή SC3ML και εισαγάγετέ το. Η απόκριση είναι καθαρό κέρδος: είσοδος
μετατόπιση σε μέτρα, έξοδος counts, κέρδος 10⁷ counts ανά μέτρο, χωρίς πόλους
ή μηδενικά.

Πλήρες αρχείο για τον σταθμό παραγωγής είναι το `docs/UPC10.xml` (τρία κανάλια,
συντεταγμένες της κεραίας, έναρξη 2026-10-22T13:21:00). Για τον UPA10Z αλλάξτε
τον κωδικό σταθμού και την ημερομηνία έναρξης. Το πρότυπο δείχνει ένα κανάλι:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FDSNStationXML xmlns="http://www.fdsn.org/xml/station/1" schemaVersion="1.1">
  <Source>GaiaSeis</Source>
  <Created>2026-10-22T13:30:00</Created>
  <Network code="CL" startDate="2026-01-01T00:00:00">
    <Description>Corinth Rift Laboratory GNSS seismogeodesy (GaiaSeis)</Description>
    <Station code="UPC10" startDate="2026-10-22T13:21:00">
      <Latitude>38.283226</Latitude><Longitude>21.786237</Longitude><Elevation>120</Elevation>
      <Site><Name>University of Patras, GaiaSeis 10 Hz</Name></Site>
      <Channel code="LNN" locationCode="" startDate="2026-10-22T13:21:00">
        <Latitude>38.283226</Latitude><Longitude>21.786237</Longitude><Elevation>120</Elevation><Depth>0</Depth>
        <Azimuth>0</Azimuth><Dip>0</Dip>
        <SampleRate>10</SampleRate>
        <Sensor><Description>GNSS variometric displacement (GaiaSeis/PPPHVA)</Description></Sensor>
        <Response>
          <InstrumentSensitivity><Value>1e7</Value><Frequency>0.1</Frequency>
            <InputUnits><Name>M</Name><Description>Displacement in meters</Description></InputUnits>
            <OutputUnits><Name>COUNTS</Name></OutputUnits></InstrumentSensitivity>
          <Stage number="1">
            <PolesZeros><InputUnits><Name>M</Name></InputUnits><OutputUnits><Name>V</Name></OutputUnits>
              <PzTransferFunctionType>LAPLACE (RADIANS/SECOND)</PzTransferFunctionType>
              <NormalizationFactor>1</NormalizationFactor><NormalizationFrequency>0.1</NormalizationFrequency></PolesZeros>
            <StageGain><Value>1</Value><Frequency>0.1</Frequency></StageGain>
          </Stage>
          <Stage number="2">
            <Coefficients><InputUnits><Name>V</Name></InputUnits><OutputUnits><Name>COUNTS</Name></OutputUnits>
              <CfTransferFunctionType>DIGITAL</CfTransferFunctionType></Coefficients>
            <Decimation><InputSampleRate>10</InputSampleRate><Factor>1</Factor><Offset>0</Offset>
              <Delay>0</Delay><Correction>0</Correction></Decimation>
            <StageGain><Value>1e7</Value><Frequency>0.1</Frequency></StageGain>
          </Stage>
        </Response>
      </Channel>
      <!-- LNE: ίδιο μπλοκ με code="LNE" και <Azimuth>90</Azimuth><Dip>0</Dip> -->
      <!-- LNZ: ίδιο μπλοκ με code="LNZ" και <Azimuth>0</Azimuth><Dip>-90</Dip> -->
    </Station>
  </Network>
</FDSNStationXML>
```

Αντιγράψτε το μπλοκ καναλιού για `LNE` (αζιμούθιο 90, dip 0) και `LNZ`
(αζιμούθιο 0, dip −90). Έπειτα, στον υπολογιστή του SeisComP:

```
fdsnxml2inv UPC10.xml > UPC10.sc.xml        # ή UPA10.xml
cp UPC10.sc.xml ~/seiscomp/etc/inventory/
seiscomp update-config inventory
```

Το `scinv check` αναφέρει ό,τι δεν δέχθηκε. Οι κωδικοί καναλιών ακολουθούν τη
σύμβαση SEED: `L` για ζώνη μακράς περιόδου 1 έως 10 Hz, `N` για αισθητήρα που
μετρά απευθείας μετατόπιση, `N/E/Z` προσανατολισμός.

## 4. Σύνδεση του SeisComP με τη ροή

Υπάρχουν δύο τρόποι. Ο πρώτος αρκεί για προβολή και picking· ο δεύτερος είναι ο
τυπικός όταν τα δεδομένα πρέπει να αρχειοθετηθούν και να αναμεταδοθούν.

### 4α. Απευθείας: RecordStream προς τον ringserver

Κάθε άρθρωμα SeisComP διαβάζει κυματομορφές μέσω `recordstream`. Ορίστε το
καθολικά στο `~/seiscomp/etc/global.cfg`:

```
recordstream = slink://<seedlink-host>:18000
```

Τα `scrttv`, `scautopick`, `scamp` κ.λπ. διαβάζουν τότε τα κανάλια GaiaSeis
απευθείας από τον ringserver. Τίποτα δεν αρχειοθετείται στην πλευρά SeisComP.

### 4β. Τυπικό: το seedlink του SeisComP με πηγή chain

Το άρθρωμα `seedlink` του SeisComP δέχεται την απομακρυσμένη ροή SeedLink, την
αναμεταδίδει στον υπολογιστή SeisComP (θύρα 18000 εκεί) και αφήνει το `slarchive`
να γράφει το αρχείο SDS. Προσθέστε προφίλ binding για το πρόσθετο chain:

```
seiscomp exec scconfig            # ή επεξεργαστείτε τα παρακάτω αρχεία με το χέρι
```

Δημιουργήστε το `~/seiscomp/etc/key/seedlink/profile_gaiaseis`:

```
sources = chain
sources.chain.address = <seedlink-host>
sources.chain.port = 18000
sources.chain.selectors = LN?.D
# κρατήστε τον αρχικό κωδικό σταθμού· χωρίς μετονομασία
```

Δέστε το στον σταθμό στο `~/seiscomp/etc/key/station_CL_UPC10` (ή/και
`station_CL_UPA10`):

```
seedlink:gaiaseis
slarchive:local
```

Έπειτα:

```
seiscomp update-config
seiscomp restart seedlink slarchive
slinktool -Q -S CL_UPC10 localhost:18000      # πρέπει τώρα να δείχνει τη ροή τοπικά
```

Με δεμένο το `slarchive`, οι εγγραφές πηγαίνουν στο
`~/seiscomp/var/lib/archive/2026/CL/UPC10/LNZ.D/CL.UPC10..LNZ.D.2026.295`,
την ίδια διάταξη SDS που χρησιμοποιεί το GaiaSeis για τα δικά του ημερήσια
αρχεία. Ορίστε `recordstream` σε `slink://localhost:18000` για τα αρθρώματα
πραγματικού χρόνου και σε
`combined://slink/localhost:18000;sdsarchive//home/sysop/seiscomp/var/lib/archive`
για όσα κοιτούν και πίσω στον χρόνο.

## 5. Προβολή

Το `scrttv` με επιλεγμένο τον σταθμό δείχνει τα τρία ίχνη. Χρήσιμα φίλτρα για
ροή μετατόπισης ανά εποχή: κανένα για να φαίνονται τα βήματα, `BW_HP(2,0.02)`
για καταστολή αργών ολισθήσεων. Η κλίμακα πλάτους είναι σε counts· διαιρέστε με
10⁷ για μέτρα. Στο `scrttv` η μονάδα του άξονα y προέρχεται από το inventory
(`InputUnits = M`), οπότε με φορτωμένη την απόκριση το ίχνος επισημαίνεται σε
μέτρα όταν είναι ενεργή η εμφάνιση μονάδων.

Σημειώστε ότι η ροή είναι μετατόπιση ανά εποχή, όχι θέση. Μια στατική
μετατόπιση του σταθμού μετά από σεισμό εμφανίζεται ως παλμός κατά την κίνηση
και επιστρέφει στο μηδέν μετά· ολοκληρώστε (το `scrttv` δεν μπορεί· το ObsPy
`trace.integrate()` μπορεί) για να δείτε το βήμα.

## 6. Picking και πλάτη

Μην αφήσετε το προεπιλεγμένο `scautopick` να τρέξει σε αυτά τα κανάλια με τις
ρυθμίσεις σεισμομέτρου· η ζώνη `L` και ο κωδικός οργάνου `N` είναι εκτός των
προεπιλογών του, οπότε τα αγνοεί. Αν θέλετε picks GNSS, δημιουργήστε
ξεχωριστό προφίλ `scautopick` δεμένο στον `CL.UPC10` (ή `CL.UPA10`) με μακρύ
STA/LTA (π.χ. `picker.STA = 2`, `picker.LTA = 60`, `thresholds.triggerOn = 4`)
και φίλτρο `BW_HP(2,0.05)`. Τα πλάτη μεγέθους (`scamp`) δεν έχουν βαθμονομημένη
σημασία για αυτή τη ροή και πρέπει να εξαιρεθούν με `amplitudes.enable = false`
στο προφίλ.

## 7. Προβλήματα και τα σημάδια τους

| σημάδι | αιτία | διόρθωση |
|---|---|---|
| Το `slinktool` δείχνει τον σταθμό αλλά δεν φτάνουν εγγραφές | το GaiaSeis δεν εκπέμπει, ή το προφίλ του έχει κενό `datalink_host` | ελέγξτε την ιστοσελίδα GaiaSeis· ορίστε `datalink_host = "127.0.0.1"` στο προφίλ και επανεκκινήστε τη συνεδρία |
| Φτάνουν εγγραφές αλλά το SeisComP δεν δείχνει τίποτα | δεν υπάρχει inventory για τον σταθμό (CL.UPC10 ή CL.UPA10) | ενότητα 3 |
| Το `slinktool` δείχνει τον CL.UPA10 αλλά σταμάτησε στις 22/10/2026 | η παραγωγή μεταφέρθηκε στον UPC10Z | εγγραφείτε στον CL.UPC10 |
| Τα ίχνη μοιάζουν με κλιμακωτή συνάρτηση με επαναλαμβανόμενες τιμές | το `miniseed_flush_interval_sec = 0` με ένα δείγμα ανά εγγραφή είναι εντάξει· θα ήταν artefact σχεδίασης μεγάλων κενών | ελέγξτε τα κενά με την εμφάνιση κενών του `scrttv` |
| Το ίχνος είναι 18 s νωρίς ή αργά | λάθος χρονική κλίμακα στην πλευρά GaiaSeis | οι εγγραφές είναι UTC από 10/09/2026· παλαιότερα αρχεία είναι σε χρόνο GPS |
| Τιμές μέτρων μεταξύ 22:00 και 00:00 UTC, ή έκρηξη στις 23:59:42 UTC | ελαττώματα του υπολογιστικού πυρήνα του GaiaSeis έως την έκδοση 0.4.1 (βλ. `docs/Causes_and_Mitigation_Report_2026-10.md`) | διορθώθηκαν στην 0.4.2 (22/10/2026): η έκρηξη του μεσονυκτίου GPS και οι ωριαίες αιχμές αλλαγής εφημερίδας δεν εμφανίζονται πλέον· τα δεδομένα πριν από αυτή την ημερομηνία τις περιέχουν ακόμη |
| `ERROR Write permission not granted` στην κονσόλα GaiaSeis | ringserver σε άλλον υπολογιστή από το GaiaSeis | προσθέστε `WriteIP <gaiaseis host>` στη ρύθμιση του ringserver |

## 8. Τι υπάρχει στον υπολογιστή του GaiaSeis

* `~/.local/bin/ringserver` (EarthScope ringserver 4.5.6, μεταγλωττισμένος από πηγαίο κώδικα), προς το παρόν στον υπολογιστή του GaiaSeis· θα μεταφερθεί σε αποκλειστικό διακομιστή.
* `~/.config/gaiaseis/ringserver.conf`: δακτύλιος στο `~/.local/share/gaiaseis/ring`,
  DataLink στη 16000, SeedLink στη 18000· το `AcceptIP` περιορίζει και τις δύο σε localhost και στα δίκτυα του τμήματος (προσθέστε καταναλωτή με επεξεργασία του αρχείου· χωρίς επανεκκίνηση).
* `systemctl --user status gaiaseis-ringserver` για την υπηρεσία,
  `journalctl --user -u gaiaseis-ringserver -f` για το ημερολόγιό της.
* Επανεγκατάσταση ή μεταφορά σε άλλο μηχάνημα με `tools/ringserver/install.sh`.
* Η πλευρά GaiaSeis είναι το `src/datalink.jl`· τα πεδία προφίλ είναι
  `datalink_host` και `datalink_port`· ο επεξεργαστής προφίλ του παραθύρου
  γραφημάτων τα έχει ως "SeedLink (ringserver) host" και "DataLink port".
