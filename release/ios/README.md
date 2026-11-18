Buildbot Configuration
======================

Files used by Buildbot's `package-code-binaires` step for the darwin platform.

## Source and Dependency Baseline

The native iOS interface is integrated with the official Blender `ios` branch at
`a1de44dd54af75a4c8c4a29a5fed2a1334a87446`, based on Blender 5.1.2. The previous
native interface used a Blender 5.0 alpha base.

Build the application, runtime libraries and macOS code generators from matching
versions. The older iOS precompiled-library checkout is not sufficient for this
source: in particular, this baseline needs Python 3.13, NumPy 2.3, fmt 12 and the
updated image, geometry and rendering libraries.

For an iOS-configured `build_files/build_environment` build, the
`apple_runtime_dependencies` target builds the app's runtime dependencies without
the unsupported desktop compiler backends. Set `HARVEST_TARGET` outside the source
checkout. With CMake 4, set `CMAKE_POLICY_VERSION_MINIMUM=3.5` for dependencies that
still declare older policy versions.

The host dependency build must provide Python 3.13 with Cython and Meson. Host
tools (`makesdna`, `makesrna`, `datatoc`, `msgfmt` and `shader_tool`) must also come
from the current source. Set `CROSSCOMPILE_TOOLDIR` when configuring the app to use
a separate host-tool build directory, and set `LIBDIR` to the rebuilt iOS
libraries. Keep device and simulator library/build directories separate: both
use ARM64, but their binaries are not interchangeable.

## TestFlight Distribution

The main app requests Increased Memory Limit and Extended Virtual Addressing for
production scenes. Enable both capabilities on its App ID and regenerate its
provisioning profile before signing. These entitlements do not grant all physical
RAM: iPadOS determines the allowance for the device and current conditions. Keep
the thumbnail extension on its own profile without the app's memory entitlements.

Reloadable file and tiled image buffers obey the image cache limit on iPadOS, so
CPU copies can be evicted to leave room for GPU textures. Dirty image buffers
remain protected by the cache; generated and viewer images remain persistent.

The native interface targets iOS/iPadOS 27.0 for external testing. Use the stable
Xcode 27.0 installation for the distribution build; the Xcode 27.1 simulator used
by some development tests is not a runtime requirement. The optional 27.1 toolbar
compression preference is guarded at both compile time and runtime.

### Building a tester build

`build_testflight.sh` is the way to make one. It goes from nothing to a prepared, checked app
in a build directory of its own (`build_ios_testflight` beside the checkout), never the
development one, and never uploads:

```sh
cp release/ios/testflight.env.example ../testflight.env   # once; fill in the team when there is one
release/ios/build_testflight.sh                           # or: build_testflight.sh /path/to/settings.env
```

The settings file lives outside the repository because it holds the team id and signing
identity; the example lists its keys (bundle id `app.satsuma3d`, version, build number, source
address, team, identity, profile). The script, logging each step to `<build dir>/logs/`:

1. configures the Xcode project with those settings (`IOS_BUNDLE_VERSION` is the build number:
   raise it for each upload; a bundle id ending in `.dev` or an empty source address is refused);
2. builds the `install` target unsigned, without the thumbnail extension (`IOS_THUMBNAIL_EXTENSION=OFF`;
   with it, the unsigned extension fails `ValidateEmbeddedBinary` and Xcode cancels the step that
   compiles the icon), so any failure is a real one;
3. stages the complete app with `cmake --install` (`bin/Blender.app`, not `bin/Release`);
4. rebuilds NumPy's modules as dynamic libraries with `build_numpy_ios.sh` and proves them with
   `check_numpy_replacements.py` (see below);
5. rebuilds OpenImageDenoise with its framework loader with `build_oidn_ios.sh` and proves it with
   `check_oidn_replacements.py` (see below);
6. runs `prepare_testflight.py --without-plugins` with both sets of replacements: every library becomes a framework, each Python
   module gets its `.fwork` marker, each framework whose binary uses a required reason API gets
   a privacy manifest, any app extension is left out (decision 36), and
   the layout is checked (`check_prepared`);
7. checks the prepared app: its identity in `Info.plist` (id, name, version, build, source
   address and commit, iPad only, minimum OS), the icon and glyphs in `Assets.car`
   (`check_icons`), `required_reason_apis.py`, and
   `tests/ios/test_testflight_packaging.py`;
8. only with a team, a signing identity, an installed profile for `<team>.<bundle id>` that grants
   `entitlements.plist`, and a clean checkout: archives with `archive_testflight.py` and exports
   an `.ipa` with `xcodebuild -exportArchive` (`method` `app-store-connect`, `destination`
   `export`, `manageAppVersionAndBuildNumber` false). Without them it stops after the checks and
   says what is missing.

Uploading is a separate step on the owner's word; the script has no upload code path, and a test
holds that.

**Uploading** (ROUND5 8L, L4) is `upload_testflight.sh [<settings>]`. It reads the archive and the
exported `.ipa` that `build_testflight.sh` made, prints the app, version, build number, source
commit and encryption key it would send, and checks that the archive matches the settings, that
the commit is on the `github` remote's `ipad/main` (`git ls-remote`; nothing is fetched) and that
the tag `testers/<version>-<build>` is free. It sends nothing unless called with
`--upload-build <n>`, `<n>` being the archive's build number. Then it uploads with
`xcodebuild -exportArchive` and export options `method` `app-store-connect`, `destination`
`upload` (Xcode's own account, from its settings), tags the commit `testers/<version>-<build>`
and pushes that tag alone. Each upload is the owner's word, given for that build (gate G4).
Validating without uploading (Xcode 27.2): export `method` `validation` is Xcode's "Validate with
App Store Connect" (`IDEDistributionMethodiOSAppStoreValidation` in `IDEDistribution.framework`).
It refuses `destination` `export` ("expected one of {upload}"): it sends the package to Apple's
validation service, which needs the app's record in App Store Connect, so it is run only on the
owner's word, like an upload. `xcrun altool --validate-app <ipa>` does the same with an App Store
Connect API key or an app-specific password. Everything checkable on this Mac (signature, profile,
entitlements, layout, privacy manifests, identity) is checked by `build_testflight.sh`. A full build takes hours the first time and wants about twice the development build
directory's size free.

**NumPy.** The prebuilt libraries ship NumPy's modules as `MH_BUNDLE`, which cannot become
frameworks. `build_numpy_ios.sh <work dir> <output dir>` rebuilds the bundled version (checked
against `versions.cmake`'s hash) with its vendored Meson and the recipe's cross files, then
relinks every module as `MH_DYLIB`. Meson asks the Mac's Python for the extension suffix, so it
runs with `_PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__darwin_arm64-iphoneos` and a `PYTHONPATH`
holding only that file from the iOS Python; without that the modules are named for the Mac and
the app never finds them.

**OpenImageDenoise.** It loads its Metal device module at run time from the folder its core library
is in; in the framework layout that module is a sibling framework, which only a core built with
`oidn_ios_frameworks.diff` looks for. The prebuilt `lib/ios_arm64` library of 2026-10-06 lacks it:
on the iPad its framework layout reported "no supported devices found" (2026-11-18), and
`prepare_testflight.py` refuses it (`MODULE_LOADERS`). `build_oidn_ios.sh <work dir> <output dir>`
rebuilds the version in `versions.cmake` (hash checked) with `oidn.diff` and
`oidn_ios_frameworks.diff`, the Metal device only, as `openimagedenoise.cmake` does for iOS, and
writes the three libraries under the prebuilt names and install names, without the build's run
paths. `check_oidn_replacements.py` compares them with the prebuilt set (names, install names,
architecture, minimum iOS, dependencies, exports), and checks that the core holds the framework
lookup and that the framework name it asks for (`OpenImageDenoise_` + module, with Release's empty
postfix) is the name packaging gives the module. About a minute; the development build keeps the
prebuilt libraries (its loose layout finds the module either way).

The pieces can also be run by hand:

```sh
release/ios/build_numpy_ios.sh /path/to/numpy-work /path/to/replacements
release/ios/build_oidn_ios.sh /path/to/oidn-work /path/to/oidn-replacements
python3 release/ios/prepare_testflight.py /path/to/bin/Blender.app /path/to/prepared/Blender.app \
  --replacement-directory /path/to/replacements --replacement-directory /path/to/oidn-replacements \
  --without-plugins
python3 release/ios/required_reason_apis.py /path/to/prepared/Blender.app
python3 release/ios/archive_testflight.py /path/to/prepared/Blender.app /path/to/Blender.xcarchive \
  --profile /path/to/profile.mobileprovision --identity SIGNING_IDENTITY \
  --dsym /path/to/Blender.app.dSYM
```

The archive is locally signed with the supplied profile and the app's own
entitlements from `entitlements.plist`, such as rendering with the GPU in the
background. The profile must grant each of them, so use the development profile
Xcode makes for the app's own identifier: a wildcard profile cannot carry
capabilities. After enabling a capability on the App ID, existing profiles become
invalid; Xcode makes new ones when building for a device and when exporting.
Distribution signing requires the account's appropriate certificate or Xcode
cloud signing access.

### Checking the framework layout on a device

The same prepared layout can be signed for development and run on an iPad before any upload.
`sign_development.py` signs either layout (loose libraries or frameworks):

```sh
python3 release/ios/sign_development.py /path/to/prepared/Blender.app /path/to/prepared_signed/Blender.app \
  --profile /path/to/development.mobileprovision --identity SIGNING_IDENTITY --without-plugins
```

The bundle id must be the profile's: prepare from a build configured with it (the development
build, for a free team). Installing replaces the app of that id on the device. Then copy
`tests/ios/testflight_device_test.py` into the app's `tmp` folder and launch it with factory
startup, with `PLATYPUS_SCRATCH_DOCUMENT=1` so the launcher opens a scratch copy instead of the
last document (`--` ends `devicectl`'s own options; what follows goes to the app):

```sh
xcrun devicectl device install app --device UDID /path/to/prepared_signed/Blender.app
xcrun devicectl device copy to --device UDID --domain-type appDataContainer --domain-identifier BUNDLE_ID \
  --source tests/ios/testflight_device_test.py --destination tmp/testflight_device_test.py
xcrun devicectl device process launch --device UDID --terminate-existing \
  --environment-variables '{"PLATYPUS_SCRATCH_DOCUMENT":"1"}' BUNDLE_ID -- --factory-startup --python-expr \
  "exec(compile(open(__import__('os').path.expanduser('~/tmp/testflight_device_test.py')).read(), 'testflight_device_test.py', 'exec'))"
xcrun devicectl device copy from --device UDID --domain-type appDataContainer --domain-identifier BUNDLE_ID \
  --source tmp/testflight-check/testflight-device-test.json --destination testflight-device-test.json
```

The report's `success` is true when NumPy imports from all its frameworks, OpenImageDenoise
initialises, a scene saves and renders, and the default cube exports to glTF. Everything the
test writes stays in the app's `tmp/testflight-check/`; it saves a copy, so the recent-files
list is untouched. Validate on an iPadOS 27.0 device before inviting testers.

See [Apple's bundle layout requirements](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
and [Python's iOS packaging instructions](https://docs.python.org/3.13/using/ios.html).
The first external TestFlight build requires Apple's beta review; invite colleagues
after approval. Each uploaded build expires after 90 days. See
[TestFlight distribution](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).

## Native UI Threading

The iOS port has three independent execution paths:

- UIKit owns windows, native controls, gestures, menus, scrolling and animations.
  It never calls the Blender event loop or waits for Blender or a Metal drawable.
- The `Blender Engine` thread initializes Blender (including Python and Blender's
  logical main-thread identity), processes events and commands, evaluates scenes,
  and submits rendering. Blender's existing internal job system remains available.
- `org.blender.viewport.presentation` acquires drawables and presents completed
  viewport frames. It never accesses a UIView or live Blender state.

This separation follows [Apple's responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).

`GHOST_MessageQueue` transfers owned commands/events without a consumer-held
lock. All native command types share one FIFO inbox. `GHOST_Latest` transfers
the latest immutable UI snapshot, replacing obsolete unpublished snapshots.
UIKit keeps its last snapshot while the engine is busy. Native menu queries and
file-picker results are asynchronous too.

The toolbar menu and iPadOS menu bar project Blender's registered top-bar and
viewport menus. The viewport Actions menu and Pencil radial menu resolve
Blender's live context menu on demand. All of them preserve the original command
routes, properties, submenus and polling; none uses a hand-written fallback list.

`GHOST_IOSSurface` keeps a bounded three-texture copy pool. Copies are submitted
after the engine's render commands on the same Metal queue, and published only
after GPU completion. Presentation retains its frame until its own GPU work
finishes. A pool slot cannot be overwritten while either consumer holds it.
When the pool is busy, presentation copies are skipped; the last completed frame
remains available, including during a live resize. The engine retains the latest
pending swap and retries it, so its final update is not lost when rendering goes
idle. Offscreen contexts do not create UIKit views.

Window geometry and pointer positions cross the boundary as atomic values.
Input carries a window-lifetime token: closing a window first detaches native
callbacks on UIKit, then invalidates queued input before destroying engine state.
Scene inactivity pauses new engine iterations and viewport presentation; scene
reconnection reattaches the retained native windows.

The engine may synchronously ask UIKit to create/destroy a native resource or
answer a legacy OS query (keyboard/clipboard). These short blocks must not call
Blender. The reverse dependency is forbidden. Normal controls, UI snapshots and
frame presentation do not use this synchronous path. File coordination, bookmark
resolution and filesystem checks run outside UIKit.

## Tests

The native interface's Python side is tested with Blender's own tests (`script_native_*` in
`tests/python`). Simulator harnesses, device checks and probes are in `tests/ios`, see its
README.

## Native Warnings

iOS uses UIKit alerts for operator confirmations (including Delete and Revert),
unsaved-file choices, overwrite warnings, report popups and general alerts.
Warnings with options use a SwiftUI sheet with toggles, including modified
images, asset catalogs and the blocked-script security prompt. Script
execution remains opt-in; dismissing the security sheet does not grant permission.
Complex operator property forms are separate from confirmations and remain in
Blender's UI.

The engine owns pending actions and their original context. UIKit receives copied
dialog content and returns queued results only after dismissal, allowing an action
to open a file picker safely. Closing a window or replacing its editor cancels
stale requests. Cancellation never executes the pending destructive operation.

## Character Animation Template

The Character Animation seed contains Blender Studio's Ellie rig, adapted for
Blender 5.1 without document scripts. It opens in Pose Mode with the timeline,
body/head controls, and native Object Properties panels for control visibility,
appearance, pose assets, IK/FK and parent spaces. Detailed face/finger controls
remain available in bone collections. The original rigged mesh hair replaces
the legacy particle-hair handlers.

Ellie and the generated preview are CC BY 4.0, separately from application code.
The chooser displays creator attribution and opens source/license links and a
modification notice. Scene and rig metadata retain this credit in saved files;
duplicating or exporting a personal template also preserves its chooser credit.
`templates/library/ELLIE-CREDITS.txt` and `CC-BY-4.0.txt` ship with the assets.
Do not add asset-specific EULA restrictions or copy protection when distributing
this material. Release packaging and store terms still need their own review.

Regenerate only this seed and preview with:

```sh
blender --background --factory-startup --disable-autoexec --python release/ios/templates/build_character.py
python3 -m unittest release.ios.test_character_template release.ios.test_native_templates
```

The builder checks the recorded source hash; it never runs the original rig's
embedded code. `templates/sources/README.md` records provenance. The source
directory is not installed in the app. Full template regeneration includes Ellie.

For physical-device checks, use a separate QA bundle with TemplatesDeviceProbe,
copy `character_template_device_test.py` to its Documents directory, and launch
with the same `--factory-startup --python-expr` procedure above. The report is
`Documents/character-template-test.json`. This verifies native document creation,
Pose Mode, rig operators, keyframes, export, reopen, and attribution retention;
it does not synthesize physical Pencil input.
