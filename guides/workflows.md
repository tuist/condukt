# Workflows

A workflow is a typed JSON document describing a directed acyclic graph
of steps. The document is the source of truth: it is what `condukt
run` executes, what `condukt check` validates, and what editors and
agents read and write. The basename of the file is the run name.

There is no project layout, manifest, or lockfile. To run a workflow
you point the engine at a `.json`, `.yaml`, or `.star` path.

## A first workflow

`hello.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json",
  "inputs": {
    "name": { "type": "string" }
  },
  "steps": {
    "greet": {
      "kind": "cmd",
      "argv": ["echo", "Hello, ${inputs.name}"]
    }
  },
  "output": "${steps.greet.stdout}"
}
```

Run it with the standalone engine or with Mix:

```sh
condukt run hello.json --input '{"name": "world"}'
mix condukt.run hello.json --input '{"name": "world"}'
```

The resolved `output` expression is printed on stdout. Strings are
printed as is, other values are JSON-encoded.

## The schema

The workflow document is validated against a published JSON Schema.
The canonical source lives in this repository at
`priv/schemas/condukt.workflow.schema.json` and is reachable on GitHub
at:

```
https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json
```

Reference it from a workflow file with the standard `$schema` key so
editors pick up auto-completion and validation.

The top-level shape is:

```jsonc
{
  "name": "review-pr",            // optional, defaults to file basename
  "inputs": { ... },              // typed input map (JSON Schema fragments)
  "steps": { "<id>": { ... } },   // map of step id to step definition
  "output": "<expression>"        // optional, what `condukt run` prints
}
```

A step has the shape:

```jsonc
{
  "kind": "cmd" | "agent" | "http" | "tool" | "map",
  "needs": ["other_step"],        // explicit dependencies, optional
  "when": "<expression>",         // optional gate; step is skipped if false
  // ...kind-specific fields
}
```

Implicit dependencies are inferred from `${steps.X.*}` references
inside any field, so `needs:` is only required when the dependency is
purely ordering and not data flow.

## Step kinds

- `cmd`: runs an executable on the host. Fields: `argv` (list of
  strings, required), `cwd` (optional), `env` (optional dict).
  Outputs: `stdout`, `exit_code`, `ok`.
- `agent`: runs an LLM-driven step. Fields: `model` (required),
  `input` (required, any), `tools` (optional list of tool ids),
  `system` (optional system prompt), `output_schema` (optional JSON
  Schema for structured output). Output: `output` and `ok`.
- `http`: deterministic HTTP call. Fields: `method`, `url`, `headers`,
  `body`, `expect_status`. Output: `status`, `headers`, `body`.
- `tool`: invokes a registered host tool by id. Fields: `id`, `args`.
  Output: `output` and `ok`.
- `map`: fan-out. Fields: `over` (expression resolving to a list),
  `as` (binding name), `do` (a sub-step definition). Output: a list of
  the sub-step's outputs in input order.

Each step's outputs are addressable as `${steps.<id>.<field>}` from
later steps and from the top-level `output`.

## Expressions

Expressions live between `${` and `}`. They are evaluated against
`inputs`, `steps`, and (inside a `map` step) the `as` binding.

Supported:

- Member access: `inputs.name`, `steps.fetch.body.title`
- Indexing: `steps.list.items[0]`, `obj["a key"]`, negative indices
- Comparisons: `==`, `!=`, `<`, `<=`, `>`, `>=`
- Boolean: `&&`, `||`, `!`
- Unary minus: `-1`, `xs[-1]`
- Literals: strings, numbers, booleans, null, parens
- Type-aware formatters: `${var:json}`, `${var:csv}`

Not supported:

- Arbitrary function calls, regex, or arithmetic beyond comparisons.
  Anything more substantial belongs in a `cmd`, `agent`, or `tool`
  step.

A `when:` expression must evaluate to a boolean. Member access on
`null` returns `null` so a reference to a skipped step degrades
gracefully; typos against a real value still raise a loud error.

## Skipping and cascade

If a step's `when:` evaluates to false, the step is skipped. Any
downstream step whose declared or inferred dependencies include a
skipped step is also skipped. The step's slot in `steps.<id>` is set
to `null`.

## YAML

YAML files (`.yaml`, `.yml`) are accepted and converted to the same
JSON document at load time. The same `hello.json` above looks like:

```yaml
$schema: https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json
inputs:
  name:
    type: string
steps:
  greet:
    kind: cmd
    argv: ["echo", "Hello, ${inputs.name}"]
output: "${steps.greet.stdout}"
```

## Authoring DSL (Starlark)

Hand-writing JSON or YAML is fine for most workflows. For larger
graphs there is an authoring DSL: a Starlark file that compiles to
the same JSON document. The Starlark layer runs at compile time and
lets you use `def`, `for`, `if`, list and dict comprehensions, and
`load(...)` to build the document programmatically. There is no
runtime suspension and no introspection of step outputs at compile
time: references between steps are written as plain `${...}`
expression strings.

`hello.star`:

```python
workflow(
    name = "hello",
    inputs = {"name": {"type": "string"}},
    steps = {
        "greet": {
            "kind": "cmd",
            "argv": ["echo", "Hello, ${inputs.name}"],
        },
    },
    output = "${steps.greet.stdout}",
)
```

Compile and run:

```sh
condukt compile hello.star > hello.json
condukt run hello.json --input '{"name": "world"}'
```

`condukt run hello.star` does the compile step transparently.

A more substantial example uses `for` to fan out a map step over a
static list of stages:

```python
stages = ["lint", "test", "build"]

steps = {}
for stage in stages:
    steps[stage] = {
        "kind": "cmd",
        "argv": ["./script/" + stage],
    }

workflow(
    steps = steps,
    output = {stage: "${steps." + stage + ".stdout}" for stage in stages},
)
```

The `workflow(...)` builtin must be called exactly once at top level.
Any Starlark feature is fair game for *building* the data; it is
expression strings, not Starlark values, that represent runtime
references between steps.

## Validating a workflow

`condukt check PATH` parses and validates the document against the
schema and reports all problems without executing it. It accepts
`.json`, `.yaml`, and `.star` paths.

```sh
condukt check review-pr.json
condukt check review-pr.star
```

Use it in CI or as part of an LLM authoring loop: generate, check,
fix, repeat.

## Future direction

These are planned but not yet implemented:

- Remote `load(...)` of versioned helpers from
  `github.com/owner/repo/path/file.star@v1.0.0`, with the compiled
  JSON cached locally.
- Optional `--lock` mode that records SHA-256 per fetched URL and
  verifies on later runs (Deno-style integrity).
- Triggers (`condukt.trigger.webhook`, `condukt.schedule.cron`) and
  `condukt serve PATH` to host webhook and cron-driven runs.
- Visual editor that reads and writes the same JSON document.
