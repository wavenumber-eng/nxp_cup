const { test, expect } = require("@playwright/test");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const repoRoot = path.resolve(__dirname, "../../..");
const lessonUrl = pathToFileURL(
  path.join(repoRoot, "docs/learn/camera_scanline_lab.html"),
).href;
const publicHeader = fs.readFileSync(
  path.join(repoRoot, "src/embedded/nxp_cup_core0/source/nxp_cup.h"),
  "utf8",
);
const visionExample = fs.readFileSync(
  path.join(repoRoot, "src/embedded/nxp_cup_core0/source/app/vision_test.c"),
  "utf8",
);

test("camera scanline laboratory teaches firmware-shaped one-bit filters", async ({ page }) => {
  const pageErrors = [];
  const networkRequests = [];
  page.on("pageerror", error => pageErrors.push(error.message));
  page.on("request", request => {
    if (/^https?:/.test(request.url())) networkRequests.push(request.url());
  });

  await page.goto(lessonUrl);
  await expect(page).toHaveTitle(/Interactive One-Bit Scanline Lab/);
  await expect(page.locator("#camfeed")).toBeVisible();
  await expect(page.getByRole("heading", { name: /Raw scan-row Y profile/ })).toBeVisible();
  await expect(page.locator("#filter-mask-plot")).toBeVisible();
  await expect(page.locator("#blue-filter-mask-plot")).toBeVisible();
  await expect(page.locator("#plot1")).toHaveAttribute("height", "96");
  await expect(page.locator("#filter-mask-plot")).toHaveAttribute("data-black-edge-count", /\d+/);
  await expect(page.locator("#filter-main-analysis")).toHaveText(/pixels match · \d+ transitions$/);
  await expect(page.locator("#blue-filter-main-analysis")).toHaveText(/\d+ \/ 320 pixels match$/);
  await expect(page.locator("#analysis")).toBeHidden();

  const compactLayout = await page.evaluate(() => {
    const camera = document.querySelector(".feedwrap").getBoundingClientRect();
    const raw = document.getElementById("plot1").getBoundingClientRect();
    const black = document.getElementById("filter-mask-plot").getBoundingClientRect();
    const blue = document.getElementById("blue-filter-mask-plot").getBoundingClientRect();
    return {
      cameraWidth: camera.width,
      cameraHeight: camera.height,
      plotWidth: raw.width,
      plotHeight: raw.height,
      blackPlotHeight: black.height,
      bluePlotHeight: blue.height,
      blueBottom: blue.bottom,
      viewportHeight: innerHeight,
      controlPanelLeft: document.getElementById("panel").getBoundingClientRect().left,
    };
  });
  expect(compactLayout.cameraWidth).toBeLessThanOrEqual(512);
  expect(compactLayout.cameraHeight).toBeLessThanOrEqual(320);
  expect(compactLayout.plotWidth).toBeGreaterThanOrEqual(630);
  expect(compactLayout.plotHeight).toBeGreaterThanOrEqual(80);
  expect(Math.abs(compactLayout.plotHeight - compactLayout.blackPlotHeight)).toBeLessThanOrEqual(1);
  expect(Math.abs(compactLayout.plotHeight - compactLayout.bluePlotHeight)).toBeLessThanOrEqual(1);
  expect(compactLayout.blueBottom).toBeLessThanOrEqual(compactLayout.viewportHeight);
  expect(Math.abs(compactLayout.controlPanelLeft)).toBeLessThanOrEqual(1);

  await expect(page.locator("#panel #open-scanline-lab")).toBeVisible();
  await expect(page.locator("#toggle-sim-overview, #sim-lab-toolbar")).toHaveCount(0);
  await expect(page.locator("#toggle-sim-controls")).toHaveAttribute("aria-label", "Hide controls");
  await expect(page.getByText(/centroid/i)).toHaveCount(0);
  await expect(page.locator("#scanline-worksheet, .lab-stage, .lab-results, .lab-plots")).toHaveCount(0);

  await page.locator("#open-scanline-lab").click();
  await expect(page.locator("#scanline-lab")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Turn one camera row into black-or-white decisions." })).toBeVisible();
  await expect(page.locator("#lab-filter-mask-plot")).toBeVisible();
  await expect(page.locator("#lab-blue-filter-mask-plot")).toBeVisible();
  await expect(page.locator("#yhsv-live-table tbody tr")).toHaveCount(4);
  for (const channel of ["y", "h", "s", "v"]) {
    await expect(page.locator(`#yhsv-live-table tr[data-channel="${channel}"] td`)).toHaveCount(320);
  }
  await expect(page.locator("#yhsv-live-row")).toHaveText(/A \(y = 150\)/);
  await expect.poll(async () => page.locator("#yhsv-live-table td.is-v-match").count())
    .toBeGreaterThan(0);
  const blackMatches = Number.parseInt(await page.locator("#filter-match-count").textContent(), 10);
  const blueMatches = Number.parseInt(await page.locator("#blue-filter-match-count").textContent(), 10);
  await expect(page.locator("#yhsv-live-table td.is-v-match")).toHaveCount(blackMatches * 4);
  await expect(page.locator("#yhsv-live-table td.is-blue-match")).toHaveCount(blueMatches * 4);
  await expect(page.locator(".binary-output-key")).toContainText("Filled/color = 1");
  await expect(page.locator("#filter-expression")).toHaveText(/V\[x\] < 80/);
  await expect(page.locator("#blue-filter-expression")).toHaveText(
    /hue_distance\(H\[x\], 160\).*S\[x\] > 100.*V\[x\] > 80/,
  );

  for (const declaration of [
    "typedef struct",
    "uint8_t y;",
    "uint8_t h;",
    "uint8_t s;",
    "uint8_t v;",
    "static inline uint16_t *camera_row(uint16_t *frame, uint32_t y)",
    "void color_convert_rgb565_to_yhsv(const uint16_t *pixels, color_features_t *features,",
    "bool telemetry_u32(const char *name, uint32_t value, const char *units);",
  ]) {
    expect(publicHeader).toContain(declaration);
  }
  expect(visionExample).toContain("static color_features_t scanline[CAMERA_WIDTH];");
  expect(visionExample).toContain(
    "color_convert_rgb565_to_yhsv(camera_row(frame, row), scanline, CAMERA_WIDTH);",
  );

  const code = page.locator("#filter-code");
  await expect(code).toContainText('#include "vision_test.h"');
  await expect(code).toContainText('#include "nxp_cup.h"');
  await expect(code).toContainText("static color_features_t scanline[CAMERA_WIDTH]");
  await expect(code).toContainText("void vision_test_on_frame(uint16_t *frame)");
  await expect(code).toContainText("color_convert_rgb565_to_yhsv(camera_row(frame, row), scanline, CAMERA_WIDTH)");
  await expect(code).toContainText("scanline[x].v");
  await expect(code).toContainText("scanline[x].h");
  await expect(code).toContainText("scanline[x].s");
  await expect(code).toContainText("telemetry_u32");
  await expect(code).toContainText("black_mask[x] != black_mask[x - 1U]");
  await expect(code).toContainText("STUDENT TODO");
  await expect(code).not.toContainText(/centroid|first_moment|coordinate_sum/i);

  await page.locator("#lab-filter-mask-plot").hover({ position: { x: 120, y: 50 } });
  await expect(page.locator("#filter-selected-detail")).toHaveText(
    /Y=\d+ H=\d+ S=\d+ V=\d+ → black=[01] blue=[01]/,
  );
  await page.locator('#yhsv-live-table tr[data-channel="h"] td').nth(12).hover();
  await expect(page.locator("#filter-selected-detail")).toHaveText(/^x=12 /);
  await expect(page.locator("#yhsv-live-table td.is-selected")).toHaveCount(4);
  await page.locator("#lab-second-enabled").check();
  await page.locator("#lab-filter-row").selectOption("b");
  await expect(page.locator("#filter-row")).toHaveValue("b");
  await expect(page.locator("#yhsv-live-row")).toHaveText(/B \(y = 170\)/);
  await expect(page.locator("#row2Enabled")).toBeChecked();

  const referenceToken = await page.evaluate(() => {
    const token = coinGroup.getObjectByName("blue-reference-token");
    return {
      x: token.position.x,
      z: token.position.z,
      radius: token.children[0].geometry.parameters.radiusTop,
    };
  });
  expect(referenceToken).toEqual({ x: 0.1094, z: -0.0657, radius: 0.04 });

  const tokenFeatures = await page.evaluate(() => {
    const frame = { data: new Uint8ClampedArray(labWidth * 4) };
    frame.data.set([8, 65, 247, 255]);
    const y = new Float64Array(labWidth);
    const h = new Uint8Array(labWidth);
    const s = new Uint8Array(labWidth);
    const v = new Uint8Array(labWidth);
    extractYhsvRow(frame, 0, y, h, s, v);
    return { y: y[0], h: h[0], s: s[0], v: v[0] };
  });
  expect(tokenFeatures).toEqual({ y: 68, h: 160, s: 247, v: 247 });
  expect(await page.evaluate(() => circularHueDistance(250, 5))).toBe(11);
  expect(await page.evaluate(() => findMaskTransitions(Uint8Array.from([0, 1, 1, 0, 1]))))
    .toEqual([0.5, 2.5, 3.5]);

  await page.locator("#close-scanline-lab").click();
  await page.locator("#filter-view-blue").click();
  await expect.poll(async () => Number.parseInt(
    await page.locator("#blue-filter-match-count").textContent(), 10,
  )).toBeGreaterThan(0);

  await page.locator("#toggle-sim-controls").click();
  await expect(page.locator("#panel")).toBeHidden();
  await expect(page.locator("#show-sim-controls")).toBeVisible();
  await page.locator("#show-sim-controls").click();
  await expect(page.locator("#panel")).toBeVisible();
  await expect(page.locator("#show-sim-controls")).toBeHidden();

  expect(pageErrors).toEqual([]);
  expect(networkRequests).toEqual([]);
});
