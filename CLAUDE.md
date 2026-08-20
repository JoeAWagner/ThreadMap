# ThreadMap — working notes

An iOS app that discovers Thread border routers, the Thread/HomeKit/Matter
devices behind them, and everything else advertising on the local network.

## The constraint that shapes everything

**iOS exposes no API for Thread mesh topology.** Not through HomeKit, not
through `ThreadNetwork.framework`, not to any third-party app. There is no
supported way to see a device's mesh parent, its role (Router / REED / End
Device), link quality, hop count, or the neighbour table.

If a change would require any of those, it cannot be built as specified — say
so rather than approximating it. The app's credibility rests on never drawing
a line it can't justify.

**The one legitimate device→router link** is proxy attribution: a Thread device
has no Wi-Fi radio, so whatever answers an mDNS query for it is the border
router holding its SRP registration (`MulticastProber`). That is a
*registration* relationship, not mesh parentage, and every place it surfaces
says so. Don't let that distinction erode.

## Conventions

- **`Attributed<T>`** (`Model/Confidence.swift`) wraps a value with a
  `Confidence` (`observed` / `derived` / `inferred` / `unknown`) and a
  plain-language `reason` shown verbatim in the UI. Anything not read straight
  off the wire must carry one. Inferred edges draw dashed on the map.
- **Never read or display Thread key material.** `networkKey`, `PSKC` and
  `activeOperationalDataSet` are never pulled out of `THCredentials`;
  `ThreadCredentialsService.summarize` is an exhaustive field list so that
  stays reviewable. If a feature needs the operational dataset, it has to be an
  explicit user-initiated export with a real warning.
- **Read-only.** No commissioning, no HomeKit mutation.
- **Degrade, don't fail.** Every capability that needs an entitlement
  (`manage-thread-network-credentials`, `multicast`) or a permission
  (HomeKit, Local Network) must fail soft with a message explaining what's
  reduced. Check `ScannerModel.notices` for the pattern.
- **UI copy states limits in place.** Don't let an empty region of the map read
  as "nothing there" when it means "not visible to any app".
- **Findings** (`PostureAuditor`) carry detail, impact, remediation and the
  exact TXT key they came from. A finding without evidence isn't one.

## Layout

```
Model/       value types; all Codable for scan history
Services/    discovery + correlation
  BonjourScanner        NWBrowser over every declared service type
  DNSSDResolver         dnssd resolve + all A/AAAA (NWBrowser hides addresses)
  ServiceTypeEnumerator _services._dns-sd._udp meta-query
  DNSMessage            minimal DNS wire format (query + parse)
  MulticastProber       raw mDNS, captures responder address
  SSDPBrowser           SSDP/UPnP — a separate plane from mDNS
  TopologyBuilder       the correlation engine
  PostureAuditor        finding rules
  ScanHistoryStore      snapshot + ledger persistence
ViewModel/   ScannerModel orchestrates the scan phases
Views/       map (Canvas), inventory, health, activity, diagnostics
Tests/       pure-logic tests; no device or network needed
```

Adding a service type means **three** edits: a `ServiceType` case, the
`NSBonjourServices` array in `Info.plist`, and usually `contextTypes`. A type
missing from Info.plist returns nothing at runtime, silently.

`MeshDevice.stableKey` (HAP device ID → Matter node ID → hostname) is what
history keys on. `id` is derived from the mDNS instance name, which changes on
rename — using it for history invents phantom disappearances.

## Building

```bash
brew install xcodegen && xcodegen generate && open ThreadMap.xcodeproj
```

`.xcodeproj` is generated, not committed. CI (`.github/workflows/build.yml`)
builds for the Simulator and runs tests on every push; its job summary lists
errors and warnings, since raw xcodebuild output buries them.

- **iOS 17.0+**, SwiftUI, `@Observable`.
- `ThreadNetwork.framework` **is not in the Simulator SDK** — it's behind
  `#if canImport(ThreadNetwork)`. Keep it that way so the app stays
  previewable. Don't add it as an explicit link dependency.
- Real discovery needs **hardware on Wi-Fi**. The Simulator finds nothing and
  its HomeKit is a stub.

## Verified vs. not

CI compiles it. The tests pin the parsing and correlation logic. What no test
can confirm is behaviour against real hardware — nobody has run this against a
live Thread network yet. Treat these as open:

- `THClient.retrieveAllActiveCredentials()` — some SDK versions spell the bulk
  accessor `retrieveAllCredentials()`.
- `THCredentials` optionality — the service assumes `Data?` and uses
  `.map(hex)`.
- The MeshCoP `sb` bitmap offsets came from documentation. `MeshcopRecordTests`
  pins the layout in one place; if a real router disagrees, change it there.
- Service type names for eero, Ring, SmartThings and Nest's Weave-era services
  were deliberately **not** added — unverified names fail silently. Use the
  meta-query (Diagnostics tab) to see what's really advertising, then add it.
