//! Mirror of ../vkmtl_proto.h (the VKMTL wire protocol). Keep the two in step.
#![allow(dead_code)]

pub const VERSION: u32 = 1;
pub const REPLY: u32 = 0x8000_0000;

pub const HELLO: u32 = 1;
pub const BUF_NEW: u32 = 2;
pub const OBJ_DEL: u32 = 3;
pub const TEX_NEW: u32 = 4;
pub const TEX_REPLACE: u32 = 5;
pub const TEX_GETBYTES: u32 = 6;
pub const QUEUE_NEW: u32 = 7;
pub const CB_COMMIT: u32 = 8;
pub const EVENT_NEW: u32 = 9;
pub const EVENT_SET: u32 = 10;
pub const EVENT_GET: u32 = 11;
pub const BUF_WRITE: u32 = 12;
pub const BUF_READ: u32 = 13;
pub const SYNC: u32 = 14;
pub const LIB_NEW: u32 = 15;
pub const FUNC_NEW: u32 = 16;
pub const CPS_NEW: u32 = 17;
pub const SAMPLER_NEW: u32 = 18;
pub const RPS_NEW: u32 = 19;
pub const DSS_NEW: u32 = 20;
pub const TEX_NEW_BUF: u32 = 21;
pub const TEX_VIEW: u32 = 22;

pub const EV_CB_DONE: u32 = 100;
pub const EV_EVENT: u32 = 101;

pub const C_COPY_BB: u32 = 1;
pub const C_COPY_BT: u32 = 2;
pub const C_COPY_TB: u32 = 3;
pub const C_COPY_TT: u32 = 4;
pub const C_FILL: u32 = 5;
pub const C_MIPMAPS: u32 = 6;
pub const C_RENDER_PASS: u32 = 7;
pub const C_SIGNAL: u32 = 8;
pub const C_WAIT: u32 = 9;
pub const C_CS_BEGIN: u32 = 10;
pub const C_CS_PIPELINE: u32 = 11;
pub const C_CS_BUFFER: u32 = 12;
pub const C_CS_BYTES: u32 = 13;
pub const C_CS_TEXTURE: u32 = 14;
pub const C_CS_SAMPLER: u32 = 15;
pub const C_CS_TGMEM: u32 = 16;
pub const C_CS_DISPATCH: u32 = 17;
pub const C_CS_BARRIER: u32 = 18;
pub const C_CS_USE: u32 = 19;
pub const C_CS_END: u32 = 20;
pub const C_CS_BUFFER_OFFSET: u32 = 21;
pub const C_RE_PIPELINE: u32 = 30;
pub const C_RE_BUFFER: u32 = 31;
pub const C_RE_BYTES: u32 = 32;
pub const C_RE_TEXTURE: u32 = 33;
pub const C_RE_SAMPLER: u32 = 34;
pub const C_RE_BUFFER_OFFSET: u32 = 35;
pub const C_RE_VIEWPORT: u32 = 36;
pub const C_RE_SCISSOR: u32 = 37;
pub const C_RE_CULL: u32 = 38;
pub const C_RE_WINDING: u32 = 39;
pub const C_RE_FILL: u32 = 40;
pub const C_RE_DEPTH_BIAS: u32 = 41;
pub const C_RE_STENCIL_REF: u32 = 42;
pub const C_RE_BLEND_COLOR: u32 = 43;
pub const C_RE_DSS: u32 = 44;
pub const C_RE_DEPTH_CLIP: u32 = 45;
pub const C_RE_DRAW: u32 = 46;
pub const C_RE_DRAW_INDEXED: u32 = 47;
pub const C_RE_END: u32 = 48;
pub const C_RE_USE: u32 = 49;
pub const C_RE_DRAW_INDIRECT: u32 = 50;
pub const C_RE_DRAW_INDEXED_INDIRECT: u32 = 51;

pub const MAX_COLOR: usize = 8;

/// Little-endian reader over a message payload. Reads past the end yield zeros (and set `short`).
pub struct Rd<'a> {
    pub b: &'a [u8],
    pub at: usize,
    pub short: bool,
}

impl<'a> Rd<'a> {
    pub fn new(b: &'a [u8]) -> Self {
        Rd { b, at: 0, short: false }
    }
    pub fn bytes(&mut self, n: usize) -> &'a [u8] {
        if self.at + n > self.b.len() {
            self.short = true;
            self.at = self.b.len();
            return &[];
        }
        let s = &self.b[self.at..self.at + n];
        self.at += n;
        s
    }
    pub fn u32(&mut self) -> u32 {
        let s = self.bytes(4);
        if s.len() < 4 { 0 } else { u32::from_le_bytes(s.try_into().unwrap()) }
    }
    pub fn u64(&mut self) -> u64 {
        let s = self.bytes(8);
        if s.len() < 8 { 0 } else { u64::from_le_bytes(s.try_into().unwrap()) }
    }
    pub fn f64(&mut self) -> f64 {
        f64::from_bits(self.u64())
    }
    pub fn i32(&mut self) -> i32 {
        self.u32() as i32
    }
    pub fn f32(&mut self) -> f32 {
        f32::from_bits(self.u32())
    }
    pub fn rest(&mut self) -> &'a [u8] {
        let s = &self.b[self.at..];
        self.at = self.b.len();
        s
    }
}

/// Little-endian writer.
#[derive(Default)]
pub struct Wr(pub Vec<u8>);

impl Wr {
    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn i32(&mut self, v: i32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn f64(&mut self, v: f64) -> &mut Self {
        self.u64(v.to_bits())
    }
    pub fn bytes(&mut self, v: &[u8]) -> &mut Self {
        self.0.extend_from_slice(v);
        self
    }
    /// {u32 len, text}
    pub fn text(&mut self, v: &str) -> &mut Self {
        self.u32(v.len() as u32).bytes(v.as_bytes())
    }
}
