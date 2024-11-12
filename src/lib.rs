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
	os_str_display,
)]

#![expect(incomplete_features)]
#![warn(fuzzy_provenance_casts)]

pub mod child;
pub mod pty;
pub use pty::{openpt, OpenptControl};

pub mod fdops;
pub use fdops::FdOps;

pub mod parent;

pub mod poller;

pub mod vecext;
pub use vecext::{Data, DataExt, DataBuf, DataBufExt, VecExt};
