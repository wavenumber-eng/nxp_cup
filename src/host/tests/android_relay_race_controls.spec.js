const { test, expect } = require("@playwright/test");
const path = require("path");
const { pathToFileURL } = require("url");

const viewerUrl = pathToFileURL(
  path.join(
    __dirname,
    "..",
    "..",
    "android",
    "nxp_cup_bridge",
    "app",
    "src",
    "main",
    "res",
    "raw",
    "relay_viewer.html",
  ),
).href;

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    class MockWebSocket {
      static CONNECTING = 0;
      static OPEN = 1;
      static CLOSING = 2;
      static CLOSED = 3;

      constructor(url) {
        this.url = url;
        this.readyState = MockWebSocket.CONNECTING;
        this.sent = [];
        window.__nxpcRelaySocket = this;
        queueMicrotask(() => {
          this.readyState = MockWebSocket.OPEN;
          this.onopen?.();
        });
      }

      send(message) {
        this.sent.push(message);
      }

      close() {
        this.readyState = MockWebSocket.CLOSED;
      }

      emit(data) {
        this.onmessage?.({ data });
      }
    }

    window.WebSocket = MockWebSocket;
    window.fetch = async () => ({
      json: async () => ({ state: "streaming", capabilities: 1 << 7, system_actions: true }),
    });

    function textTelemetry(nameValue, textValue, sampleId) {
      const encoder = new TextEncoder();
      const name = encoder.encode(nameValue);
      const text = encoder.encode(textValue);
      const payload = new Uint8Array(16 + name.length + text.length);
      const payloadView = new DataView(payload.buffer);
      payloadView.setUint32(0, 1234 + sampleId, true);
      payloadView.setUint32(4, sampleId, true);
      payloadView.setUint32(8, text.length, true);
      payloadView.setUint16(12, name.length, true);
      payloadView.setUint8(14, 5);
      payloadView.setUint8(15, 0);
      payload.set(name, 16);
      payload.set(text, 16 + name.length);

      const packet = new Uint8Array(32 + payload.length);
      const view = new DataView(packet.buffer);
      view.setUint32(0, 0x55435641, true);
      view.setUint8(4, 1);
      view.setUint8(5, 32);
      view.setUint32(8, 0x01000500, true);
      view.setUint32(12, sampleId, true);
      view.setUint32(16, payload.length, true);
      packet.set(payload, 32);
      return packet.buffer;
    }

    function floatTelemetry(nameValue, numericValue, unitsValue, sampleId) {
      const encoder = new TextEncoder();
      const name = encoder.encode(nameValue);
      const units = encoder.encode(unitsValue);
      const payload = new Uint8Array(16 + name.length + units.length);
      const payloadView = new DataView(payload.buffer);
      payloadView.setUint32(0, 1234 + sampleId, true);
      payloadView.setUint32(4, sampleId, true);
      payloadView.setFloat32(8, numericValue, true);
      payloadView.setUint16(12, name.length, true);
      payloadView.setUint8(14, 3);
      payloadView.setUint8(15, units.length);
      payload.set(name, 16);
      payload.set(units, 16 + name.length);

      const packet = new Uint8Array(32 + payload.length);
      const view = new DataView(packet.buffer);
      view.setUint32(0, 0x55435641, true);
      view.setUint8(4, 1);
      view.setUint8(5, 32);
      view.setUint32(8, 0x01000500, true);
      view.setUint32(12, sampleId, true);
      view.setUint32(16, payload.length, true);
      packet.set(payload, 32);
      return packet.buffer;
    }

    window.__nxpcRelaySendRaceReady = () => {
      window.__nxpcRelaySocket.emit(textTelemetry("system.mode", "RACE / WAITING", 1));
      window.__nxpcRelaySocket.emit(textTelemetry("system.state", "READY TO START", 2));
    };
    window.__nxpcRelaySendRaceRunning = () => {
      window.__nxpcRelaySocket.emit(textTelemetry("system.mode", "RACE RUNNING", 3));
      window.__nxpcRelaySocket.emit(textTelemetry("system.state", "RUNNING", 4));
    };
    window.__nxpcRelaySendDashboardTelemetry = () => {
      const samples = [
        ["battery.voltage", 7.4, "V"],
        ["wheel.left.rpm", 120, "RPM"],
        ["wheel.right.rpm", -60, "RPM"],
        ["motor.left.command", .5, ""],
        ["motor.right.command", -.25, ""],
        ["steering.command", -.5, ""],
      ];
      samples.forEach(([name, value, units], index) => {
        window.__nxpcRelaySocket.emit(floatTelemetry(name, value, units, 10 + index));
      });
    };
    window.__nxpcRelayActionMessages = () => window.__nxpcRelaySocket.sent.map(JSON.parse);
    window.__nxpcRelayActionResult = (action, outcome, detail = "") => {
      window.__nxpcRelaySocket.emit(JSON.stringify({
        type: "system_action_result",
        action,
        outcome,
        detail,
      }));
    };
  });
  await page.goto(viewerUrl);
});

test("Android relay uses the F1 overlay instead of the legacy page", async ({ page }) => {
  await expect(page).toHaveTitle("NXP Cup Live Dashboard");
  await expect(page.locator(".stage")).toBeVisible();
  await expect(page.locator(".hud .card")).toHaveCount(3);
  await expect(page.locator("#dashboardLive")).toHaveText("CONNECTED");
  await expect(page.locator(".side-readout.battery")).toBeHidden();
  await expect(page.locator("h1")).toHaveCount(0);

  await page.evaluate(() => window.__nxpcRelaySendDashboardTelemetry());
  await expect(page.locator("#dashboardBattery")).toHaveText("7.4");
  await expect(page.locator("#dashboardLeftRpm")).toHaveText("120");
  await expect(page.locator("#dashboardRightRpm")).toHaveText("60");
  await expect(page.locator("#dashboardSpeed")).toHaveText("1.3");
  await expect(page.locator('[data-telemetry-name="wheel.right.rpm"] td').nth(2)).toHaveText("-60");
  await expect(page.locator("#dashboardLeftCommand")).toHaveText("50%");
  await expect(page.locator("#dashboardRightCommand")).toHaveText("-25%");
  await expect(page.locator("#dashboardSteeringCommand")).toHaveText("-15");
});

test("dashboard side readouts do not overlap", async ({ page }) => {
  const readouts = await page.locator(".side-readout:visible").evaluateAll((elements) =>
    elements.map((element) => {
      const bounds = element.getBoundingClientRect();
      return { top: bounds.top, bottom: bounds.bottom };
    }),
  );

  expect(readouts).toHaveLength(2);
  expect(readouts[1].top).toBeGreaterThanOrEqual(readouts[0].bottom);
});

test("relay shows deliberate race controls and sends only after the start hold", async ({ page }) => {
  await expect(page.locator("#raceControls")).toBeHidden();

  await page.evaluate(() => window.__nxpcRelaySendRaceReady());
  await expect(page.locator("#raceControls")).toBeVisible();
  await expect(page.locator("#dashboardState")).toContainText("RACE / WAITING / READY TO START");
  await expect(page.locator("#raceStartButton")).toBeEnabled();
  await expect(page.locator("#raceStopButton")).toBeEnabled();

  await page.locator("#raceStartButton").dispatchEvent("pointerdown", { button: 0 });
  await page.waitForTimeout(250);
  await page.locator("#raceStartButton").dispatchEvent("pointerup", { button: 0 });
  await page.waitForTimeout(1_350);
  expect(await page.evaluate(() => window.__nxpcRelayActionMessages())).toEqual([]);

  await page.locator("#raceStartButton").dispatchEvent("pointerdown", { button: 0 });
  await page.waitForTimeout(1_600);
  await expect.poll(() => page.evaluate(() => window.__nxpcRelayActionMessages())).toEqual([
    { type: "system_action", action: "race_start" },
  ]);
  await page.evaluate(() => window.__nxpcRelayActionResult("race_start", "accepted"));
  await expect(page.locator("#raceControlStatus")).toContainText("Race start accepted");

  await page.evaluate(() => window.__nxpcRelaySendRaceRunning());
  await expect(page.locator("#raceStartButton")).toBeHidden();
  await page.locator("#raceStopButton").click();
  await expect.poll(() => page.evaluate(() => window.__nxpcRelayActionMessages())).toEqual([
    { type: "system_action", action: "race_start" },
    { type: "system_action", action: "stop" },
  ]);
});

test("relay keeps race actions disabled without the firmware capability", async ({ page }) => {
  await page.evaluate(() => {
    window.fetch = async () => ({ json: async () => ({ state: "streaming", capabilities: 0 }) });
    window.__nxpcRelaySendRaceReady();
  });
  await page.waitForTimeout(1_100);

  await expect(page.locator("#raceControls")).toBeVisible();
  await expect(page.locator("#raceStartButton")).toBeDisabled();
  await expect(page.locator("#raceStopButton")).toBeDisabled();
});
