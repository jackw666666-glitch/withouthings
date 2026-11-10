use crate::objects::{DebugDumpAnchor, DebugDumpMask};
use crate::{Command, Frame, WppObject};

/// Settings + log: what every dump asks for.
const BASE_MASK: u32 = 0x2000_0003;
/// RAWDATA + raw recording: workout accelerometer and light sensor, workout activity, background PPG,
/// PPG algorithm, ECG. CMD_DEBUG_SET also stores the mask as what the watch records, so every dump
/// has to carry these bits or it switches recording off.
const DEFAULT_RAW_MASK: u32 = 0x1A4A_0010;

const FIRST_ANCHOR: u32 = 0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Idle,
    Selecting(u32),
    Receiving,
    Acking { next: Option<u32> },
}

#[derive(Debug, Clone)]
pub struct DebugDump {
    state: State,
    raw_capture: bool,
    raw_mask: u32,
    applied: Option<u32>,
}

impl DebugDump {
    pub fn new() -> DebugDump {
        DebugDump { state: State::Idle, raw_capture: false, raw_mask: DEFAULT_RAW_MASK, applied: None }
    }

    pub fn running(&self) -> bool {
        self.state != State::Idle
    }

    /// Record raw sensor data or not; `mask` picks which sensors (None = the default set).
    /// Sends the mask once per change; a running dump picks it up itself.
    pub fn set_raw_capture(&mut self, on: bool, mask: Option<u32>) -> Vec<Frame> {
        self.raw_capture = on;
        if let Some(m) = mask {
            self.raw_mask = m;
        }
        if self.running() || self.applied == Some(self.mask()) {
            return Vec::new();
        }
        self.applied = Some(self.mask());
        vec![self.mask_frame()]
    }

    fn mask(&self) -> u32 {
        if self.raw_capture { BASE_MASK | self.raw_mask } else { BASE_MASK }
    }

    fn mask_frame(&self) -> Frame {
        Frame::new(
            Command::CMD_DEBUG_SET,
            vec![WppObject::DebugDumpMask(DebugDumpMask { mask: self.mask() })],
        )
    }

    pub fn start(&mut self) -> Vec<Frame> {
        if self.running() {
            return Vec::new();
        }
        self.select(FIRST_ANCHOR)
    }

    pub fn on_frame(&mut self, frame: &Frame) -> Vec<Frame> {
        let command = frame.command.opcode();
        let refused = frame.objects.iter().any(|o| {
            matches!(o, WppObject::Cmderror(e)
                if e.cmd == Command::CMD_DEBUG_SET.0
                    || e.cmd == Command::CMD_DEBUG_DUMP.0
                    || e.cmd == Command::CMD_DEBUG_DUMP_ACK.0)
        });
        if refused {
            self.state = State::Idle;
            return Vec::new();
        }

        match self.state {
            State::Idle => Vec::new(),
            State::Selecting(anchor) if command == Command::CMD_DEBUG_SET => {
                self.state = State::Receiving;
                vec![Frame::new(
                    Command::CMD_DEBUG_DUMP,
                    vec![WppObject::DebugDumpAnchor(DebugDumpAnchor {
                        value: anchor,
                    })],
                )]
            }
            State::Receiving if command == Command::CMD_DEBUG_DUMP => {
                if !frame
                    .objects
                    .iter()
                    .any(|o| matches!(o, WppObject::Null(_)))
                {
                    return Vec::new();
                }
                let next = frame.objects.iter().find_map(|o| match o {
                    WppObject::DebugDumpAnchor(a) => Some(a.value),
                    _ => None,
                });
                self.state = State::Acking { next };
                vec![Frame::new(Command::CMD_DEBUG_DUMP_ACK, Vec::new())]
            }
            State::Acking { next } if command == Command::CMD_DEBUG_DUMP_ACK => match next {
                Some(anchor) => self.select(anchor),
                None => {
                    self.state = State::Idle;
                    Vec::new()
                }
            },
            _ => Vec::new(),
        }
    }

    fn select(&mut self, anchor: u32) -> Vec<Frame> {
        self.state = State::Selecting(anchor);
        self.applied = Some(self.mask());
        vec![self.mask_frame()]
    }
}

impl Default for DebugDump {
    fn default() -> Self {
        DebugDump::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::objects::{DebugDumpData, DebugDumpType, Null};

    fn reply(command: Command, objects: Vec<WppObject>) -> Frame {
        Frame::new(command, objects)
    }

    fn sent(frames: &[Frame]) -> Vec<u16> {
        frames.iter().map(|f| f.command.opcode().0).collect()
    }

    fn mask_of(frames: &[Frame]) -> u32 {
        match frames[0].objects[0] {
            WppObject::DebugDumpMask(DebugDumpMask { mask }) => mask,
            _ => panic!("not a mask"),
        }
    }

    #[test]
    fn raw_capture_is_sent_once_per_change_and_every_dump_keeps_it() {
        let mut dump = DebugDump::new();
        assert_eq!(mask_of(&dump.set_raw_capture(true, None)), 0x3A4A_0013);
        assert!(dump.set_raw_capture(true, None).is_empty());
        assert_eq!(mask_of(&dump.start()), 0x3A4A_0013);
        let mut dump = DebugDump::new();
        assert_eq!(mask_of(&dump.start()), 0x2000_0003);
        let mut off = DebugDump::new();
        off.set_raw_capture(true, None);
        assert_eq!(mask_of(&off.set_raw_capture(true, Some(0x10))), 0x2000_0013);
        assert_eq!(mask_of(&off.set_raw_capture(false, None)), 0x2000_0003);
    }

    #[test]
    fn a_single_round_drains_and_ends() {
        let mut dump = DebugDump::new();
        assert_eq!(sent(&dump.start()), vec![Command::CMD_DEBUG_SET.0]);
        assert!(dump.running());

        let asked = dump.on_frame(&reply(
            Command::CMD_DEBUG_SET,
            vec![WppObject::Null(Null {})],
        ));
        assert_eq!(sent(&asked), vec![Command::CMD_DEBUG_DUMP.0]);
        assert!(matches!(
            asked[0].objects[0],
            WppObject::DebugDumpAnchor(DebugDumpAnchor {
                value: FIRST_ANCHOR
            })
        ));

        let header = reply(
            Command::CMD_DEBUG_DUMP,
            vec![WppObject::DebugDumpType(DebugDumpType {
                r#type: 3,
                size: 128,
            })],
        );
        assert!(
            dump.on_frame(&header).is_empty(),
            "a header answers nothing"
        );
        let data = reply(
            Command::CMD_DEBUG_DUMP,
            vec![WppObject::DebugDumpData(DebugDumpData { buf: vec![0; 64] })],
        );
        assert!(dump.on_frame(&data).is_empty(), "nor does data");

        let end = reply(Command::CMD_DEBUG_DUMP, vec![WppObject::Null(Null {})]);
        assert_eq!(
            sent(&dump.on_frame(&end)),
            vec![Command::CMD_DEBUG_DUMP_ACK.0]
        );

        let done = reply(Command::CMD_DEBUG_DUMP_ACK, vec![WppObject::Null(Null {})]);
        assert!(dump.on_frame(&done).is_empty(), "nothing left to ask for");
        assert!(!dump.running());
    }

    #[test]
    fn the_anchor_the_watch_gives_back_opens_the_next_round() {
        let mut dump = DebugDump::new();
        dump.start();
        dump.on_frame(&reply(
            Command::CMD_DEBUG_SET,
            vec![WppObject::Null(Null {})],
        ));

        let end = reply(
            Command::CMD_DEBUG_DUMP,
            vec![
                WppObject::DebugDumpAnchor(DebugDumpAnchor { value: 2910826012 }),
                WppObject::Null(Null {}),
            ],
        );
        dump.on_frame(&end);
        let again = dump.on_frame(&reply(
            Command::CMD_DEBUG_DUMP_ACK,
            vec![WppObject::Null(Null {})],
        ));
        assert_eq!(sent(&again), vec![Command::CMD_DEBUG_SET.0]);

        let asked = dump.on_frame(&reply(
            Command::CMD_DEBUG_SET,
            vec![WppObject::Null(Null {})],
        ));
        assert!(
            matches!(asked[0].objects[0], WppObject::DebugDumpAnchor(DebugDumpAnchor { value })
                if value == 2910826012),
            "the next round asks from where the watch said"
        );
    }

    #[test]
    fn a_refusal_ends_the_drain() {
        use crate::objects::Cmderror;
        let mut dump = DebugDump::new();
        dump.start();
        let error = reply(
            Command::CMD_ERROR,
            vec![WppObject::Cmderror(Cmderror {
                cmd: Command::CMD_DEBUG_DUMP.0,
                err: -3,
            })],
        );
        assert!(dump.on_frame(&error).is_empty());
        assert!(!dump.running());
    }
}
