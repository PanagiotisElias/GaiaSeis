# GaiaSeis: Feeding the real-time displacement solution into SeisComP

How to take the 10 Hz displacement stream of a GaiaSeis station into a SeisComP
system through SeedLink. Two stations exist on the same antenna at the
University of Patras: **UPC10Z** (in production since 2026-10-22, station
code `UPC10`) and **UPA10Z** (station
code `UPA10`, the production station until 2026-10-22). Use the one that is
streaming; the commands below are given for UPC10 with UPA10 in brackets.
GaiaSeis 0.4.2, SeisComP 5 or 6. Written 2026-10-06, updated 2026-10-22.

> **The SeedLink address (`<seedlink-host>:18000`) is given to consumers separately; it is temporary until a dedicated ringserver host is installed, and only the host name changes then.**

## 1. What GaiaSeis provides

GaiaSeis writes its solution as miniSEED and pushes every record to a
`ringserver` running beside it. The ringserver is the SeedLink server; SeisComP
connects to it like to any other SeedLink source.

| item | UPC10Z (production since 2026-10-22) | UPA10Z |
|---|---|---|
| SeedLink server | the GaiaSeis host, port 18000 (`<seedlink-host>:18000`); accepts only the department networks and localhost | same |
| Network, station, location | `CL`, `UPC10`, blank | `CL`, `UPA10`, blank |
| Receiver | Topcon NET-G5, built-in NTRIP caster, mount `B` | Topcon NET-G5, built-in NTRIP caster, mount `B` |
| Status | streaming, SSR off, `CL.UPC10` on SeedLink and in `mseed2/` | not streaming since 2026-10-22 13:21 UTC; `CL.UPA10` stopped then |
| Channels | `LNN` north, `LNE` east, `LNZ` up | same |
| Sample rate | 10 Hz (one sample per solved epoch) | same |
| Encoding | miniSEED 2.4, 512-byte records, INT32 samples, big-endian | same |
| Units | counts; 1 count = 0.1 µm. Counts × 10⁻⁷ = metres of displacement per epoch | same |
| Time stamps | UTC (the GPS-to-UTC leap seconds are removed before stamping) | same |
| Quantity | epoch-to-epoch displacement from the variometric solution, i.e. velocity × 0.1 s; integrate for position change | same |
| Gaps | a missing or blanked epoch closes the record; SeisComP sees a true gap, not a time-shifted trace | same |
| Replay | the ringserver keeps a 1 GiB disk ring (about one day at the current one-sample-per-record flushing, 2.5 days with 1 s flushing); a reconnecting client resumes by sequence number | same |

Only one of the two streams exists at a time (one GaiaSeis session in production).
A consumer that wants both must subscribe to both stations; the one not streaming
simply delivers nothing. The receivers' built-in casters degrade with every extra
client, so never connect a second NTRIP client to the receiver that production
uses; the SeedLink side has no such limit.

**Temporary arrangement.** The ringserver currently runs on the same machine
as GaiaSeis (`<seedlink-host>:18000`). This is temporary, until a
dedicated ringserver host is installed. At that point GaiaSeis will push its
records to the new host over DataLink (profile fields `datalink_host` /
`datalink_port`), the SeedLink address in sections 2 and 4 changes to the new
host, and every client must be repointed; the station codes, channels, units
and inventory stay the same. Keep the SeedLink address in one configurable
place on the consumer side so the move is a one-line change.

The data stream exists only while GaiaSeis is streaming. The ringserver stays
up independently as a systemd user service (`gaiaseis-ringserver`).

## 2. Quick check before touching SeisComP

From a machine on the department networks (since 2026-10-23 the ringserver accepts connections only from the department networks and localhost, `AcceptIP` in its configuration; any other address is rejected at connection time):

```
python3 tools/seedlink_check.py <seedlink-host> 18000 30 CL UPC10     # or CL UPA10
```

It prints the records as they arrive and ends with `OK: all three channels
streaming`. With SeisComP installed, the same check is:

```
slinktool -Q -S CL_UPC10 <seedlink-host>:18000      # or CL_UPA10
```

With ObsPy:

```python
from obspy.clients.seedlink.basic_client import Client
c = Client("<seedlink-host>", 18000)
print(c.get_info(level="station"))
```

## 3. Inventory

SeisComP will not route, display or archive a stream it has no inventory for.
Create the station once with a small StationXML or SC3ML file and import it.
The response is a pure gain: input displacement in metres, output counts,
gain 10⁷ counts per metre, no poles or zeros.

A complete file for the production station is `docs/UPC10.xml` (three channels,
coordinates of the antenna, start 2026-10-22T13:21:00). For UPA10Z change the
station code and the start date. The template below shows one channel:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FDSNStationXML xmlns="http://www.fdsn.org/xml/station/1" schemaVersion="1.1">
  <Source>GaiaSeis</Source>
  <Created>2026-10-06T00:00:00</Created>
  <Network code="CL" startDate="2026-01-01T00:00:00">
    <Description>Corinth Rift Laboratory GNSS seismogeodesy (GaiaSeis)</Description>
    <Station code="UPA10" startDate="2026-01-01T00:00:00">
      <Latitude>38.288</Latitude><Longitude>21.788</Longitude><Elevation>100</Elevation>
      <Site><Name>University of Patras, GaiaSeis 10 Hz</Name></Site>
      <Channel code="LNN" locationCode="" startDate="2026-01-01T00:00:00">
        <Latitude>38.288</Latitude><Longitude>21.788</Longitude><Elevation>100</Elevation><Depth>0</Depth>
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
      <!-- LNE: same block with code="LNE" and <Azimuth>90</Azimuth><Dip>0</Dip> -->
      <!-- LNZ: same block with code="LNZ" and <Azimuth>0</Azimuth><Dip>-90</Dip> -->
    </Station>
  </Network>
</FDSNStationXML>
```

Duplicate the channel block for `LNE` (azimuth 90, dip 0) and `LNZ`
(azimuth 0, dip −90). Then, on the SeisComP host:

```
fdsnxml2inv UPC10.xml > UPC10.sc.xml        # or UPA10.xml
cp UPC10.sc.xml ~/seiscomp/etc/inventory/
seiscomp update-config inventory
```

`scinv check` reports what it did not like. The channel codes follow the SEED
convention: `L` for 1 to 10 Hz long-period band, `N` for a sensor that
measures displacement directly, `N/E/Z` orientation.

## 4. Pointing SeisComP at the stream

There are two ways. The first is enough for viewing and picking; the second
is the standard way when the data must be archived and served on.

### 4a. Direct: RecordStream to the ringserver

Every SeisComP module reads waveforms through `recordstream`. Set it globally
in `~/seiscomp/etc/global.cfg`:

```
recordstream = slink://<seedlink-host>:18000
```

`scrttv`, `scautopick`, `scamp` and friends then read the GaiaSeis channels
directly from the ringserver. Nothing is archived on the SeisComP side.

### 4b. Standard: SeisComP's own seedlink with a chain source

The SeisComP `seedlink` module ingests the remote SeedLink stream, re-serves it
on the SeisComP host (port 18000 there) and lets `slarchive` write the SDS
archive. Add a binding profile for the chain plugin:

```
seiscomp exec scconfig            # or edit the files below by hand
```

Create `~/seiscomp/etc/key/seedlink/profile_gaiaseis`:

```
sources = chain
sources.chain.address = <seedlink-host>
sources.chain.port = 18000
sources.chain.selectors = LN?.D
# keep the original station code; no renaming
```

Bind it to the station in `~/seiscomp/etc/key/station_CL_UPC10` (and/or `station_CL_UPA10`):

```
seedlink:gaiaseis
slarchive:local
```

Then:

```
seiscomp update-config
seiscomp restart seedlink slarchive
slinktool -Q -S CL_UPC10 localhost:18000      # should now show the stream locally
```

With `slarchive` bound, the records go to
`~/seiscomp/var/lib/archive/2026/CL/UPC10/LNZ.D/CL.UPC10..LNZ.D.2026.295`,
the same SDS layout GaiaSeis uses for its own day files. Set `recordstream` to
`slink://localhost:18000` for real-time modules and to
`combined://slink/localhost:18000;sdsarchive//home/sysop/seiscomp/var/lib/archive`
for modules that also look back in time.

## 5. Viewing

`scrttv` with the station selected shows the three traces. Useful filters for
a displacement-per-epoch stream: none for seeing steps, `BW_HP(2,0.02)` to
suppress long drifts. The amplitude scale is in counts; divide by 10⁷ for
metres. In `scrttv` the y-axis unit comes from the inventory
(`InputUnits = M`), so with the response loaded the trace is labelled in metres
when "unit" display is on.

Note that the stream is displacement per epoch, not position. A static offset
of the station after an earthquake shows up as a pulse during the motion and
returns to zero afterwards; integrate (`scrttv` cannot; ObsPy
`trace.integrate()` can) to see the step.

## 6. Picking and amplitudes

Do not let the default `scautopick` run on these channels with its seismometer
settings; `L` band and `N` instrument codes are outside its defaults, so by
default it ignores them. If GNSS picks are wanted, create a dedicated
`scautopick` profile bound to `CL.UPC10` (or `CL.UPA10`) with a long STA/LTA (for example
`picker.STA = 2`, `picker.LTA = 60`, `thresholds.triggerOn = 4`) and the
`BW_HP(2,0.05)` filter. Magnitude amplitudes (`scamp`) have no calibrated
meaning for this stream and should be excluded with `amplitudes.enable =
false` in that profile.

## 7. Problems and their signs

| sign | cause | fix |
|---|---|---|
| `slinktool` lists the station but no records arrive | GaiaSeis is not streaming, or its profile has `datalink_host` blank | check the GaiaSeis web page; set `datalink_host = "127.0.0.1"` in the profile and restart the session |
| Records arrive but SeisComP shows nothing | no inventory for the station (CL.UPC10 or CL.UPA10) | section 3 |
| `slinktool` shows CL.UPA10 but it stopped on 2026-10-22 | production moved to UPC10Z | subscribe to CL.UPC10 |
| Traces look like a step function with repeated values | `miniseed_flush_interval_sec = 0` and one sample per record is fine; this would be a plotting artefact of large gaps | check gaps with `scrttv` gap display |
| Trace is 18 s early or late | wrong time scale on the GaiaSeis side | the records are UTC since 2026-09-10; older files are GPS time |
| Metre-level values between 22:00 and 00:00 UTC, or a burst at 23:59:42 UTC | engine defects of GaiaSeis up to 0.4.1 (see `docs/Causes_and_Mitigation_Report_2026-10.md`) | fixed in 0.4.2 (2026-10-22): the GPS-midnight burst and the hourly changeover spikes no longer occur; data before that date still carries them |
| `ERROR Write permission not granted` in the GaiaSeis console | ringserver on another host than GaiaSeis | add `WriteIP <gaiaseis host>` to the ringserver config |

## 8. What is on the GaiaSeis host

* `~/.local/bin/ringserver` (EarthScope ringserver 4.5.6, built from source), on the GaiaSeis host for now; to move to a dedicated host.
* `~/.config/gaiaseis/ringserver.conf`: ring in `~/.local/share/gaiaseis/ring`,
  DataLink on 16000, SeedLink on 18000; `AcceptIP` limits both to localhost and the department networks (edit the file to add a consumer; no restart needed).
* `systemctl --user status gaiaseis-ringserver` for the service,
  `journalctl --user -u gaiaseis-ringserver -f` for its log.
* Re-install or move to another machine with `tools/ringserver/install.sh`.
* The GaiaSeis side is `src/datalink.jl`; the profile fields are
  `datalink_host` and `datalink_port`; the plot window's profile editor has
  them as "SeedLink (ringserver) host" and "DataLink port".
