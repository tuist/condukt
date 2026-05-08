use std::collections::BTreeMap;

use starlark::syntax::{AstModule, Dialect};

use crate::error::{WorkflowsError, WorkflowsResult};
use crate::terms::NifValue;

pub(crate) fn parse(filename: &str, source: String) -> WorkflowsResult<AstModule> {
    // The Extended dialect allows top-level `for`/`if`/`while`, which the
    // authoring DSL relies on for compile-time meta-programming
    // (generating step dicts from a static list, etc.).
    AstModule::parse(filename, source, &Dialect::Extended)
        .map_err(|error| WorkflowsError::Parse(error.to_string()))
}

pub(crate) fn parse_only(source: String, filename: String) -> WorkflowsResult<NifValue> {
    let ast = parse(&filename, source)?;
    let loads: Vec<NifValue> = ast
        .loads()
        .into_iter()
        .map(|load| NifValue::String(load.module_id.to_owned()))
        .collect();

    let mut map: BTreeMap<String, NifValue> = BTreeMap::new();
    map.insert("loads".to_owned(), NifValue::List(loads));
    Ok(NifValue::Map(map))
}
