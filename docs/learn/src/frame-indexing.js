(() => {
  "use strict";

  const DEMO_WIDTH = 8;
  const DEMO_HEIGHT = 5;
  const CAMERA_WIDTH = 320;
  const CAMERA_HEIGHT = 200;
  const $ = (id) => document.getElementById(id);
  const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));
  const toHex = (value, width) => value.toString(16).toUpperCase().padStart(width, "0");

  function demoRgb(x, y) {
    const across = x / (DEMO_WIDTH - 1);
    const down = y / (DEMO_HEIGHT - 1);
    const stripe = (x === y || x === DEMO_WIDTH - y - 1) ? 72 : 0;
    return {
      r: clamp(Math.round(28 + 190 * across + stripe), 0, 255),
      g: clamp(Math.round(42 + 165 * down), 0, 255),
      b: clamp(Math.round(190 - 105 * across + 38 * down), 0, 255),
    };
  }

  function rgb888ToRgb565({ r, g, b }) {
    return (((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3)) & 0xffff;
  }

  function expandRgb565(pixel) {
    const r5 = (pixel >> 11) & 0x1f;
    const g6 = (pixel >> 5) & 0x3f;
    const b5 = pixel & 0x1f;
    return {
      r: (r5 << 3) | (r5 >> 2),
      g: (g6 << 2) | (g6 >> 4),
      b: (b5 << 3) | (b5 >> 2),
    };
  }

  function pixelAt(index) {
    const x = index % DEMO_WIDTH;
    const y = Math.floor(index / DEMO_WIDTH);
    return rgb888ToRgb565(demoRgb(x, y));
  }

  function cssRgb565(pixel) {
    const rgb = expandRgb565(pixel);
    return `rgb(${rgb.r} ${rgb.g} ${rgb.b})`;
  }

  let selectedX = 3;
  let selectedY = 2;
  let selectThreePixel = () => {};

  function buildGrid() {
    const columnLabels = $("column-labels");
    const rowLabels = $("row-labels");
    const grid = $("pixel-grid");

    for (let x = 0; x < DEMO_WIDTH; x += 1) {
      const label = document.createElement("span");
      label.textContent = String(x);
      columnLabels.append(label);
    }
    for (let y = 0; y < DEMO_HEIGHT; y += 1) {
      const label = document.createElement("span");
      label.textContent = String(y);
      rowLabels.append(label);
    }
    for (let index = 0; index < DEMO_WIDTH * DEMO_HEIGHT; index += 1) {
      const x = index % DEMO_WIDTH;
      const y = Math.floor(index / DEMO_WIDTH);
      const pixel = pixelAt(index);
      const button = document.createElement("button");
      const coordinate = document.createElement("span");
      const expression = document.createElement("b");
      button.type = "button";
      button.dataset.index = String(index);
      button.setAttribute("role", "gridcell");
      button.setAttribute("aria-label", `pixel x ${x}, y ${y}, array index ${index}`);
      button.style.setProperty("--pixel-color", cssRgb565(pixel));
      coordinate.textContent = `(${x},${y})`;
      expression.textContent = `[${index}]`;
      button.append(coordinate, expression);
      button.addEventListener("click", () => selectDemoPixel(x, y));
      grid.append(button);
    }
  }

  function updateMemoryWindow(selectedIndex) {
    const host = $("memory-cells");
    const first = clamp(selectedIndex - 3, 0, (DEMO_WIDTH * DEMO_HEIGHT) - 7);
    host.replaceChildren();
    for (let index = first; index < first + 7; index += 1) {
      const cell = document.createElement("div");
      const address = document.createElement("span");
      const indexLabel = document.createElement("b");
      const swatch = document.createElement("i");
      const value = document.createElement("code");
      if (index === selectedIndex) cell.className = "is-selected";
      address.textContent = `+0x${toHex(index * 2, 4)}`;
      indexLabel.textContent = `[${index}]`;
      swatch.style.background = cssRgb565(pixelAt(index));
      value.textContent = `0x${toHex(pixelAt(index), 4)}`;
      cell.append(address, indexLabel, swatch, value);
      host.append(cell);
    }
  }

  function selectDemoPixel(x, y) {
    selectedX = clamp(Math.round(x), 0, DEMO_WIDTH - 1);
    selectedY = clamp(Math.round(y), 0, DEMO_HEIGHT - 1);
    const index = selectedY * DEMO_WIDTH + selectedX;
    const pixel = pixelAt(index);

    $("demo-x").value = String(selectedX);
    $("demo-y").value = String(selectedY);
    $("demo-x-value").value = String(selectedX);
    $("demo-y-value").value = String(selectedY);
    $("demo-formula").value = `${selectedY} × ${DEMO_WIDTH} + ${selectedX} = ${index}`;
    $("demo-coordinate").textContent = `(${selectedX}, ${selectedY})`;
    $("demo-expression").textContent = `frame[${index}]`;
    $("demo-byte-offset").textContent = `${index * 2} bytes`;
    $("demo-pixel-value").textContent = `0x${toHex(pixel, 4)}`;

    $("pixel-grid").querySelectorAll("button").forEach((button) => {
      const isSelected = Number(button.dataset.index) === index;
      button.classList.toggle("is-selected", isSelected);
      button.setAttribute("aria-selected", String(isSelected));
    });
    updateMemoryWindow(index);
    selectThreePixel(index);
  }

  function readBoundedInteger(input, maximum) {
    const value = Number(input.value);
    const valid = Number.isInteger(value) && value >= 0 && value <= maximum;
    input.setAttribute("aria-invalid", String(!valid));
    return valid ? value : null;
  }

  function updateRealCalculator() {
    const x = readBoundedInteger($("real-x"), CAMERA_WIDTH - 1);
    const y = readBoundedInteger($("real-y"), CAMERA_HEIGHT - 1);
    if (x === null || y === null) {
      $("real-index").value = "out of bounds";
      $("real-bytes").value = "—";
      $("real-equation").textContent = "choose a valid x and y";
      return;
    }
    const index = y * CAMERA_WIDTH + x;
    $("real-index").value = index.toLocaleString("en-US");
    $("real-bytes").value = (index * 2).toLocaleString("en-US");
    $("real-equation").textContent = `${y} * ${CAMERA_WIDTH} + ${x}`;
  }

  function createTileTexture(index) {
    const canvas = document.createElement("canvas");
    canvas.width = 128;
    canvas.height = 128;
    const context = canvas.getContext("2d");
    context.fillStyle = cssRgb565(pixelAt(index));
    context.fillRect(0, 0, 128, 128);
    context.strokeStyle = index === 19 ? "#f05a28" : "rgba(17, 17, 17, 0.7)";
    context.lineWidth = index === 19 ? 12 : 5;
    context.strokeRect(3, 3, 122, 122);
    context.fillStyle = "rgba(255, 255, 255, 0.88)";
    context.fillRect(25, 43, 78, 43);
    context.fillStyle = "#111";
    context.font = "700 28px monospace";
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.fillText(`[${index}]`, 64, 65);
    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    return texture;
  }

  function initializeMemoryScene() {
    const host = $("memory-scene");
    const fallback = $("memory-scene-fallback");
    let renderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: "high-performance" });
    } catch (error) {
      fallback.hidden = false;
      return;
    }

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0xffffff);
    const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 100);
    const imageCameraPosition = new THREE.Vector3(5.8, 4.5, 8.4);
    const memoryCameraPosition = new THREE.Vector3(0, 0, 24);
    camera.position.copy(imageCameraPosition);
    const orbit = new THREE.OrbitControls(camera, renderer.domElement);
    orbit.target.set(0, 0, 0);
    orbit.enableDamping = true;
    orbit.dampingFactor = 0.08;
    orbit.minDistance = 5.2;
    orbit.maxDistance = 35;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    host.prepend(renderer.domElement);

    const tiles = [];
    const tileGeometry = new THREE.PlaneGeometry(0.62, 0.62);
    const selectedOutline = new THREE.Mesh(
      new THREE.PlaneGeometry(0.66, 0.66),
      new THREE.MeshBasicMaterial({ color: 0xf05a28, side: THREE.DoubleSide }),
    );
    selectedOutline.position.z = -0.015;
    scene.add(selectedOutline);

    for (let index = 0; index < DEMO_WIDTH * DEMO_HEIGHT; index += 1) {
      const tile = new THREE.Mesh(
        tileGeometry,
        new THREE.MeshBasicMaterial({ map: createTileTexture(index), side: THREE.DoubleSide }),
      );
      tile.userData.index = index;
      tiles.push(tile);
      scene.add(tile);
    }

    function gridPosition(index) {
      const x = index % DEMO_WIDTH;
      const y = Math.floor(index / DEMO_WIDTH);
      return new THREE.Vector3((x - 3.5) * 0.7, (2 - y) * 0.7, 0);
    }

    function memoryPosition(index) {
      return new THREE.Vector3((index - 19.5) * 0.68, 0, 0);
    }

    function placeTiles(amount) {
      tiles.forEach((tile, index) => {
        tile.position.lerpVectors(gridPosition(index), memoryPosition(index), amount);
      });
      camera.position.lerpVectors(imageCameraPosition, memoryCameraPosition, amount);
      orbit.target.set(0, 0, 0);
      orbit.update();
      const selected = tiles[selectedY * DEMO_WIDTH + selectedX];
      selectedOutline.position.copy(selected.position);
      selectedOutline.position.z -= 0.015;
      $("unfold-status").value = amount < 0.05
        ? "2D image: five rows of eight pixels"
        : amount > 0.95
          ? "Linear memory: one row of 40 consecutive elements"
          : "The same pixels are moving; their index order does not change";
    }

    selectThreePixel = (index) => {
      const selected = tiles[index];
      if (!selected) return;
      selectedOutline.position.copy(selected.position);
      selectedOutline.position.z -= 0.015;
    };

    const slider = $("unfold-slider");
    slider.addEventListener("input", () => placeTiles(Number(slider.value) / 100));

    function resize() {
      const width = Math.max(1, host.clientWidth);
      const height = Math.max(1, host.clientHeight);
      renderer.setSize(width, height, false);
      camera.aspect = width / height;
      camera.updateProjectionMatrix();
    }
    new ResizeObserver(resize).observe(host);
    resize();
    placeTiles(0);

    function render() {
      orbit.update();
      renderer.render(scene, camera);
      requestAnimationFrame(render);
    }
    render();
  }

  buildGrid();
  $("demo-x").addEventListener("input", () => selectDemoPixel(Number($("demo-x").value), selectedY));
  $("demo-y").addEventListener("input", () => selectDemoPixel(selectedX, Number($("demo-y").value)));
  $("real-x").addEventListener("input", updateRealCalculator);
  $("real-y").addEventListener("input", updateRealCalculator);
  initializeMemoryScene();
  selectDemoPixel(selectedX, selectedY);
  updateRealCalculator();
  document.body.dataset.lessonReady = "true";
})();
