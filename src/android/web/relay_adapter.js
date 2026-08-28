"use strict";

(() => {
  const AVCU_MAGIC = 0x55435641;
  const JPEG_MAGIC = 0x4a435641;
  const H264_MAGIC = 0x34435641;
  const RAW_MAGIC = 0x52435641;
  const HEADER_BYTES = 32;
  const RAW_PIXEL_FORMAT_RGB565_LE = 1;
  const H264_FLAG_INITIALIZATION = 1;
  const MAX_MSE_QUEUE = 48;
  const MAX_TELEMETRY_SIGNALS = 32;
  const MSG_TELEMETRY = 0x01000500;
  const CAPABILITY_SYSTEM_ACTIONS = 1 << 7;
  const TELEMETRY_TEXT_MAX_BYTES = 48;

  const dashboard = window.NxpCupDashboard.create();
  const status = document.getElementById("connectionState");
  const health = document.getElementById("relayHealth");
  const telemetryBody = document.getElementById("telemetryTableBody");
  const canvas = document.getElementById("frameCanvas");
  const video = document.getElementById("h264Video");
  const raceControls = document.getElementById("raceControls");
  const raceStartButton = document.getElementById("raceStartButton");
  const raceStopButton = document.getElementById("raceStopButton");
  const raceControlStatus = document.getElementById("raceControlStatus");
  const batteryReadout = document.querySelector(".side-readout.battery");
  const context = canvas.getContext("2d", { alpha: false });
  const rawImage = context.createImageData(320, 200);
  const telemetryRows = new Map();
  const decoder = new TextDecoder();
  const pageParameters = new URLSearchParams(location.search);
  const requestedVideo = ["raw", "jpeg", "h264"].includes(pageParameters.get("video"))
    ? pageParameters.get("video")
    : "jpeg";

  let pendingJpeg = null;
  let decodingJpeg = false;
  let lastFrameId = -1;
  let displayed = 0;
  let lastRateDisplayed = 0;
  let lastRateTime = performance.now();
  let currentSocket = null;
  let mediaSource = null;
  let sourceBuffer = null;
  let mediaUrl = null;
  let mseQueue = [];
  let helloCapabilities = 0;
  let systemMode = "";
  let systemState = "";
  let socketConnected = false;
  let raceStartHoldTimer = null;

  if (batteryReadout) batteryReadout.hidden = true;

  document.querySelectorAll("[data-video]").forEach((button) => {
    const active = button.dataset.video === requestedVideo;
    button.classList.toggle("active", active);
    button.setAttribute("aria-current", active ? "page" : "false");
  });

  function setStatus(label, connected = false, live = false) {
    status.textContent = label;
    dashboard.setConnection({ connected, live, label });
  }

  function setRaceControls() {
    const actionsSupported = socketConnected && (helloCapabilities & CAPABILITY_SYSTEM_ACTIONS) !== 0;
    const raceWaiting = systemMode === "RACE / WAITING";
    const raceRunning = systemMode === "RACE RUNNING";
    const raceMode = raceWaiting || raceRunning;
    const raceReady = raceWaiting && systemState === "READY TO START";
    raceControls.hidden = !raceMode;
    raceControls.classList.toggle("waiting", raceWaiting);
    raceControls.classList.toggle("running", raceRunning);
    raceStartButton.hidden = !raceWaiting;
    raceStartButton.disabled = !actionsSupported || !raceReady;
    raceStartButton.classList.toggle("ready", actionsSupported && raceReady);
    raceStopButton.hidden = !raceMode;
    raceStopButton.disabled = !actionsSupported;
  }

  function cancelRaceStartHold() {
    if (raceStartHoldTimer !== null) {
      clearTimeout(raceStartHoldTimer);
      raceStartHoldTimer = null;
    }
    raceStartButton.classList.remove("holding");
  }

  function requestSystemAction(action) {
    if (!currentSocket || !socketConnected) {
      raceControlStatus.textContent = "Race action unavailable: relay is disconnected";
      setRaceControls();
      return;
    }
    raceControlStatus.textContent = action === "stop" ? "Sending STOP..." : "Requesting race start...";
    currentSocket.send(JSON.stringify({ type: "system_action", action }));
  }

  function beginRaceStartHold() {
    if (raceStartButton.disabled || raceStartHoldTimer !== null) return;
    raceStartButton.classList.add("holding");
    raceControlStatus.textContent = "Keep holding to start the race...";
    raceStartHoldTimer = setTimeout(() => {
      raceStartHoldTimer = null;
      raceStartButton.classList.remove("holding");
      requestSystemAction("race_start");
    }, 1500);
  }

  function receiveSystemActionResult(message) {
    let result;
    try { result = JSON.parse(message); } catch (_) { return; }
    if (result?.type !== "system_action_result") return;
    const start = result.action === "race_start";
    const messages = {
      queued: start ? "Race start queued for the car..." : "STOP queued for the car...",
      accepted: start ? "Race start accepted; awaiting state telemetry" : "STOP accepted; outputs disabled",
      not_ready: "Start rejected: the camera is not ready",
      denied: "Action denied by the firmware state machine",
      busy: "Another race action is already pending",
      unavailable: "Race actions are unavailable on this USB session",
      superseded: "Race start cancelled by STOP",
      failed: `Race action failed: ${result.detail || "unknown error"}`,
    };
    raceControlStatus.textContent = messages[result.outcome] || result.detail || "Unknown race action result";
  }

  function noteDisplayedFrame(label) {
    displayed += 1;
    const now = performance.now();
    if (now - lastRateTime >= 1000) {
      const elapsed = Math.max((now - lastRateTime) / 1000, 0.001);
      dashboard.setFrameRate((displayed - lastRateDisplayed) / elapsed);
      lastRateDisplayed = displayed;
      lastRateTime = now;
      setStatus(`${label} - frame ${lastFrameId}, browser frames ${displayed}`, true, true);
    }
  }

  function codecName(codecConfig) {
    return `avc1.${codecConfig.toString(16).padStart(6, "0")}`;
  }

  function closeForMseError(error) {
    console.error("AVC H.264 MSE", error);
    setStatus(`H.264 playback error: ${error}`, true, false);
    if (currentSocket) currentSocket.close();
  }

  function pumpMse() {
    if (!sourceBuffer || sourceBuffer.updating) return;
    if (sourceBuffer.buffered.length && video.currentTime < sourceBuffer.buffered.start(0)) {
      video.currentTime = sourceBuffer.buffered.start(0);
      void video.play().catch(() => {});
    }
    if (mseQueue.length > 0) {
      try { sourceBuffer.appendBuffer(mseQueue.shift()); }
      catch (error) { closeForMseError(error); }
      return;
    }
    if (sourceBuffer.buffered.length && video.currentTime > 8) {
      const removeBefore = video.currentTime - 4;
      if (sourceBuffer.buffered.start(0) < removeBefore) {
        try { sourceBuffer.remove(0, removeBefore); }
        catch (error) { closeForMseError(error); }
      }
    }
  }

  function beginH264(initialization, codecConfig) {
    mseQueue = [initialization];
    sourceBuffer = null;
    if (mediaSource && mediaSource.readyState === "open") {
      try { mediaSource.endOfStream(); } catch (_) {}
    }
    if (mediaUrl) URL.revokeObjectURL(mediaUrl);
    mediaSource = new MediaSource();
    mediaUrl = URL.createObjectURL(mediaSource);
    video.src = mediaUrl;
    dashboard.showVideoSurface("h264");
    mediaSource.addEventListener("sourceopen", () => {
      try {
        const mime = `video/mp4; codecs="${codecName(codecConfig)}"`;
        if (!MediaSource.isTypeSupported(mime)) throw new Error(`unsupported ${mime}`);
        sourceBuffer = mediaSource.addSourceBuffer(mime);
        sourceBuffer.mode = "segments";
        sourceBuffer.addEventListener("updateend", pumpMse);
        sourceBuffer.addEventListener("error", () => closeForMseError("SourceBuffer error"));
        pumpMse();
        void video.play().catch(() => {});
      } catch (error) { closeForMseError(error); }
    }, { once: true });
  }

  function queueH264(fragment) {
    if (!mediaSource) return;
    if (mseQueue.length >= MAX_MSE_QUEUE) {
      closeForMseError("decoder queue exceeded its bounded limit");
      return;
    }
    mseQueue.push(fragment);
    pumpMse();
  }

  if ("requestVideoFrameCallback" in video) {
    const countVideoFrame = () => {
      noteDisplayedFrame("Live H.264");
      video.requestVideoFrameCallback(countVideoFrame);
    };
    video.requestVideoFrameCallback(countVideoFrame);
  }

  async function drainJpeg() {
    if (decodingJpeg) return;
    decodingJpeg = true;
    while (pendingJpeg !== null) {
      const frame = pendingJpeg;
      pendingJpeg = null;
      try {
        const bitmap = await createImageBitmap(
          new Blob([new Uint8Array(frame.buffer, HEADER_BYTES, frame.jpegBytes)], { type: "image/jpeg" }),
        );
        context.drawImage(bitmap, 0, 0, 320, 200);
        bitmap.close();
        lastFrameId = frame.frameId;
        noteDisplayedFrame("Live JPEG");
      } catch (error) {
        setStatus(`JPEG decode error: ${error}`, true, false);
      }
    }
    decodingJpeg = false;
  }

  function showRaw(buffer, view, rawBytes) {
    const source = new Uint8Array(buffer, HEADER_BYTES, rawBytes);
    const destination = rawImage.data;
    for (let sourceIndex = 0, pixelIndex = 0; sourceIndex < source.length; sourceIndex += 2, pixelIndex += 4) {
      const pixel = source[sourceIndex] | (source[sourceIndex + 1] << 8);
      destination[pixelIndex] = Math.round(((pixel >>> 11) & 0x1f) * 255 / 31);
      destination[pixelIndex + 1] = Math.round(((pixel >>> 5) & 0x3f) * 255 / 63);
      destination[pixelIndex + 2] = Math.round((pixel & 0x1f) * 255 / 31);
      destination[pixelIndex + 3] = 255;
    }
    dashboard.showVideoSurface("canvas");
    context.putImageData(rawImage, 0, 0);
    lastFrameId = view.getUint32(8, true);
    noteDisplayedFrame("Live raw RGB565");
  }

  function updateTelemetryRow(sample) {
    const numeric = Number(sample.value);
    const dashboardSample =
      (sample.name === "wheel.left.rpm" || sample.name === "wheel.right.rpm") && Number.isFinite(numeric)
        ? { ...sample, value: Math.abs(numeric) }
        : sample;
    dashboard.updateTelemetry(dashboardSample);
    if (sample.name === "system.mode") systemMode = String(sample.value);
    if (sample.name === "system.state") systemState = String(sample.value);
    if (sample.name === "system.mode" || sample.name === "system.state") setRaceControls();
    let row = telemetryRows.get(sample.name);
    if (!row) {
      if (telemetryRows.size >= MAX_TELEMETRY_SIGNALS) return;
      row = document.createElement("tr");
      row.dataset.telemetryName = sample.name;
      for (let index = 0; index < 6; index += 1) row.appendChild(document.createElement("td"));
      telemetryRows.set(sample.name, row);
      telemetryBody.appendChild(row);
    }
    row.children[1].textContent = sample.name;
    row.children[2].textContent = String(sample.value);
    row.children[3].textContent = sample.units || "-";
  }

  function showTelemetry(view, payloadStart, payloadLength) {
    if (payloadLength < 16) return;
    const valueBits = view.getUint32(payloadStart + 8, true);
    const nameBytes = view.getUint16(payloadStart + 12, true);
    const type = view.getUint8(payloadStart + 14);
    const unitsBytes = view.getUint8(payloadStart + 15);
    const textValue = type === 5;
    const textBytes = textValue ? valueBits : 0;
    if (
      16 + nameBytes + unitsBytes + textBytes !== payloadLength || nameBytes === 0 ||
      type < 1 || type > 5 ||
      (textValue && (textBytes === 0 || textBytes > TELEMETRY_TEXT_MAX_BYTES || unitsBytes !== 0))
    ) return;
    const bytes = new Uint8Array(
      view.buffer,
      view.byteOffset + payloadStart + 16,
      nameBytes + unitsBytes + textBytes,
    );
    const name = decoder.decode(bytes.subarray(0, nameBytes));
    const units = decoder.decode(bytes.subarray(nameBytes, nameBytes + unitsBytes));
    let value;
    if (type === 1) value = view.getInt32(payloadStart + 8, true);
    else if (type === 2) value = valueBits;
    else if (type === 3) value = Number(view.getFloat32(payloadStart + 8, true).toFixed(3));
    else if (type === 4) value = valueBits !== 0;
    else value = decoder.decode(bytes.subarray(nameBytes + unitsBytes));
    updateTelemetryRow({ name, units, value, valueType: type });
  }

  function receivePacket(buffer) {
    const view = new DataView(buffer);
    if (view.byteLength < HEADER_BYTES) return;
    const magic = view.getUint32(0, true);
    if (magic === JPEG_MAGIC) {
      const jpegBytes = view.getUint32(16, true);
      if (
        view.getUint8(4) !== 1 || view.getUint8(5) !== HEADER_BYTES ||
        view.getUint16(12, true) !== 320 || view.getUint16(14, true) !== 200 ||
        HEADER_BYTES + jpegBytes !== view.byteLength || jpegBytes < 4 ||
        view.getUint8(HEADER_BYTES) !== 0xff || view.getUint8(HEADER_BYTES + 1) !== 0xd8 ||
        view.getUint8(view.byteLength - 2) !== 0xff || view.getUint8(view.byteLength - 1) !== 0xd9
      ) return;
      dashboard.showVideoSurface("canvas");
      pendingJpeg = { buffer, jpegBytes, frameId: view.getUint32(8, true) };
      void drainJpeg();
      return;
    }
    if (magic === H264_MAGIC) {
      const flags = view.getUint16(6, true);
      const payloadBytes = view.getUint32(16, true);
      if (
        view.getUint8(4) !== 1 || view.getUint8(5) !== HEADER_BYTES ||
        view.getUint16(12, true) !== 320 || view.getUint16(14, true) !== 200 ||
        HEADER_BYTES + payloadBytes !== view.byteLength
      ) return;
      lastFrameId = view.getUint32(8, true);
      const payload = buffer.slice(HEADER_BYTES);
      if (flags & H264_FLAG_INITIALIZATION) beginH264(payload, view.getUint32(28, true));
      else queueH264(payload);
      return;
    }
    if (magic === RAW_MAGIC) {
      const rawBytes = view.getUint32(16, true);
      if (
        view.getUint8(4) !== 1 || view.getUint8(5) !== HEADER_BYTES ||
        view.getUint16(12, true) !== 320 || view.getUint16(14, true) !== 200 ||
        rawBytes !== 320 * 200 * 2 || HEADER_BYTES + rawBytes !== view.byteLength ||
        view.getUint32(28, true) !== RAW_PIXEL_FORMAT_RGB565_LE
      ) return;
      showRaw(buffer, view, rawBytes);
      return;
    }
    if (magic !== AVCU_MAGIC || view.getUint8(4) !== 1 || view.getUint8(5) !== HEADER_BYTES) return;
    const messageId = view.getUint32(8, true);
    const payloadLength = view.getUint32(16, true);
    if (HEADER_BYTES + payloadLength !== view.byteLength) return;
    if (messageId === MSG_TELEMETRY) showTelemetry(view, HEADER_BYTES, payloadLength);
  }

  function connect() {
    const streamParameters = new URLSearchParams({ video: requestedVideo });
    if (pageParameters.has("replace")) streamParameters.set("replace", "1");
    const protocol = location.protocol === "https:" ? "wss" : "ws";
    const socket = new WebSocket(`${protocol}://${location.host}/stream?${streamParameters}`);
    currentSocket = socket;
    socket.binaryType = "arraybuffer";
    socket.onopen = () => {
      socketConnected = true;
      setStatus(`Connected (${requestedVideo}); waiting for frame...`, true, false);
      setRaceControls();
    };
    socket.onmessage = (event) => {
      if (typeof event.data === "string") receiveSystemActionResult(event.data);
      else receivePacket(event.data);
    };
    socket.onerror = () => socket.close();
    socket.onclose = () => {
      if (currentSocket !== socket) return;
      currentSocket = null;
      socketConnected = false;
      cancelRaceStartHold();
      setStatus("Disconnected; retrying...", false, false);
      setRaceControls();
      setTimeout(connect, 1000);
    };
  }

  async function pollHealth() {
    try {
      const response = await fetch("/health", { cache: "no-store" });
      const snapshot = await response.json();
      helloCapabilities = Number(snapshot.capabilities) || 0;
      health.textContent = JSON.stringify(snapshot, null, 2);
      setRaceControls();
    } catch (error) {
      health.textContent = `Health error: ${error}`;
    }
    setTimeout(pollHealth, 1000);
  }

  setStatus("Connecting...", false, false);
  raceStartButton.addEventListener("pointerdown", (event) => {
    if (event.button === 0) beginRaceStartHold();
  });
  for (const eventName of ["pointerup", "pointercancel", "pointerleave"]) {
    raceStartButton.addEventListener(eventName, cancelRaceStartHold);
  }
  raceStartButton.addEventListener("keydown", (event) => {
    if ((event.key === " " || event.key === "Enter") && !event.repeat) {
      event.preventDefault();
      beginRaceStartHold();
    }
  });
  raceStartButton.addEventListener("keyup", (event) => {
    if (event.key === " " || event.key === "Enter") cancelRaceStartHold();
  });
  raceStopButton.addEventListener("click", () => {
    cancelRaceStartHold();
    requestSystemAction("stop");
  });
  setRaceControls();
  connect();
  void pollHealth();
})();
