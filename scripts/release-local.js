import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const registry = "https://registry.npmjs.org";
const npmCommand = process.platform === "win32" ? "npm.cmd" : "npm";
const versionPattern = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

const nativePackages = [
  ["darwin-arm64", "aarch64-macos"],
  ["darwin-x64", "x86_64-macos"],
  ["linux-arm64", "aarch64-linux-musl"],
  ["linux-x64", "x86_64-linux-musl"],
  ["win32-arm64", "aarch64-windows"],
  ["win32-x64", "x86_64-windows"],
].map(([directory, zigTarget]) => ({
  directory,
  zigTarget,
  path: `packages/${directory}`,
}));

const packages = [
  ...nativePackages,
  { directory: "cli", path: "packages/cli" },
];

function commandText(command, args) {
  return [command, ...args].join(" ");
}

function usesWindowsShell(command) {
  return process.platform === "win32" && command === npmCommand;
}

function run(command, args, cwd, { capture = false } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    shell: usesWindowsShell(command),
    stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
    windowsHide: true,
  });

  if (result.error) {
    throw new Error(`Unable to run ${command}: ${result.error.message}`);
  }

  if (result.status !== 0) {
    const detail = capture
      ? `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim()
      : "";
    throw new Error(
      `Command failed with exit code ${result.status}: ${commandText(command, args)}${detail ? `\n${detail}` : ""}`,
    );
  }

  return result;
}

function output(result) {
  return (result.stdout ?? "").trim();
}

function resolveReleaseTag(argument) {
  if (argument) {
    const version = argument.startsWith("v") ? argument.slice(1) : argument;
    if (!versionPattern.test(version)) {
      throw new Error(`Invalid version: ${argument}. Expected a semantic version.`);
    }

    const tag = `v${version}`;
    const result = spawnSync(
      "git",
      ["rev-parse", "--verify", `refs/tags/${tag}^{commit}`],
      {
        cwd: root,
        encoding: "utf8",
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      },
    );
    if (result.error || result.status !== 0) {
      throw new Error(`Tag ${tag} does not exist locally.`);
    }
    return tag;
  }

  const tag = output(
    run(
      "git",
      ["describe", "--tags", "--match", "v[0-9]*", "--abbrev=0"],
      root,
      { capture: true },
    ),
  );
  if (!tag || !tag.startsWith("v") || !versionPattern.test(tag.slice(1))) {
    throw new Error(
      "Could not find a reachable v* version tag. Pass the version explicitly.",
    );
  }
  return tag;
}

function warnIfWorktreeDirty() {
  const status = output(
    run("git", ["status", "--porcelain"], root, { capture: true }),
  );
  if (status) {
    console.warn(
      "Working tree has uncommitted changes; only the tagged commit will be released.",
    );
  }
}

async function readPackageName(cwd, packagePath) {
  const manifest = JSON.parse(
    await readFile(join(cwd, packagePath, "package.json"), "utf8"),
  );
  return manifest.name;
}

function isRegistryFailure(result) {
  const detail = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  return /EAI_AGAIN|ECONNREFUSED|ECONNRESET|ENETUNREACH|ENOTFOUND|ETIMEDOUT|ENEEDAUTH|E401|E403|fetch failed|network/i.test(
    detail,
  );
}

function isPublished(cwd, name, version) {
  const result = spawnSync(
    npmCommand,
    ["view", `${name}@${version}`, "version", "--registry", registry],
    {
      cwd,
      encoding: "utf8",
      shell: usesWindowsShell(npmCommand),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );

  if (result.error) {
    throw new Error(`Unable to query npm: ${result.error.message}`);
  }
  if (result.status === 0) return true;
  if (isRegistryFailure(result)) {
    const detail = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim();
    throw new Error(`Could not query npm for ${name}@${version}.\n${detail}`);
  }
  return false;
}

async function testFiles(cwd) {
  const directories = ["packages/cli/test", "test"];
  const files = [];
  for (const directory of directories) {
    const entries = await readdir(join(cwd, directory), {
      withFileTypes: true,
    });
    for (const entry of entries) {
      if (entry.isFile() && entry.name.endsWith(".test.js")) {
        files.push(join(directory, entry.name));
      }
    }
  }
  return files.sort();
}

async function main() {
  if (process.argv[2] === "--help" || process.argv[2] === "-h") {
    console.log("Usage: npm run release:local [-- <version>]\n");
    console.log(
      "With no version, the script uses the nearest reachable v* tag.",
    );
    return;
  }

  const [nodeMajor, nodeMinor] = process.versions.node
    .split(".")
    .map(Number);
  if (nodeMajor < 22 || (nodeMajor === 22 && nodeMinor < 14)) {
    throw new Error("Node.js 22.14.0 or newer is required.");
  }

  const releaseTag = resolveReleaseTag(process.argv[2]);
  const version = releaseTag.slice(1);
  console.log(`Preparing local release ${version} from tag ${releaseTag}.`);
  warnIfWorktreeDirty();

  const stagingRoot = await mkdtemp(join(tmpdir(), "brandpeel-release-"));
  try {
    console.log(`Building in temporary staging directory ${stagingRoot}.`);
    run(
      "git",
      ["clone", "--local", "--no-hardlinks", "--branch", releaseTag, root, stagingRoot],
      root,
    );

    const packageInfo = [];
    for (const packageEntry of packages) {
      const name = await readPackageName(stagingRoot, packageEntry.path);
      const published = isPublished(stagingRoot, name, version);
      packageInfo.push({ ...packageEntry, name, published });
      console.log(
        `${name}@${version}: ${published ? "already published" : "needs publishing"}`,
      );
    }

    if (packageInfo.every((packageEntry) => packageEntry.published)) {
      console.log("All seven packages are already published; nothing to do.");
      return;
    }

    const npmIdentity = output(
      run(npmCommand, ["whoami", "--registry", registry], root, {
        capture: true,
      }),
    );
    console.log(`Authenticated with npm as ${npmIdentity}.`);
    console.log(`Using Zig ${output(run("zig", ["version"], root, { capture: true }))}.`);

    run(npmCommand, ["ci", "--omit=dev", "--omit=optional"], stagingRoot);
    run(npmCommand, ["run", "version:sync", "--", version], stagingRoot);

    for (const packageEntry of nativePackages) {
      run(
        "zig",
        [
          "build",
          "-Doptimize=ReleaseSafe",
          `-Dtarget=${packageEntry.zigTarget}`,
          "--prefix",
          `dist/${packageEntry.zigTarget}`,
        ],
        stagingRoot,
      );
    }

    run(process.execPath, ["scripts/assemble-release.js"], stagingRoot);
    run("zig", ["build"], stagingRoot);
    run("zig", ["build", "test"], stagingRoot);
    run(process.execPath, ["--test", ...(await testFiles(stagingRoot))], stagingRoot);
    run(npmCommand, ["run", "pack:check"], stagingRoot);
    run(npmCommand, ["run", "pack:inspect"], stagingRoot);

    for (const packageEntry of packageInfo) {
      if (isPublished(stagingRoot, packageEntry.name, version)) {
        console.log(`${packageEntry.name}@${version} is already published; skipping.`);
        continue;
      }

      run(
        npmCommand,
        [
          "publish",
          `./${packageEntry.path}`,
          "--access",
          "public",
          "--provenance=false",
          "--registry",
          registry,
        ],
        stagingRoot,
      );
    }
  } finally {
    await rm(stagingRoot, { recursive: true, force: true });
  }

  console.log(`Local release ${version} completed.`);
  console.log(`Next: git push origin main refs/tags/v${version}`);
}

main().catch((error) => {
  console.error(`\nLocal release failed: ${error.message}`);
  process.exitCode = 1;
});
