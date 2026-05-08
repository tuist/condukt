use rustler::{Encoder, Env, Term};
use thiserror::Error;

use crate::atoms;

#[derive(Debug, Error)]
pub(crate) enum WorkflowsError {
    #[error("parse error: {0}")]
    Parse(String),
    #[error("eval error: {0}")]
    Eval(String),
    #[error("invalid arguments: {0}")]
    InvalidArguments(String),
}

pub(crate) type WorkflowsResult<T> = Result<T, WorkflowsError>;

impl WorkflowsError {
    fn kind(&self) -> rustler::Atom {
        match self {
            WorkflowsError::Parse(_) => atoms::parse_error(),
            WorkflowsError::Eval(_) => atoms::eval_error(),
            WorkflowsError::InvalidArguments(_) => atoms::invalid_arguments(),
        }
    }
}

impl<T> EncodeResult for WorkflowsResult<T>
where
    T: Encoder,
{
    fn encode<'a>(self, env: Env<'a>) -> Term<'a> {
        match self {
            Ok(value) => (atoms::ok(), value).encode(env),
            Err(error) => (atoms::error(), (error.kind(), error.to_string())).encode(env),
        }
    }
}

pub(crate) trait EncodeResult {
    fn encode<'a>(self, env: Env<'a>) -> Term<'a>;
}
