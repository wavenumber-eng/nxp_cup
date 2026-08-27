// Computation-lab extension for camera_sim.html. This source is injected into
// the simulator's module scope so it can consume the exact rendered RGB565 frame.
const labWidth = CONFIG.cam.width;
const labLineA = new Float64Array(labWidth);
const labLineB = new Float64Array(labWidth);
const labMass = new Uint16Array(labWidth);
const labProduct = new Int32Array(labWidth);
let labSelectedPixel = Math.floor(labWidth / 2);
let labRevealedStep = 1;
let labLastWorksheetUpdate = 0;

const lab = {};
[
  'scanline-lab', 'open-scanline-lab', 'close-scanline-lab',
  'toggle-sim-controls', 'toggle-sim-overview', 'lab-camera-feed',
  'lab-camera-overlay', 'lab-row-a', 'lab-row-a-value', 'lab-second-enabled',
  'lab-row-b-controls', 'lab-row-b', 'lab-row-b-value', 'worksheet-line',
  'lab-previous-step', 'lab-next-step', 'lab-step-output', 'lab-a-mass',
  'lab-a-moment', 'lab-a-position', 'lab-b-position', 'lab-plot-a',
  'lab-plot-b', 'lab-plot-b-card', 'selected-pixel-detail', 'worksheet-scroll'
].forEach(id => lab[id] = document.getElementById(id));

const row2Enabled = document.getElementById('row2Enabled');
const row2Controls = document.getElementById('row2Controls');
const row2Input = document.getElementById('row2');
const row2Value = document.getElementById('r2Val');
const row2Distance = document.getElementById('r2d');
const plot2Group = document.getElementById('plot2Group');
const worksheetRows = {
  x: document.getElementById('worksheet-x'),
  y: document.getElementById('worksheet-y'),
  mass: document.getElementById('worksheet-mass'),
  weight: document.getElementById('worksheet-weight'),
  product: document.getElementById('worksheet-product'),
};

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

function buildWorksheet() {
  for (let x = 0; x < labWidth; x++) {
    for (const row of Object.values(worksheetRows)) {
      const cell = document.createElement('td');
      cell.dataset.x = String(x);
      cell.addEventListener('pointerenter', () => selectWorksheetPixel(x, false));
      cell.addEventListener('click', () => selectWorksheetPixel(x, true));
      row.appendChild(cell);
    }
  }
}

function worksheetCells(row) {
  return row.querySelectorAll('td');
}

function selectWorksheetPixel(x, scroll) {
  labSelectedPixel = Math.max(0, Math.min(labWidth - 1, x));
  document.querySelectorAll('#scanline-worksheet td.is-selected')
    .forEach(cell => cell.classList.remove('is-selected'));
  for (const row of Object.values(worksheetRows)) {
    const cell = worksheetCells(row)[labSelectedPixel];
    cell.classList.add('is-selected');
    if (scroll && row === worksheetRows.x) cell.scrollIntoView({ block: 'nearest', inline: 'center' });
  }
  updateSelectedPixelDetail();
}

function activeWorksheetLine() {
  return lab['worksheet-line'].value === 'b' && row2Enabled.checked ? labLineB : labLineA;
}

function calculateLine(values) {
  let totalMass = 0;
  let firstMoment = 0;
  for (let x = 0; x < labWidth; x++) {
    const mass = 255 - Math.round(values[x]);
    const weight2 = 2 * x - (labWidth - 1);
    const product = mass * weight2;
    labMass[x] = mass;
    labProduct[x] = product;
    totalMass += mass;
    firstMoment += product;
  }
  return {
    totalMass,
    firstMoment,
    position: totalMass ? firstMoment / (2 * totalMass) : null,
  };
}

function formatInteger(value) {
  return Math.round(value).toLocaleString('en-US');
}

function formatPosition(value) {
  if (value === null || !Number.isFinite(value)) return 'no mass';
  const sign = value > 0 ? '+' : '';
  return `${sign}${value.toFixed(2)} px`;
}

function updateWorksheet() {
  const values = activeWorksheetLine();
  const result = calculateLine(values);
  const cells = {};
  for (const [name, row] of Object.entries(worksheetRows)) cells[name] = worksheetCells(row);
  for (let x = 0; x < labWidth; x++) {
    cells.x[x].textContent = String(x);
    cells.y[x].textContent = String(Math.round(values[x]));
    cells.mass[x].textContent = String(labMass[x]);
    cells.weight[x].textContent = String(2 * x - (labWidth - 1));
    cells.product[x].textContent = formatInteger(labProduct[x]);
  }
  updateSelectedPixelDetail();
  return result;
}

function updateSelectedPixelDetail() {
  const values = activeWorksheetLine();
  calculateLine(values);
  const x = labSelectedPixel;
  const lineName = lab['worksheet-line'].value.toUpperCase();
  lab['selected-pixel-detail'].textContent =
    `ROW ${lineName} · x=${x} · Y=${Math.round(values[x])} · mass=${labMass[x]} · ` +
    `weight2=${2 * x - (labWidth - 1)} · contribution=${formatInteger(labProduct[x])}`;
}

function setRevealStep(step) {
  labRevealedStep = Math.max(1, Math.min(5, step));
  document.querySelectorAll('#scanline-worksheet tr[data-stage]').forEach(row => {
    row.classList.toggle('is-future', Number(row.dataset.stage) > labRevealedStep);
  });
  document.querySelectorAll('.lab-step-strip li').forEach(item => {
    const itemStep = Number(item.dataset.step);
    item.classList.toggle('is-revealed', itemStep <= labRevealedStep);
    item.classList.toggle('is-current', itemStep === labRevealedStep);
  });
  document.querySelector('.lab-results').hidden = labRevealedStep < 5;
  lab['lab-step-output'].textContent = `Step ${labRevealedStep} of 5`;
  lab['lab-previous-step'].disabled = labRevealedStep === 1;
  lab['lab-next-step'].disabled = labRevealedStep === 5;
}

function drawColoredPlot(canvas, values, color) {
  const context = canvas.getContext('2d');
  const width = canvas.width;
  const height = canvas.height;
  context.clearRect(0, 0, width, height);
  context.fillStyle = '#fff';
  context.fillRect(0, 0, width, height);
  context.strokeStyle = '#e3e6ea';
  context.lineWidth = 1;
  for (const value of [64, 128, 192]) {
    const y = height - 8 - value / 255 * (height - 18);
    context.beginPath();
    context.moveTo(0, y);
    context.lineTo(width, y);
    context.stroke();
  }
  context.strokeStyle = color;
  context.lineWidth = 2;
  context.beginPath();
  for (let x = 0; x < values.length; x++) {
    const px = x * width / (values.length - 1);
    const py = height - 8 - values[x] / 255 * (height - 18);
    if (x === 0) context.moveTo(px, py); else context.lineTo(px, py);
  }
  context.stroke();
}

function extractLumaRow(frameImage, row, target) {
  for (let x = 0; x < labWidth; x++) {
    const pixel = (row * labWidth + x) * 4;
    target[x] = (77 * frameImage.data[pixel] + 150 * frameImage.data[pixel + 1] +
      29 * frameImage.data[pixel + 2] + 128) >> 8;
  }
}

function updateLabCamera(frameImage, rowA, rowB, secondEnabled) {
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
}

function scanlineLabOnFrame(frameImage) {
  const rowA = Number(ui.row1.value);
  const rowB = Number(row2Input.value);
  const secondEnabled = row2Enabled.checked;
  extractLumaRow(frameImage, rowA, labLineA);
  if (secondEnabled) extractLumaRow(frameImage, rowB, labLineB);

  if (secondEnabled) {
    overlay.strokeStyle = '#0ea5b7';
    overlay.lineWidth = 2;
    overlay.beginPath();
    overlay.moveTo(0, rowB * 2 + 1);
    overlay.lineTo(640, rowB * 2 + 1);
    overlay.stroke();
    drawColoredPlot(document.getElementById('plot2'), labLineB, '#0ea5b7');
    ui.analysis.insertAdjacentHTML('beforeend',
      `<br><span style="color:#0ea5b7">■</span> row ${rowB}: second raw Y profile`);
  }

  updateLabCamera(frameImage, rowA, rowB, secondEnabled);
  const now = performance.now();
  if (now - labLastWorksheetUpdate < 150) return;
  labLastWorksheetUpdate = now;
  const resultA = calculateLine(labLineA);
  lab['lab-a-mass'].textContent = formatInteger(resultA.totalMass);
  lab['lab-a-moment'].textContent = formatInteger(resultA.firstMoment);
  lab['lab-a-position'].textContent = formatPosition(resultA.position);
  drawColoredPlot(lab['lab-plot-a'], labLineA, '#d99a00');
  if (secondEnabled) {
    const resultB = calculateLine(labLineB);
    lab['lab-b-position'].textContent = formatPosition(resultB.position);
    drawColoredPlot(lab['lab-plot-b'], labLineB, '#0e91a2');
  }
  if (!lab['scanline-lab'].hidden) updateWorksheet();
}

function setSecondLineEnabled(enabled) {
  row2Enabled.checked = enabled;
  lab['lab-second-enabled'].checked = enabled;
  lab['lab-row-b-controls'].hidden = !enabled;
  lab['lab-plot-b-card'].hidden = !enabled;
  document.querySelectorAll('.result-b').forEach(card => card.hidden = !enabled);
  document.querySelector('.lab-results').classList.toggle('has-second', enabled);
  document.querySelector('.lab-plots').classList.toggle('has-second', enabled);
  lab['worksheet-line'].options[1].disabled = !enabled;
  if (!enabled && lab['worksheet-line'].value === 'b') lab['worksheet-line'].value = 'a';
  updateSecondStripe();
  updateWorksheet();
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

buildWorksheet();
selectWorksheetPixel(labSelectedPixel, false);
setRevealStep(1);
syncRowA(ui.row1.value);
syncRowB(row2Input.value);
setSecondLineEnabled(false);

lab['open-scanline-lab'].addEventListener('click', () => {
  lab['scanline-lab'].hidden = false;
  document.body.classList.add('lab-open');
  lab['close-scanline-lab'].focus();
  updateWorksheet();
});
lab['close-scanline-lab'].addEventListener('click', () => {
  lab['scanline-lab'].hidden = true;
  document.body.classList.remove('lab-open');
  lab['open-scanline-lab'].focus();
});
lab['toggle-sim-controls'].addEventListener('click', event => {
  const panel = document.getElementById('panel');
  panel.hidden = !panel.hidden;
  event.currentTarget.textContent = panel.hidden ? 'Show controls' : 'Hide controls';
  event.currentTarget.setAttribute('aria-pressed', String(!panel.hidden));
});
lab['toggle-sim-overview'].addEventListener('click', event => {
  const left = document.getElementById('left');
  const layout = document.getElementById('layout');
  left.hidden = !left.hidden;
  layout.classList.toggle('camera-focus', left.hidden);
  event.currentTarget.textContent = left.hidden ? 'Show overview' : 'Focus camera';
  event.currentTarget.setAttribute('aria-pressed', String(left.hidden));
  resize();
});
lab['lab-row-a'].addEventListener('input', event => syncRowA(event.currentTarget.value));
ui.row1.addEventListener('input', event => syncRowA(event.currentTarget.value));
lab['lab-row-b'].addEventListener('input', event => syncRowB(event.currentTarget.value));
row2Input.addEventListener('input', event => syncRowB(event.currentTarget.value));
lab['lab-second-enabled'].addEventListener('change', event => setSecondLineEnabled(event.currentTarget.checked));
row2Enabled.addEventListener('change', event => setSecondLineEnabled(event.currentTarget.checked));
lab['worksheet-line'].addEventListener('change', updateWorksheet);
lab['lab-previous-step'].addEventListener('click', () => setRevealStep(labRevealedStep - 1));
lab['lab-next-step'].addEventListener('click', () => setRevealStep(labRevealedStep + 1));
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
