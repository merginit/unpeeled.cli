# Changelog

All notable changes to Brand Peel CLI are documented here.

## 0.2.0 - 2026-09-16

- Added a native `brandpeel mcp` stdio server implementing the MCP 2025-11-25
  lifecycle, tool discovery, and tool calls in the existing executable and npm
  package.
- Exposed four local export tools and seven public API tools with typed input
  schemas, absolute local paths, explicit file writes, and overwrite protection.
- Added structured MCP tool results and recoverable validation/API errors with
  bounded input frames, JSON nesting, and reusable per-request memory.
- Rejected non-string theme values, including nested objects and arrays, as
  invalid themes before token serialization.
- Added end-to-end MCP coverage for the native binary and npm launcher,
  local tools, mock API failures, malformed messages, and long-lived sessions.
- Kept version output and MCP server metadata tied to the shared CLI version.

## 0.1.0 - 2026-08-28

- Initial native CLI for inspecting, validating, and compiling Brand Peel exports.
- WCAG 2 contrast diagnostics for light and dark semantic theme tokens.
- CSS, Tailwind CSS v4, JSON, and TypeScript token exporters.
- Read-only client commands for the public Brand Peel API.
- Native npm packages for macOS, Linux, and Windows on arm64 and x64.
