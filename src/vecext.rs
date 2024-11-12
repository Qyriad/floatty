use std::ffi::c_char;

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

pub trait VecExt<T>
{
	/// Same as [`Vec::push()`], but also returns a shared reference to the new item.
	fn push_get(&mut self, item: T) -> &T;

	/// Same as [`Vec::push()`], but also returns an exclusive reference to the new item.
	fn push_get_mut(&mut self, item: T) -> &mut T;
}

impl<T> VecExt<T> for Vec<T>
{
	fn push_get(&mut self, item: T) -> &T
	{
		self.push(item);
		self.last().unwrap()
	}

	fn push_get_mut(&mut self, item: T) -> &mut T
	{
		self.push(item);
		self.last_mut().unwrap()
	}
}

