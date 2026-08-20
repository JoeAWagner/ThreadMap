# Thread Map

An iPhone app that discovers the **Thread border routers** on your home network,
the **Thread and HomeKit devices** behind them, and draws the relationship
between the two.

> **Status:** builds and tests in CI on every push. Never run against real
> hardware — see [Verified vs. not](#verified-vs-not).

---

## Read this first: what an iOS app can and cannot see

This is the part most "Thread scanner" projects get wrong, so it's worth being
blunt.

**iOS exposes no API for Thread mesh topology.** Not to third-party apps, not
through HomeKit, not through `ThreadNetwork.framework`. There is no supported
way for any App Store app to see:

- which router a given end device attached to (its *parent*)
- whether a device is acting as a Router, a REED, or an End Device
- link quality, RSSI, LQI, or hop count
- the neighbour table, the routing table, or the network's child table

That data lives inside the border routers and Apple's private daemons. If an app
draws you a line from a light bulb to a specific HomePod, it made that line up.

**What is genuinely reachable**, and what this app is built on:

| Source | What it gives you |
|---|---|
| `_meshcop._udp` mDNS | Every Thread Border Router on the Wi-Fi link, announcing its network name, extended PAN ID, border agent ID, Thread version, partition ID, mesh role, backbone-router status, and (Thread 1.4+) its off-mesh-routable prefix |
| `_hap._udp` mDNS | HomeKit accessories on Thread. HAP-over-CoAP is *only* used on Thread, so this is proof of Thread membership, not a guess |
| `_matter._tcp` / `_matterc._udp` mDNS | Matter nodes, their node ID, vendor/product, and sleepy-device (ICD) profile |
| `_trel._udp` mDNS | Routers that support Thread Radio Encapsulation Link |
| `_matterd._udp` mDNS | Matter *commissioners* — anything offering to add devices to a fabric |
| SSDP / UPnP | An entirely separate discovery plane: Sonos, Roku, Wemo, smart TVs, printers, NAS — hardware that never appears in Bonjour at all |
| `_matter._tcp` instance names | The compressed fabric ID, which reveals **how many parties can control each device** |
| `ThreadNetwork.framework` | Names, channels and PAN IDs of Thread networks stored on *this iPhone* |
| `HomeKit.framework` | Your homes, rooms, accessory names, manufacturers, models, reachability, and — for Matter accessories — the `matterNodeID` |
| `_services._dns-sd._udp` meta-query | Every service *type* advertised on the link, including ones this app doesn't inspect — so you find things you didn't know to look for |
| Raw mDNS via `NWConnectionGroup` | Which host answers a query for a given device, identifying the border router that holds its service registration |
| HomeKit characteristic notifications | A live, timestamped log of every state change in the home |

Thread devices show up on Wi-Fi at all because border routers run an SRP server
plus an *advertising proxy*: devices register their services with the border
router over Thread, and the border router republishes them as mDNS on the
infrastructure link. That indirection is exactly why you can enumerate the
devices and exactly why you can't see the links between them.

### One real device-to-router link

There is one exception to "no device-to-router edges", and it's worth being
precise about. A Thread device has no radio on your Wi-Fi, so it cannot answer
an mDNS query itself — its records are republished by the *advertising proxy*
on the border router it registered with over SRP. Send the query yourself and
watch the source address of the reply, and you learn which border router holds
that device's registration.

That is a genuine, observed device-to-router relationship. It is **not** the
device's mesh parent — a device can register with one router and route its
traffic through another — but it's the strongest link obtainable without
joining the mesh, and the app labels it as exactly what it is wherever it
appears.

### So what does the map actually show?

Three layers, and every edge is labelled with how it was established:

```
Thread network  ──  border routers serving it     (observed: the router says so)
       │
       └────────  devices on it                   (derived or inferred, see below)
```

A device is placed on a network by one of three rules, strongest first:

1. **Derived — address match.** The device's IPv6 address falls inside an
   off-mesh-routable prefix that a border router advertises in its `omr` TXT
   key. This is exact.
2. **Inferred — only one network.** The device is on Thread and exactly one
   Thread network is visible, so it must be that one.
3. **Unknown.** Several networks are visible and nothing ties the device to one.

Tap any device and the detail sheet tells you which rule fired and why, in
words. Inferred edges are drawn dashed. That honesty is the point of the app —
a map that silently guesses is worse than no map.

---

## Matter fabric visibility

A Matter device can be commissioned into several fabrics at once — Apple's,
Google's, Amazon's, Home Assistant's — and **every fabric holder has full
control of it**: read state, actuate, remove. Revoking one ecosystem's access
does not revoke another's.

Nothing shows you this, but the operational mDNS instance name is formatted
`<compressedFabricID>-<nodeID>`, so the fabric each device belongs to is in
plain sight. Group by it and you get "11 Matter devices across 3 fabrics", with
the shared devices called out. A fabric you can't account for is worth
investigating.

The one fabric that can be *named* is Apple's, identified because HomeKit told
us about its devices. The rest are anonymous by design — Matter deliberately
doesn't broadcast which ecosystem an admin belongs to.

## What it tells you

**Map** — networks, their border routers, their devices. Pinch, pan, tap.

**Devices** — the same thing as a searchable list, grouped by network.

**Health** — three views, and where most of the value is:

- *Findings*: posture rules over the advertisements themselves. Accessories
  broadcasting that they've never been paired (anyone in range can claim them);
  Matter devices left in commissioning mode; border routers advertising that
  they'll accept a commissioner; a Thread network that has **split into
  partitions**, which makes automations fail silently while every device still
  looks online; a network running on a single border router; a leader role
  that keeps moving, which is the usual cause of Thread devices that drop out
  for no visible reason. Each finding says what was seen, why it matters, what
  to do, and the exact TXT key it came from.
- *Changes*: what moved since the previous scan. Devices that appeared or
  stopped answering, accessories whose HAP config number bumped (almost always
  a firmware update), partition and leader changes, room and firmware edits.
- *Timeline*: every device ever seen, with first-seen and last-seen. This is
  what makes "it stopped working sometime last week" an answerable question.

**Activity** — a live log of HomeKit state changes: which door opened, which
light changed, when, in what order. Sensor telemetry is filtered out by default
so a few thermometers don't bury everything else.

**Diagnostics** — raw records, every service type found on the link, and the
scope note. Everything the app claims is derived from what's on this screen.

### Two discovery planes

Everything above is mDNS. SSDP/UPnP is a different protocol on a different
multicast group, and a large amount of consumer hardware only announces there —
adding it roughly doubles what the app sees on a typical home network. Where a
device appears on both (a Sonos speaker is a Matter device *and* a UPnP
MediaRenderer), the UPnP description usually wins on naming, because it's the
one the manufacturer wrote for humans.

It also produces a finding worth having: a router advertising an **Internet
Gateway Device** service means UPnP port mapping is on, and any device on your
LAN can open an inbound firewall hole without prompting you.

### Scan depth is a real setting

Battery-powered Thread devices wake only every few seconds. A short browse
window will miss them and then report them as *gone* — so the browse window is
exposed in scan settings, and the differ explicitly says when a disappearance
followed a shorter scan than the one before it. Use 10 seconds or more before
trusting an absence.

---

## Building it

```bash
git clone https://github.com/JoeAWagner/ThreadMap.git
cd ThreadMap
brew install xcodegen
xcodegen generate
open ThreadMap.xcodeproj
```

The `.xcodeproj` is generated from `project.yml` at the repo root and
deliberately not committed, so the file list can't drift from what's on disk. If
you'd rather not use XcodeGen: make a new iOS App target in Xcode, drag in the
`ThreadMap/` source folder, and point Build Settings at `ThreadMap/Info.plist`
and `ThreadMap/ThreadMap.entitlements`.

**Deployment target is iOS 17.0** (`@Observable`, `MagnifyGesture`,
`ContentUnavailableView`).

### It must run on a real device

The Simulator does not join your Wi-Fi network's multicast group in a way that
surfaces border routers, and HomeKit in the Simulator is a stub. A scan on the
Simulator returns approximately nothing. Use hardware, on Wi-Fi, on the same
VLAN as your hubs — not cellular, not a guest network with client isolation.

### CI

`.github/workflows/build.yml` builds for the Simulator and runs the tests on
every push, summarising errors and warnings into the job summary because raw
`xcodebuild` output buries them. Simulator builds skip signing, so the
entitlements need no provisioning profile.

`ThreadNetwork.framework` **is not in the Simulator SDK**, so it sits behind
`#if canImport(ThreadNetwork)`. That keeps the whole app buildable and
previewable in the Simulator; the credentials service simply reports the
feature as unavailable there. Don't add it as an explicit link dependency —
Swift autolinks what it imports, and an unconditional link breaks the Simulator
build.

### Verified vs. not

CI compiles it and the tests pin the parsing and correlation logic. What no
test can confirm is behaviour against real hardware — **nobody has run this
against a live Thread network yet.** Treat these as open:

1. **`THClient.retrieveAllActiveCredentials()`**
   (`Services/ThreadCredentialsService.swift`). Some SDK versions spell the bulk
   accessor `retrieveAllCredentials()`.
2. **`THCredentials` optionality.** The service assumes `extendedPANID`,
   `borderAgentID` and `panID` are `Data?` and uses `.map(hex)`. If your SDK
   declares them non-optional, drop the `.map`.
3. **The MeshCoP `sb` bitmap offsets** came from documentation. A wrong offset
   would mislabel every router's role with no visible symptom, so
   `MeshcopRecordTests` pins the layout in one asserted place — if a real router
   disagrees, that's the single thing to change.
4. **Service type names for eero, Ring, SmartThings and Nest's Weave-era
   services were deliberately left out.** An invented service type fails
   *silently* — it just returns nothing. Use the meta-query on the Diagnostics
   tab to see what's genuinely advertising on your network, then add it.

Neither 1 nor 2 affects anything but network *naming* — see the entitlement
note below.

### Entitlements

| Entitlement | Needed for | If you don't have it |
|---|---|---|
| `com.apple.developer.homekit` | Accessory names, rooms, `matterNodeID` | Devices appear as bare Matter node IDs and hostnames; everything else works |
| `com.apple.developer.networking.manage-thread-network-credentials` | Reading stored Thread networks | Networks show as `Thread network 1A2B…` instead of `My Home`; **all** router and device discovery still works |
| `com.apple.developer.networking.multicast` | Sending mDNS queries directly, to attribute devices to the router proxying them | The attribution probe fails soft and says so; everything else is unaffected |

The Thread credentials entitlement is granted by Apple on request via the
[Thread network credentials request form][thread-form]. **The app is built to
run without it** — remove the key from `ThreadMap.entitlements` and it degrades
to a clearly-labelled reduced mode rather than failing. It also offers
`retrievePreferredCredentials()`, which shows a system picker and needs no bulk
entitlement, as a fallback path.

Note that ordinary Bonjour browsing does **not** need the multicast
entitlement — `NWBrowser` and `dnssd` work without it. Only the raw mDNS probe
used for proxy attribution does, and it's a separate toggle in scan settings
that turns itself off cleanly when the entitlement isn't there. Request it at
the [multicast networking form][multicast-form].

[multicast-form]: https://developer.apple.com/contact/request/networking-multicast

[thread-form]: https://developer.apple.com/contact/request/thread-network

### Permissions the user grants at runtime

- **Local Network** — without it, `NWBrowser` returns zero results *silently*.
  The app detects the policy-denied state and says so rather than showing an
  empty map.
- **HomeKit** — prompted the first time a scan touches `HMHomeManager`.

Every service type the app browses is listed in `NSBonjourServices` in
`Info.plist`. Anything missing from that array is invisible at runtime, so add
a type there whenever you add one to `ServiceType`.

---

## How it's put together

```
Model/
  Confidence.swift      Attributed<T> — a value plus how we know it
  IPv6Prefix.swift      IPAddress, IPv6Prefix, OMR prefix containment
  ServiceRecord.swift   ServiceType (Thread + context types), raw mDNS record
  MeshcopRecord.swift   Thread border agent TXT decoding, incl. the sb bitmap
  MatterRecord.swift    Matter operational + commissionable TXT decoding
  HAPRecord.swift       HomeKit accessory TXT decoding, category table
  Topology.swift        ThreadNetwork / BorderRouter / MeshDevice / HomeKitAccessory
  Finding.swift         a posture finding: severity, impact, remediation, evidence
  ScanSnapshot.swift    one scan, frozen, for history
  DeviceLedger.swift    first-seen / last-seen for every device ever seen
  TopologyChange.swift  change kinds + TopologyDiffer
  HomeEvent.swift       one HomeKit characteristic change

Services/
  BonjourScanner.swift          NWBrowser across every declared service type
  DNSSDResolver.swift           dnssd resolve + address enumeration
  ServiceTypeEnumerator.swift   the _services._dns-sd._udp meta-query
  DNSMessage.swift              minimal DNS wire format: build a query, read answers
  MulticastProber.swift         raw mDNS, capturing who answered
  IPAddressParser.swift         sockaddr ↔ IPAddress
  ThreadCredentialsService.swift THClient wrapper (non-secret fields only)
  HomeKitService.swift          HMHomeManager wrapper
  HomeKitEventLog.swift         characteristic notifications → event log
  TopologyBuilder.swift         the correlation engine
  PostureAuditor.swift          the finding rules
  ScanHistoryStore.swift        snapshot + ledger persistence

ViewModel/ScannerModel.swift    scan orchestration, phases, notices
Views/                          map canvas, layout, inventory, health, activity, diagnostics
```

Two implementation notes worth knowing:

**Why `dnssd` and not just `NWBrowser`.** `NWBrowser` hands you an opaque
endpoint and hides IP addresses. For Thread mapping the addresses *are* the
payload — matching a device's IPv6 address against a border router's advertised
OMR prefix is the only exact way to place a device on a network. So discovery
uses `NWBrowser` (nice API, gives TXT) and resolution drops to the `dnssd` C
API, which returns every A/AAAA record a host publishes. A Thread device
typically has three: link-local, mesh-local, and OMR.

**Why the layout is rings and not a force simulation.** A force-directed graph
re-shuffles on every scan, which makes "did that sensor move?" unanswerable.
Concentric rings keep a device in the same place run to run.

**Why there's a hand-rolled DNS parser.** Both `NWBrowser` and `dnssd` hide the
responder's address, which is the one thing proxy attribution needs. For that
one job the app speaks the protocol directly: `DNSMessage` builds a PTR query
and reads names, compression pointers included, and skips everything else. It
caps pointer-following so a malformed or hostile packet can't spin it.

**Why devices have a `stableKey`.** A device's mDNS instance name changes when
it's renamed or when Bonjour re-disambiguates a collision, so history keyed on
it would show phantom disappearances. `stableKey` prefers identifiers burned
into the device — HAP device ID, then Matter node ID — and falls back to the
hostname.

### Correlating mDNS with HomeKit

HomeKit never exposes an accessory's HAP pairing ID, so there's no exact join
key for HomeKit-over-Thread accessories. The builder does two passes:

1. **Exact** — `HMAccessory.matterNodeID` against the node ID in the
   `_matter._tcp` instance name. Byte-for-byte; no guessing.
2. **Fuzzy** — normalised name similarity with a matching model as a tiebreaker,
   thresholded at 0.72, each accessory claimable once. Names dominate
   deliberately: five identical bulbs would otherwise all score the same on
   model alone.

Accessories HomeKit knows about but the network never showed get their own
section in the inventory, rather than being quietly dropped.

---

## Things it deliberately does not do

- **Never reads or displays Thread key material.** `networkKey`, `PSKC` and
  `activeOperationalDataSet` are never pulled out of `THCredentials`;
  `ThreadCredentialsService.summarize` is written as an exhaustive field list so
  that's checkable at review time.
- **Never writes anything.** No commissioning, no HomeKit mutation, read-only
  throughout.
- **Never leaves the device.** No network calls beyond local mDNS.

## Where you could take it next

The remaining visibility gap is the mesh itself, and both routes out of it live
off the phone:

- **Become a second Matter admin.** Matter's `ThreadNetworkDiagnostics` cluster
  (0x0035) exposes `NeighborTable` and `RouteTable`, with per-neighbour `LQI`,
  `AverageRssi`, and `IsChild`. That is the real topology, specified and
  supported — it's just unreachable from iOS because Apple's fabric is closed
  to third parties. Commission your devices into your own fabric as well
  (`python-matter-server` or `chip-tool`) and poll it. Both table attributes
  are optional and feature-gated, so expect uneven vendor coverage.
- **Run your own border router.** A Pi plus an nRF52840 gives you `otbr-agent`
  and a REST API with the full router, child, and neighbour tables. To see your
  *existing* mesh rather than a new one it has to join with the active
  operational dataset — the network key. If you add that, make it an explicit
  user-initiated export with a real warning, not something the scanner does
  quietly.
- **802.15.4 sniffing.** The same dongle in sniffer mode feeds Wireshark, which
  has Thread dissectors and will decrypt given the network key. RF-level truth:
  retries, channel utilisation, which radios actually talk to each other.

Smaller things still on the table:

- **Notifications.** The findings and change engines already produce everything
  a "your Thread network split" or "the back door sensor stopped answering"
  alert would need; nothing surfaces them outside the app.
- **Export.** Snapshots are already Codable JSON on disk. A share sheet would
  make them diffable outside the app.
- **Commissioning.** `MatterSupport` can add a device to a fabric; combined
  with `retrievePreferredCredentials()` this could become a setup tool rather
  than only a viewer.
