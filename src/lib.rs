#![feature(
	try_blocks,
	try_trait_v2,
	try_trait_v2_yeet,
	generic_arg_infer,
	const_trait_impl,
	inline_const_pat,
	type_changing_struct_update,
	io_error_more,
	new_range_api,
	dyn_star,
	generic_assert,
	lazy_type_alias,
	cell_leak,
	impl_trait_in_assoc_type,
	min_specialization,
	postfix_match,
	return_type_notation,
	strict_provenance_lints,
	structural_match,
	trait_upcasting,
	trivial_bounds,
	adt_const_params,
	yeet_expr,
	error_reporter,
	error_generic_member_access,
	core_io_borrowed_buf,
	raw_os_error_ty,
	transmutability,
)]

#![warn(fuzzy_provenance_casts)]

use std::ffi::c_char;

pub mod child;
pub mod pty;
pub use pty::{openpt, OpenptControl};

pub mod fdops;
pub use fdops::FdOps;

pub mod parent;

pub mod poller;

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
