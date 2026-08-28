import { chmod, copyFile, mkdir, readdir, stat } from "node:fs/promises";
import { basename, join } from "node:path";

const targets = [
  ["darwin-arm64", "aarch64-macos"],
  ["darwin-x64", "x86_64-macos"],
  ["linux-arm64", "aarch64-linux-musl"],
  ["linux-x64", "x86_64-linux-musl"],
  ["win32-arm64", "aarch64-windows"],
  ["win32-x64", "x86_64-windows"],
];

async function findBinary(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      const nested = await findBinary(path);
      if (nested) return nested;
    } else if (/^brandpeel(?:\.exe)?$/.test(entry.name)) {
      return path;
    }
  }
  return undefined;
}

for (const [target, zigTarget] of targets) {
  let source;
  for (const directory of [
    join("dist", `brandpeel-${target}`),
    join("dist", zigTarget),
  ]) {
    try {
      source = await findBinary(directory);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    if (source) break;
  }
  if (!source || !(await stat(source)).isFile()) {
    throw new Error(`Missing release binary for ${target}`);
  }
  const binDirectory = join("packages", target, "bin");
  await mkdir(binDirectory, { recursive: true });
  const destination = join(binDirectory, basename(source));
  await copyFile(source, destination);
  if (!destination.endsWith(".exe")) await chmod(destination, 0o755);
}
