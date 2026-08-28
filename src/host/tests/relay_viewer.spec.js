const { test, expect } = require("@playwright/test");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const relayPath = path.join(
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
);

function relayUrl(mode) {
  return `${pathToFileURL(relayPath).href}?video=${mode}`;
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.__relaySockets = [];
    window.__h264Appends = 0;

    class FakeWebSocket {
      constructor(url) {
        this.url = url;
        this.binaryType = "";
        this.closed = false;
        window.__relaySockets.push(this);
        queueMicrotask(() => this.onopen?.());
      }

      close() {
        if (this.closed) return;
        this.closed = true;
        this.onclose?.();
      }

      emit(buffer) {
        this.onmessage?.({ data: buffer });
      }
    }

    class FakeSourceBuffer extends EventTarget {
      constructor() {
        super();
        this.updating = false;
        this.mode = "segments";
        this.buffered = { length: 0, start: () => 0, end: () => 0 };
      }

      appendBuffer() {
        window.__h264Appends += 1;
        queueMicrotask(() => this.dispatchEvent(new Event("updateend")));
      }

      remove() {}
    }

    class FakeMediaSource extends EventTarget {
      constructor() {
        super();
        this.readyState = "closed";
        queueMicrotask(() => {
          this.readyState = "open";
          this.dispatchEvent(new Event("sourceopen"));
        });
      }

      static isTypeSupported() { return true; }
      addSourceBuffer() { return new FakeSourceBuffer(); }
      endOfStream() { this.readyState = "ended"; }
    }

    Object.defineProperty(window, "WebSocket", { configurable: true, value: FakeWebSocket });
    Object.defineProperty(window, "MediaSource", { configurable: true, value: FakeMediaSource });
    URL.createObjectURL = () => "data:video/mp4;base64,";
    window.fetch = async () => ({ json: async () => ({ usb_state: "streaming", relay_clients: 1 }) });
    window.createImageBitmap = async () => {
      const bitmap = document.createElement("canvas");
      bitmap.width = 320;
      bitmap.height = 200;
      bitmap.close = () => {};
      return bitmap;
    };

    window.__sendRelayPacket = (kind, options = {}) => {
      const socket = window.__relaySockets[0];
      if (kind === "raw") {
        const bytes = new Uint8Array(32 + 320 * 200 * 2);
        const view = new DataView(bytes.buffer);
        view.setUint32(0, 0x52435641, true);
        view.setUint8(4, 1);
        view.setUint8(5, 32);
        view.setUint32(8, options.frameId || 7, true);
        view.setUint16(12, 320, true);
        view.setUint16(14, 200, true);
        view.setUint32(16, 320 * 200 * 2, true);
        view.setUint32(28, 1, true);
        bytes[32] = 0xe0;
        bytes[33] = 0x07;
        socket.emit(bytes.buffer);
        return;
      }
      if (kind === "jpeg") {
        const bytes = new Uint8Array(36);
        const view = new DataView(bytes.buffer);
        view.setUint32(0, 0x4a435641, true);
        view.setUint8(4, 1);
        view.setUint8(5, 32);
        view.setUint32(8, options.frameId || 8, true);
        view.setUint16(12, 320, true);
        view.setUint16(14, 200, true);
        view.setUint32(16, 4, true);
        bytes.set([0xff, 0xd8, 0xff, 0xd9], 32);
        socket.emit(bytes.buffer);
        return;
      }
      if (kind === "h264") {
        const bytes = new Uint8Array(36);
        const view = new DataView(bytes.buffer);
        view.setUint32(0, 0x34435641, true);
        view.setUint8(4, 1);
        view.setUint8(5, 32);
        view.setUint16(6, 1, true);
        view.setUint32(8, options.frameId || 9, true);
        view.setUint16(12, 320, true);
        view.setUint16(14, 200, true);
        view.setUint32(16, 4, true);
        view.setUint32(28, 0x42000d, true);
        bytes.set([1, 2, 3, 4], 32);
        socket.emit(bytes.buffer);
        return;
      }

      const name = new TextEncoder().encode(options.name);
      const units = new TextEncoder().encode(options.units || "");
      const text = options.type === 5 ? new TextEncoder().encode(String(options.value)) : new Uint8Array();
      const payloadLength = 16 + name.length + units.length + text.length;
      const bytes = new Uint8Array(32 + payloadLength);
      const view = new DataView(bytes.buffer);
      view.setUint32(0, 0x55435641, true);
      view.setUint8(4, 1);
      view.setUint8(5, 32);
      view.setUint32(8, 0x01000500, true);
      view.setUint32(16, payloadLength, true);
      if (options.type === 3) view.setFloat32(40, options.value, true);
      else view.setUint32(40, options.type === 5 ? text.length : options.value, true);
      view.setUint16(44, name.length, true);
      view.setUint8(46, options.type, true);
      view.setUint8(47, units.length);
      bytes.set(name, 48);
      bytes.set(units, 48 + name.length);
      bytes.set(text, 48 + name.length + units.length);
      socket.emit(bytes.buffer);
    };
  });
});

test("generated dashboard pages are standalone and contain their distinct adapters", async () => {
  const relay = fs.readFileSync(relayPath, "utf8");
  const host = fs.readFileSync(path.join(__dirname, "..", "nxpc_usb_debug_viewer.html"), "utf8");
  const externalAsset = /<(?:script|link|img|source)[^>]+(?:src|href)=["'](?:https?:)?\/\//i;
  const externalCss = /(?:@import\s+(?:url\()?|url\()\s*["']?(?:https?:)?\/\//i;
  expect(relay).not.toMatch(externalAsset);
  expect(host).not.toMatch(externalAsset);
  expect(relay).not.toMatch(externalCss);
  expect(host).not.toMatch(externalCss);
  expect(relay).toContain("new WebSocket");
  expect(relay).not.toContain("navigator.serial.requestPort");
  expect(host).toContain("navigator.serial.requestPort");
  expect(host).not.toContain("new WebSocket");
  expect(relay).not.toMatch(/NXPC_(?:DASHBOARD|ADAPTER)|\{\{TRANSPORT\}\}/);
  expect(host).not.toMatch(/NXPC_(?:DASHBOARD|ADAPTER)|\{\{TRANSPORT\}\}/);
});

test("right-side readouts do not overlap in a short wide viewport", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 480 });
  await page.goto(relayUrl("jpeg"));
  const boxes = await page.locator(".side-readout:visible").evaluateAll((elements) =>
    elements.map((element) => {
      const box = element.getBoundingClientRect();
      return { top: box.top, bottom: box.bottom };
    }),
  );
  expect(boxes).toHaveLength(2);
  expect(boxes[0].bottom).toBeLessThan(boxes[1].top);
});

for (const mode of ["jpeg", "h264", "raw"]) {
  test(`relay dashboard selects ${mode} without exposing vehicle controls`, async ({ page }) => {
    await page.goto(relayUrl(mode));
    await expect(page.locator("body")).toHaveAttribute("data-transport", "relay");
    await expect(page.locator(`[data-video="${mode}"]`)).toHaveAttribute("aria-current", "page");
    await expect(page.locator("#raceControls")).toBeHidden();
    await expect(page.locator("#connectionState")).toContainText(`Connected (${mode})`);
    expect(await page.evaluate(() => window.__relaySockets[0].url)).toContain(`video=${mode}`);
  });
}

test("relay dashboard renders raw video and shared Formula One telemetry", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.goto(relayUrl("raw"));
  await page.evaluate(() => {
    window.__sendRelayPacket("telemetry", { name: "battery.voltage", value: 7.849, type: 3, units: "V" });
    window.__sendRelayPacket("telemetry", { name: "wheel.left.rpm", value: 100, type: 3, units: "RPM" });
    window.__sendRelayPacket("telemetry", { name: "wheel.right.rpm", value: 100, type: 3, units: "RPM" });
    window.__sendRelayPacket("telemetry", { name: "motor.left.command", value: 0.6, type: 3 });
    window.__sendRelayPacket("telemetry", { name: "steering.command", value: 0.5, type: 3 });
    window.__sendRelayPacket("telemetry", { name: "system.mode", value: "RACE RUNNING", type: 5 });
    window.__sendRelayPacket("raw", { frameId: 17 });
  });
  await expect(page.locator("#dashboardBattery")).toHaveText("7.8");
  await expect(page.locator("#dashboardSpeed")).toHaveText("1.4");
  await expect(page.locator("#dashboardLeftCommand")).toHaveText("60%");
  await expect(page.locator("#dashboardSteeringCommand")).toHaveText("+15");
  await expect(page.locator("#dashboardState")).toHaveText("RACE RUNNING");
  await expect(page.locator("#telemetryTableBody tr")).toHaveCount(6);
  expect(await page.locator("#frameCanvas").evaluate((element) => Array.from(element.getContext("2d").getImageData(0, 0, 1, 1).data))).toEqual([0, 255, 0, 255]);
  expect(pageErrors).toEqual([]);
});

test("relay dashboard accepts bounded JPEG and H.264 initialization paths", async ({ page }) => {
  await page.goto(relayUrl("jpeg"));
  await page.evaluate(() => window.__sendRelayPacket("jpeg", { frameId: 18 }));
  await expect(page.locator("#frameCanvas")).toBeVisible();

  await page.goto(relayUrl("h264"));
  await page.evaluate(() => window.__sendRelayPacket("h264", { frameId: 19 }));
  await expect(page.locator("#h264Video")).toBeVisible();
  await expect.poll(() => page.evaluate(() => window.__h264Appends)).toBe(1);
});
