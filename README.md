# IconServices

The services of IconServices on pearOS, wire-compatible with macOS 26.7.2: `iconservicesagent` (per user, Mach service `com.apple.iconservices`) and `iconservicesd` (system, `com.apple.iconservices.store`), and the per-user icon index `store.index`.
The protocol, the classes on the wire, the store files and the evidence are in `research/docs/ICONSERVICES-WIRE.md` (github.com/pearOS-bsd/research). Our own code, BSD-2-Clause.

| part | what |
|---|---|
| `agent/main.m` | `iconservicesagent`: `ISIconCacheServiceProtocol` (`fetchCacheConfigurationWithReply:`, `generateImageWithRequest:reply:`, `clearAllCachedItemsWithReply:`). Renders with the recipe of IconServices.framework (`-[ISGenerationRequest generateImageReturningRecordIdentifiers:]`, what the real agent calls); where it gives nothing (no Metal) it draws the bundle's `.icns` with ImageIO into an `IFImage` unit. Stores the unit through `iconservicesd`, adds the node to `store.index`, replies with `ISGenerationResponse` (shared memory, unit UUID, 40-byte validation token). |
| `daemon/main.m` | `iconservicesd`: `ISStoreServiceProtocol` (`fetchCachePathForDomain:`, `addData:withUUID:domain:`, `removeItemWithUUID:domain:`); the units are `/Library/Caches/com.apple.iconservices.store/<UUID>.isdata`. |
| `common/store_index.[ch]` | `store.index` (hash table, 152-byte nodes, 116-byte payload): add, find, verify. |
| `test/index_check.c` | `make check`: 2500 nodes, chains, growth, lookups. |
| `test/xpcping.m`, `test/isenc.m`, `test/isclient.m` | pearOS tests (`WITH_TESTS=1 sh build-bsd.sh OUT`): an NSXPC round trip (async, sync, NSURL reply), the secure encoding of `ISIconCacheConfiguration`, and a client that calls the agent with the framework's interface. |
| `test/redirect.c` | macOS test helper: renames Mach services in one process (`IS_REDIRECT`), to point Apple's client at our services while SIP keeps Apple's jobs loaded. |

## Build
macOS: `make`.  FreeBSD (pearOS): `sh build-bsd.sh OUTDIR`.  Tests: `make check`.

## Checked on the Mac VM (2026-11-26)
- Our verifier reads Apple's own `store.index` (108 nodes, 0 errors).
- Apple's client (IconServices.framework, `getCGImageForImageDescriptor:completion:` on an `ISBundleIcon` of a copied Calculator.app) against our agent + daemon (launchd jobs `com.pearos.t.*`, names redirected with `test/redirect.c`): the configuration path is the Mac's string (`.../C/com.apple.iconservicesagent//../com.apple.iconservices/`), the image arrives (128 x 128), our daemon writes the unit, our node goes into the real index (109 nodes, 0 errors), and the next requests are served from the index by Apple's client with no generation call. Apple's own agent keeps working with the index that holds our node.
Not checked yet: our agent against Apple's daemon (the real daemon probably wants the agent's entitlement `com.apple.iconservices.allow-add-store-data`), the `bplist17` messages compared byte for byte with a capture, `UserName _iconservices` for the daemon, pearOS.

## On pearOS (ISO of 2026-11-20, 2026-11-26)
Built on FreeBSD (`build-bsd.sh`), started as root next to the image's Mac stack (the launchd of `d/darwin` creates a service at check-in for root only).
- NSXPC works both ways on darwinator (`xpcping`: async, sync, NSURL reply, client as root and as a user).
- The agent answers `fetchCacheConfigurationWithReply:` and the daemon `fetchCachePathForDomain:` for Apple's IconServices client (our `isclient` and our Dock): the two synchronous calls that blocked the Dock now return.
- Found on the way: a restarted daemon was refused at check-in by `d`'s launchd (its old port was kept; clients got `MACH_SEND_INVALID_DEST`): fixed in `d` (32c6f15).
- Next blocker of the Dock: after IconServices it waits on `com.apple.lsd.mapdb` (the client reads the Launch Services database UUID and sequence for `ISGenerationRequest`; `lsd-stub` does not answer it): LaunchServices is the next service (docs/development/DOCK-REPLACEMENT.md).
- To do here: run the agent as the user (index readable by the user's clients; needs check-in by non-root jobs in `d`'s launchd), the daemon as `_iconservices`, launchd jobs in the image, the fallback renderer exercised (no Metal on pearOS).
