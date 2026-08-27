const path = require("path");
const { pathToFileURL } = require("url");
const { test, expect } = require("@playwright/test");

const lessonUrl = pathToFileURL(
  path.resolve(__dirname, "../../../docs/learn/frame-indexing.html"),
).href;

test("frame indexing lesson connects coordinates, array indices, and byte offsets", async ({ page }) => {
  await page.goto(lessonUrl);
  await expect(page.locator("body")).toHaveAttribute("data-lesson-ready", "true");
  await expect(page.locator("#demo-formula")).toHaveText("2 × 8 + 3 = 19");
  await expect(page.locator("#demo-expression")).toHaveText("frame[19]");
  await expect(page.locator("#demo-byte-offset")).toHaveText("38 bytes");

  await page.locator('#pixel-grid button[data-index="33"]').click();
  await expect(page.locator("#demo-coordinate")).toHaveText("(1, 4)");
  await expect(page.locator("#demo-formula")).toHaveText("4 × 8 + 1 = 33");
  await expect(page.locator("#demo-expression")).toHaveText("frame[33]");
  await expect(page.locator("#demo-byte-offset")).toHaveText("66 bytes");
  await expect(page.locator("#memory-cells .is-selected b")).toHaveText("[33]");

  await page.locator("#real-x").fill("319");
  await page.locator("#real-y").fill("199");
  await expect(page.locator("#real-index")).toHaveText("63,999");
  await expect(page.locator("#real-bytes")).toHaveText("127,998");

  await page.locator("#real-x").fill("320");
  await expect(page.locator("#real-x")).toHaveAttribute("aria-invalid", "true");
  await expect(page.locator("#real-index")).toHaveText("out of bounds");
});

test("frame indexing lesson remains usable at phone width", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(lessonUrl);
  await expect(page.locator("#page-title")).toBeVisible();
  await expect(page.locator("#pixel-grid")).toBeVisible();
  await expect(page.locator("#real-x")).toBeVisible();
  await page.locator("#demo-x").fill("7");
  await expect(page.locator("#demo-expression")).toHaveText("frame[23]");
});
