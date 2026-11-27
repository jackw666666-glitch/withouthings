"""Brick guards for firmware pushes and raw commands — NUC-side twin of wpp/src/fw_guard.rs
(~/APPLICATIONS/WRIST). Keep the two in step; test_fw_guard.py checks both against the real images.
Why: research/FIRMWARE_MOD.md §14. A wrong-watch package passes every bootloader check and makes the
watch rewrite its own bootloader/MBR/SoftDevice = permanent brick. Odd SW1 versions are 'gold'."""
import struct, zlib

BANK_CAPACITY = 0x119000

# ie, address, length, crc (None = appl, may change), version
PROFILES = {
    "scanwatch": dict(entries=[(1, 0x44, 0xa93fc, None, None),
                               (4, 0xa9440, 0x4000, 0xa7199aa2, 6),
                               (8, 0xad440, 0x26598, 0x4a5277b8, 202)],
                      trailer=0xa93f8, even=True, confirm=True),
    "steelhr": dict(entries=[(1, 0x58, 0x540c4, None, None),
                             (4, 0x5411c, 0x4000, 0x380c382a, 27),
                             (7, 0x5811c, 0xa72d, 0xf3c2782b, 0x5002),
                             (8, 0x6284c, 0x1b358, 0x81916595, 195)],
                    trailer=None, even=False, confirm=False),
}
NAMES = {1: "appl", 4: "bootloader", 7: "resources", 8: "softdevice"}

SCANWATCH_RAW_DENY = {284: "HANDS_MOVE", 286: "HANDS_CAL_START", 287: "HANDS_CAL_STOP", 291: "FACTORY_RESET",
                      294: "RESTART_TO_UPDATE", 337: "REBOOT", 343: "RAW_DATA erase", 516: "GPIO", 526: "SPIFLASH",
                      1025: "UP_FIRMWARE_START", 1026: "UP_FIRMWARE_ACK", 1027: "UP_FIRMWARE_REBOOT",
                      1041: "NETUPDATE_REBOOT", 2349: "CALIBRATION_SET", 2386: "SPI_FLASH", 2407: "FW_AVAILABLE",
                      2408: "REQUEST_FW_CHUNK", 2416: "FACTORY_MODE_SET", 2418: "HAND_UNBLOCK_TRACKER",
                      2422: "HANDS_CAL_CANCEL", 2433: "DIGITAL_CROWN_CALIB", 2444: "BOOTSTRAP_REBOOT",
                      2475: "TRACKER_MOVE_HANDS_SET", 2483: "FACTORY_TEST"}


class Refused(Exception):
    pass


def check_image(watch, img):
    """Return (appl_version, appl_crc, package_len, confirm_token) or raise Refused."""
    p = PROFILES.get(watch)
    if p is None:
        raise Refused(f"no firmware profile for watch '{watch}'")
    if len(img) > BANK_CAPACITY:
        raise Refused(f"{len(img):#x} bytes is larger than one bank")
    if len(img) < 8:
        raise Refused("too short to be a package")
    ver, body = struct.unpack_from("<HH", img, 0)
    if ver != 1:
        raise Refused(f"header version {ver}")
    if body != 20 * len(p["entries"]):
        raise Refused(f"header has {body} bytes of entries, {watch} stock has {20 * len(p['entries'])}: wrong watch?")
    if struct.unpack_from("<I", img, 4 + body)[0] != zlib.crc32(img[:4 + body]):
        raise Refused("header CRC wrong")
    end, appl = 0, None
    for i, (ie_w, a_w, l_w, c_w, v_w) in enumerate(p["entries"]):
        at = 4 + 20 * i
        ie, elen = struct.unpack_from("<HH", img, at)
        a, l, c, v = struct.unpack_from("<IIII", img, at + 4)
        name = NAMES.get(ie, "unknown")
        if ie != ie_w or elen != 16:
            raise Refused(f"entry {i} is ie={ie}; {watch} stock has ie={ie_w}: wrong watch or altered header")
        if a != a_w or l != l_w:
            raise Refused(f"{name} at {a:#x} len {l:#x}; {watch} stock {a_w:#x} len {l_w:#x}: wrong watch or altered part")
        part = img[a:a + ((l + 3) & ~3)]
        if len(part) != (l + 3) & ~3:
            raise Refused(f"{name} runs past the end")
        if zlib.crc32(part) != c:
            raise Refused(f"{name} CRC {c:#010x} in header does not match its bytes")
        if c_w is not None and c != c_w:
            raise Refused(f"{name} CRC {c:#010x} is not {watch}'s installed {name} ({c_w:#010x}): bootloader would rewrite it (BRICK RISK)")
        if v_w is not None and v != v_w:
            raise Refused(f"{name} version {v} is not {watch}'s stock {v_w}")
        if ie == 1:
            appl = (v, c, a)
        end = max(end, a + l)
    if any(b != 0xff for b in img[end:]):
        raise Refused(f"non-0xFF bytes after the package end {end:#x}")
    v, c, a = appl
    if p["trailer"] is not None and struct.unpack_from("<I", img, a + p["trailer"])[0] != v:
        raise Refused("appl version trailer disagrees with the header")
    if p["even"] and v % 2:
        raise Refused(f"appl version {v} is odd = 'gold' on {watch}: would replace stock as the fallback. Use an even version")
    return v, c, end, (f"{watch}-{c:08x}" if p["confirm"] else "")


def check_raw(watch, frames):
    """Raise Refused if a raw blob for `watch` holds a blocked opcode or is malformed."""
    if watch != "scanwatch":
        return
    if not frames:
        raise Refused("empty raw command")
    at = 0
    while at < len(frames):
        if len(frames) - at < 5:
            raise Refused(f"{len(frames) - at} stray bytes after the last frame")
        cmd, ln = struct.unpack_from(">HH", frames, at + 1)
        op = cmd & 0x3fff
        if op in SCANWATCH_RAW_DENY:
            raise Refused(f"opcode {op} ({SCANWATCH_RAW_DENY[op]}) is blocked for the ScanWatch")
        at += 5 + ln
        if at > len(frames):
            raise Refused("frame length runs past the end")
