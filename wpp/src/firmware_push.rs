//! Phone-driven firmware PUSH for the Steel HR (and other push-model watches).
//!
//! Flow (see research/FIRMWARE_MOD.md):
//!   phone -> CMD_UP_FIRMWARE_START (UpdateFirmware{fw_type, fw_size})
//!   watch -> CMD_UP_FIRMWARE_START reply (raw 0x0000700f = {status 0, credit 0x700f})
//!   phone -> stream CMD_UP_FIRMWARE_START frames each carrying one FwChunk{offset, packet},
//!            FLOW-CONTROLLED: one window up front, then ~half a window per
//!   watch -> CMD_UP_FIRMWARE_ACK (1026, status 1) credit ACK the watch sends as it flashes.
//!   watch -> CMD_UP_FIRMWARE_REBOOT when the whole image is in; it reboots and the bootloader
//!            picks the highest-version bank that passes CRC (no signature enforced).
//!
//! The 11/13 all-at-once attempt streamed every chunk up front and never finalized (34 credit
//! ACKs, no completion) -> the watch was overrun. This paces to the 1026 ACKs instead.
//!
//! Both the START reply and the 1026 ACK carry a raw 4-byte status that is not a WPP object, so
//! they fail strict frame parsing; wpp-ffi's on_bytes injects synthetic empty frames for commands
//! 1025/1026 so this state machine still sees them.

use crate::commands::Command;
use crate::frame::{Frame, HEADER_LEN, MAX_FRAME_BYTES, OBJECT_HEADER_LEN};
use crate::objects::{FwChunk, UpdateFirmware};
use crate::WppObject;

/// Offset(4) + length byte(1) in front of an FwChunk's packet.
const FW_CHUNK_FIELDS_LEN: usize = 5;
/// Largest packet that still fits one frame.
pub const CHUNK_CAP: usize = MAX_FRAME_BYTES - (HEADER_LEN + OBJECT_HEADER_LEN + FW_CHUNK_FIELDS_LEN);
/// The watch's receive credit, declared in the START reply (0x0000700f). Max bytes kept in flight.
const WINDOW: usize = 0x700f;
/// Bytes to send per 1026 credit ACK. The watch ACKs once per full window it consumes (observed:
/// 18 ACKs for a 515 KB image = 515 KB / 0x700f), so send a full window per credit — half a window
/// (the first try) under-fed it and the watch timed out and rebooted mid-transfer.
const STEP: usize = WINDOW;

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

    /// Emit the next batch of FwChunks covering `[sent, sent+count)`, advancing the cursor.
    fn emit(push: &mut Push, count: usize) -> Vec<Frame> {
        let mut out = Vec::new();
        let target = (push.sent + count).min(push.bytes.len());
        while push.sent < target {
            let end = (push.sent + CHUNK_CAP).min(target);
            out.push(Frame::new(
                Command::CMD_UP_FIRMWARE_START,
                vec![WppObject::FwChunk(FwChunk {
                    offset: push.sent as u32,
                    packet: push.bytes[push.sent..end].to_vec(),
                })],
            ));
            push.sent = end;
        }
        if push.sent >= push.bytes.len() {
            push.done = true;
        }
        out
    }

    /// Feed an incoming frame. The START reply opens the stream (first window); each 1026 credit
    /// ACK sends the next STEP bytes. Returns the frames to send.
    pub fn on_frame(&mut self, frame: &Frame) -> Vec<Frame> {
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
                Self::emit(push, STEP)
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

    fn reassemble(frames: &[Frame]) -> Vec<u8> {
        let mut out = Vec::new();
        for f in frames {
            match &f.objects[0] {
                WppObject::FwChunk(c) => {
                    assert_eq!(c.offset as usize, out.len(), "chunks must be contiguous");
                    out.extend_from_slice(&c.packet);
                }
                _ => panic!("expected FwChunk"),
            }
        }
        out
    }

    #[test]
    fn start_declares_type_and_size() {
        let mut fp = FirmwarePush::new();
        let f = fp.start(vec![0u8; 400], 0, false);
        assert_eq!(f.command, Command::CMD_UP_FIRMWARE_START);
        match &f.objects[0] {
            WppObject::UpdateFirmware(u) => { assert_eq!(u.fw_size, 400); }
            _ => panic!(),
        }
    }

    #[test]
    fn small_image_fits_first_window() {
        let mut fp = FirmwarePush::new();
        let n = 256;
        fp.start(vec![7u8; n], 0, false);
        let frames = fp.on_frame(&ack_start());
        assert_eq!(reassemble(&frames).len(), n);
        assert!(fp.progress().unwrap().done, "a sub-window image finishes on the start ack");
        assert!(fp.on_frame(&ack_credit()).is_empty());
    }

    #[test]
    fn large_image_paces_across_credit_acks() {
        let mut fp = FirmwarePush::new();
        let n = WINDOW * 3 + 1234; // several windows
        fp.start(vec![9u8; n], 0, false);
        let mut all = reassemble(&fp.on_frame(&ack_start()));
        assert_eq!(all.len(), WINDOW, "first window on the start ack");
        // each credit ack sends STEP until done
        let mut guard = 0;
        while !fp.progress().unwrap().done {
            let batch = fp.on_frame(&ack_credit());
            assert!(!batch.is_empty(), "a credit ack before done must send more");
            let before = all.len();
            all.extend(reassemble_from(&batch, before));
            guard += 1;
            assert!(guard < 1000, "must terminate");
        }
        assert_eq!(all.len(), n, "every byte sent exactly once, in order");
        // extra acks after done do nothing
        assert!(fp.on_frame(&ack_credit()).is_empty());
    }

    fn reassemble_from(frames: &[Frame], base: usize) -> Vec<u8> {
        let mut out = Vec::new();
        let mut at = base;
        for f in frames {
            match &f.objects[0] {
                WppObject::FwChunk(c) => {
                    assert_eq!(c.offset as usize, at);
                    out.extend_from_slice(&c.packet);
                    at += c.packet.len();
                }
                _ => panic!(),
            }
        }
        out
    }
}
