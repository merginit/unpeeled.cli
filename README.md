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

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Success |
| 1 | Unexpected internal failure |
| 2 | Invalid command or option |
| 3 | Invalid export or strict contrast failure |
| 4 | Filesystem or output conflict |
| 5 | Network, protocol, or API failure |

Brand Peel CLI is licensed under the [MIT License](LICENSE).
