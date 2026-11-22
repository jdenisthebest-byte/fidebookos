#!/bin/sh
# MediaTek MT7902 Bluetooth USB support (13d3:3594 and sibling MT7902 USB IDs)
# for drivers/bluetooth/{btusb.c,btmtk.c,btmtk.h} on Linux 6.18.
#
# Why both btusb_table[] and quirks_table[] receive the MT7902 entries:
#   - MODULE_DEVICE_TABLE(usb, btusb_table) exports modalias entries ONLY from
#     btusb_table[], NOT quirks_table[]. Placing MT7902 IDs at the top of
#     btusb_table[] (above the generic 0xe0/0x01/0x01 class wildcard and the
#     0x13d3/0xff Broadcom vendor rule) both advertises the explicit
#     usb:v13D3p3594... alias in modinfo/modules.alias AND passes
#     driver_info = BTUSB_MEDIATEK | BTUSB_WIDEBAND_SPEECH (0x300000) directly
#     to btusb_probe().
#   - Keeping them in quirks_table[] matches upstream Linux 7.1/7.2 as well.
#   - btmtk.c adds case 0x7902: in btmtk_usb_setup() (resolving firmware
#     mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin via btmtk_fw_get_filename) and
#     MODULE_FIRMWARE(FIRMWARE_MT7902) so modinfo and tools/fw_wanted.py track it.
#
# Idempotent; safe on both pristine AOSP android17-6.18 and partially patched trees.
set -e
SRC=${SRC:-/build/src}

python3 - "$SRC" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
btmtk_h = src / "drivers/bluetooth/btmtk.h"
btmtk_c = src / "drivers/bluetooth/btmtk.c"
btusb_c = src / "drivers/bluetooth/btusb.c"

MT7902_BLOCK = """\t/* MediaTek MT7902 Bluetooth devices */
\t{ USB_DEVICE(0x0489, 0xe156), .driver_info = BTUSB_MEDIATEK |
\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH },
\t{ USB_DEVICE(0x0e8d, 0x1ede), .driver_info = BTUSB_MEDIATEK |
\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH },
\t{ USB_DEVICE(0x13d3, 0x3579), .driver_info = BTUSB_MEDIATEK |
\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH },
\t{ USB_DEVICE(0x13d3, 0x3580), .driver_info = BTUSB_MEDIATEK |
\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH },
\t{ USB_DEVICE(0x13d3, 0x3594), .driver_info = BTUSB_MEDIATEK |
\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH },
\t{ USB_DEVICE(0x13d3, 0x3596), .driver_info = BTUSB_MEDIATEK |
\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH },
"""

# 1. btmtk.h: FIRMWARE_MT7902
h_txt = btmtk_h.read_text()
if "FIRMWARE_MT7902" not in h_txt:
    anchor = '#define FIRMWARE_MT7922\t\t"mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin"\n'
    assert anchor in h_txt, "FIRMWARE_MT7922 anchor not found in btmtk.h"
    h_txt = h_txt.replace(
        anchor,
        anchor + '#define FIRMWARE_MT7902\t\t"mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin"\n',
        1,
    )
    btmtk_h.write_text(h_txt)

# 2. btmtk.c: case 0x7902: in btmtk_usb_setup() + MODULE_FIRMWARE(FIRMWARE_MT7902)
c_txt = btmtk_c.read_text()
# Normalize any space-indented case 0x7902: first
c_txt = re.sub(r"^[ \t]*case 0x7902:\n", "", c_txt, flags=re.MULTILINE)
anchor_case = "\tcase 0x7922:\n\tcase 0x7925:\n\tcase 0x7961:\n"
assert anchor_case in c_txt, "case 0x7922 anchor not found in btmtk.c"
c_txt = c_txt.replace(anchor_case, "\tcase 0x7902:\n" + anchor_case, 1)

if "MODULE_FIRMWARE(FIRMWARE_MT7902);" not in c_txt:
    anchor_fw = "MODULE_FIRMWARE(FIRMWARE_MT7922);\n"
    assert anchor_fw in c_txt, "MODULE_FIRMWARE(FIRMWARE_MT7922) anchor not found in btmtk.c"
    c_txt = c_txt.replace(anchor_fw, anchor_fw + "MODULE_FIRMWARE(FIRMWARE_MT7902);\n", 1)
btmtk_c.write_text(c_txt)

# 3. btusb.c: clean any prior ad-hoc MT7902 lines, then insert cleanly into BOTH
#    btusb_table[] (for MODULE_DEVICE_TABLE modalias + direct driver_info match)
#    and quirks_table[] (matching upstream Linux 7.1/7.2).
u_txt = btusb_c.read_text()
u_txt = re.sub(
    r"\t/\* MediaTek MT7902 Bluetooth devices \*/\n(?:\t\{ USB_DEVICE\(0x[0-9a-f]+, 0x[0-9a-f]+\), \.driver_info = BTUSB_MEDIATEK \|\n\t\t\t\t\t\t     BTUSB_WIDEBAND_SPEECH \},\n)+\n?",
    "",
    u_txt,
)
u_txt = re.sub(
    r"^[ \t]*\{ USB_DEVICE\(0x13d3, 0x3594\), \.driver_info = BTUSB_MEDIATEK \|[ \t\n]*BTUSB_WIDEBAND_SPEECH \},\n",
    "",
    u_txt,
    flags=re.MULTILINE,
)

table_anchor = "static const struct usb_device_id btusb_table[] = {\n"
assert table_anchor in u_txt, "btusb_table anchor not found in btusb.c"
u_txt = u_txt.replace(table_anchor, table_anchor + MT7902_BLOCK + "\n", 1)

quirks_anchor = "\t/* Additional MediaTek MT7920 Bluetooth devices */\n"
assert quirks_anchor in u_txt, "MT7920 quirks_table anchor not found in btusb.c"
u_txt = u_txt.replace(quirks_anchor, MT7902_BLOCK + "\n" + quirks_anchor, 1)
btusb_c.write_text(u_txt)

print("mt7902_bt: patched btmtk.h, btmtk.c, btusb.c")
PY
