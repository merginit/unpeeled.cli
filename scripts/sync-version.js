import { readFile, writeFile } from "node:fs/promises";

const version = process.argv[2];
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version ?? "")) {
  console.error("Usage: npm run version:sync -- <semver>");
  process.exit(2);
}

const packagePaths = [
  "package.json",
  "packages/cli/package.json",
  "packages/darwin-arm64/package.json",
  "packages/darwin-x64/package.json",
  "packages/linux-arm64/package.json",
  "packages/linux-x64/package.json",
  "packages/win32-arm64/package.json",
  "packages/win32-x64/package.json",
];

for (const path of packagePaths) {
  const manifest = JSON.parse(await readFile(path, "utf8"));
  manifest.version = version;
  if (manifest.optionalDependencies) {
    for (const name of Object.keys(manifest.optionalDependencies)) {
      manifest.optionalDependencies[name] = version;
    }
  }
  await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`);
}

const zonPath = "build.zig.zon";
const zon = await readFile(zonPath, "utf8");
await writeFile(
  zonPath,
  zon.replace(/\.version = "[^"]+"/, `.version = "${version}"`),
);

const cliPath = "src/cli.zig";
const cli = await readFile(cliPath, "utf8");
await writeFile(
  cliPath,
  cli
    .replace(/pub const version = "[^"]+";/, `pub const version = "${version}";`)
    .replace(/\\Brand Peel CLI [^\r\n]+/, `\\Brand Peel CLI ${version}`),
);

const apiPath = "src/api.zig";
const api = await readFile(apiPath, "utf8");
await writeFile(
  apiPath,
  api.replace(/brandpeel-cli\/[^"]+/, `brandpeel-cli/${version}`),
);
