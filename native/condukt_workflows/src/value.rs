use serde_json::{Map as JsonMap, Value as JsonValue};
use starlark::values::Value;
use starlark::values::dict::DictRef;
use starlark::values::list::ListRef;
use starlark::values::tuple::TupleRef;

use crate::error::{WorkflowsError, WorkflowsResult};

pub(crate) fn starlark_to_json(value: Value<'_>) -> WorkflowsResult<JsonValue> {
    if value.is_none() {
        return Ok(JsonValue::Null);
    }

    if let Some(b) = value.unpack_bool() {
        return Ok(JsonValue::Bool(b));
    }

    if let Some(i) = value.unpack_i32() {
        return Ok(JsonValue::Number(serde_json::Number::from(i)));
    }

    if let Some(s) = value.unpack_str() {
        return Ok(JsonValue::String(s.to_owned()));
    }

    if let Some(list) = ListRef::from_value(value) {
        let entries = list
            .iter()
            .map(starlark_to_json)
            .collect::<WorkflowsResult<Vec<_>>>()?;
        return Ok(JsonValue::Array(entries));
    }

    if let Some(tuple) = TupleRef::from_value(value) {
        let entries = tuple
            .iter()
            .map(starlark_to_json)
            .collect::<WorkflowsResult<Vec<_>>>()?;
        return Ok(JsonValue::Array(entries));
    }

    if let Some(dict) = DictRef::from_value(value) {
        let mut entries = JsonMap::with_capacity(dict.len());
        for (key, value) in dict.iter() {
            let key = key.unpack_str().ok_or_else(|| {
                WorkflowsError::InvalidArguments("dict keys must be strings".into())
            })?;
            entries.insert(key.to_owned(), starlark_to_json(value)?);
        }
        return Ok(JsonValue::Object(entries));
    }

    if let Ok(json_string) = value.to_json() {
        if let Ok(parsed) = serde_json::from_str::<JsonValue>(&json_string) {
            return Ok(parsed);
        }
    }

    Err(WorkflowsError::InvalidArguments(format!(
        "cannot convert Starlark value of type {} to JSON",
        value.get_type()
    )))
}

