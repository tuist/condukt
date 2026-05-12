# HTTP Routes

Typed operations can be exposed as JSON HTTP endpoints with `Condukt.Plug` or
`Condukt.Phoenix`. This is intended for statically declared agent entrypoints
that have input and output schemas.

## Declare an operation

```elixir
defmodule MyApp.ReviewAgent do
  use Condukt

  operation :review_pr,
    input: %{
      type: "object",
      properties: %{
        repo: %{type: "string"},
        pr_number: %{type: "integer"}
      },
      required: ["repo", "pr_number"]
    },
    output: %{
      type: "object",
      properties: %{
        verdict: %{type: "string", enum: ["approve", "request_changes", "comment"]},
        summary: %{type: "string"}
      },
      required: ["verdict", "summary"]
    },
    instructions: "Review the pull request and return a verdict."
end
```

Each request runs the operation through Condukt's one-shot structured run path.
No conversation history is kept between HTTP requests.

## Plug Router

```elixir
defmodule MyApp.Router do
  use Plug.Router

  import Condukt.Plug, only: [operation_route: 3, operation_route: 4]

  plug Plug.Parsers, parsers: [:json], json_decoder: JSON
  plug :match
  plug :dispatch

  operation_route "/review-pr", MyApp.ReviewAgent, :review_pr,
    run_opts: [timeout: 120_000]
end
```

You can also mount `Condukt.Plug` directly:

```elixir
post "/review-pr",
  to: Condukt.Plug,
  init_opts: [
    agent: MyApp.ReviewAgent,
    operation: :review_pr,
    run_opts: [timeout: 120_000]
  ]
```

## Phoenix Router

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  import Condukt.Phoenix, only: [operation_route: 3, operation_route: 4]

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MyAppWeb do
    pipe_through :api

    operation_route "/review-pr", MyApp.ReviewAgent, :review_pr,
      run_opts: [timeout: 120_000]
  end
end
```

Phoenix pipelines normally parse JSON before the action runs. If
`conn.body_params` has not been fetched, `Condukt.Plug` reads and decodes the
request body itself.

## Request and response shape

Requests are JSON objects that match the operation input schema:

```json
{
  "repo": "tuist/condukt",
  "pr_number": 42
}
```

Successful responses use this envelope:

```json
{
  "ok": true,
  "result": {
    "verdict": "approve",
    "summary": "Looks good."
  }
}
```

Errors use this envelope:

```json
{
  "ok": false,
  "error": {
    "code": "invalid_input",
    "message": "..."
  }
}
```

Input validation failures return `422`, malformed JSON returns `400`, unknown
operations return `404`, and structured agent failures return `502` or `500`
depending on where the failure happened.

## Per-request run options

Use `:run_opts` to pass the same options accepted by `Condukt.Operation.run/4`.
The value can be a keyword list or a one-arity function that receives the
connection:

```elixir
operation_route "/review-pr", MyApp.ReviewAgent, :review_pr,
  run_opts: &MyApp.RouteOptions.condukt_run_opts/1
```

If the HTTP input should come from somewhere other than the JSON body, pass an
`:input` function. In router declarations, use remote captures rather than
anonymous functions because route options are stored at compile time:

```elixir
post "/repos/:owner/:repo/pulls/:number/review",
  to: Condukt.Plug,
  init_opts: [
    agent: MyApp.ReviewAgent,
    operation: :review_pr,
    input: &MyApp.RouteOptions.review_input/1
  ]
```

```elixir
defmodule MyApp.RouteOptions do
  def condukt_run_opts(conn) do
    [
      api_key: fetch_session_api_key(conn),
      timeout: 120_000
    ]
  end

  def review_input(conn) do
    %{
      "repo" => conn.path_params["owner"] <> "/" <> conn.path_params["repo"],
      "pr_number" => String.to_integer(conn.path_params["number"])
    }
  end
end
```
