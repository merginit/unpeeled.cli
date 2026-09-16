# @merginit/brandpeel

This package installs the native [`brandpeel`](https://brandpeel.app/developers)
command for the current operating system and CPU architecture.

```sh
npx @merginit/brandpeel --help
```

## MCP

The native executable includes a stdio MCP server with four local export tools
and seven read-only API tools. Configure your MCP client with:

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

Requires an MCP client supporting the `2025-11-25` handshake-based protocol.
Local tools require absolute paths. Token exports and book compilation return
content by default; files are written only with an explicit `output`, and existing
files are replaced only with `force: true`. The server uses the caller's account
filesystem permissions and does not provide a filesystem sandbox. MCP mode does
not accept `--json`.

See the [repository documentation](https://github.com/merginit/unpeeled.cli#readme) for tool inputs, limits, and API configuration.
