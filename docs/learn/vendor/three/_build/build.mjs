import { build } from "esbuild";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const buildDirectory = dirname(fileURLToPath(import.meta.url));
const packageMetadata = JSON.parse(
  readFileSync(resolve(buildDirectory, "node_modules", "three", "package.json"), "utf8"),
);

async function buildBundle(entry, output, includes) {
  const outputFile = resolve(buildDirectory, "..", output);
  await build({
    entryPoints: [resolve(buildDirectory, entry)],
    bundle: true,
    format: "iife",
    globalName: "THREE",
    minify: true,
    outfile: outputFile,
    target: ["es2020"],
    banner: {
      js: [
        "/**",
        ` * Three.js ${packageMetadata.version}`,
        ` * Includes: ${includes}.`,
        " * Built with esbuild for the Wavenumber NXP Cup standalone lessons.",
        " * @license MIT",
        " */",
      ].join("\n"),
    },
    legalComments: "none",
    logLevel: "info",
  });

  // Three's embedded shader templates contain presentation-only trailing spaces.
  // Remove them so both the vendored runtime and the generated HTML pass the
  // repository's whitespace checks without changing JavaScript or GLSL meaning.
  const normalized = readFileSync(outputFile, "utf8")
    .replace(/[ \t]+$/gm, "")
    .replace(/^ +(?=\t)/gm, "")
    .replace(/\r\n/g, "\n");
  writeFileSync(outputFile, normalized, "utf8");
}

await buildBundle("entry.js", "three.iife.min.js", "core, WebGLRenderer, OrbitControls");
await buildBundle(
  "camera-entry.js",
  "three-camera.iife.min.js",
  "core, WebGLRenderer, OrbitControls, GLTFLoader",
);
