# FideBookOS 1.25 build payload

The firmware, module tree, BusyBox, Vulkan drivers, and KernelSU binaries were checked
against the local FideBookOS 1.25 R5 image manifest before publication. Use the
checked-in `usb/out/BOOTX64.EFI`, `usb/kmod/`, and `usb/modules/` together.
Rebuilding the kernel requires re-exporting the corresponding signed modules.

| Paths | Source |
| --- | --- |
| `usb/out/BOOTX64.EFI`, `usb/modules/`, `usb/kmod/` | AOSP kernel/common at [3938c8d](https://android.googlesource.com/kernel/common/+/3938c8d97142d5cf31543aa96f864a2cf832dda0), the patches under `kernel/`, and the local build entry point `kernel/build_kernel.sh`. |
| `kernel/mt7902/` | The MT7902 PCIe Wi-Fi module sources from [abdullaabdullazade/mt7902_driver at f1b728b](https://github.com/abdullaabdullazade/mt7902_driver/tree/f1b728bf56703feb91503e66870590476fef2f99/mt7902/src). The kernel build uses this directory by default. |
| `usb/firmware/` | Linux firmware and Intel SOF firmware. See `usb/firmware/FIRMWARE_SOURCE.txt`, `usb/firmware/licenses/WHENCE`, the companion vendor notices, and `usb/firmware/intel/LICENCE.sof-bin`. |
| `kernel/out/busybox` | Debian trixie x86-64 [busybox-static 1:1.37.0-6+b9](https://tracker.debian.org/pkg/busybox) from the BusyBox 1:1.37.0-6 source package. See `tools/fetch_busybox.sh`. |
| `usb/patched/vulkan.radv.so`, `usb/patched/vulkan.swiftshader.so` | Android graphics drivers. The upstream versions, build steps, and local changes are under `tools/radv-android/` and `tools/swiftshader-android/`. |
| `usb/ksu/manager.apk`, `usb/ksu/ksud` | Unmodified x86-64 [KernelSU v3.3.1 release assets](https://github.com/tiann/KernelSU/releases/tag/v3.3.1). |

The Android system comes from the Google recovery URL and SHA-256 pinned in
`lapis/BUILD` and `lapis/recovery.zip.sha256`. Run `./build.sh --standard`
to download it directly from Google and extract the six needed partitions, or
provide them locally in `lapis/parts/`. The generated installer and Google
partition images should stay local.

Optional Surface Laptop 7 helpers can be built from `tools/build_surface_tools.sh`.
The standard R5 payload includes the Surface scripts and configuration. See
`usb/surface/README.md` for the optional binaries.
