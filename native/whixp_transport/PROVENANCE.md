Vendored from the `whixp` Dart package (https://pub.dev/packages/whixp),
version 3.1.0, `native/whixp_transport/` subdirectory. MIT licensed (see
LICENSE_UPSTREAM.md).

Why vendored here instead of depended on from the pub-cache checkout:
whixp 3.1.0's `lib/` requires this crate to be compiled into a platform
native library (`whixp_transport.dll` on Windows) that its FFI transport
loads at runtime - there is no pure-Dart fallback. whixp itself ships this
as source only (no prebuilt binaries), expecting consumers to build it via
its own Makefile. Depending on a path inside `~/.pub-cache/...` would not be
reproducible across machines or `flutter pub cache` resets, so the crate
source is vendored into this repo instead and built by
`windows/CMakeLists.txt` as part of the normal Windows build.

Cross-platform note: this is one crate compiled separately per target OS
(see Cargo.toml - no OS-specific code, standard Rust cross-compilation).
The Windows build here produces `whixp_transport.dll` only. macOS will need
its own build (`.dylib`) wired into the Xcode/CMake build once Mac access is
available - not covered yet.
