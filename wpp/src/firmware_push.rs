//! Phone-driven firmware PUSH for the Steel HR (and other push-model watches).
//!
//! Flow (see research/FIRMWARE_MOD.md):
//!   phone -> CMD_UP_FIRMWARE_START (UpdateFirmware{fw_type, fw_size})   [a WPP frame]
//!   watch -> CMD_UP_FIRMWARE_START reply (raw 0x0000700f = {status 0, credit 0x700f})
//!   phone -> stream the RAW image bytes (NO framing) straight to the watch, which writes them to
//!            the idle flash bank verbatim; flow-controlled one window up front then a window per
//!   watch -> CMD_UP_FIRMWARE_ACK (1026) credit it sends as it flashes.
//!   watch -> CMD_UP_FIRMWARE_REBOOT when fw_size bytes are in; it reboots and the bootloader picks
//!            the highest-version bank that passes CRC.
//!
//! CRITICAL (found 11/13 by reading bank B back): in update mode the watch writes the raw received
//! bytes to flash verbatim. Wrapping the data in WPP/FwChunk frames baked the frame+object headers
//! into the image (a +14 byte shift per chunk) -> corrupt -> CRC fail -> fell back to bank A every
//! time. So the data phase sends RAW image bytes, not frames. (FwChunk is the ScanWatch PULL object,
//! not this push.)
//!
//! Both the START reply and the 1026 ACK carry a raw 4-byte status that is not a WPP object, so they
//! fail strict parsing; wpp-ffi's on_bytes injects synthetic empty frames for commands 1025/1026 so
//! this state machine still sees them.

use crate::commands::Command;
use crate::frame::{Frame, MAX_FRAME_BYTES};
use crate::objects::UpdateFirmware;
use crate::WppObject;

/// Bytes of raw image per BLE write when the caller names no size (the size the watch survives per write).
pub const RAW_CHUNK: usize = MAX_FRAME_BYTES;
/// The watch acknowledges (CMD_UP_FIRMWARE_ACK) once per this many received WRITES, whatever their
/// size. Read out of the ScanWatch 1 handler (0x66828: `count % ack_every == 0`), and the START reply
/// `00 00 70 0f` is {status 0, 0x70 = 112 max bytes per unconfirmed write, 0x0f = ack every 15 writes}
/// — not a 0x700f-byte credit, which is what this module assumed until 11/26 and which queued the
/// whole image up front.
pub const ACK_EVERY: usize = 15;
/// Windows (of ACK_EVERY writes) kept in flight, so the link never idles waiting for an ACK.
const WINDOWS_IN_FLIGHT: usize = 4;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushProgress {
    pub sent: usize,
    pub total: usize,
    /// Every image byte has been handed to the link (the watch may still be flashing and will reboot).
    pub done: bool,
    pub streaming: bool,
}

#[derive(Debug, Clone)]
struct Push {
    bytes: Vec<u8>,
    /// Size of each write on the air: the pacing counts writes, so this must be what the link sends.
    write_bytes: usize,
    streaming: bool,
    sent: usize,
    done: bool,
}

#[derive(Debug, Clone, Default)]
pub struct FirmwarePush {
    active: Option<Push>,
}

impl FirmwarePush {
    pub fn new() -> FirmwarePush {
        FirmwarePush { active: None }
    }

    pub fn reset(&mut self) {
        self.active = None;
    }

    /// True from START until the link drops (the watch reboots itself once the image is in). The push
    /// owns the channel for all of that time: in update mode the watch writes every received byte to
    /// the flash bank, so no other frame may be written, including after the last image byte is queued.
    pub fn busy(&self) -> bool {
        self.active.is_some()
    }

    /// Take the channel BEFORE the push: from here `busy()` is true and every other frame is held back,
    /// so nothing is in flight when START goes out a few seconds later. (11/26 push #7: two screen
    /// commands sent 0.27 s before START kept the watch busy 13 s and its START reply was lost, leaving
    /// the watch in update mode with nothing streaming.)
    pub fn arm(&mut self) {
        self.active = Some(Push { bytes: Vec::new(), write_bytes: RAW_CHUNK, streaming: false, sent: 0, done: false });
    }

    /// Begin a push: yields the CMD_UP_FIRMWARE_START frame. `write_bytes` is the size of one BLE
    /// write as the link will send it (0 = RAW_CHUNK). `reboot` is accepted for API compatibility but
    /// unused — the watch reboots itself once the whole image is in.
    pub fn start(&mut self, bytes: Vec<u8>, fw_type: u8, _reboot: bool, write_bytes: usize) -> Frame {
        let fw_size = bytes.len() as u32;
        let write_bytes = if write_bytes == 0 { RAW_CHUNK } else { write_bytes };
        self.active = Some(Push { bytes, write_bytes, streaming: false, sent: 0, done: false });
        Frame::new(
            Command::CMD_UP_FIRMWARE_START,
            vec![WppObject::UpdateFirmware(UpdateFirmware { fw_type, fw_size })],
        )
    }

    /// Emit the next `writes` BLE writes of the image (`write_bytes` each, the last one shorter),
    /// advancing the cursor. These go out as Action::SendRaw — no WPP/FwChunk framing.
    fn emit(push: &mut Push, writes: usize) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        while out.len() < writes && push.sent < push.bytes.len() {
            let end = (push.sent + push.write_bytes).min(push.bytes.len());
            out.push(push.bytes[push.sent..end].to_vec());
            push.sent = end;
        }
        if push.sent >= push.bytes.len() {
            push.done = true;
        }
        out
    }

    /// Feed an incoming frame. The START reply opens the stream with WINDOWS_IN_FLIGHT windows; each
    /// 1026 ACK means the watch took ACK_EVERY more writes, so that many more go out. Returns raw
    /// byte writes (no framing).
    pub fn on_frame(&mut self, frame: &Frame) -> Vec<Vec<u8>> {
        let Some(push) = self.active.as_mut() else {
            return Vec::new();
        };
        if push.done {
            return Vec::new();
        }
        match frame.command.opcode() {
            Command::CMD_UP_FIRMWARE_START if !push.streaming => {
                push.streaming = true;
                Self::emit(push, ACK_EVERY * WINDOWS_IN_FLIGHT)
            }
            Command::CMD_UP_FIRMWARE_ACK if push.streaming => Self::emit(push, ACK_EVERY),
            _ => Vec::new(),
        }
    }

    pub fn progress(&self) -> Option<PushProgress> {
        let p = self.active.as_ref()?;
        Some(PushProgress {
            sent: p.sent,
            total: p.bytes.len(),
            done: p.done,
            streaming: p.streaming,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ack_start() -> Frame {
        Frame::new(Command::CMD_UP_FIRMWARE_START, Vec::new())
    }
    fn ack_credit() -> Frame {
        Frame::new(Command::CMD_UP_FIRMWARE_ACK, Vec::new())
    }

    #[test]
    fn start_declares_type_and_size() {
        let mut fp = FirmwarePush::new();
        let f = fp.start(vec![0u8; 400], 0, false, 0);
        assert_eq!(f.command, Command::CMD_UP_FIRMWARE_START);
        match &f.objects[0] {
            WppObject::UpdateFirmware(u) => assert_eq!(u.fw_size, 400),
            _ => panic!(),
        }
    }

    #[test]
    fn data_is_raw_bytes_not_framed() {
        let mut fp = FirmwarePush::new();
        let img: Vec<u8> = (0..500u32).map(|i| i as u8).collect();
        fp.start(img.clone(), 0, false, 0);
        let writes = fp.on_frame(&ack_start());
        // reassembled raw writes == the image byte-for-byte (no headers injected)
        let flat: Vec<u8> = writes.concat();
        assert_eq!(flat, &img[..flat.len()]);
        for w in &writes {
            assert!(w.len() <= RAW_CHUNK);
        }
    }

    #[test]
    fn arming_takes_the_channel_and_sends_nothing() {
        let mut fp = FirmwarePush::new();
        fp.arm();
        assert!(fp.busy());
        assert!(fp.on_frame(&ack_credit()).is_empty());
        let img = vec![7u8; 1000];
        fp.start(img.clone(), 0, false, 200);
        assert_eq!(fp.on_frame(&ack_start()).concat(), img);
    }

    #[test]
    fn paced_by_writes_and_owns_the_channel_until_reset() {
        for write_bytes in [112usize, 200] {
            let mut fp = FirmwarePush::new();
            let n: usize = 866_776;
            let img: Vec<u8> = (0..n).map(|i| (i % 251) as u8).collect();
            fp.start(img.clone(), 0, false, write_bytes);
            assert!(fp.busy());
            assert!(fp.on_frame(&ack_credit()).is_empty(), "nothing before the START reply");
            let first = fp.on_frame(&ack_start());
            assert_eq!(first.len(), ACK_EVERY * WINDOWS_IN_FLIGHT);
            assert!(first.iter().all(|w| w.len() == write_bytes));
            let mut all: Vec<u8> = first.concat();
            // the watch acks once per ACK_EVERY writes it received
            let total_writes = n.div_ceil(write_bytes);
            let mut acks = 0;
            while !fp.progress().unwrap().done {
                let w = fp.on_frame(&ack_credit());
                assert!(w.len() <= ACK_EVERY);
                all.extend(w.concat());
                acks += 1;
                // never more than WINDOWS_IN_FLIGHT windows ahead of what the watch acknowledged
                let sent_writes = all.len().div_ceil(write_bytes);
                assert!(sent_writes <= (acks + WINDOWS_IN_FLIGHT) * ACK_EVERY);
                assert!(acks <= total_writes / ACK_EVERY + 1, "must terminate");
            }
            assert_eq!(all, img, "every byte delivered once, in order, unframed");
            assert!(fp.on_frame(&ack_credit()).is_empty());
            assert!(fp.busy(), "still owns the channel until the link resets");
            fp.reset();
            assert!(!fp.busy());
        }
    }
}
