//! Phone-driven firmware PUSH for the Steel HR (and other push-model watches).
//!
//! Unlike the ScanWatch pull flow (`wpp-sim-client/src/update.rs`: the watch asks
//! for ranges with CMD_REQUEST_FW_CHUNK), the Steel HR has no 2407/2408. It uses:
//!   phone -> CMD_UP_FIRMWARE_START (UpdateFirmware{fw_type, fw_size})
//!   watch -> CMD_UP_FIRMWARE_START reply (observed 0x0000700f; likely {status:0, window:0x700f})
//!   phone -> stream CMD_UP_FIRMWARE_START frames each carrying one FwChunk{offset, packet}
//!   phone -> (optional) CMD_UP_FIRMWARE_REBOOT to boot the written bank
//! The bootloader then picks the highest-version bank that passes CRC (the image carries its
//! own CRC32s + version; no signature is enforced — see research/FIRMWARE_MOD.md).
//!
//! First cut: on the START ack we stream the whole image in one go (correct for a small test
//! transfer, which stays under the watch's buffer window). If a full-size push trips the
//! firmware's "Too many bytes pushed" guard, add windowing keyed off later 1025 acks.

use crate::commands::Command;
use crate::frame::{Frame, HEADER_LEN, MAX_FRAME_BYTES, OBJECT_HEADER_LEN};
use crate::objects::{FwChunk, UpdateFirmware};
use crate::WppObject;

/// Offset(4) + length byte(1) in front of an FwChunk's packet.
const FW_CHUNK_FIELDS_LEN: usize = 5;
/// Largest packet that still fits one frame.
pub const CHUNK_CAP: usize = MAX_FRAME_BYTES - (HEADER_LEN + OBJECT_HEADER_LEN + FW_CHUNK_FIELDS_LEN);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushProgress {
    pub sent: usize,
    pub total: usize,
    pub done: bool,
    /// true once the START ack arrived and streaming began.
    pub streaming: bool,
}

#[derive(Debug, Clone)]
struct Push {
    bytes: Vec<u8>,
    reboot: bool,
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

    /// A push is in flight (don't interleave other traffic).
    pub fn busy(&self) -> bool {
        self.active.as_ref().map_or(false, |p| !p.done)
    }

    /// Begin a push: yields the CMD_UP_FIRMWARE_START frame. Any push in flight is dropped.
    pub fn start(&mut self, bytes: Vec<u8>, fw_type: u8, reboot: bool) -> Frame {
        let fw_size = bytes.len() as u32;
        self.active = Some(Push {
            bytes,
            reboot,
            streaming: false,
            sent: 0,
            done: false,
        });
        Frame::new(
            Command::CMD_UP_FIRMWARE_START,
            vec![WppObject::UpdateFirmware(UpdateFirmware { fw_type, fw_size })],
        )
    }

    /// Feed an incoming frame. On the START ack (a CMD_UP_FIRMWARE_START frame the watch sends
    /// back, which carries a raw 4-byte status that does not parse as an object -> empty objects)
    /// we stream every FwChunk, then optionally the reboot. Returns the frames to send.
    pub fn on_frame(&mut self, frame: &Frame) -> Vec<Frame> {
        let Some(push) = self.active.as_mut() else {
            return Vec::new();
        };
        if push.done || push.streaming {
            return Vec::new();
        }
        if frame.command.opcode() != Command::CMD_UP_FIRMWARE_START {
            return Vec::new();
        }
        // The START ack. Stream the whole image.
        push.streaming = true;
        let mut out: Vec<Frame> = Vec::new();
        let mut offset = 0usize;
        while offset < push.bytes.len() {
            let end = (offset + CHUNK_CAP).min(push.bytes.len());
            out.push(Frame::new(
                Command::CMD_UP_FIRMWARE_START,
                vec![WppObject::FwChunk(FwChunk {
                    offset: offset as u32,
                    packet: push.bytes[offset..end].to_vec(),
                })],
            ));
            offset = end;
        }
        push.sent = push.bytes.len();
        if push.reboot {
            out.push(Frame::new(Command::CMD_UP_FIRMWARE_REBOOT, Vec::new()));
        }
        push.done = true;
        out
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

    fn ack() -> Frame {
        Frame::new(Command::CMD_UP_FIRMWARE_START, Vec::new())
    }

    #[test]
    fn start_declares_type_and_size() {
        let mut fp = FirmwarePush::new();
        let f = fp.start(vec![0u8; 400], 0, false);
        assert_eq!(f.command, Command::CMD_UP_FIRMWARE_START);
        assert!(fp.busy());
        match &f.objects[0] {
            WppObject::UpdateFirmware(u) => {
                assert_eq!(u.fw_type, 0);
                assert_eq!(u.fw_size, 400);
            }
            _ => panic!("expected UpdateFirmware"),
        }
    }

    #[test]
    fn ack_streams_all_chunks() {
        let mut fp = FirmwarePush::new();
        let n = CHUNK_CAP * 2 + 10;
        fp.start(vec![7u8; n], 0, false);
        let frames = fp.on_frame(&ack());
        assert_eq!(frames.len(), 3); // two full chunks + remainder, no reboot
        // offsets are contiguous and packets reassemble to the whole image
        let mut rebuilt = Vec::new();
        for f in &frames {
            match &f.objects[0] {
                WppObject::FwChunk(c) => {
                    assert_eq!(c.offset as usize, rebuilt.len());
                    rebuilt.extend_from_slice(&c.packet);
                }
                _ => panic!("expected FwChunk"),
            }
        }
        assert_eq!(rebuilt.len(), n);
        // a second ack does nothing (already streamed)
        assert!(fp.on_frame(&ack()).is_empty());
        assert!(fp.progress().unwrap().done);
    }

    #[test]
    fn reboot_appended_when_requested() {
        let mut fp = FirmwarePush::new();
        fp.start(vec![1u8; 10], 0, true);
        let frames = fp.on_frame(&ack());
        assert_eq!(frames.len(), 2); // one chunk + reboot
        assert_eq!(frames[1].command, Command::CMD_UP_FIRMWARE_REBOOT);
    }
}
