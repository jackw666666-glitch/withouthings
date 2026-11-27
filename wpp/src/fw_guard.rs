//! Brick guards for firmware pushes and raw commands. See research/FIRMWARE_MOD.md §14.
//!
//! The watch bootloaders check almost nothing: no signature, no model or hardware id. A ScanWatch 1
//! takes a Steel HR (or ScanWatch 2) package as valid, and because that package's bootloader and
//! SoftDevice CRCs differ from what is installed, it rewrites its own bootloader, MBR and SoftDevice
//! with the wrong watch's code: a permanent brick. Nothing on the watch prevents it, so the phone
//! must refuse it here, before the first byte leaves.
//!
//! Per watch, an image is accepted only when it is that watch's own stock layout with only the
//! application changed:
//! - header version 1, header CRC and every component CRC correct (zlib CRC32),
//! - exactly the stock component list, in order, at the stock addresses,
//! - bootloader, SoftDevice (and any resource part) identical to stock: same length, CRC and version,
//!   so the bootloader never takes its rewrite-bootloader / rewrite-MBR+SoftDevice path,
//! - application the stock length (in-place patches only),
//! - anything after the package is 0xFF padding and the whole fits one bank,
//! - ScanWatch 1 only: the version trailer at the end of the appl part equals the header version,
//!   and the version is EVEN. An odd appl version is "gold" to the SW1 bootloader and app: the next
//!   update would overwrite the stock bank and fallback would prefer the custom image.
//! - ScanWatch 1 only: the push must carry the confirm token `scanwatch-<appl crc>`, so only the exact
//!   package somebody checked can go out.

const BANK_CAPACITY: usize = 0x119000;
const HEADER_VERSION: u16 = 1;
const IE_ENTRY_BODY: u16 = 16;
const IE_APPL: u16 = 1;

/// One header entry of a stock package. `crc`/`version` are `None` for the appl entry (it may change).
struct StockEntry {
    ie: u16,
    address: u32,
    length: u32,
    crc: Option<u32>,
    version: Option<u32>,
}

struct Profile {
    watch: &'static str,
    entries: &'static [StockEntry],
    /// Offset of the version trailer word inside the appl part, if known.
    trailer_in_appl: Option<usize>,
    even_version: bool,
    needs_confirm: bool,
}

// ScanWatch 1 (model 93), stock fw 2941, from research/fw2941.bin (= bank A of the 8 MB dump).
const SCANWATCH: Profile = Profile {
    watch: "scanwatch",
    entries: &[
        StockEntry { ie: 1, address: 0x44, length: 0xa93fc, crc: None, version: None },
        StockEntry { ie: 4, address: 0xa9440, length: 0x4000, crc: Some(0xa7199aa2), version: Some(6) },
        StockEntry { ie: 8, address: 0xad440, length: 0x26598, crc: Some(0x4a5277b8), version: Some(202) },
    ],
    trailer_in_appl: Some(0xa93f8),
    even_version: true,
    needs_confirm: true,
};

// Steel HR, from STEEL_RECOVERY/steel_test_v7042_bankA_based.pkg; all 48 flashed packages
// (v7042..v7086) carry exactly these parts.
const STEELHR: Profile = Profile {
    watch: "steelhr",
    entries: &[
        StockEntry { ie: 1, address: 0x58, length: 0x540c4, crc: None, version: None },
        StockEntry { ie: 4, address: 0x5411c, length: 0x4000, crc: Some(0x380c382a), version: Some(27) },
        StockEntry { ie: 7, address: 0x5811c, length: 0xa72d, crc: Some(0xf3c2782b), version: Some(0x5002) },
        StockEntry { ie: 8, address: 0x6284c, length: 0x1b358, crc: Some(0x81916595), version: Some(195) },
    ],
    trailer_in_appl: None,
    even_version: false,
    needs_confirm: false,
};

fn profile(watch: &str) -> Option<&'static Profile> {
    match watch {
        "scanwatch" => Some(&SCANWATCH),
        "steelhr" => Some(&STEELHR),
        _ => None,
    }
}

/// What a checked image is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckedImage {
    pub appl_version: u32,
    pub appl_crc: u32,
    pub package_len: usize,
    /// The token a push of this image must carry (empty when the watch needs none).
    pub confirm_token: String,
}

fn u16_at(b: &[u8], at: usize) -> Result<u16, String> {
    b.get(at..at + 2).map(|s| u16::from_le_bytes([s[0], s[1]])).ok_or_else(|| format!("truncated at {at:#x}"))
}

fn u32_at(b: &[u8], at: usize) -> Result<u32, String> {
    b.get(at..at + 4)
        .map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
        .ok_or_else(|| format!("truncated at {at:#x}"))
}

pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

/// Check `image` against `watch`'s stock layout. Err carries the reason it must not be pushed.
pub fn check_firmware_image(watch: &str, image: &[u8]) -> Result<CheckedImage, String> {
    let p = profile(watch).ok_or_else(|| format!("no firmware profile for watch '{watch}': refusing"))?;
    if image.len() > BANK_CAPACITY {
        return Err(format!("{:#x} bytes is larger than one bank ({BANK_CAPACITY:#x})", image.len()));
    }
    let version = u16_at(image, 0)?;
    if version != HEADER_VERSION {
        return Err(format!("header version {version}, expected {HEADER_VERSION}"));
    }
    let body = u16_at(image, 2)? as usize;
    let want_body = p.entries.len() * (4 + IE_ENTRY_BODY as usize);
    if body != want_body {
        return Err(format!("header has {body} bytes of entries, {} stock has {want_body}", p.watch));
    }
    let stored = u32_at(image, 4 + body)?;
    let computed = crc32(&image[..4 + body]);
    if stored != computed {
        return Err(format!("header CRC {stored:#010x} != computed {computed:#010x}"));
    }

    let mut appl: Option<(u32, u32, usize)> = None; // (version, crc, address)
    let mut end = 0usize;
    for (i, want) in p.entries.iter().enumerate() {
        let at = 4 + i * (4 + IE_ENTRY_BODY as usize);
        let ie = u16_at(image, at)?;
        let entry_len = u16_at(image, at + 2)?;
        let address = u32_at(image, at + 4)?;
        let length = u32_at(image, at + 8)?;
        let crc = u32_at(image, at + 12)?;
        let ver = u32_at(image, at + 16)?;
        let name = match ie { 1 => "appl", 4 => "bootloader", 7 => "resources", 8 => "softdevice", _ => "unknown" };
        if ie != want.ie || entry_len != IE_ENTRY_BODY {
            return Err(format!("entry {i} is ie={ie} len={entry_len}; {} stock has ie={} here: wrong watch or altered header", p.watch, want.ie));
        }
        if address != want.address || length != want.length {
            return Err(format!(
                "{name} at {address:#x} len {length:#x}; {} stock is at {:#x} len {:#x}: wrong watch or altered part",
                p.watch, want.address, want.length
            ));
        }
        let start = address as usize;
        let aligned = (length as usize + 3) & !3;
        let part = image.get(start..start + aligned).ok_or_else(|| format!("{name} runs past the end of the image"))?;
        let actual = crc32(part);
        if actual != crc {
            return Err(format!("{name} CRC {crc:#010x} in header but the bytes give {actual:#010x}"));
        }
        if let Some(stock_crc) = want.crc {
            if crc != stock_crc {
                return Err(format!(
                    "{name} CRC {crc:#010x} is not {}'s installed {name} ({stock_crc:#010x}): the bootloader would rewrite it (brick risk)",
                    p.watch
                ));
            }
        }
        if let Some(stock_ver) = want.version {
            if ver != stock_ver {
                return Err(format!("{name} version {ver} is not {}'s stock {stock_ver}", p.watch));
            }
        }
        if ie == IE_APPL {
            appl = Some((ver, crc, start));
        }
        end = end.max(start + length as usize);
    }
    if image[end..].iter().any(|&b| b != 0xff) {
        return Err(format!("non-0xFF bytes after the package end {end:#x}"));
    }
    let (appl_version, appl_crc, appl_at) = appl.ok_or("no appl entry")?;
    if let Some(off) = p.trailer_in_appl {
        let embedded = u32_at(image, appl_at + off)?;
        if embedded != appl_version {
            return Err(format!("appl trailer holds {embedded}, header says {appl_version}"));
        }
    }
    if p.even_version && appl_version % 2 != 0 {
        return Err(format!(
            "appl version {appl_version} is odd = 'gold' on {}: it would replace the stock bank as the fallback. Use an even version",
            p.watch
        ));
    }
    let confirm_token = if p.needs_confirm { format!("{}-{appl_crc:08x}", p.watch) } else { String::new() };
    Ok(CheckedImage { appl_version, appl_crc, package_len: end, confirm_token })
}

/// Full gate for a push: the image check plus the confirm token where the watch needs one.
pub fn check_firmware_push(watch: &str, image: &[u8], confirm: Option<&str>) -> Result<CheckedImage, String> {
    let checked = check_firmware_image(watch, image)?;
    if !checked.confirm_token.is_empty() && confirm != Some(checked.confirm_token.as_str()) {
        return Err(format!("push to {watch} needs confirm token {} (got {:?})", checked.confirm_token, confirm.unwrap_or("none")));
    }
    Ok(checked)
}

/// Opcodes never sent raw to the ScanWatch: resets/reboots/update, flash and GPIO writes,
/// calibration and factory sets, hand motors. The firmware push builds its own frames and does not
/// go through this list.
const SCANWATCH_RAW_DENY: &[(u16, &str)] = &[
    (284, "HANDS_MOVE"),
    (286, "HANDS_CAL_START"),
    (287, "HANDS_CAL_STOP"),
    (291, "FACTORY_RESET"),
    (294, "RESTART_TO_UPDATE"),
    (337, "REBOOT"),
    (343, "RAW_DATA erase"),
    (516, "GPIO"),
    (526, "SPIFLASH"),
    (1025, "UP_FIRMWARE_START"),
    (1026, "UP_FIRMWARE_ACK"),
    (1027, "UP_FIRMWARE_REBOOT"),
    (1041, "NETUPDATE_REBOOT"),
    (2349, "CALIBRATION_SET"),
    (2386, "SPI_FLASH"),
    (2407, "FW_AVAILABLE"),
    (2408, "REQUEST_FW_CHUNK"),
    (2416, "FACTORY_MODE_SET"),
    (2418, "HAND_UNBLOCK_TRACKER"),
    (2422, "HANDS_CAL_CANCEL"),
    (2433, "DIGITAL_CROWN_CALIB"),
    (2444, "BOOTSTRAP_REBOOT"),
    (2475, "TRACKER_MOVE_HANDS_SET"),
    (2483, "FACTORY_TEST"),
];

/// Check a raw blob of WPP frames before it is written to `watch`. Every frame in the blob is
/// walked; for the ScanWatch a malformed blob is refused too, so nothing can hide after a frame.
pub fn check_raw_frames(watch: &str, bytes: &[u8]) -> Result<(), String> {
    if watch != "scanwatch" {
        return Ok(());
    }
    if bytes.is_empty() {
        return Err("empty raw command".into());
    }
    let mut at = 0usize;
    while at < bytes.len() {
        if bytes.len() - at < 5 {
            return Err(format!("{} stray bytes after the last frame", bytes.len() - at));
        }
        let cmd = u16::from_be_bytes([bytes[at + 1], bytes[at + 2]]);
        let len = u16::from_be_bytes([bytes[at + 3], bytes[at + 4]]) as usize;
        let opcode = cmd & 0x3fff;
        if let Some((_, name)) = SCANWATCH_RAW_DENY.iter().find(|(op, _)| *op == opcode) {
            return Err(format!("opcode {opcode} ({name}) is blocked for the ScanWatch"));
        }
        at += 5 + len;
        if at > bytes.len() {
            return Err("frame length runs past the end of the raw command".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal image in `p`'s layout with correct CRCs, parts filled with `fill`.
    fn build(p: &Profile, appl_version: u32, fill: u8) -> Vec<u8> {
        let end = p.entries.iter().map(|e| e.address as usize + e.length as usize).max().unwrap();
        let mut img = vec![0u8; end];
        let body = p.entries.len() * 20;
        img[0..2].copy_from_slice(&1u16.to_le_bytes());
        img[2..4].copy_from_slice(&(body as u16).to_le_bytes());
        for e in p.entries.iter() {
            let start = e.address as usize;
            let len = e.length as usize;
            for b in &mut img[start..start + len] {
                *b = fill;
            }
            if e.ie == 1 {
                if let Some(off) = p.trailer_in_appl {
                    img[start + off..start + off + 4].copy_from_slice(&appl_version.to_le_bytes());
                }
            }
        }
        // Stock parts must carry stock CRCs, which a synthetic fill can't; the tests that need a
        // passing image patch the profile CRCs out via `check_with`, so header CRCs here are honest.
        for (i, e) in p.entries.iter().enumerate() {
            let at = 4 + i * 20;
            let start = e.address as usize;
            let aligned = (e.length as usize + 3) & !3;
            let crc = crc32(&img[start..(start + aligned).min(img.len())]);
            img[at..at + 2].copy_from_slice(&e.ie.to_le_bytes());
            img[at + 2..at + 4].copy_from_slice(&16u16.to_le_bytes());
            img[at + 4..at + 8].copy_from_slice(&e.address.to_le_bytes());
            img[at + 8..at + 12].copy_from_slice(&e.length.to_le_bytes());
            img[at + 12..at + 16].copy_from_slice(&crc.to_le_bytes());
            let v = if e.ie == 1 { appl_version } else { e.version.unwrap() };
            img[at + 16..at + 20].copy_from_slice(&v.to_le_bytes());
        }
        let hcrc = crc32(&img[..4 + body]);
        img[4 + body..8 + body].copy_from_slice(&hcrc.to_le_bytes());
        img
    }

    fn real(path: &str) -> Option<Vec<u8>> {
        std::fs::read(path).ok()
    }

    #[test]
    fn crc_matches_zlib() {
        assert_eq!(crc32(b"123456789"), 0xcbf43926);
    }

    #[test]
    fn synthetic_image_fails_on_stock_part_crc() {
        let img = build(&SCANWATCH, 2942, 0x5a);
        let err = check_firmware_image("scanwatch", &img).unwrap_err();
        assert!(err.contains("bootloader CRC"), "{err}");
    }

    #[test]
    fn unknown_watch_refused() {
        assert!(check_firmware_image("scanwatch2", &[1, 0]).unwrap_err().contains("no firmware profile"));
    }

    #[test]
    fn steel_layout_refused_for_scanwatch() {
        let img = build(&STEELHR, 7042, 0x11);
        let err = check_firmware_image("scanwatch", &img).unwrap_err();
        assert!(err.contains("entries") || err.contains("wrong watch"), "{err}");
    }

    #[test]
    fn scanwatch_layout_refused_for_steel() {
        let img = build(&SCANWATCH, 2942, 0x11);
        let err = check_firmware_image("steelhr", &img).unwrap_err();
        assert!(err.contains("entries") || err.contains("wrong watch"), "{err}");
    }

    #[test]
    fn oversize_refused() {
        let img = vec![0xffu8; BANK_CAPACITY + 1];
        assert!(check_firmware_image("scanwatch", &img).unwrap_err().contains("larger than one bank"));
    }

    // --- against the real images on the NUC (skipped where the files are absent, e.g. CI) ---
    const SW1_STOCK: &str = "/home/jack/COMMANDS/WITHINGS_RAW/research/fw2941.bin";
    const STEEL_DIR: &str = "/mnt/BACKUPS/WITHINGS_RAW/STEEL_RECOVERY";

    /// Re-version a real SW1 package: header + trailer version, appl CRC, header CRC.
    fn reversion(mut img: Vec<u8>, v: u32) -> Vec<u8> {
        let (appl_at, appl_len) = (0x44usize, 0xa93fcusize);
        img[appl_at + 0xa93f8..appl_at + 0xa93fc].copy_from_slice(&v.to_le_bytes());
        let crc = crc32(&img[appl_at..appl_at + appl_len]);
        img[4 + 12..4 + 16].copy_from_slice(&crc.to_le_bytes());
        img[4 + 16..4 + 20].copy_from_slice(&v.to_le_bytes());
        let body = 60;
        let h = crc32(&img[..4 + body]);
        img[4 + body..8 + body].copy_from_slice(&h.to_le_bytes());
        img
    }

    #[test]
    fn real_sw1_stock_is_odd_so_refused() {
        let Some(img) = real(SW1_STOCK) else { return };
        let err = check_firmware_image("scanwatch", &img).unwrap_err();
        assert!(err.contains("odd"), "{err}");
    }

    #[test]
    fn real_sw1_even_identity_passes_and_needs_token() {
        let Some(img) = real(SW1_STOCK) else { return };
        let img = reversion(img, 2942);
        let ok = check_firmware_image("scanwatch", &img).expect("v2942 identity must pass");
        assert_eq!(ok.appl_version, 2942);
        assert_eq!(ok.package_len, 0xd39d8);
        assert!(check_firmware_push("scanwatch", &img, None).is_err());
        assert!(check_firmware_push("scanwatch", &img, Some("scanwatch-00000000")).is_err());
        assert!(check_firmware_push("scanwatch", &img, Some(&ok.confirm_token)).is_ok());
        // trimmed padding passes too
        assert!(check_firmware_image("scanwatch", &img[..0xd39d8]).is_ok());
    }

    #[test]
    fn real_sw1_tampered_parts_refused() {
        let Some(img) = real(SW1_STOCK) else { return };
        let good = reversion(img, 2942);
        // a bootloader byte changed (header CRC fixed up honestly) -> refused as not-installed bootloader
        let mut bl = good.clone();
        bl[0xa9440 + 0x100] ^= 1;
        let c = crc32(&bl[0xa9440..0xa9440 + 0x4000]);
        bl[24 + 12..24 + 16].copy_from_slice(&c.to_le_bytes());
        let h = crc32(&bl[..64]);
        bl[64..68].copy_from_slice(&h.to_le_bytes());
        assert!(check_firmware_image("scanwatch", &bl).unwrap_err().contains("brick risk"));
        // an appl byte changed without fixing the CRC -> refused
        let mut ap = good.clone();
        ap[0x1000] ^= 1;
        assert!(check_firmware_image("scanwatch", &ap).unwrap_err().contains("appl CRC"));
        // junk after the package -> refused
        let mut tail = good.clone();
        tail[0xd39d8 + 10] = 0;
        assert!(check_firmware_image("scanwatch", &tail).unwrap_err().contains("after the package"));
        // trailer disagrees with header
        let mut tr = good;
        tr[4 + 16..4 + 20].copy_from_slice(&2944u32.to_le_bytes());
        let h = crc32(&tr[..64]);
        tr[64..68].copy_from_slice(&h.to_le_bytes());
        assert!(check_firmware_image("scanwatch", &tr).unwrap_err().contains("trailer"));
    }

    #[test]
    fn every_real_steel_package_passes_steel_and_fails_scanwatch() {
        let Ok(dir) = std::fs::read_dir(STEEL_DIR) else { return };
        let mut n = 0;
        for e in dir.flatten() {
            let path = e.path();
            if path.extension().and_then(|s| s.to_str()) != Some("pkg") {
                continue;
            }
            let img = std::fs::read(&path).unwrap();
            check_firmware_image("steelhr", &img).unwrap_or_else(|err| panic!("{}: {err}", path.display()));
            assert!(check_firmware_image("scanwatch", &img).is_err(), "{} passed as scanwatch", path.display());
            n += 1;
        }
        assert!(n >= 40, "only {n} steel packages found");
    }

    #[test]
    fn raw_frames() {
        // live polls and shortcuts pass
        assert!(check_raw_frames("scanwatch", &hex("0101490000")).is_ok());
        assert!(check_raw_frames("scanwatch", &hex("0109300000")).is_ok());
        assert!(check_raw_frames("scanwatch", &hex("010989000509a1000101")).is_ok());
        // reboot / restart-to-update / firmware start refused, also with channel bits set
        assert!(check_raw_frames("scanwatch", &hex("0101510000")).is_err()); // 337
        assert!(check_raw_frames("scanwatch", &hex("0101260000")).is_err()); // 294
        assert!(check_raw_frames("scanwatch", &hex("0144010000")).is_err()); // 1025 | 0x4000
        // a dangerous frame hidden after a harmless one
        assert!(check_raw_frames("scanwatch", &hex("01014900000101510000")).is_err());
        // malformed
        assert!(check_raw_frames("scanwatch", &hex("010149")).is_err());
        assert!(check_raw_frames("scanwatch", &hex("0101490005aa")).is_err());
        // other watches untouched
        assert!(check_raw_frames("steelhr", &hex("0101510000")).is_ok());
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }
}
