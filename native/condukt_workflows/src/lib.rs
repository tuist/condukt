//! Rustler NIF for the Condukt workflows authoring DSL.
//!
//! A workflow is a typed JSON document; this crate turns a Starlark
//! `.star` file into that document. The Starlark surface is purely a
//! compile-time graph builder: it evaluates once, calls `workflow(...)`
//! with the document fields, and returns the resulting JSON. There is
//! no runtime suspension and no introspection of step outputs at
//! compile time.

use rustler::{Env, NifResult, Term};

use crate::error::{EncodeResult, WorkflowsResult};

mod compiler;
mod error;
mod parse;
mod terms;
mod value;

pub(crate) mod atoms {
    rustler::atoms! {
        ok,
        error,
        parse_error,
        eval_error,
        invalid_arguments,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compile<'a>(env: Env<'a>, source: String, filename: String) -> NifResult<Term<'a>> {
    let result: WorkflowsResult<String> = compiler::compile(source, filename)
        .map(|json| serde_json::to_string(&json).unwrap_or_else(|_| "null".to_owned()));
    Ok(result.encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn parse_only<'a>(env: Env<'a>, source: String, filename: String) -> NifResult<Term<'a>> {
    Ok(parse::parse_only(source, filename).encode(env))
}

rustler::init!("Elixir.Condukt.Workflows.NIF");
