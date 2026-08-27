// Computation-lab extension for camera_sim.html. This source is injected into
// the simulator's module scope so it can consume the exact rendered RGB565 frame.
const labWidth = CONFIG.cam.width;
const labLineA = new Float64Array(labWidth);
const labLineB = new Float64Array(labWidth);
const labHueA = new Uint8Array(labWidth);
const labHueB = new Uint8Array(labWidth);
const labSaturationA = new Uint8Array(labWidth);
const labSaturationB = new Uint8Array(labWidth);
const labValueA = new Uint8Array(labWidth);
const labValueB = new Uint8Array(labWidth);
const labFilterMask = new Uint8Array(labWidth);
const labBlueFilterMask = new Uint8Array(labWidth);
let labSelectedPixel = Math.floor(labWidth / 2);
let labLastPresentationUpdate = 0;
let labLastFilterResult = null;
let labLastBlueFilterResult = null;

const lab = {};
[
  'scanline-lab', 'open-scanline-lab', 'close-scanline-lab',
  'toggle-sim-controls', 'show-sim-controls', 'lab-camera-feed',
  'lab-camera-overlay', 'lab-row-a', 'lab-row-a-value', 'lab-second-enabled',
  'lab-row-b-controls', 'lab-row-b', 'lab-row-b-value', 'lab-filter-row',
  'filter-row', 'filter-black-controls', 'filter-blue-controls',
  'filter-black-v', 'filter-black-v-value', 'filter-blue-h', 'filter-blue-h-value',
  'filter-blue-width', 'filter-blue-width-value', 'filter-blue-s',
  'filter-blue-s-value', 'filter-blue-v', 'filter-blue-v-value',
  'filter-view-blue',
  'filter-name', 'filter-expression', 'blue-filter-expression', 'filter-code',
  'filter-mask-plot', 'blue-filter-mask-plot', 'lab-filter-mask-plot',
  'lab-blue-filter-mask-plot', 'filter-main-analysis', 'blue-filter-main-analysis',
  'filter-match-count', 'black-edge-count', 'blue-filter-match-count',
  'filter-selected-detail', 'yhsv-live-table', 'yhsv-live-row', 'yhsv-table-scroll'
].forEach(id => lab[id] = document.getElementById(id));

const labYhsvCells = {};
for (const channel of ['y', 'h', 's', 'v']) {
  const row = lab['yhsv-live-table'].querySelector(`tr[data-channel="${channel}"]`);
  labYhsvCells[channel] = [];
  for (let x = 0; x < labWidth; x++) {
    const cell = document.createElement('td');
    cell.dataset.x = String(x);
    cell.textContent = '0';
    row.appendChild(cell);
    labYhsvCells[channel].push(cell);
  }
}

// Fixed teaching references. ref1.png maps this 8 cm blue token to the track
// cross. Future yellow/red references can be added without changing filtering.
const labReferenceTokens = [
  { name: 'blue', x: 0.1094, z: -0.0657, radius: 0.04, color: 0x0e42f1 },
];
for (const token of labReferenceTokens) {
  coinRGB.push({
    x: token.x, z: token.z, r2: token.radius * token.radius,
    r: (token.color >> 16) & 255, g: (token.color >> 8) & 255, b: token.color & 255,
  });
  const group = new THREE.Group();
  const face = new THREE.Mesh(
    new THREE.CylinderGeometry(token.radius, token.radius, 0.005, 36),
    new THREE.MeshBasicMaterial({ color: token.color }));
  face.position.y = 0.003;
  const rim = new THREE.Mesh(
    new THREE.RingGeometry(token.radius * 0.72, token.radius * 0.91, 36),
    new THREE.MeshBasicMaterial({ color: 0x071caf, side: THREE.DoubleSide }));
  rim.rotation.x = -Math.PI / 2;
  rim.position.y = 0.006;
  group.add(face, rim);
  group.position.set(token.x, 0, token.z);
  group.name = `${token.name}-reference-token`;
  coinGroup.add(group);
}

const row2Enabled = document.getElementById('row2Enabled');
const row2Controls = document.getElementById('row2Controls');
const row2Input = document.getElementById('row2');
const row2Value = document.getElementById('r2Val');
const row2Distance = document.getElementById('r2d');
const plot2Group = document.getElementById('plot2Group');

const stripeGeom2 = new THREE.BufferGeometry();
stripeGeom2.setAttribute('position', new THREE.BufferAttribute(new Float32Array(4 * 3), 3));
stripeGeom2.setIndex([0, 1, 2, 0, 2, 3]);
const stripe2 = new THREE.Mesh(stripeGeom2, new THREE.MeshBasicMaterial({
  color: 0x0ea5b7, transparent: true, opacity: 0.9, depthWrite: false, side: THREE.DoubleSide }));
stripe2.renderOrder = 2;
stripe2.visible = false;
car.add(stripe2);

function updateSecondStripe() {
  const enabled = row2Enabled.checked;
  stripe2.visible = enabled;
  row2Controls.hidden = !enabled;
  plot2Group.hidden = !enabled;
  if (!enabled || !rig) return;
  const row = Number(row2Input.value);
  const W = CONFIG.cam.width - 1;
  const H = CONFIG.cam.height - 1;
  const M = CONFIG.footprintMax;
  const a0 = pixelToGround(0, row, rig, M);
  const a1 = pixelToGround(W, row, rig, M);
  const b0 = pixelToGround(0, Math.min(row + 1.5, H), rig, M);
  const b1 = pixelToGround(W, Math.min(row + 1.5, H), rig, M);
  const positions = stripeGeom2.attributes.position.array;
  [[a0, 0], [a1, 1], [b1, 2], [b0, 3]].forEach(([point, index]) => {
    positions[3 * index] = point[0];
    positions[3 * index + 1] = 0.0045;
    positions[3 * index + 2] = point[2];
  });
  stripeGeom2.attributes.position.needsUpdate = true;
  stripeGeom2.computeBoundingSphere();
  row2Value.textContent = `y = ${row}`;
  const middle = pixelToGround((CONFIG.cam.width - 1) / 2, row, rig, null);
  row2Distance.textContent = middle
    ? `→ ${((middle[2] - CONFIG.cam.forward) * 100).toFixed(0)} cm ahead`
    : '→ above horizon';
}

function selectFilterPixel(x) {
  labSelectedPixel = Math.max(0, Math.min(labWidth - 1, x));
  if (labLastFilterResult && labLastBlueFilterResult) {
    updateFilterPresentation(labLastFilterResult, labLastBlueFilterResult);
  }
}

function extractYhsvRow(frameImage, row, targetY, targetH, targetS, targetV) {
  for (let x = 0; x < labWidth; x++) {
    const pixel = (row * labWidth + x) * 4;
    const red = frameImage.data[pixel];
    const green = frameImage.data[pixel + 1];
    const blue = frameImage.data[pixel + 2];
    targetY[x] = (77 * red + 150 * green + 29 * blue + 128) >> 8;
    const maximum = Math.max(red, green, blue);
    const minimum = Math.min(red, green, blue);
    const delta = maximum - minimum;
    let hue = 0;
    if (delta) {
      if (maximum === red) hue = ((green - blue) / delta) % 6;
      else if (maximum === green) hue = (blue - red) / delta + 2;
      else hue = (red - green) / delta + 4;
      hue /= 6;
      if (hue < 0) hue += 1;
    }
    targetH[x] = Math.floor(hue * 256) & 0xff;
    targetS[x] = maximum ? Math.min(255, Math.floor(delta / maximum * 255 + 0.5)) : 0;
    targetV[x] = maximum;
  }
}

const filterStyles = {
  black: { name: 'Black / dark mask', color: '#111827' },
  blue: { name: 'Blue token mask', color: '#0e42f1' },
};

function circularHueDistance(left, right) {
  const direct = Math.abs(left - right);
  return Math.min(direct, 256 - direct);
}

function activeFilterChannels() {
  const useRowB = lab['filter-row'].value === 'b' && row2Enabled.checked;
  return {
    rowName: useRowB ? 'B' : 'A',
    row: Number(useRowB ? row2Input.value : ui.row1.value),
    y: useRowB ? labLineB : labLineA,
    h: useRowB ? labHueB : labHueA,
    s: useRowB ? labSaturationB : labSaturationA,
    v: useRowB ? labValueB : labValueA,
  };
}

function findMaskTransitions(mask) {
  const transitions = [];
  for (let x = 1; x < mask.length; x++) {
    if (mask[x] !== mask[x - 1]) transitions.push(x - 0.5);
  }
  return transitions;
}

function calculateFilterMask(mode, targetMask) {
  const channels = activeFilterChannels();
  const blackV = Number(lab['filter-black-v'].value);
  const blueH = Number(lab['filter-blue-h'].value);
  const blueWidth = Number(lab['filter-blue-width'].value);
  const blueS = Number(lab['filter-blue-s'].value);
  const blueV = Number(lab['filter-blue-v'].value);
  let matched = 0;
  for (let x = 0; x < labWidth; x++) {
    const isMatch = mode === 'black'
      ? channels.v[x] < blackV
      : circularHueDistance(channels.h[x], blueH) <= blueWidth &&
        channels.s[x] > blueS && channels.v[x] > blueV;
    targetMask[x] = isMatch ? 1 : 0;
    if (isMatch) matched++;
  }
  let expression = `mask[x] = (V[x] < ${blackV}) ? 1 : 0`;
  let cCondition = `scanline[x].v < ${blackV}U`;
  if (mode === 'blue') {
    expression = `mask[x] = (hue_distance(H[x], ${blueH}) ≤ ${blueWidth} && ` +
      `S[x] > ${blueS} && V[x] > ${blueV}) ? 1 : 0`;
    cCondition = `hue_distance_u8(scanline[x].h, ${blueH}U) <= ${blueWidth}U &&\n` +
      `              scanline[x].s > ${blueS}U && scanline[x].v > ${blueV}U`;
  }
  const edgePositions = mode === 'black' ? findMaskTransitions(targetMask) : [];
  return {
    ...channels, mode, matched, expression, cCondition,
    color: filterStyles[mode].color, mask: targetMask, edgePositions,
  };
}

function drawFilterMaskPlot(canvas, result, showSelectedPixel) {
  const context = canvas.getContext('2d');
  const width = canvas.width;
  const height = canvas.height;
  const top = 24;
  const bottom = height - 24;
  const scale = width / labWidth;
  context.clearRect(0, 0, width, height);
  context.fillStyle = '#fff';
  context.fillRect(0, 0, width, height);
  context.strokeStyle = '#d9dde3';
  context.lineWidth = 1;
  for (const y of [top, bottom]) {
    context.beginPath();
    context.moveTo(0, y);
    context.lineTo(width, y);
    context.stroke();
  }
  context.fillStyle = '#69717b';
  context.font = '16px Consolas, monospace';
  context.fillText('1', 6, top - 5);
  context.fillText('0', 6, bottom + 19);
  context.fillStyle = result.color;
  context.globalAlpha = 0.22;
  for (let x = 0; x < labWidth; x++) {
    if (result.mask[x]) context.fillRect(x * scale, top, Math.ceil(scale), bottom - top);
  }
  context.globalAlpha = 1;
  context.strokeStyle = result.color;
  context.lineWidth = 2;
  context.beginPath();
  for (let x = 0; x < labWidth; x++) {
    const px = x * scale;
    const py = result.mask[x] ? top : bottom;
    if (x === 0) context.moveTo(px, py);
    else {
      context.lineTo(px, py);
      context.lineTo(px + scale, py);
    }
  }
  context.stroke();
  if (result.mode === 'black') {
    context.fillStyle = '#dc2626';
    for (const edge of result.edgePositions) {
      const edgeX = (edge + 0.5) * scale;
      context.beginPath();
      context.moveTo(edgeX, 2);
      context.lineTo(edgeX - 5, 12);
      context.lineTo(edgeX + 5, 12);
      context.closePath();
      context.fill();
    }
  }
  if (showSelectedPixel) {
    const selectedX = (labSelectedPixel + 0.5) * scale;
    context.strokeStyle = '#d68d00';
    context.lineWidth = 2;
    context.beginPath();
    context.moveTo(selectedX, 0);
    context.lineTo(selectedX, height);
    context.stroke();
  }
}

function updateYhsvTable(blackResult, blueResult) {
  lab['yhsv-live-row'].textContent =
    `${blackResult.rowName} (y = ${blackResult.row})`;
  const channels = {
    y: blackResult.y,
    h: blackResult.h,
    s: blackResult.s,
    v: blackResult.v,
  };
  for (const [channel, values] of Object.entries(channels)) {
    for (let x = 0; x < labWidth; x++) {
      const cell = labYhsvCells[channel][x];
      const value = Math.round(values[x]);
      if (cell.textContent !== String(value)) cell.textContent = String(value);
      cell.className = [
        blackResult.mask[x] ? 'is-v-match' : '',
        blueResult.mask[x] ? 'is-blue-match' : '',
        x === labSelectedPixel ? 'is-selected' : '',
      ].filter(Boolean).join(' ');
      cell.title = `x=${x} ${channel.toUpperCase()}=${value}`;
    }
  }
}

function updateFilterPresentation(blackResult, blueResult) {
  lab['filter-name'].textContent = `${filterStyles.black.name} · row ${blackResult.rowName}`;
  lab['filter-expression'].textContent = blackResult.expression;
  lab['blue-filter-expression'].textContent = blueResult.expression;
  lab['filter-code'].textContent =
    '#include "vision_test.h"\n' +
    '#include "nxp_cup.h"\n\n' +
    'static color_features_t scanline[CAMERA_WIDTH];\n' +
    'static uint8_t black_mask[CAMERA_WIDTH];\n' +
    'static uint8_t blue_mask[CAMERA_WIDTH];\n\n' +
    'static uint8_t hue_distance_u8(uint8_t left, uint8_t right)\n' +
    '{\n' +
    '    uint8_t direct = (left > right) ? (left - right) : (right - left);\n' +
    '    return (direct <= 128U) ? direct : (uint8_t)(256U - direct);\n' +
    '}\n\n' +
    'void vision_test_on_frame(uint16_t *frame)\n' +
    '{\n' +
    `    const uint32_t row = ${blackResult.row}U;\n` +
    '    uint32_t black_match_count = 0U;\n' +
    '    uint32_t blue_match_count = 0U;\n' +
    '    uint32_t black_edge_count = 0U;\n\n' +
    '    color_convert_rgb565_to_yhsv(camera_row(frame, row), scanline, CAMERA_WIDTH);\n' +
    '    for (uint32_t x = 0U; x < CAMERA_WIDTH; x++)\n' +
    '    {\n' +
    `        black_mask[x] = (${blackResult.cCondition}) ? 1U : 0U;\n` +
    `        blue_mask[x] = (${blueResult.cCondition}) ? 1U : 0U;\n` +
    '        black_match_count += black_mask[x];\n' +
    '        blue_match_count += blue_mask[x];\n' +
    '    }\n\n' +
    '    /* A black edge is a transition between adjacent samples. */\n' +
    '    for (uint32_t x = 1U; x < CAMERA_WIDTH; x++)\n' +
    '    {\n' +
    '        if (black_mask[x] != black_mask[x - 1U])\n' +
    '        {\n' +
    '            black_edge_count++;\n' +
    '        }\n' +
    '    }\n\n' +
    '    (void)telemetry_u32("vision.black_pixels", black_match_count, "count");\n' +
    '    (void)telemetry_u32("vision.blue_pixels", blue_match_count, "count");\n' +
    '    (void)telemetry_u32("vision.black_edges", black_edge_count, "count");\n\n' +
    '    /* STUDENT TODO: pair suitable entering/exiting edges and store\n' +
    '     * every candidate black-line center. Handle an odd edge count and\n' +
    '     * lines touching the image boundary; do not assume which is the track. */\n' +
    '}';
  lab['filter-match-count'].textContent = `${blackResult.matched} / ${labWidth} pixels match`;
  lab['black-edge-count'].textContent = `${blackResult.edgePositions.length} black transitions`;
  lab['filter-main-analysis'].textContent =
    `${blackResult.matched} / ${labWidth} pixels match · ` +
    `${blackResult.edgePositions.length} transitions`;
  lab['blue-filter-match-count'].textContent = `${blueResult.matched} / ${labWidth} pixels match`;
  lab['blue-filter-main-analysis'].textContent =
    `${blueResult.matched} / ${labWidth} pixels match`;
  const x = labSelectedPixel;
  lab['filter-selected-detail'].textContent =
    `x=${x} · Y=${Math.round(blackResult.y[x])} H=${blackResult.h[x]} ` +
    `S=${blackResult.s[x]} V=${blackResult.v[x]} → ` +
    `black=${blackResult.mask[x]} blue=${blueResult.mask[x]}`;
  updateYhsvTable(blackResult, blueResult);
  drawFilterMaskPlot(lab['filter-mask-plot'], blackResult, false);
  lab['filter-mask-plot'].dataset.blackEdgeCount = String(blackResult.edgePositions.length);
  drawFilterMaskPlot(lab['blue-filter-mask-plot'], blueResult, false);
  drawFilterMaskPlot(lab['lab-filter-mask-plot'], blackResult, true);
  drawFilterMaskPlot(lab['lab-blue-filter-mask-plot'], blueResult, true);
}

function drawFilterCameraMask(context, result, verticalOffset) {
  context.save();
  context.fillStyle = result.color;
  context.globalAlpha = 0.85;
  for (let x = 0; x < labWidth; x++) {
    if (result.mask[x]) context.fillRect(x * 2, result.row * 2 + verticalOffset, 2, 5);
  }
  context.restore();
}

function updateLabCamera(frameImage, rowA, rowB, secondEnabled, blackResult, blueResult) {
  lab['lab-camera-feed'].getContext('2d').putImageData(frameImage, 0, 0);
  const context = lab['lab-camera-overlay'].getContext('2d');
  context.clearRect(0, 0, 640, 400);
  [[rowA, '#eab308'], ...(secondEnabled ? [[rowB, '#0ea5b7']] : [])].forEach(([row, color]) => {
    context.strokeStyle = color;
    context.lineWidth = 3;
    context.beginPath();
    context.moveTo(0, row * 2 + 1);
    context.lineTo(640, row * 2 + 1);
    context.stroke();
  });
  drawFilterCameraMask(context, blackResult, -6);
  drawFilterCameraMask(context, blueResult, 1);
}

function scanlineLabOnFrame(frameImage) {
  const rowA = Number(ui.row1.value);
  const rowB = Number(row2Input.value);
  const secondEnabled = row2Enabled.checked;
  extractYhsvRow(frameImage, rowA, labLineA, labHueA, labSaturationA, labValueA);
  if (secondEnabled) {
    extractYhsvRow(frameImage, rowB, labLineB, labHueB, labSaturationB, labValueB);
  }
  const filterResult = calculateFilterMask('black', labFilterMask);
  const blueFilterResult = calculateFilterMask('blue', labBlueFilterMask);
  labLastFilterResult = filterResult;
  labLastBlueFilterResult = blueFilterResult;

  if (secondEnabled) {
    overlay.strokeStyle = '#0ea5b7';
    overlay.lineWidth = 2;
    overlay.beginPath();
    overlay.moveTo(0, rowB * 2 + 1);
    overlay.lineTo(640, rowB * 2 + 1);
    overlay.stroke();
    drawPlot(document.getElementById('plot2'), labLineB);
    ui.analysis.insertAdjacentHTML('beforeend',
      `<br><span style="color:#0ea5b7">■</span> row ${rowB}: second raw Y profile`);
  }

  drawFilterCameraMask(overlay, filterResult, -6);
  drawFilterCameraMask(overlay, blueFilterResult, 1);
  updateLabCamera(frameImage, rowA, rowB, secondEnabled, filterResult, blueFilterResult);
  const now = performance.now();
  if (now - labLastPresentationUpdate < 150) return;
  labLastPresentationUpdate = now;
  updateFilterPresentation(filterResult, blueFilterResult);
}

function setSecondLineEnabled(enabled) {
  row2Enabled.checked = enabled;
  lab['lab-second-enabled'].checked = enabled;
  lab['lab-row-b-controls'].hidden = !enabled;
  lab['filter-row'].options[1].disabled = !enabled;
  lab['lab-filter-row'].options[1].disabled = !enabled;
  if (!enabled && lab['filter-row'].value === 'b') lab['filter-row'].value = 'a';
  if (!enabled && lab['lab-filter-row'].value === 'b') lab['lab-filter-row'].value = 'a';
  updateSecondStripe();
}

function syncRowA(value) {
  ui.row1.value = value;
  lab['lab-row-a'].value = value;
  lab['lab-row-a-value'].textContent = value;
  rebuildRig();
  updateSecondStripe();
}

function syncRowB(value) {
  row2Input.value = value;
  lab['lab-row-b'].value = value;
  lab['lab-row-b-value'].textContent = value;
  updateSecondStripe();
}

function updateFilterControls() {
  const valuePairs = [
    ['filter-black-v', 'filter-black-v-value'],
    ['filter-blue-h', 'filter-blue-h-value'],
    ['filter-blue-width', 'filter-blue-width-value'],
    ['filter-blue-s', 'filter-blue-s-value'],
    ['filter-blue-v', 'filter-blue-v-value'],
  ];
  for (const [input, output] of valuePairs) lab[output].textContent = lab[input].value;
  labLastFilterResult = calculateFilterMask('black', labFilterMask);
  labLastBlueFilterResult = calculateFilterMask('blue', labBlueFilterMask);
  updateFilterPresentation(labLastFilterResult, labLastBlueFilterResult);
}

function syncFilterRow(value) {
  lab['filter-row'].value = value;
  lab['lab-filter-row'].value = value;
  updateFilterControls();
}

syncRowA(ui.row1.value);
syncRowB(row2Input.value);
setSecondLineEnabled(false);
updateFilterControls();

lab['open-scanline-lab'].addEventListener('click', () => {
  lab['scanline-lab'].hidden = false;
  document.body.classList.add('lab-open');
  lab['close-scanline-lab'].focus();
});
lab['close-scanline-lab'].addEventListener('click', () => {
  lab['scanline-lab'].hidden = true;
  document.body.classList.remove('lab-open');
  lab['open-scanline-lab'].focus();
});
lab['toggle-sim-controls'].addEventListener('click', event => {
  const panel = document.getElementById('panel');
  panel.hidden = true;
  lab['show-sim-controls'].hidden = false;
  lab['show-sim-controls'].focus();
});
lab['show-sim-controls'].addEventListener('click', () => {
  document.getElementById('panel').hidden = false;
  lab['show-sim-controls'].hidden = true;
  lab['toggle-sim-controls'].focus();
});
lab['lab-row-a'].addEventListener('input', event => syncRowA(event.currentTarget.value));
ui.row1.addEventListener('input', event => syncRowA(event.currentTarget.value));
lab['lab-row-b'].addEventListener('input', event => syncRowB(event.currentTarget.value));
row2Input.addEventListener('input', event => syncRowB(event.currentTarget.value));
lab['lab-second-enabled'].addEventListener('change', event => setSecondLineEnabled(event.currentTarget.checked));
row2Enabled.addEventListener('change', event => setSecondLineEnabled(event.currentTarget.checked));
lab['filter-row'].addEventListener('change', event => syncFilterRow(event.currentTarget.value));
lab['lab-filter-row'].addEventListener('change', event => syncFilterRow(event.currentTarget.value));
[
  'filter-black-v', 'filter-blue-h',
  'filter-blue-width', 'filter-blue-s', 'filter-blue-v',
].forEach(id => lab[id].addEventListener('input', updateFilterControls));
['filter-mask-plot', 'blue-filter-mask-plot', 'lab-filter-mask-plot',
  'lab-blue-filter-mask-plot'].forEach(id => {
  lab[id].addEventListener('pointermove', event => {
    const bounds = event.currentTarget.getBoundingClientRect();
    const x = Math.floor((event.clientX - bounds.left) / bounds.width * labWidth);
    selectFilterPixel(x);
  });
});
lab['yhsv-live-table'].addEventListener('pointermove', event => {
  const cell = event.target.closest('td[data-x]');
  if (cell) selectFilterPixel(Number(cell.dataset.x));
});
lab['filter-view-blue'].addEventListener('click', () => {
  state.x = labReferenceTokens[0].x;
  state.z = labReferenceTokens[0].z - 0.375;
  state.yaw = 0;
  state.v = 0;
  state.steer = 0;
  syncRowA('150');
  syncFilterRow('a');
});
['camH', 'camT', 'camF'].forEach(id => ui[id].addEventListener('input', updateSecondStripe));

// Keep arrow keys available to sliders and prevent the hidden simulator from
// driving while the full-screen computation lab is open.
addEventListener('keydown', event => {
  const interactive = ['INPUT', 'SELECT', 'BUTTON'].includes(event.target.tagName);
  if ((!lab['scanline-lab'].hidden || interactive) &&
      ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)) {
    event.stopImmediatePropagation();
  }
}, true);
addEventListener('keyup', event => {
  if (!lab['scanline-lab'].hidden &&
      ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)) {
    event.stopImmediatePropagation();
    keys[event.key] = false;
  }
}, true);
