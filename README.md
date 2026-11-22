# FideBookOS 1.25

<p align="center">
  <img src="usb/branding/fidebookos-logo.png" alt="FideBookOS Logo" width="160">
</p>

**FideBookOS 1.25** is a fast, hardware-accelerated Material 3 Desktop Android 17 operating system engineered for modern **AMD Ryzen / Radeon** and **Intel 6th Gen+** x86_64 laptops.

---

## Key Features in FideBookOS 1.25

- **Liquid Glass Cross-Window Background Refraction + Live Settings Toggle:**
  - Real-time GPU optical **Liquid Glass** across the **Taskbar / Dock**, **Control Center / Quick Settings**, and **App Menu / All Apps Drawer** (`tools/radv-android/fidebook_liquid_glass.h`), adapted from open-source Android Liquid Glass projects **[`Kyant0/AndroidLiquidGlass`](https://github.com/Kyant0/AndroidLiquidGlass)** (`Backdrop`, Apache-2.0) and **[`styropyr0/Prismal`](https://github.com/styropyr0/Prismal)** (MIT): rounded-box SDF meniscus dome normals, physical Snell's-law refraction (`IOR = 1.52`), 3-channel RGB prismatic dispersion, `1.26x` vibrancy boost, and Fresnel + dual Blinn-Phong crystal rim highlights while keeping foreground icons, text, and sliders 100% sharp.
  - Native Material 3 **"Liquid Glass & Motion"** screen injected directly into **Settings -> Display & touch** and the **Settings Homepage** (`FideBookVisualSettings.apk`), allowing instant ON/OFF switching (`persist.fidebook.liquid_glass` + live mutable RRO overlays `FideBookGlass{Framework,Launcher,SystemUI}Overlay.apk`), Refraction Lens Depth (`Subtle` / `Balanced` / `Expressive`), and Scroll Motion Blur with **zero reboot required**.
- **Complete FideBookOS Visual Identity & Google-Gradient `"F"` Branding:**
  - Google 4-color gradient **`F`** emblem across the **Desktop Dock / Taskbar** (`FideBookLauncherOverlay.apk`), **Settings** (`FideBookSettingsOverlay.apk` across `default`, `mdpi..xxhdpi`, `sw600dp`, and `anydpi-v24`), **60 FPS Motion-Blur Boot Animation** (`usb/branding/bootanimation.zip`), **Graphical Boot Menu & Installer**, and **First-Boot Setup Wizard**.
  - Identifies cleanly as **`FideBook`** running **`FideBookOS 1.25`** across Settings > About, Bluetooth, Quick Share, and Chrome while preserving Google Play / GMS device certification.
- **ARM64 Mobile App Translation on Both AMD Ryzen & Intel (`libndk_translation.so` / Berberis):**
  - Automatically switches `ro.dalvik.vm.native.bridge` from Intel-locked `libhoudini.so` (which aborts on AMD Ryzen due to `GenuineIntel` CPUID checks and AVX-512 instructions) to Google's vendor-neutral **`libndk_translation.so`** (`Berberis 16.0.0`) on AMD Ryzen and non-AVX-512 CPUs so ARM64 Android mobile apps run natively out of the box.
- **Material 3 Expressive Laptop Setup Wizard (`FideBookSetup.apk`):**
  - Launches **only on the very first boot** (`org.fidebookos.setup`, statically linked with `-static-libstdc++`), guiding through Language & Accessibility, live Wi-Fi & Bluetooth pairing, Physical Keyboard & 20ms Touchpad Flick Boost, Laptop Name, Dark/Light Material 3 Theme, **Liquid Glass** & **GPU Scroll Motion Blur**, Display Scaling, Webcam & Audio verification, and Google Account sign-in.
- **Hardware GPU Vulkan 1.4 Multi-Queue + Real-Time 60 FPS Scroll Motion Blur (`vulkan.radv.so`):**
  - Custom Mesa RADV Vulkan 1.4 driver compiled with `-O3 -march=x86-64-v3 -mtune=znver3`, `queueCount=4` per-queue `amdgpu_ctx` multiplexing, `AB24` hardware gralloc, native Vulkan HWUI (`ro.hwui.use_vulkan=true`), and `skiavkthreaded` SurfaceFlinger.
  - Fork-aware post-Zygote **9-tap Gaussian shutter motion blur** in `radv_QueueSignalReleaseImageANDROID` (`tools/radv-android/fidebook_mblur.h`) when scrolling in the **App Menu**, **Settings**, and **Control Center** (`persist.fidebook.motion_blur=ui`, zero ghosting on stop frames).
- **Full Laptop Hardware Support (`6.18.21-fidebook`):**
  - **Wi-Fi & Bluetooth:** MediaTek **MT7902** PCIe Wi-Fi (`14c3:7902`, `mt7902e.ko`) & USB Bluetooth (`13d3:3594`, `btmtk.ko` + `btusb.ko`), plus Intel, Realtek, Qualcomm Atheros, Broadcom, and Marvell.
  - **Built-in Laptop Webcam:** Automatic UVC camera registration (`04f2:b79c` Chicony ACER HD + generic `/sys/class/video4linux` auto-discovery) and software MJPEG decode on AMD Radeon.
  - **Graphical Boot Menu & SSD Installer (`fidebook-gui`):** KMS / UEFI framebuffer graphical UI with mouse, touchpad, and keyboard navigation, Windows/Linux Dual-Boot installation, and mandatory drive-serial confirmation before disk erase.

---

## Build & Flash

```sh
# Build the standard FideBookOS 1.25 Live USB + Graphical Installer image:
sh tools/make_fidebookos_image.sh --output dist/FideBookOS-1.25.img

# Or build a persistent 64 GB sparse USB/SSD image (MODE=boot):
sh tools/make_fidebookos_image.sh --type looper --data-size 64

# Flash to USB drive:
sudo dd if=dist/FideBookOS-1.25.img of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot from USB (**F12** / **F2** / **Esc** UEFI boot menu, Secure Boot off) to launch the **FideBookOS 1.25 Graphical Boot Menu**.

---

## Verification & Test Suites

```sh
sh tools/test_fidebook_release.sh
sh tools/test_gpu_select.sh
sh tools/test_bt_init.sh
sh tools/test_device_model.sh
sh tools/test_audio_config.sh
sh tools/test_native_zygote.sh
sh tools/radv-android/run_hw_test.sh usb/patched/vulkan.radv.so
```
