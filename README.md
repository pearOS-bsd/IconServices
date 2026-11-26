# IconServices

The services of IconServices on pearOS, wire-compatible with macOS 26.7.2: `iconservicesagent` (per user, Mach service `com.apple.iconservices`) and `iconservicesd` (system, `com.apple.iconservices.store`), and the per-user icon index `store.index`.
The protocol, the classes on the wire, the store files and the evidence are in `research/docs/ICONSERVICES-WIRE.md` (github.com/pearOS-bsd/research). Our own code, BSD-2-Clause.

| part | what |
|---|---|
| `agent/main.m` | `iconservicesagent`: `ISIconCacheServiceProtocol` (`fetchCacheConfigurationWithReply:`, `generateImageWithRequest:reply:`, `clearAllCachedItemsWithReply:`). Renders with the recipe of IconServices.framework (`-[ISGenerationRequest generateImageReturningRecordIdentifiers:]`, what the real agent calls); where it gives nothing (no Metal) it draws the bundle's `.icns` with ImageIO into an `IFImage` unit. Stores the unit through `iconservicesd`, adds the node to `store.index`, replies with `ISGenerationResponse` (shared memory, unit UUID, 40-byte validation token). |
| `daemon/main.m` | `iconservicesd`: `ISStoreServiceProtocol` (`fetchCachePathForDomain:`, `addData:withUUID:domain:`, `removeItemWithUUID:domain:`); the units are `/Library/Caches/com.apple.iconservices.store/<UUID>.isdata`. |
| `common/store_index.[ch]` | `store.index` (hash table, 152-byte nodes, 116-byte payload): add, find, verify. |
| `test/index_check.c` | `make check`: 2500 nodes, chains, growth, lookups. |
| `test/redirect.c` | macOS test helper: renames Mach services in one process (`IS_REDIRECT`), to point Apple's client at our services while SIP keeps Apple's jobs loaded. |

## Build
macOS: `make`.  FreeBSD (pearOS): `sh build-bsd.sh OUTDIR`.  Tests: `make check`.

## Checked on the Mac VM (2026-11-26)
- Our verifier reads Apple's own `store.index` (108 nodes, 0 errors).
- Apple's client (IconServices.framework, `getCGImageForImageDescriptor:completion:` on an `ISBundleIcon` of a copied Calculator.app) against our agent + daemon (launchd jobs `com.pearos.t.*`, names redirected with `test/redirect.c`): the configuration path is the Mac's string (`.../C/com.apple.iconservicesagent//../com.apple.iconservices/`), the image arrives (128 x 128), our daemon writes the unit, our node goes into the real index (109 nodes, 0 errors), and the next requests are served from the index by Apple's client with no generation call. Apple's own agent keeps working with the index that holds our node.
Not checked yet: our agent against Apple's daemon (the real daemon probably wants the agent's entitlement `com.apple.iconservices.allow-add-store-data`), the `bplist17` messages compared byte for byte with a capture, `UserName _iconservices` for the daemon, pearOS.
