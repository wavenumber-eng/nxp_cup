const { test, expect } = require("@playwright/test");
const path = require("path");
const { pathToFileURL } = require("url");

const lessonUrl = pathToFileURL(
  path.resolve(__dirname, "../../../docs/learn/camera_scanline_lab.html"),
).href;

test("camera scanline laboratory reveals a real 320-pixel weighted reduction", async ({ page }) => {
  const pageErrors = [];
  const networkRequests = [];
  page.on("pageerror", error => pageErrors.push(error.message));
  page.on("request", request => {
    if (/^https?:/.test(request.url())) networkRequests.push(request.url());
  });

  await page.goto(lessonUrl);
  await expect(page).toHaveTitle(/Interactive Scanline Computation Lab/);
  await expect(page.locator("#camfeed")).toBeVisible();
  await expect(page.locator("#scanline-worksheet #worksheet-x td")).toHaveCount(320);

  await page.locator("#open-scanline-lab").click();
  await expect(page.locator("#scanline-lab")).toBeVisible();
  await expect(page.locator("#scanline-worksheet tr.is-future")).toHaveCount(3);
  await expect(page.locator(".lab-results")).toBeHidden();

  for (let step = 0; step < 4; step += 1) {
    await page.locator("#lab-next-step").click();
  }
  await expect(page.locator(".lab-results")).toBeVisible();
  await expect(page.locator("#lab-a-mass")).toHaveText(/[\d,]+/);
  await expect(page.locator("#lab-a-moment")).toHaveText(/-?[\d,]+/);
  await expect(page.locator("#lab-a-position")).toHaveText(/[+-]?\d+\.\d{2} px/);

  await page.locator("#worksheet-product td").nth(12).hover();
  await expect(page.locator("#selected-pixel-detail")).toContainText("x=12");
  await expect(page.locator("#selected-pixel-detail")).toContainText("contribution=");

  await page.locator("#lab-second-enabled").check();
  await expect(page.locator("#lab-plot-b-card")).toBeVisible();
  await expect(page.locator("#lab-b-position")).toHaveText(/[+-]?\d+\.\d{2} px/);
  await expect(page.locator("#row2Enabled")).toBeChecked();

  await page.locator("#close-scanline-lab").click();
  await page.locator("#toggle-sim-controls").click();
  await expect(page.locator("#panel")).toBeHidden();
  await page.locator("#toggle-sim-controls").click();
  await expect(page.locator("#panel")).toBeVisible();
  await page.locator("#toggle-sim-overview").click();
  await expect(page.locator("#left")).toBeHidden();
  await expect(page.locator("#layout")).toHaveClass(/camera-focus/);

  expect(pageErrors).toEqual([]);
  expect(networkRequests).toEqual([]);
});
