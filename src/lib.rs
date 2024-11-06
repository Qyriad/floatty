use std::ffi::c_char;

pub mod pty;
pub use pty::{openpt, OpenptControl};

pub mod fdops;
pub use fdops::FdOps;

/// Like `Path`, but for data!
pub type Data = [u8];

/// Like `PathBuf`, but for data!
pub type DataBuf = Vec<u8>;

pub trait DataBufExt
{
    fn zeroed(len: usize) -> Self;
}
impl DataBufExt for DataBuf
{
    fn zeroed(len: usize) -> Self
    {
        vec![0u8; len]
    }
}

pub trait DataExt
{
    fn as_c_buf(&self) -> *const c_char;
    fn as_c_buf_mut(&mut self) -> *mut c_char;
}
impl DataExt for Data
{
    fn as_c_buf(&self) -> *const c_char
    {
        self.as_ptr().cast()
    }

    fn as_c_buf_mut(&mut self) -> *mut c_char
    {
        self.as_mut_ptr().cast()
    }
}
