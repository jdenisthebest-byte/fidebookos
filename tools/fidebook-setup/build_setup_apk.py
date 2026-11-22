#!/usr/bin/env python3
"""
Build FideBookSetup.apk (org.fidebookos.setup) 100% offline:
  - Generates a spec-exact, self-verified Dalvik classes.dex (dex 035) bridging
    SetupActivity + ActionClick to lib/x86_64/libfidebook_setup.so
  - Generates binary AndroidManifest.xml + resources.arsc + 144x144 Google-gradient "F" icon
  - Packs ZIP with 16384-byte alignment for lib/x86_64/libfidebook_setup.so and 4-byte alignment
    for resources.arsc (Android 17 16KB page compatibility)
  - Signs with JAR v1 + APK Signature Scheme v2 (0x7109871A)
"""

import hashlib
import io
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[2]
LOGO_ALPHA = REPO_ROOT / "usb" / "branding" / "fidebookos-logo-alpha.png"
NATIVE_SO = Path(__file__).resolve().parent / "out" / "libfidebook_setup.so"
VISUAL_SO = Path(__file__).resolve().parent / "out" / "libfidebook_visual.so"
OUT_APK = REPO_ROOT / "usb" / "branding" / "app" / "FideBookSetup.apk"
OUT_VISUAL_APK = REPO_ROOT / "usb" / "branding" / "app" / "FideBookVisualSettings.apk"


# ==============================================================================
# 1. Spec-Exact Dalvik DEX (035) Compiler & Verifier
# ==============================================================================

def uleb128(val: int) -> bytes:
    assert val >= 0
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def read_uleb128(buf: bytes, off: int) -> tuple[int, int]:
    res = 0
    shift = 0
    while True:
        b = buf[off]
        off += 1
        res |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return res, off
        shift += 7


def mutf8_encode(s: str) -> bytes:
    # Pure ASCII strings in our DEX -> UTF-16 code units length == byte length
    raw = s.encode("utf-8")
    return uleb128(len(s)) + raw + b"\x00"


def build_classes_dex(
    pkg_slash: str = "org/fidebookos/setup",
    act_name: str = "SetupActivity",
    lib_name: str = "fidebook_setup",
) -> bytes:
    ac_desc = f"L{pkg_slash}/ActionClick;"
    sa_desc = f"L{pkg_slash}/{act_name};"
    # Collect all strings needed by types, protos, fields, methods, and const-string
    strings_set = {
        "<clinit>",
        "<init>",
        "I",
        "IL",
        "J",
        "L",
        "Landroid/app/Activity;",
        "Landroid/os/Bundle;",
        "Landroid/view/View$OnClickListener;",
        "Landroid/view/View;",
        "Ljava/lang/Object;",
        "Ljava/lang/Runnable;",
        "Ljava/lang/String;",
        "Ljava/lang/System;",
        ac_desc,
        sa_desc,
        "V",
        "VI",
        "VIL",
        "VL",
        "VLI",
        "dispatchAction",
        lib_name,
        "host",
        "id",
        "loadLibrary",
        "nativeOnAction",
        "nativeOnBack",
        "nativeOnCreate",
        "nativeOnDestroy",
        "nativeOnResume",
        "nativePtr",
        "onBackPressed",
        "onClick",
        "onCreate",
        "onDestroy",
        "onResume",
        "run",
    }
    strings = sorted(strings_set)
    s_idx = {s: i for i, s in enumerate(strings)}

    type_descs = sorted([
        "I",
        "J",
        "Landroid/app/Activity;",
        "Landroid/os/Bundle;",
        "Landroid/view/View$OnClickListener;",
        "Landroid/view/View;",
        "Ljava/lang/Object;",
        "Ljava/lang/Runnable;",
        "Ljava/lang/String;",
        "Ljava/lang/System;",
        ac_desc,
        sa_desc,
        "V",
    ], key=lambda t: s_idx[t])
    t_idx = {t: i for i, t in enumerate(type_descs)}

    raw_protos = [
        ("V", "V", ()),
        ("VL", "V", ("Landroid/os/Bundle;",)),
        ("VL", "V", ("Landroid/view/View;",)),
        ("VL", "V", ("Ljava/lang/String;",)),
        ("VLI", "V", (sa_desc, "I")),
        ("VIL", "V", ("I", "Landroid/view/View;")),
    ]
    protos = sorted(raw_protos, key=lambda p: (t_idx[p[1]], tuple(t_idx[x] for x in p[2])))
    p_idx = {(p[1], p[2]): i for i, p in enumerate(protos)}

    # Fields: (class_desc, type_desc, name) sorted by (class_idx, name_idx, type_idx)
    raw_fields = [
        (ac_desc, sa_desc, "host"),
        (ac_desc, "I", "id"),
        (sa_desc, "J", "nativePtr"),
    ]
    fields = sorted(raw_fields, key=lambda f: (t_idx[f[0]], s_idx[f[2]], t_idx[f[1]]))
    f_idx = {(f[0], f[2], f[1]): i for i, f in enumerate(fields)}

    # Methods: (class_desc, ret_desc, params_tuple, name) sorted by (class_idx, name_idx, proto_idx)
    raw_methods = [
        # Framework methods invoked
        ("Ljava/lang/Object;", "V", (), "<init>"),
        ("Ljava/lang/System;", "V", ("Ljava/lang/String;",), "loadLibrary"),
        ("Landroid/app/Activity;", "V", (), "<init>"),
        ("Landroid/app/Activity;", "V", ("Landroid/os/Bundle;",), "onCreate"),
        ("Landroid/app/Activity;", "V", (), "onDestroy"),
        ("Landroid/app/Activity;", "V", (), "onResume"),
        # ActionClick methods
        (ac_desc, "V", (sa_desc, "I"), "<init>"),
        (ac_desc, "V", ("Landroid/view/View;",), "onClick"),
        (ac_desc, "V", (), "run"),
        # Activity direct + virtual methods
        (sa_desc, "V", (), "<clinit>"),
        (sa_desc, "V", (), "<init>"),
        (sa_desc, "V", ("I", "Landroid/view/View;"), "nativeOnAction"),
        (sa_desc, "V", (), "nativeOnBack"),
        (sa_desc, "V", ("Landroid/os/Bundle;",), "nativeOnCreate"),
        (sa_desc, "V", (), "nativeOnDestroy"),
        (sa_desc, "V", (), "nativeOnResume"),
        (sa_desc, "V", ("I", "Landroid/view/View;"), "dispatchAction"),
        (sa_desc, "V", (), "onBackPressed"),
        (sa_desc, "V", ("Landroid/os/Bundle;",), "onCreate"),
        (sa_desc, "V", (), "onDestroy"),
        (sa_desc, "V", (), "onResume"),
    ]
    methods = sorted(raw_methods, key=lambda m: (t_idx[m[0]], s_idx[m[3]], p_idx[(m[1], m[2])]))
    m_idx = {(m[0], m[3], m[1], m[2]): i for i, m in enumerate(methods)}

    def pack_code(registers: int, ins: int, outs: int, units: list[int]) -> bytes:
        insns = struct.pack(f"<{len(units)}H", *units)
        hdr = struct.pack("<HHHHII", registers, ins, outs, 0, 0, len(units))
        blob = hdr + insns
        if len(blob) % 4:
            blob += b"\x00" * (4 - (len(blob) % 4))
        return blob

    # Dalvik instruction helpers (16-bit code units, little-endian)
    # 35c format: A|G|op BBBB F|E|D|C -> word0 = op | ((G & 0xf) << 8) | ((A & 0xf) << 12)
    #                                    word1 = BBBB
    #                                    word2 = (C & 0xf) | ((D & 0xf) << 4) | ((E & 0xf) << 8) | ((F & 0xf) << 12)
    def insn_35c(op: int, regs: list[int], ref_idx: int) -> list[int]:
        a = len(regs)
        assert 0 <= a <= 5
        padded = regs + [0] * (5 - a)
        c, d, e, f, g = padded
        w0 = (op & 0xFF) | ((g & 0xF) << 8) | ((a & 0xF) << 12)
        w1 = ref_idx & 0xFFFF
        w2 = (c & 0xF) | ((d & 0xF) << 4) | ((e & 0xF) << 8) | ((f & 0xF) << 12)
        return [w0, w1, w2]

    # 22c format (iget/iput): B|A|op CCCC -> vA = value reg, vB = object reg
    def insn_22c(op: int, va: int, vb: int, field_ref: int) -> list[int]:
        w0 = (op & 0xFF) | ((va & 0xF) << 8) | ((vb & 0xF) << 12)
        return [w0, field_ref & 0xFFFF]

    # 21c format (const-string vAA, string@BBBB)
    def insn_21c(op: int, vaa: int, ref_idx: int) -> list[int]:
        return [(op & 0xFF) | ((vaa & 0xFF) << 8), ref_idx & 0xFFFF]

    # 11n format (const/4 vA, #+B)
    def insn_11n(op: int, va: int, lit4: int) -> list[int]:
        return [(op & 0xFF) | ((va & 0xF) << 8) | ((lit4 & 0xF) << 12)]

    INSN_RETURN_VOID = [0x000E]
    OP_CONST_4 = 0x12
    OP_CONST_STRING = 0x1A
    OP_IGET = 0x52
    OP_IGET_OBJECT = 0x54
    OP_IPUT = 0x59
    OP_IPUT_OBJECT = 0x5B
    OP_INVOKE_VIRTUAL = 0x6E
    OP_INVOKE_SUPER = 0x6F
    OP_INVOKE_DIRECT = 0x70
    OP_INVOKE_STATIC = 0x71

    fld_host = f_idx[(ac_desc, "host", sa_desc)]
    fld_id = f_idx[(ac_desc, "id", "I")]

    m_obj_init = m_idx[("Ljava/lang/Object;", "<init>", "V", ())]
    m_sys_loadlib = m_idx[("Ljava/lang/System;", "loadLibrary", "V", ("Ljava/lang/String;",))]
    m_act_init = m_idx[("Landroid/app/Activity;", "<init>", "V", ())]
    m_act_oncreate = m_idx[("Landroid/app/Activity;", "onCreate", "V", ("Landroid/os/Bundle;",))]
    m_act_ondestroy = m_idx[("Landroid/app/Activity;", "onDestroy", "V", ())]
    m_act_onresume = m_idx[("Landroid/app/Activity;", "onResume", "V", ())]

    m_dispatch = m_idx[(sa_desc, "dispatchAction", "V", ("I", "Landroid/view/View;"))]
    m_nat_action = m_idx[(sa_desc, "nativeOnAction", "V", ("I", "Landroid/view/View;"))]
    m_nat_back = m_idx[(sa_desc, "nativeOnBack", "V", ())]
    m_nat_create = m_idx[(sa_desc, "nativeOnCreate", "V", ("Landroid/os/Bundle;",))]
    m_nat_destroy = m_idx[(sa_desc, "nativeOnDestroy", "V", ())]
    m_nat_resume = m_idx[(sa_desc, "nativeOnResume", "V", ())]

    # Code items
    code_items: dict[str, bytes] = {}

    # ActionClick.<init>(Activity, int): v0=this, v1=host, v2=id
    code_items["ac_init"] = pack_code(3, 3, 1,
        insn_35c(OP_INVOKE_DIRECT, [0], m_obj_init) +
        insn_22c(OP_IPUT_OBJECT, 1, 0, fld_host) +
        insn_22c(OP_IPUT, 2, 0, fld_id) +
        INSN_RETURN_VOID
    )
    # ActionClick.onClick(View): v0, v1, v2=this, v3=view
    code_items["ac_onclick"] = pack_code(4, 2, 3,
        insn_22c(OP_IGET_OBJECT, 0, 2, fld_host) +
        insn_22c(OP_IGET, 1, 2, fld_id) +
        insn_35c(OP_INVOKE_VIRTUAL, [0, 1, 3], m_dispatch) +
        INSN_RETURN_VOID
    )
    # ActionClick.run(): v0, v1, v2, v3=this
    code_items["ac_run"] = pack_code(4, 1, 3,
        insn_22c(OP_IGET_OBJECT, 0, 3, fld_host) +
        insn_22c(OP_IGET, 1, 3, fld_id) +
        insn_11n(OP_CONST_4, 2, 0) +
        insn_35c(OP_INVOKE_VIRTUAL, [0, 1, 2], m_dispatch) +
        INSN_RETURN_VOID
    )
    # Activity.<clinit>()
    code_items["sa_clinit"] = pack_code(1, 0, 1,
        insn_21c(OP_CONST_STRING, 0, s_idx[lib_name]) +
        insn_35c(OP_INVOKE_STATIC, [0], m_sys_loadlib) +
        INSN_RETURN_VOID
    )
    # SetupActivity.<init>(): v0=this
    code_items["sa_init"] = pack_code(1, 1, 1,
        insn_35c(OP_INVOKE_DIRECT, [0], m_act_init) +
        INSN_RETURN_VOID
    )
    # SetupActivity.dispatchAction(int, View): v0=this, v1=id, v2=view
    code_items["sa_dispatch"] = pack_code(3, 3, 3,
        insn_35c(OP_INVOKE_DIRECT, [0, 1, 2], m_nat_action) +
        INSN_RETURN_VOID
    )
    # SetupActivity.onBackPressed(): v0=this
    code_items["sa_back"] = pack_code(1, 1, 1,
        insn_35c(OP_INVOKE_DIRECT, [0], m_nat_back) +
        INSN_RETURN_VOID
    )
    # SetupActivity.onCreate(Bundle): v0=this, v1=bundle
    code_items["sa_create"] = pack_code(2, 2, 2,
        insn_35c(OP_INVOKE_SUPER, [0, 1], m_act_oncreate) +
        insn_35c(OP_INVOKE_DIRECT, [0, 1], m_nat_create) +
        INSN_RETURN_VOID
    )
    # SetupActivity.onDestroy(): v0=this
    code_items["sa_destroy"] = pack_code(1, 1, 1,
        insn_35c(OP_INVOKE_DIRECT, [0], m_nat_destroy) +
        insn_35c(OP_INVOKE_SUPER, [0], m_act_ondestroy) +
        INSN_RETURN_VOID
    )
    # SetupActivity.onResume(): v0=this
    code_items["sa_resume"] = pack_code(1, 1, 1,
        insn_35c(OP_INVOKE_SUPER, [0], m_act_onresume) +
        insn_35c(OP_INVOKE_DIRECT, [0], m_nat_resume) +
        INSN_RETURN_VOID
    )

    # Layout deterministic DEX binary
    header_size = 0x70
    string_ids_off = header_size
    type_ids_off = string_ids_off + len(strings) * 4
    proto_ids_off = type_ids_off + len(type_descs) * 4
    field_ids_off = proto_ids_off + len(protos) * 12
    method_ids_off = field_ids_off + len(fields) * 8
    class_defs_off = method_ids_off + len(methods) * 8
    num_classes = 2
    data_off = class_defs_off + num_classes * 32
    assert data_off % 4 == 0

    data = bytearray()
    def cur_off() -> int:
        return data_off + len(data)
    def align4():
        while len(data) % 4:
            data.append(0)

    # 1. type_list section (proto parameter lists + ActionClick interfaces list)
    type_lists: list[tuple[int, ...]] = []
    for _, _, params in protos:
        if params and params not in type_lists:
            type_lists.append(params)
    ac_ifaces = tuple(sorted(
        ("Landroid/view/View$OnClickListener;", "Ljava/lang/Runnable;"),
        key=lambda x: t_idx[x]
    ))
    if ac_ifaces not in type_lists:
        type_lists.append(ac_ifaces)

    tl_offsets: dict[tuple[int, ...], int] = {}
    type_list_sec_off = cur_off()
    for tl in type_lists:
        align4()
        tl_offsets[tl] = cur_off()
        data += struct.pack("<I", len(tl))
        for td in tl:
            data += struct.pack("<H", t_idx[td])
    align4()

    # 2. code_item section
    code_order = [
        "ac_init", "ac_onclick", "ac_run",
        "sa_clinit", "sa_init", "sa_dispatch", "sa_back", "sa_create", "sa_destroy", "sa_resume",
    ]
    code_offsets: dict[str, int] = {}
    code_sec_off = cur_off()
    for k in code_order:
        align4()
        code_offsets[k] = cur_off()
        data += code_items[k]
    align4()

    # 3. string_data_item section
    string_data_sec_off = cur_off()
    string_data_offsets: list[int] = []
    for s in strings:
        string_data_offsets.append(cur_off())
        data += mutf8_encode(s)

    # 4. class_data_item section
    def encode_fields(flist: list[tuple[int, int]]) -> bytes:
        # flist sorted by field_idx: (field_idx, access_flags)
        flist = sorted(flist, key=lambda x: x[0])
        out = bytearray()
        prev = 0
        for fidx, flags in flist:
            assert fidx >= prev
            out += uleb128(fidx - prev) + uleb128(flags)
            prev = fidx
        return bytes(out)

    def encode_methods(mlist: list[tuple[int, int, int]]) -> bytes:
        # mlist sorted by method_idx: (method_idx, access_flags, code_off)
        mlist = sorted(mlist, key=lambda x: x[0])
        out = bytearray()
        prev = 0
        for midx, flags, coff in mlist:
            assert midx >= prev
            out += uleb128(midx - prev) + uleb128(flags) + uleb128(coff)
            prev = midx
        return bytes(out)

    class_data_sec_off = cur_off()

    # ActionClick class_data
    ac_ifields = [
        (fld_host, 0x0011),  # ACC_PUBLIC | ACC_FINAL
        (fld_id, 0x0011),    # ACC_PUBLIC | ACC_FINAL
    ]
    ac_dmethods = [
        (m_idx[(ac_desc, "<init>", "V", (sa_desc, "I"))],
         0x10001, code_offsets["ac_init"]),
    ]
    ac_vmethods = [
        (m_idx[(ac_desc, "onClick", "V", ("Landroid/view/View;",))],
         0x0001, code_offsets["ac_onclick"]),
        (m_idx[(ac_desc, "run", "V", ())],
         0x0001, code_offsets["ac_run"]),
    ]
    ac_class_data_off = cur_off()
    data += (uleb128(0) + uleb128(len(ac_ifields)) + uleb128(len(ac_dmethods)) + uleb128(len(ac_vmethods)) +
             encode_fields(ac_ifields) + encode_methods(ac_dmethods) + encode_methods(ac_vmethods))

    # Activity class_data
    sa_ifields = [
        (f_idx[(sa_desc, "nativePtr", "J")], 0x0002),  # ACC_PRIVATE
    ]
    sa_dmethods = [
        (m_idx[(sa_desc, "<clinit>", "V", ())], 0x10008, code_offsets["sa_clinit"]),
        (m_idx[(sa_desc, "<init>", "V", ())], 0x10001, code_offsets["sa_init"]),
        (m_nat_action, 0x0102, 0),
        (m_nat_back, 0x0102, 0),
        (m_nat_create, 0x0102, 0),
        (m_nat_destroy, 0x0102, 0),
        (m_nat_resume, 0x0102, 0),
    ]
    sa_vmethods = [
        (m_dispatch, 0x0001, code_offsets["sa_dispatch"]),
        (m_idx[(sa_desc, "onBackPressed", "V", ())], 0x0001, code_offsets["sa_back"]),
        (m_idx[(sa_desc, "onCreate", "V", ("Landroid/os/Bundle;",))], 0x0004, code_offsets["sa_create"]),
        (m_idx[(sa_desc, "onDestroy", "V", ())], 0x0004, code_offsets["sa_destroy"]),
        (m_idx[(sa_desc, "onResume", "V", ())], 0x0004, code_offsets["sa_resume"]),
    ]
    sa_class_data_off = cur_off()
    data += (uleb128(0) + uleb128(len(sa_ifields)) + uleb128(len(sa_dmethods)) + uleb128(len(sa_vmethods)) +
             encode_fields(sa_ifields) + encode_methods(sa_dmethods) + encode_methods(sa_vmethods))

    # 5. map_list section (4-byte aligned, sorted by offset ascending!)
    align4()
    map_off = cur_off()
    map_entries = [
        (0x0000, 1, 0),                             # TYPE_HEADER_ITEM
        (0x0001, len(strings), string_ids_off),     # TYPE_STRING_ID_ITEM
        (0x0002, len(type_descs), type_ids_off),    # TYPE_TYPE_ID_ITEM
        (0x0003, len(protos), proto_ids_off),       # TYPE_PROTO_ID_ITEM
        (0x0004, len(fields), field_ids_off),       # TYPE_FIELD_ID_ITEM
        (0x0005, len(methods), method_ids_off),     # TYPE_METHOD_ID_ITEM
        (0x0006, num_classes, class_defs_off),      # TYPE_CLASS_DEF_ITEM
        (0x1001, len(type_lists), type_list_sec_off),   # TYPE_TYPE_LIST
        (0x2001, len(code_order), code_sec_off),        # TYPE_CODE_ITEM
        (0x2002, len(strings), string_data_sec_off),    # TYPE_STRING_DATA_ITEM
        (0x2000, num_classes, class_data_sec_off),      # TYPE_CLASS_DATA_ITEM
        (0x1000, 1, map_off),                           # TYPE_MAP_LIST
    ]
    data += struct.pack("<I", len(map_entries))
    for mtype, msize, moffset in map_entries:
        data += struct.pack("<HHII", mtype, 0, msize, moffset)
    align4()

    # Index tables
    string_ids_bin = b"".join(struct.pack("<I", off) for off in string_data_offsets)
    type_ids_bin = b"".join(struct.pack("<I", s_idx[td]) for td in type_descs)
    proto_ids_bin = b"".join(
        struct.pack("<III", s_idx[shorty], t_idx[ret], tl_offsets[params] if params else 0)
        for shorty, ret, params in protos
    )
    field_ids_bin = b"".join(
        struct.pack("<HHI", t_idx[c], t_idx[ft], s_idx[fn])
        for c, ft, fn in fields
    )
    method_ids_bin = b"".join(
        struct.pack("<HHI", t_idx[c], p_idx[(ret, params)], s_idx[mn])
        for c, ret, params, mn in methods
    )

    NO_INDEX = 0xFFFFFFFF
    class_defs_bin = (
        struct.pack(
            "<IIIIIIII",
            t_idx[ac_desc],
            0x0011,  # ACC_PUBLIC | ACC_FINAL
            t_idx["Ljava/lang/Object;"],
            tl_offsets[ac_ifaces],
            NO_INDEX,
            0,
            ac_class_data_off,
            0,
        ) +
        struct.pack(
            "<IIIIIIII",
            t_idx[sa_desc],
            0x0001,  # ACC_PUBLIC
            t_idx["Landroid/app/Activity;"],
            0,
            NO_INDEX,
            0,
            sa_class_data_off,
            0,
        )
    )

    file_size = data_off + len(data)
    data_size = len(data)

    header_tail = struct.pack(
        "<IIIIIIIIIIIIIIIIIIII",
        file_size,
        header_size,
        0x12345678,  # ENDIAN_CONSTANT
        0, 0,        # link_size, link_off
        map_off,
        len(strings), string_ids_off,
        len(type_descs), type_ids_off,
        len(protos), proto_ids_off,
        len(fields), field_ids_off,
        len(methods), method_ids_off,
        num_classes, class_defs_off,
        data_size, data_off,
    )

    body_after_sig = (
        header_tail +
        string_ids_bin +
        type_ids_bin +
        proto_ids_bin +
        field_ids_bin +
        method_ids_bin +
        class_defs_bin +
        bytes(data)
    )
    assert 32 + len(body_after_sig) == file_size

    sha1_sig = hashlib.sha1(body_after_sig).digest()
    adler = zlib.adler32(sha1_sig + body_after_sig) & 0xFFFFFFFF
    dex = b"dex\n035\x00" + struct.pack("<I", adler) + sha1_sig + body_after_sig
    assert len(dex) == file_size
    return dex


def verify_dex(dex: bytes) -> None:
    assert dex[:8] == b"dex\n035\x00", "Bad DEX magic"
    adler, = struct.unpack_from("<I", dex, 8)
    assert (zlib.adler32(dex[12:]) & 0xFFFFFFFF) == adler, "Bad DEX Adler32"
    assert hashlib.sha1(dex[32:]).digest() == dex[12:32], "Bad DEX SHA-1"

    (file_size, hdr_size, endian, _, _, map_off,
     s_sz, s_off, t_sz, t_off, p_sz, p_off, f_sz, f_off, m_sz, m_off,
     c_sz, c_off, d_sz, d_off) = struct.unpack_from("<20I", dex, 32)
    assert file_size == len(dex) and hdr_size == 0x70 and endian == 0x12345678
    assert d_off + d_sz == file_size

    # Verify strings sorted strictly ascending
    decoded_strings = []
    for i in range(s_sz):
        soff, = struct.unpack_from("<I", dex, s_off + i * 4)
        ulen, p = read_uleb128(dex, soff)
        end = dex.index(0, p)
        s = dex[p:end].decode("utf-8")
        assert len(s) == ulen
        decoded_strings.append(s)
    assert decoded_strings == sorted(decoded_strings), "Strings not sorted!"

    # Verify map_list offsets monotonically non-decreasing
    mcnt, = struct.unpack_from("<I", dex, map_off)
    last_off = -1
    for i in range(mcnt):
        _, _, _, moff = struct.unpack_from("<HHII", dex, map_off + 4 + i * 12)
        assert moff >= last_off, f"map_list out of order at {i}"
        last_off = moff

    # Verify class_defs & code_items
    assert c_sz == 2
    for ci in range(c_sz):
        cidx, _, _, _, _, _, cdata_off, _ = struct.unpack_from("<8I", dex, c_off + ci * 32)
        assert 0 <= cidx < t_sz and d_off <= cdata_off < file_size
        sf, p = read_uleb128(dex, cdata_off)
        inf, p = read_uleb128(dex, p)
        dm, p = read_uleb128(dex, p)
        vm, p = read_uleb128(dex, p)
        for _ in range(sf + inf):
            _, p = read_uleb128(dex, p)
            _, p = read_uleb128(dex, p)
        for _ in range(dm + vm):
            _, p = read_uleb128(dex, p)
            mflags, p = read_uleb128(dex, p)
            coff, p = read_uleb128(dex, p)
            if mflags & 0x0100:  # ACC_NATIVE
                assert coff == 0
            else:
                assert coff % 4 == 0 and d_off <= coff < file_size
                regs, ins_sz, outs_sz, tries, _, insns_sz = struct.unpack_from("<HHHHII", dex, coff)
                assert regs >= ins_sz and tries == 0 and insns_sz >= 2


# ==============================================================================
# 2. Binary AndroidManifest.xml + resources.arsc + 16KB-Aligned Signed APK
# ==============================================================================

def pack_utf16_string_pool(strings: list[str]) -> bytes:
    offsets = []
    pool_data = bytearray()
    for s in strings:
        offsets.append(len(pool_data))
        u16 = s.encode("utf-16le")
        char_len = len(s)
        pool_data += struct.pack("<H", char_len) + u16 + b"\x00\x00"
    while len(pool_data) % 4:
        pool_data += b"\x00"
    header_size = 28
    strings_start = header_size + 4 * len(strings)
    chunk_size = strings_start + len(pool_data)
    hdr = struct.pack("<HHIIIIII", 0x0001, header_size, chunk_size, len(strings), 0, 0, strings_start, 0)
    offs = b"".join(struct.pack("<I", o) for o in offsets)
    return hdr + offs + bytes(pool_data)


def build_setup_manifest(icon_res_id: int) -> bytes:
    ANDROID_NS = "http://schemas.android.com/apk/res/android"
    # Attribute names with exact Android 17 public resource IDs (sorted by res ID ascending)
    attr_defs = [
        ("label",             0x01010001),
        ("icon",              0x01010002),
        ("name",              0x01010003),
        ("exported",          0x01010010),
        ("excludeFromRecents", 0x01010017),
        ("launchMode",        0x0101001d),
        ("configChanges",     0x0101001f),
        ("minSdkVersion",     0x0101020c),
        ("versionCode",       0x0101021b),
        ("versionName",       0x0101021c),
        ("targetSdkVersion",  0x01010270),
        ("hardwareAccelerated", 0x010102d3),
        ("extractNativeLibs", 0x010104ea),
    ]
    strings = [name for name, _ in attr_defs]
    res_ids = [rid for _, rid in attr_defs]

    extra = [
        ANDROID_NS,
        "android",
        "manifest",
        "package",
        "org.fidebookos.setup",
        "1.25",
        "uses-sdk",
        "uses-permission",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.ACCESS_WIFI_STATE",
        "android.permission.BLUETOOTH",
        "android.permission.BLUETOOTH_CONNECT",
        "application",
        "FideBook Setup",
        "activity",
        "org.fidebookos.setup.SetupActivity",
        "intent-filter",
        "action",
        "android.intent.action.MAIN",
        "category",
        "android.intent.category.LAUNCHER",
        "android.intent.category.DEFAULT",
    ]
    for s in extra:
        if s not in strings:
            strings.append(s)
    idx = {s: i for i, s in enumerate(strings)}

    sp_chunk = pack_utf16_string_pool(strings)
    rm_size = 8 + 4 * len(res_ids)
    rm_chunk = struct.pack("<HHI", 0x0180, 8, rm_size) + b"".join(struct.pack("<I", r) for r in res_ids)

    TYPE_REFERENCE = 0x01
    TYPE_STRING = 0x03
    TYPE_INT_DEC = 0x10
    TYPE_INT_HEX = 0x11
    TYPE_INT_BOOL = 0x12

    def attr_str(ns: str | None, name: str, val: str) -> bytes:
        ns_i = idx[ns] if ns else -1
        v_i = idx[val]
        return struct.pack("<iiihBBi", ns_i, idx[name], v_i, 8, 0, TYPE_STRING, v_i)

    def attr_int(ns: str | None, name: str, dtype: int, val: int) -> bytes:
        ns_i = idx[ns] if ns else -1
        return struct.pack("<iiihBBi", ns_i, idx[name], -1, 8, 0, dtype, val)

    def start_elem(name: str, attrs: list[bytes], line: int = 1) -> bytes:
        body = b"".join(attrs)
        return struct.pack("<HHIIIiiHHHHHH", 0x0102, 16, 36 + len(body), line, 0xFFFFFFFF,
                           -1, idx[name], 0x14, 0x14, len(attrs), 0, 0, 0) + body

    def end_elem(name: str, line: int = 1) -> bytes:
        return struct.pack("<HHIIIii", 0x0103, 16, 24, line, 0xFFFFFFFF, -1, idx[name])

    ns_start = struct.pack("<HHIIIii", 0x0100, 16, 24, 1, 0xFFFFFFFF, idx["android"], idx[ANDROID_NS])
    ns_end = struct.pack("<HHIIIii", 0x0101, 16, 24, 1, 0xFFFFFFFF, idx["android"], idx[ANDROID_NS])

    perms = [
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.ACCESS_WIFI_STATE",
        "android.permission.BLUETOOTH",
        "android.permission.BLUETOOTH_CONNECT",
    ]
    perm_nodes = b"".join(
        start_elem("uses-permission", [attr_str(ANDROID_NS, "name", p)], 3) + end_elem("uses-permission", 3)
        for p in perms
    )

    xml_nodes = (
        ns_start +
        start_elem("manifest", [
            attr_int(ANDROID_NS, "versionCode", TYPE_INT_DEC, 125),
            attr_str(ANDROID_NS, "versionName", "1.25"),
            attr_str(None, "package", "org.fidebookos.setup"),
        ], 1) +
        start_elem("uses-sdk", [
            attr_int(ANDROID_NS, "minSdkVersion", TYPE_INT_DEC, 33),
            attr_int(ANDROID_NS, "targetSdkVersion", TYPE_INT_DEC, 35),
        ], 2) +
        end_elem("uses-sdk", 2) +
        perm_nodes +
        start_elem("application", [
            attr_str(ANDROID_NS, "label", "FideBook Setup"),
            attr_int(ANDROID_NS, "icon", TYPE_REFERENCE, icon_res_id),
            attr_int(ANDROID_NS, "hardwareAccelerated", TYPE_INT_BOOL, -1),
            attr_int(ANDROID_NS, "extractNativeLibs", TYPE_INT_BOOL, 0),  # false -> direct 16KB mmap from APK!
        ], 4) +
        start_elem("activity", [
            attr_str(ANDROID_NS, "label", "FideBook Setup"),
            attr_str(ANDROID_NS, "name", "org.fidebookos.setup.SetupActivity"),
            attr_int(ANDROID_NS, "exported", TYPE_INT_BOOL, -1),
            attr_int(ANDROID_NS, "excludeFromRecents", TYPE_INT_BOOL, -1),
            attr_int(ANDROID_NS, "launchMode", TYPE_INT_DEC, 2),  # singleTask
            attr_int(ANDROID_NS, "configChanges", TYPE_INT_HEX, 0x1FB0),
        ], 5) +
        start_elem("intent-filter", [], 6) +
        start_elem("action", [attr_str(ANDROID_NS, "name", "android.intent.action.MAIN")], 7) +
        end_elem("action", 7) +
        start_elem("category", [attr_str(ANDROID_NS, "name", "android.intent.category.DEFAULT")], 9) +
        end_elem("category", 9) +
        end_elem("intent-filter", 6) +
        end_elem("activity", 5) +
        end_elem("application", 4) +
        end_elem("manifest", 1) +
        ns_end
    )

    total = 8 + len(sp_chunk) + len(rm_chunk) + len(xml_nodes)
    return struct.pack("<HHI", 0x0003, 8, total) + sp_chunk + rm_chunk + xml_nodes


def build_visual_manifest(icon_res_id: int) -> bytes:
    """Build AndroidManifest.xml for FideBookVisualSettings.apk (injected into Android Settings
    Display & touch AND Settings Homepage via com.android.settings.action.IA_SETTINGS)."""
    ANDROID_NS = "http://schemas.android.com/apk/res/android"
    attr_defs = [
        ("label",               0x01010001),
        ("icon",                0x01010002),
        ("name",                0x01010003),
        ("enabled",             0x0101000e),
        ("exported",            0x01010010),
        ("configChanges",       0x0101001f),
        ("value",               0x01010024),
        ("resource",            0x01010025),
        ("targetActivity",      0x01010202),
        ("minSdkVersion",       0x0101020c),
        ("versionCode",         0x0101021b),
        ("versionName",         0x0101021c),
        ("targetSdkVersion",    0x01010270),
        ("hardwareAccelerated", 0x010102d3),
        ("extractNativeLibs",   0x010104ea),
    ]
    strings = [name for name, _ in attr_defs]
    res_ids = [rid for _, rid in attr_defs]

    extra = [
        ANDROID_NS,
        "android",
        "manifest",
        "package",
        "org.fidebookos.settings.visual",
        "1.25",
        "uses-sdk",
        "application",
        "Liquid Glass & Motion",
        "activity",
        "activity-alias",
        "meta-data",
        "org.fidebookos.settings.visual.VisualActivity",
        "org.fidebookos.settings.visual.VisualHomepageEntry",
        "intent-filter",
        "action",
        "category",
        "com.android.settings.action.IA_SETTINGS",
        "com.android.settings.action.EXTRA_SETTINGS",
        "android.intent.category.DEFAULT",
        "com.android.settings.category",
        "com.android.settings.category.ia.display",
        "com.android.settings.category.ia.homepage",
        "com.android.settings.title",
        "com.android.settings.summary",
        "com.android.settings.keyhint",
        "com.android.settings.icon",
        "Taskbar, Control Center & App Menu refraction and 60 FPS scroll blur",
        "Refractive glass & motion blur",
        "fidebook_liquid_glass_display",
        "fidebook_liquid_glass_home",
    ]
    for s in extra:
        if s not in strings:
            strings.append(s)
    idx = {s: i for i, s in enumerate(strings)}

    sp_chunk = pack_utf16_string_pool(strings)
    rm_size = 8 + 4 * len(res_ids)
    rm_chunk = struct.pack("<HHI", 0x0180, 8, rm_size) + b"".join(struct.pack("<I", r) for r in res_ids)

    TYPE_REFERENCE = 0x01
    TYPE_STRING = 0x03
    TYPE_INT_DEC = 0x10
    TYPE_INT_HEX = 0x11
    TYPE_INT_BOOL = 0x12

    def attr_str(ns: str | None, name: str, val: str) -> bytes:
        ns_i = idx[ns] if ns else -1
        v_i = idx[val]
        return struct.pack("<iiihBBi", ns_i, idx[name], v_i, 8, 0, TYPE_STRING, v_i)

    def attr_int(ns: str | None, name: str, dtype: int, val: int) -> bytes:
        ns_i = idx[ns] if ns else -1
        return struct.pack("<iiihBBi", ns_i, idx[name], -1, 8, 0, dtype, val)

    def start_elem(name: str, attrs: list[bytes], line: int = 1) -> bytes:
        body = b"".join(attrs)
        return struct.pack("<HHIIIiiHHHHHH", 0x0102, 16, 36 + len(body), line, 0xFFFFFFFF,
                           -1, idx[name], 0x14, 0x14, len(attrs), 0, 0, 0) + body

    def end_elem(name: str, line: int = 1) -> bytes:
        return struct.pack("<HHIIIii", 0x0103, 16, 24, line, 0xFFFFFFFF, -1, idx[name])

    def meta_str(mname: str, mval: str) -> bytes:
        return start_elem("meta-data", [
            attr_str(ANDROID_NS, "name", mname),
            attr_str(ANDROID_NS, "value", mval),
        ], 8) + end_elem("meta-data", 8)

    def meta_res(mname: str, rid: int) -> bytes:
        return start_elem("meta-data", [
            attr_str(ANDROID_NS, "name", mname),
            attr_int(ANDROID_NS, "resource", TYPE_REFERENCE, rid),
        ], 8) + end_elem("meta-data", 8)

    ns_start = struct.pack("<HHIIIii", 0x0100, 16, 24, 1, 0xFFFFFFFF, idx["android"], idx[ANDROID_NS])
    ns_end = struct.pack("<HHIIIii", 0x0101, 16, 24, 1, 0xFFFFFFFF, idx["android"], idx[ANDROID_NS])

    ia_filter = (
        start_elem("intent-filter", [], 6) +
        start_elem("action", [attr_str(ANDROID_NS, "name", "com.android.settings.action.IA_SETTINGS")], 7) +
        end_elem("action", 7) +
        start_elem("category", [attr_str(ANDROID_NS, "name", "android.intent.category.DEFAULT")], 7) +
        end_elem("category", 7) +
        end_elem("intent-filter", 6)
    )

    xml_nodes = (
        ns_start +
        start_elem("manifest", [
            attr_int(ANDROID_NS, "versionCode", TYPE_INT_DEC, 125),
            attr_str(ANDROID_NS, "versionName", "1.25"),
            attr_str(None, "package", "org.fidebookos.settings.visual"),
        ], 1) +
        start_elem("uses-sdk", [
            attr_int(ANDROID_NS, "minSdkVersion", TYPE_INT_DEC, 33),
            attr_int(ANDROID_NS, "targetSdkVersion", TYPE_INT_DEC, 35),
        ], 2) +
        end_elem("uses-sdk", 2) +
        start_elem("application", [
            attr_str(ANDROID_NS, "label", "Liquid Glass & Motion"),
            attr_int(ANDROID_NS, "icon", TYPE_REFERENCE, icon_res_id),
            attr_int(ANDROID_NS, "hardwareAccelerated", TYPE_INT_BOOL, -1),
            attr_int(ANDROID_NS, "extractNativeLibs", TYPE_INT_BOOL, 0),
        ], 4) +
        # 1. Settings -> Display & touch entry
        start_elem("activity", [
            attr_str(ANDROID_NS, "label", "Liquid Glass & Motion"),
            attr_int(ANDROID_NS, "icon", TYPE_REFERENCE, icon_res_id),
            attr_str(ANDROID_NS, "name", "org.fidebookos.settings.visual.VisualActivity"),
            attr_int(ANDROID_NS, "enabled", TYPE_INT_BOOL, -1),
            attr_int(ANDROID_NS, "exported", TYPE_INT_BOOL, -1),
            attr_int(ANDROID_NS, "configChanges", TYPE_INT_HEX, 0x1FB0),
        ], 5) +
        ia_filter +
        meta_str("com.android.settings.category", "com.android.settings.category.ia.display") +
        meta_str("com.android.settings.title", "Liquid Glass & Motion") +
        meta_str("com.android.settings.summary", "Taskbar, Control Center & App Menu refraction and 60 FPS scroll blur") +
        meta_str("com.android.settings.keyhint", "fidebook_liquid_glass_display") +
        meta_res("com.android.settings.icon", icon_res_id) +
        end_elem("activity", 5) +
        # 2. Settings Homepage sidebar entry
        start_elem("activity-alias", [
            attr_str(ANDROID_NS, "label", "Liquid Glass & Motion"),
            attr_int(ANDROID_NS, "icon", TYPE_REFERENCE, icon_res_id),
            attr_str(ANDROID_NS, "name", "org.fidebookos.settings.visual.VisualHomepageEntry"),
            attr_int(ANDROID_NS, "enabled", TYPE_INT_BOOL, -1),
            attr_int(ANDROID_NS, "exported", TYPE_INT_BOOL, -1),
            attr_str(ANDROID_NS, "targetActivity", "org.fidebookos.settings.visual.VisualActivity"),
        ], 9) +
        ia_filter +
        meta_str("com.android.settings.category", "com.android.settings.category.ia.homepage") +
        meta_str("com.android.settings.title", "Liquid Glass & Motion") +
        meta_str("com.android.settings.summary", "Refractive glass & motion blur") +
        meta_str("com.android.settings.keyhint", "fidebook_liquid_glass_home") +
        meta_res("com.android.settings.icon", icon_res_id) +
        end_elem("activity-alias", 9) +
        end_elem("application", 4) +
        end_elem("manifest", 1) +
        ns_end
    )

    total = 8 + len(sp_chunk) + len(rm_chunk) + len(xml_nodes)
    return struct.pack("<HHI", 0x0003, 8, total) + sp_chunk + rm_chunk + xml_nodes


def build_arsc(pkg_name: str, icon_path: str) -> bytes:
    global_sp = pack_utf16_string_pool([icon_path])
    type_sp = pack_utf16_string_pool(["drawable"])
    key_sp = pack_utf16_string_pool(["ic_fidebook_setup"])

    spec_hdr = struct.pack("<HHIBBHI", 0x0202, 16, 20, 1, 0, 0, 1)
    spec_chunk = spec_hdr + struct.pack("<I", 0x00000000)

    cfg = bytearray(64)
    struct.pack_into("<I", cfg, 0, 64)
    struct.pack_into("<H", cfg, 14, 0)       # default density (matches all DPIs & locales)
    struct.pack_into("<H", cfg, 24, 0)       # sdkVersion = 0

    entry = struct.pack("<HHIhBBi", 8, 0, 0, 8, 0, 0x03, 0)
    type_header_size = 20 + len(cfg)
    entries_start = type_header_size + 4
    type_chunk_size = entries_start + len(entry)
    type_hdr = struct.pack("<HHIBBHII", 0x0201, type_header_size, type_chunk_size, 1, 0, 0, 1, entries_start) + bytes(cfg)
    type_chunk = type_hdr + struct.pack("<I", 0) + entry

    pkg_hdr_size = 288
    pkg_name_u16 = pkg_name.encode("utf-16le").ljust(256, b"\x00")[:256]
    type_strings_off = pkg_hdr_size
    key_strings_off = pkg_hdr_size + len(type_sp)
    pkg_body = type_sp + key_sp + spec_chunk + type_chunk
    pkg_chunk_size = pkg_hdr_size + len(pkg_body)
    pkg_hdr = (
        struct.pack("<HHI", 0x0200, pkg_hdr_size, pkg_chunk_size) +
        struct.pack("<I", 0x7F) +
        pkg_name_u16 +
        struct.pack("<IIIII", type_strings_off, 1, key_strings_off, 1, 0)
    )
    pkg_chunk = pkg_hdr + pkg_body

    table_size = 12 + len(global_sp) + len(pkg_chunk)
    return struct.pack("<HHII", 0x0002, 12, table_size, 1) + global_sp + pkg_chunk


def write_aligned_zip(entries: list[tuple[str, bytes, bool, int]]) -> bytes:
    """
    entries: list of (filename, data, compress, alignment_bytes)
    Writes a clean ZIP archive where uncompressed entries (e.g. resources.arsc -> 4B,
    lib/x86_64/libfidebook_setup.so -> 16384B) have their data payload aligned to `alignment_bytes`!
    """
    out = bytearray()
    central_dir = bytearray()

    for name, raw_data, do_compress, align in entries:
        name_bytes = name.encode("utf-8")
        crc = zlib.crc32(raw_data) & 0xFFFFFFFF
        uncomp_size = len(raw_data)
        if do_compress:
            comp_obj = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
            payload = comp_obj.compress(raw_data) + comp_obj.flush()
            method = 8
        else:
            payload = raw_data
            method = 0
        comp_size = len(payload)

        local_hdr_off = len(out)
        extra = b""
        if not do_compress and align > 1:
            base_data_off = local_hdr_off + 30 + len(name_bytes)
            rem = base_data_off % align
            if rem != 0:
                pad_needed = (align - rem) % align
                if pad_needed < 4:
                    pad_needed += align
                # Zipalign extra field ID 0xD935 (Android zipalign standard)
                extra = struct.pack("<HH", 0xD935, pad_needed - 4) + (b"\x00" * (pad_needed - 4))
            assert (local_hdr_off + 30 + len(name_bytes) + len(extra)) % align == 0

        lfh = struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50,
            20,
            0,
            method,
            0, 0x2100,  # DOS date 1996-08-00 deterministic
            crc,
            comp_size,
            uncomp_size,
            len(name_bytes),
            len(extra),
        )
        out += lfh + name_bytes + extra
        if not do_compress and align > 1:
            assert len(out) % align == 0, f"{name} data offset {len(out)} not {align}-aligned!"
        out += payload

        cdfh = struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50,
            20, 20,
            0,
            method,
            0, 0x2100,
            crc,
            comp_size,
            uncomp_size,
            len(name_bytes),
            0, 0, 0, 0, 0,
            local_hdr_off,
        )
        central_dir += cdfh + name_bytes

    cd_off = len(out)
    cd_size = len(central_dir)
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), cd_size, cd_off, 0)
    return bytes(out) + bytes(central_dir) + eocd


def sign_apk_v1_v2(unsigned_entries: list[tuple[str, bytes, bool, int]], key_pem: Path, cert_der: bytes) -> bytes:
    import base64

    # 1. Build JAR v1 META-INF files
    mf_lines = ["Manifest-Version: 1.0", "Created-By: FideBookOS 1.0", ""]
    sf_entries = []
    for name, data, _, _ in unsigned_entries:
        d_b64 = base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")
        section = f"Name: {name}\r\nSHA-256-Digest: {d_b64}\r\n\r\n"
        mf_lines.append(f"Name: {name}")
        mf_lines.append(f"SHA-256-Digest: {d_b64}")
        mf_lines.append("")
        sf_d = base64.b64encode(hashlib.sha256(section.encode("utf-8")).digest()).decode("ascii")
        sf_entries.append(f"Name: {name}\r\nSHA-256-Digest: {sf_d}\r\n\r\n")

    mf_bytes = "\r\n".join(mf_lines).encode("utf-8") + b"\r\n"
    mf_digest = base64.b64encode(hashlib.sha256(mf_bytes).digest()).decode("ascii")
    sf_header = (
        "Signature-Version: 1.0\r\n"
        f"SHA-256-Digest-Manifest: {mf_digest}\r\n"
        "X-Android-APK-Signed: 2\r\n\r\n"
    )
    sf_bytes = sf_header.encode("utf-8") + "".join(sf_entries).encode("utf-8")

    with tempfile.TemporaryDirectory() as td:
        sf_file = Path(td) / "CERT.SF"
        cert_der_tmp = Path(td) / "cert.der"
        cert_pem = Path(td) / "cert.pem"
        rsa_file = Path(td) / "CERT.RSA"
        sf_file.write_bytes(sf_bytes)
        cert_der_tmp.write_bytes(cert_der)
        subprocess.run(["openssl", "x509", "-inform", "DER", "-in", str(cert_der_tmp), "-out", str(cert_pem)],
                       check=True)
        subprocess.run([
            "openssl", "cms", "-sign", "-binary", "-noattr",
            "-in", str(sf_file), "-signer", str(cert_pem), "-inkey", str(key_pem),
            "-outform", "DER", "-out", str(rsa_file), "-md", "sha256"
        ], check=True)
        rsa_bytes = rsa_file.read_bytes()

    all_entries = list(unsigned_entries) + [
        ("META-INF/MANIFEST.MF", mf_bytes, True, 1),
        ("META-INF/CERT.SF", sf_bytes, True, 1),
        ("META-INF/CERT.RSA", rsa_bytes, True, 1),
    ]
    raw_zip = write_aligned_zip(all_entries)

    # 2. Inject APK Signature Scheme v2 Block (0x7109871A)
    eocd_pos = raw_zip.rfind(b"PK\x05\x06")
    cd_size, cd_offset = struct.unpack_from("<II", raw_zip, eocd_pos + 12)
    before_cd = raw_zip[:cd_offset]
    cd = raw_zip[cd_offset:eocd_pos]
    eocd = bytearray(raw_zip[eocd_pos:])

    def chunk_digests(sections: list[bytes]) -> bytes:
        chunk_hashes = []
        for sec in sections:
            pos = 0
            n = len(sec)
            while pos < n:
                chunk = sec[pos:pos + 1048576]
                h = hashlib.sha256(b"\xa5" + struct.pack("<I", len(chunk)) + chunk).digest()
                chunk_hashes.append(h)
                pos += 1048576
        top_input = b"\x5a" + struct.pack("<I", len(chunk_hashes)) + b"".join(chunk_hashes)
        return hashlib.sha256(top_input).digest()

    eocd_for_hash = bytearray(eocd)
    struct.pack_into("<I", eocd_for_hash, 16, cd_offset)
    top_digest = chunk_digests([before_cd, cd, bytes(eocd_for_hash)])

    def lp(b: bytes) -> bytes:
        return struct.pack("<I", len(b)) + b

    ALGO_RSA_PKCS1_V1_5_SHA256 = 0x0103
    digest_entry = lp(struct.pack("<I", ALGO_RSA_PKCS1_V1_5_SHA256) + lp(top_digest))
    digests_seq = lp(digest_entry)
    certs_seq = lp(lp(cert_der))
    additional_attrs = lp(b"")
    signed_data = digests_seq + certs_seq + additional_attrs

    with tempfile.TemporaryDirectory() as td:
        sd_path = Path(td) / "sd.bin"
        sig_path = Path(td) / "sig.bin"
        pubkey_path = Path(td) / "pub.der"
        sd_path.write_bytes(signed_data)
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_pem), "-out", str(sig_path), str(sd_path)], check=True)
        subprocess.run(["openssl", "pkey", "-in", str(key_pem), "-pubout", "-outform", "DER", "-out", str(pubkey_path)], check=True)
        sig_bytes = sig_path.read_bytes()
        pubkey_der = pubkey_path.read_bytes()

    sig_entry = lp(struct.pack("<I", ALGO_RSA_PKCS1_V1_5_SHA256) + lp(sig_bytes))
    signatures_seq = lp(sig_entry)
    signer = lp(lp(signed_data) + signatures_seq + lp(pubkey_der))
    v2_value = lp(signer)

    pair = struct.pack("<QI", 4 + len(v2_value), 0x7109871A) + v2_value
    rem = (len(pair) + 8 + 24) % 4096
    if rem != 0:
        pad_total = 4096 - rem
        if pad_total < 12:
            pad_total += 4096
        pad_val = b"\x00" * (pad_total - 12)
        pad_pair = struct.pack("<QI", 4 + len(pad_val), 0x42726577) + pad_val
        pairs = pair + pad_pair
    else:
        pairs = pair

    size_of_block = len(pairs) + 24
    apk_sig_block = struct.pack("<Q", size_of_block) + pairs + struct.pack("<Q", size_of_block) + b"APK Sig Block 42"
    new_cd_offset = len(before_cd) + len(apk_sig_block)
    struct.pack_into("<I", eocd, 16, new_cd_offset)
    return before_cd + apk_sig_block + cd + bytes(eocd)


def main() -> None:
    if not NATIVE_SO.is_file():
        sys.exit(f"Missing {NATIVE_SO}: compile libfidebook_setup.so first")
    if not VISUAL_SO.is_file():
        sys.exit(f"Missing {VISUAL_SO}: compile libfidebook_visual.so first")
    if not LOGO_ALPHA.is_file():
        sys.exit(f"Missing {LOGO_ALPHA}: run tools/build_fidebook_branding.py first")

    dex_bytes = build_classes_dex("org/fidebookos/setup", "SetupActivity", "fidebook_setup")
    verify_dex(dex_bytes)
    visual_dex_bytes = build_classes_dex("org/fidebookos/settings/visual", "VisualActivity", "fidebook_visual")
    verify_dex(visual_dex_bytes)
    print(f"Verified classes.dex (setup={len(dex_bytes):,}B, visual={len(visual_dex_bytes):,}B): DEX 035 checks PASS")

    icon_path = "res/drawable/ic_fidebook_setup.png"
    icon_img = Image.open(LOGO_ALPHA).convert("RGBA").resize((96, 96), Image.Resampling.LANCZOS)
    icon_buf = io.BytesIO()
    icon_img.save(icon_buf, format="PNG", optimize=True)
    icon_bytes = icon_buf.getvalue()

    axml_bytes = build_setup_manifest(0x7F010000)
    arsc_bytes = build_arsc("org.fidebookos.setup", icon_path)
    so_bytes = NATIVE_SO.read_bytes()

    visual_axml = build_visual_manifest(0x7F010000)
    visual_arsc = build_arsc("org.fidebookos.settings.visual", icon_path)
    visual_so_bytes = VISUAL_SO.read_bytes()

    entries = [
        ("AndroidManifest.xml", axml_bytes, True, 1),
        ("classes.dex", dex_bytes, True, 1),
        ("resources.arsc", arsc_bytes, False, 4),
        (icon_path, icon_bytes, False, 4),
        ("lib/x86_64/libfidebook_setup.so", so_bytes, False, 16384),
    ]
    visual_entries = [
        ("AndroidManifest.xml", visual_axml, True, 1),
        ("classes.dex", visual_dex_bytes, True, 1),
        ("resources.arsc", visual_arsc, False, 4),
        (icon_path, icon_bytes, False, 4),
        ("lib/x86_64/libfidebook_visual.so", visual_so_bytes, False, 16384),
    ]

    with tempfile.TemporaryDirectory() as td:
        key_pem = Path(td) / "setup_key.pem"
        cert_der_path = Path(td) / "setup_cert.der"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key_pem), "-outform", "DER", "-out", str(cert_der_path),
            "-days", "10000", "-subj", "/CN=FideBookOS/O=FideBook/C=US"
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cert_der = cert_der_path.read_bytes()
        signed_apk = sign_apk_v1_v2(entries, key_pem, cert_der)
        signed_visual_apk = sign_apk_v1_v2(visual_entries, key_pem, cert_der)

    OUT_APK.parent.mkdir(parents=True, exist_ok=True)
    OUT_APK.write_bytes(signed_apk)
    OUT_VISUAL_APK.write_bytes(signed_visual_apk)

    import zipfile
    for apk_blob, so_rel, out_p in (
        (signed_apk, "lib/x86_64/libfidebook_setup.so", OUT_APK),
        (signed_visual_apk, "lib/x86_64/libfidebook_visual.so", OUT_VISUAL_APK),
    ):
        with zipfile.ZipFile(io.BytesIO(apk_blob), "r") as zf:
            so_info = zf.getinfo(so_rel)
            arsc_info = zf.getinfo("resources.arsc")
            assert so_info.compress_type == zipfile.ZIP_STORED
            assert arsc_info.compress_type == zipfile.ZIP_STORED
            for inf, req_align in ((so_info, 16384), (arsc_info, 4)):
                off = inf.header_offset
                fname_len, extra_len = struct.unpack_from("<HH", apk_blob, off + 26)
                data_off = off + 30 + fname_len + extra_len
                assert data_off % req_align == 0, f"{inf.filename} data_off={data_off} not {req_align}-aligned!"
        print(f"Built signed {out_p.name} -> {out_p} ({len(apk_blob):,} bytes, 16KB-aligned native lib + APK Sig v2 PASS)")


if __name__ == "__main__":
    main()
