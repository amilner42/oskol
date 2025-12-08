#!/usr/bin/env node

const esbuild = require("esbuild");
const ElmPlugin = require("esbuild-plugin-elm");

const args = process.argv.slice(2);
const watch = args.includes("--watch");
const deploy = args.includes("--deploy");

const plugins = [
  ElmPlugin({
    debug: false,
    optimize: deploy,
    pathToElm: "../node_modules/.bin/elm",
  }),
];

const config = {
  entryPoints: ["js/app.js"],
  bundle: true,
  target: "es2022",
  outdir: "../priv/static/assets/js",
  external: ["/fonts/*", "/images/*", "phoenix-colocated/oskol"],
  alias: {
    "@": ".",
  },
  plugins: plugins,
  logLevel: "info",
};

if (watch) {
  esbuild
    .context(config)
    .then((ctx) => {
      ctx.watch();
      console.log("Watching for changes...");
    })
    .catch(() => process.exit(1));
} else {
  esbuild.build(config).catch(() => process.exit(1));
}
