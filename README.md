# Brand Peel CLI

The official native command-line interface for [Brand Peel](https://brandpeel.app).
It validates exports created by the Brand Peel desktop app, audits semantic color
contrast, compiles design tokens, creates a single `BRAND.md`, and reads the public
Brand Peel API.

## Install

```sh
npm install --global @merginit/brandpeel
brandpeel --version
```

You can also run it without a global installation:

```sh
npx @merginit/brandpeel inspect ./my-brand-export
```

## Local releases

With a local `v*` version tag and an authenticated npm account, run the
complete release locally:

```sh
npm run release:local
```

The command checks npm first, builds all six native targets, validates the
packed files, publishes native packages before the CLI wrapper, and resumes
safely if a partial publication already exists. It uses a temporary staging
copy and does not push Git refs.

## Local export commands

```sh
brandpeel inspect ./my-brand-export
brandpeel doctor ./my-brand-export --strict
brandpeel export ./my-brand-export --format tailwind-v4 -o brandpeel.tailwind.css
brandpeel compile-book ./my-brand-export -o BRAND.md
```

A Brand Peel project export contains `.brand-peel-export.json`, `identity.md`,
`visual.md`, `guidelines.md`, `theme.json`, `theme.css`, and optional assets.

## Public API commands

```sh
brandpeel api health
brandpeel api release --platform windows --channel stable
brandpeel api tools --query contrast
brandpeel api tool contrast-checker
brandpeel api schema --version 1.0.0
brandpeel api agent-info --include functions
brandpeel api cli-manifest --platform linux
```

Use `--json` for a stable machine-readable envelope. The public API base URL can
be overridden with `--api-base-url` or `BRANDPEEL_API_BASE_URL`. Plain HTTP is
accepted only for `localhost`, `127.0.0.1`, and `[::1]`.

## MCP server

`brandpeel mcp` serves the Model Context Protocol over stdio. Configure an MCP
client that supports stdio servers with:

```json
{
  "mcpServers": {
    "brandpeel": {
      "command": "npx",
      "args": ["-y", "@merginit/brandpeel", "mcp"]
    }
  }
}
```

The server implements the [MCP 2025-11-25 stdio protocol](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports):
`initialize`, `notifications/initialized`, `ping`, `tools/list`, and `tools/call`.
It advertises only tools, returns all tools in one page, and offers `2025-11-25`
when a client requests an unsupported version. Clients must accept that version
or disconnect. It does not implement HTTP transport, resources, prompts, tasks,
or the newer handshake-free protocol.

| MCP tool           | Inputs                                                 |
| ------------------ | ------------------------------------------------------ |
| `inspect`          | Required `directory`                                   |
| `doctor`           | Required `directory`; optional `strict`                |
| `export`           | Required `input`, `format`; optional `output`, `force` |
| `compile_book`     | Required `directory`; optional `output`, `force`       |
| `api_health`       | Optional `detail`                                      |
| `api_release`      | Optional `platform`, `channel`                         |
| `api_tools`        | Optional `category`, `query`                           |
| `api_tool`         | Required `slug`                                        |
| `api_schema`       | Optional `version`                                     |
| `api_agent_info`   | Optional `include`                                     |
| `api_cli_manifest` | Optional `platform`                                    |

Enum values match the CLI commands above; `export` accepts `css`, `tailwind-v4`,
`json`, or `typescript`. All local input **and output** paths must be absolute.
For example, call `doctor` with `{"directory":"/absolute/my-brand-export","strict":true}`.
Use Windows paths such as `"D:\\brands\\my-brand-export"` on Windows.
Optional booleans default to `false`. Unknown arguments and invalid values are
rejected rather than silently ignored.

`export` and `compile_book` return content without writing files unless `output`
is supplied. Existing outputs are protected unless `force: true` is explicitly
provided; `force` also requires `output`. They run with your OS account's file
permissions, **not in a filesystem sandbox**. Absolute paths make the target
explicit; they are not an access-control boundary. Filesystem access is controlled
by the caller's OS account.
Local export data is not uploaded by the API tools.

Tool results contain the existing `{ok, command, data}` or `{ok, error}` envelope
in `structuredContent`, with a text representation in `content`. Tool failures
set `isError: true` and leave the connection usable. Malformed protocol requests
receive JSON-RPC errors. stdout contains only newline-delimited protocol messages;
diagnostics belong on stderr. MCP mode does not accept `--json`.

One tool call executes at a time; overlapping calls receive a retryable JSON-RPC
error (`-32000`). Ping and tool discovery remain responsive during API work.
Close stdin to shut down after the current request;
there is no shutdown RPC. Cancellation notifications do not interrupt an in-flight
tool. API calls still have a 15-second timeout, a 4 MiB response limit, and at most
five redirects. To override the base URL or timeout, put `--api-base-url URL` or
`--timeout SECONDS` **before** `mcp` in `args`; the environment override also works.
Input frames are limited to 1 MiB and 64 JSON nesting levels. Each request uses
reusable tool scratch memory capped at 256 MiB, with a separate 64 MiB control
buffer. Oversized frames are discarded up to
the next newline so later requests can recover.

## Exit codes

| Code | Meaning                                   |
| ---: | ----------------------------------------- |
|    0 | Success                                   |
|    1 | Unexpected internal failure               |
|    2 | Invalid command or option                 |
|    3 | Invalid export or strict contrast failure |
|    4 | Filesystem or output conflict             |
|    5 | Network, protocol, or API failure         |

Brand Peel CLI is licensed under the [MIT License](LICENSE).
