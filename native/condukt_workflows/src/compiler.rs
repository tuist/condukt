//! Compile-time evaluator that turns a Starlark workflow file into a
//! JSON workflow document.
//!
//! The Starlark file is the authoring surface; the JSON document is the
//! source of truth. The file evaluates at compile time and must call
//! `workflow(...)` exactly once with `name`, `inputs`, `steps`, and
//! `output` kwargs. Any Starlark feature is fair game for *building*
//! that data: `def`, `for`, `if`, `load(...)`, comments, list and dict
//! comprehensions, etc. There is no runtime suspension and no
//! introspection of step outputs at compile time. References between
//! steps are written as plain `${...}` expression strings.

use std::cell::RefCell;

use serde_json::{Map as JsonMap, Value as JsonValue};
use starlark::any::ProvidesStaticType;
use starlark::environment::{Globals, GlobalsBuilder, LibraryExtension, Module};
use starlark::eval::Evaluator;
use starlark::starlark_module;
use starlark::values::Value;
use starlark::values::none::NoneType;

use crate::error::{WorkflowsError, WorkflowsResult};
use crate::parse::parse;
use crate::value::starlark_to_json;

#[derive(ProvidesStaticType, Default)]
struct Compiler {
    document: RefCell<Option<JsonValue>>,
}

#[starlark_module]
fn compiler_globals(builder: &mut GlobalsBuilder) {
    fn workflow<'v>(
        #[starlark(require = named)] name: Option<&str>,
        #[starlark(require = named)] inputs: Option<Value<'v>>,
        #[starlark(require = named)] steps: Option<Value<'v>>,
        #[starlark(require = named)] output: Option<Value<'v>>,
        eval: &mut Evaluator<'v, '_, '_>,
    ) -> anyhow::Result<NoneType> {
        let compiler = eval
            .extra
            .ok_or_else(|| anyhow::anyhow!("workflow compiler not initialised"))?
            .downcast_ref::<Compiler>()
            .ok_or_else(|| anyhow::anyhow!("workflow compiler not initialised"))?;

        if compiler.document.borrow().is_some() {
            return Err(anyhow::anyhow!("workflow(...) called more than once"));
        }

        let mut doc = JsonMap::new();
        doc.insert(
            "$schema".to_owned(),
            JsonValue::String(
                "https://condukt.tuist.dev/schemas/condukt.workflow.schema.json".to_owned(),
            ),
        );

        if let Some(value) = name {
            doc.insert("name".to_owned(), JsonValue::String(value.to_owned()));
        }

        if let Some(value) = inputs {
            doc.insert(
                "inputs".to_owned(),
                starlark_to_json(value).map_err(|err| anyhow::anyhow!("inputs: {err}"))?,
            );
        }

        match steps {
            Some(value) => {
                doc.insert(
                    "steps".to_owned(),
                    starlark_to_json(value).map_err(|err| anyhow::anyhow!("steps: {err}"))?,
                );
            }
            None => {
                return Err(anyhow::anyhow!("workflow(...) requires `steps`"));
            }
        }

        if let Some(value) = output {
            doc.insert(
                "output".to_owned(),
                starlark_to_json(value).map_err(|err| anyhow::anyhow!("output: {err}"))?,
            );
        }

        *compiler.document.borrow_mut() = Some(JsonValue::Object(doc));
        Ok(NoneType)
    }
}

fn build_globals() -> Globals {
    GlobalsBuilder::extended_by(&[LibraryExtension::StructType])
        .with(compiler_globals)
        .build()
}

pub(crate) fn compile(source: String, filename: String) -> WorkflowsResult<JsonValue> {
    let globals = build_globals();
    let module = Module::new();
    let ast = parse(&filename, source)?;

    let compiler = Compiler::default();
    let mut eval = Evaluator::new(&module);
    eval.extra = Some(&compiler);

    eval.eval_module(ast, &globals)
        .map_err(|error| WorkflowsError::Eval(error.to_string()))?;

    drop(eval);

    compiler.document.into_inner().ok_or_else(|| {
        WorkflowsError::Eval(
            "file does not call workflow(name = ..., steps = ..., output = ...) at top level"
                .to_owned(),
        )
    })
}
