# Workflows

A workflow is a typed JSON document describing a directed acyclic graph
of steps. The document is the source of truth: it is what `condukt run`
executes, what `condukt check` validates, and what editors and agents
read and write. The basename of the file is the run name.

There is no project layout, manifest, or lockfile. To run a workflow you
point the engine at a path or, in a future slice, a versioned URL.

## A first workflow

`hello.json`:

```json
{
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

YAML is accepted on input as a JSON superset. The canonical on-disk form
is JSON; YAML is converted at load time.

## The schema

The workflow document is validated against a published JSON Schema,
`condukt.workflow.schema.json`. The top-level shape is:

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

Implicit dependencies are inferred from `${steps.X.*}` references inside
a step's fields, so `needs:` is only required when the dependency is
purely ordering and not data flow.

## Step kinds

- `cmd`: runs an executable on the host. Fields: `argv` (list of
  strings), `cwd` (optional), `env` (optional dict). Outputs: `stdout`,
  `exit_code`, `ok`.
- `agent`: runs an LLM-driven step. Fields: `model`, `tools` (list of
  tool ids), `input`. Outputs: `output` and any structured fields the
  agent declares.
- `http`: deterministic HTTP call. Fields: `method`, `url`, `headers`,
  `body`. Outputs: `status`, `headers`, `body`.
- `tool`: invokes a registered host tool by id. Fields: `id`, `args`.
- `map`: fan-out. Fields: `over` (expression resolving to a list),
  `as` (binding name), `do` (a sub-step definition). Outputs: a list of
  the sub-step's outputs in input order.

Each step's outputs are addressable as `${steps.<id>.<field>}` from
later steps and from the top-level `output`.

## Expressions

Expressions are written between `${` and `}`. They are evaluated against
a small, deterministic context: `inputs`, `steps`, and within a `map`
step, the `as` binding.

Supported in expressions:

- Member access: `inputs.name`, `steps.fetch.body.title`.
- Indexing: `steps.list.items[0]`.
- Comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`.
- Boolean: `&&`, `||`, `!`.
- String, number, and boolean literals.
- Type-aware formatters: `${var:json}`, `${var:csv}`.

Not supported:

- Arbitrary function calls, regex, or arithmetic beyond comparisons.
  Anything more substantial belongs in a `cmd`, `agent`, or `tool`
  step.

A `when:` expression must evaluate to a boolean. A field in a step that
is a string with `${...}` placeholders is interpolated; if the entire
string is one `${...}`, the underlying value's type is preserved.

## Authoring DSL (Starlark)

Hand-writing JSON is fine for small workflows and for what editors and
agents emit. For larger workflows there is an authoring DSL that
compiles to the same JSON document. The DSL is a Starlark dialect: it
runs at compile time, builds the step graph, and prints JSON.

`review-pr.star`:

```python
def run():
    pr = http.get(
        "https://api.github.com/repos/${inputs.repo}/pulls/${inputs.pr_number}",
    )
    review = agent(
        model = "claude-opus-4-7",
        input = pr.body,
    )
    if review.output.score < 7:
        http.post(
            url = "https://api.github.com/repos/${inputs.repo}/issues/${inputs.pr_number}/comments",
            body = {"body": review.output.comment},
        )
    return review.output

workflow(
    inputs = {
        "repo": {"type": "string"},
        "pr_number": {"type": "integer"},
    },
)
```

Compile and run:

```sh
condukt compile review-pr.star > review-pr.json
condukt run review-pr.json --input '{"repo": "tuist/condukt", "pr_number": 42}'
```

`condukt run review-pr.star` does the compile step transparently.

What the DSL does at compile time:

- Each builtin call (`http.get`, `agent`, `cmd`, etc.) returns a *step
  handle*, not a real value. Reading `.body` on a handle records a
  reference and emits a `${steps.X.body}` expression in the generated
  JSON.
- `if cond:` becomes a `when:` expression on the steps inside the
  branch. The condition is compiled from the Starlark expression.
- `for item in xs:` becomes a `map:` step.
- `def` and `load("...", "name")` are compile-time only. They produce
  helpers that fold into the graph; they do not appear in the output
  JSON.

Because the DSL is a graph builder, it cannot do runtime branching on a
step's actual value: control flow must be expressible as a `when:` edge
or a `map:` step. This is the property that lets the JSON document
remain statically validatable, visually editable, and safe to load from
arbitrary URLs.

## Validating a workflow

`condukt check PATH` parses and validates the document against the
schema and reports all problems without executing it. It accepts
`.json`, `.yaml`, and `.star` paths; for `.star` it compiles first and
then validates the JSON.

```sh
condukt check review-pr.json
condukt check review-pr.star
```

Use it in CI or as part of an LLM authoring loop: generate, check,
fix, repeat.

## Future direction

These are planned but not yet implemented:

- Remote `load(...)` of versioned helpers from
  `github.com/owner/repo/path/file.star@v1.0.0`, with the compiled JSON
  cached locally.
- Optional `--lock` mode that records SHA-256 per fetched URL and
  verifies on later runs (Deno-style integrity).
- Triggers (`condukt.trigger.webhook`, `condukt.schedule.cron`) and
  `condukt serve PATH` to host webhook and cron-driven runs. Triggers
  are declared at the top of the JSON document and exposed by the DSL
  through a `condukt` namespace.
- Visual editor that reads and writes the same JSON document.
