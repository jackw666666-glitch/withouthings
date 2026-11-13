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

/// Bytes of raw image per BLE write (the size the watch survives per write).
pub const RAW_CHUNK: usize = MAX_FRAME_BYTES;
/// The watch's receive credit from the START reply (0x0000700f). Bytes sent per credit cycle.
const WINDOW: usize = 0x700f;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushProgress {
    pub sent: usize,
    pub total: usize,
    pub done: bool,
    pub streaming: bool,
}

#[derive(Debug, Clone)]
struct Push {
    bytes: Vec<u8>,
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

    pub fn busy(&self) -> bool {
        self.active.as_ref().map_or(false, |p| !p.done)
    }

    /// Begin a push: yields the CMD_UP_FIRMWARE_START frame. `reboot` is accepted for API
    /// compatibility but unused — the watch reboots itself once the whole image is in.
    pub fn start(&mut self, bytes: Vec<u8>, fw_type: u8, _reboot: bool) -> Frame {
        let fw_size = bytes.len() as u32;
        self.active = Some(Push { bytes, streaming: false, sent: 0, done: false });
        Frame::new(
            Command::CMD_UP_FIRMWARE_START,
            vec![WppObject::UpdateFirmware(UpdateFirmware { fw_type, fw_size })],
        )
    }

    /// Emit the next `count` bytes of the image as RAW BLE writes (<= RAW_CHUNK each), advancing the
    /// cursor. These go out as Action::SendRaw — no WPP/FwChunk framing.
    fn emit(push: &mut Push, count: usize) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let target = (push.sent + count).min(push.bytes.len());
        while push.sent < target {
            let end = (push.sent + RAW_CHUNK).min(target);
            out.push(push.bytes[push.sent..end].to_vec());
            push.sent = end;
        }
        if push.sent >= push.bytes.len() {
            push.done = true;
        }
        out
    }

    /// Feed an incoming frame. The START reply opens the stream (first window); each 1026 credit ACK
    /// sends the next window. Returns raw byte writes (no framing).
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
                Self::emit(push, WINDOW)
            }
            Command::CMD_UP_FIRMWARE_ACK if push.streaming && push.sent < push.bytes.len() => {
                Self::emit(push, WINDOW)
            }
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
        let f = fp.start(vec![0u8; 400], 0, false);
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
        fp.start(img.clone(), 0, false);
        let writes = fp.on_frame(&ack_start());
        // reassembled raw writes == the image byte-for-byte (no headers injected)
        let flat: Vec<u8> = writes.concat();
        assert_eq!(flat, &img[..flat.len()]);
        for w in &writes {
            assert!(w.len() <= RAW_CHUNK);
        }
    }

    #[test]
    fn large_image_delivers_every_byte_in_order() {
        let mut fp = FirmwarePush::new();
        let n = WINDOW * 3 + 777;
        let img: Vec<u8> = (0..n).map(|i| (i % 251) as u8).collect();
        fp.start(img.clone(), 0, false);
        let mut all: Vec<u8> = fp.on_frame(&ack_start()).concat();
        assert_eq!(all.len(), WINDOW, "first window on the start ack");
        let mut guard = 0;
        while !fp.progress().unwrap().done {
            all.extend(fp.on_frame(&ack_credit()).concat());
            guard += 1;
            assert!(guard < 10000, "must terminate");
        }
        assert_eq!(all, img, "every byte delivered once, in order, unframed");
        assert!(fp.on_frame(&ack_credit()).is_empty());
    }
}
