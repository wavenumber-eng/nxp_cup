(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = {
    jumper: false,
    mode: "RACE_WAITING",
    cameraLive: false,
    page: "camera",
    events: [],
  };

  const pageDetails = {
    camera: {
      file: "app/camera_test.c",
      callback: "camera_test_on_frame(frame)",
      reason: "test_mode_on_frame(frame) reads the framework-selected CAMERA / IO page and dispatches this example.",
    },
    vision: {
      file: "app/vision_test.c",
      callback: "vision_test_on_frame(frame)",
      reason: "test_mode_on_frame(frame) reads the framework-selected VISION page and dispatches the editable exercise.",
    },
    motors: {
      file: "app/motor_test.c",
      callback: "motor_test_on_frame(frame)",
      reason: "test_mode_on_frame(frame) dispatches MOTORS, but the framework still owns centered-pot arming, limits, and the lease.",
    },
  };

  function addEvent(message) {
    state.events.unshift(message);
    state.events = state.events.slice(0, 4);
  }

  function callbackForFrame() {
    if (state.mode === "TEST") return pageDetails[state.page];
    if (state.mode === "RACE_RUNNING") {
      return {
        file: "app/race_mode.c",
        callback: "race_mode_on_frame(frame)",
        reason: "RACE_RUNNING dispatches each accepted fresh frame to the competition callback, wrapped by callback timing.",
      };
    }
    if (state.mode === "SAFE_FAULT") {
      return {
        file: "nxpc_system.c",
        callback: "No student callback",
        reason: "SAFE_FAULT is latched. Motors are disabled and steering is centered.",
      };
    }
    return {
      file: "main.c",
      callback: "No student callback",
      reason: state.cameraLive
        ? "The frame can support preview and presentation, but RACE_WAITING does not call race_mode_on_frame(). Release EXE to start."
        : "Race waiting requires a live camera and an EXE release before race code can run.",
    };
  }

  function updateTrace(kind = "idle") {
    const details = callbackForFrame();
    $("trace-frame").classList.toggle("is-active", kind === "frame");
    $("trace-mode").classList.toggle("is-active", kind === "frame");
    $("trace-callback").classList.toggle("is-active", kind === "frame");
    $("trace-frame").querySelector("b").textContent = kind === "frame" ? "accepted" : "waiting";
    $("trace-mode").querySelector("b").textContent = state.mode;
    $("trace-callback").querySelector("b").textContent = details.callback;
    $("callback-file").textContent = details.file;
    $("callback-name").textContent = details.callback;
    $("callback-reason").textContent = details.reason;
  }

  function render(kind = "idle") {
    $("jumper-button").setAttribute("aria-pressed", String(state.jumper));
    $("jumper-value").textContent = state.jumper ? "INSTALLED" : "REMOVED";
    $("mode-output").textContent = state.mode;
    $("camera-output").textContent = state.cameraLive ? "LIVE / FRESH" : "NO FRAME YET";
    $("outputs-output").textContent = state.mode === "RACE_RUNNING"
      ? "ALLOWED / LEASED"
      : state.mode === "TEST" && state.page === "motors"
        ? "GATED / TEST LIMIT"
        : "SAFE / DISABLED";
    document.querySelectorAll("[data-test-page]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.testPage === state.page));
    });
    $("event-log").replaceChildren(...state.events.map((event, index) => {
      const item = document.createElement("li");
      item.innerHTML = `<span>${String(state.events.length - index).padStart(2, "0")}</span><p></p>`;
      item.querySelector("p").textContent = event;
      return item;
    }));
    updateTrace(kind);
  }

  $("jumper-button").addEventListener("click", () => {
    if (state.mode === "SAFE_FAULT") {
      addEvent("Fault is latched; reset the simulation to leave SAFE_FAULT.");
      render();
      return;
    }
    state.jumper = !state.jumper;
    state.mode = state.jumper ? "TEST" : "RACE_WAITING";
    if (state.jumper) state.page = "camera";
    addEvent(state.jumper
      ? "Jumper installed: safe-stop, enter TEST, select CAMERA / IO."
      : "Jumper removed: safe-stop and return to RACE_WAITING.");
    render();
  });

  document.querySelectorAll("[data-test-page]").forEach((button) => {
    button.addEventListener("click", () => {
      state.page = button.dataset.testPage;
      if (state.mode === "TEST") {
        addEvent(`TEST page changed to ${button.textContent.trim()}: outputs are made safe before dispatch changes.`);
      } else {
        addEvent(`${button.textContent.trim()} selected for the next TEST session; it does not change the current mode.`);
      }
      render();
    });
  });

  $("exe-button").addEventListener("click", () => {
    if (state.mode === "RACE_WAITING") {
      if (state.cameraLive) {
        state.mode = "RACE_RUNNING";
        addEvent("EXE released with a live camera: enter RACE_RUNNING at zero duty.");
      } else {
        addEvent("EXE released, but start is rejected because no live camera has been seen.");
      }
    } else if (state.mode === "RACE_RUNNING") {
      state.mode = "RACE_WAITING";
      addEvent("EXE released: safe-stop and return to RACE_WAITING.");
    } else if (state.mode === "TEST") {
      addEvent("In TEST, the framework uses controls for page navigation and deliberate MOTORS arming; race does not start.");
    } else {
      addEvent("EXE cannot leave a latched SAFE_FAULT.");
    }
    render();
  });

  $("frame-button").addEventListener("click", () => {
    if (state.mode === "SAFE_FAULT") {
      addEvent("Frame arrived, but SAFE_FAULT does not dispatch participant code.");
      render("frame");
      return;
    }
    state.cameraLive = true;
    const details = callbackForFrame();
    if (state.mode === "TEST") {
      addEvent(`Fresh frame: main calls test_mode_on_frame(frame), then ${details.callback}.`);
    } else if (state.mode === "RACE_RUNNING") {
      addEvent("Fresh frame: main times race_mode_on_frame(), then finishes and releases the frame.");
    } else {
      addEvent("Fresh frame: camera becomes live; RACE_WAITING performs no student callback.");
    }
    render("frame");
  });

  $("fault-button").addEventListener("click", () => {
    state.mode = "SAFE_FAULT";
    addEvent("Safety fault: motors disabled, steering centered, participant callbacks stopped.");
    render();
  });

  $("reset-button").addEventListener("click", () => {
    state.jumper = false;
    state.mode = "RACE_WAITING";
    state.cameraLive = false;
    state.page = "camera";
    state.events = ["Startup complete: TEST jumper is removed, so the framework enters RACE_WAITING."];
    render();
  });

  state.events = ["Startup complete: TEST jumper is removed, so the framework enters RACE_WAITING."];
  render();
  document.body.dataset.lessonReady = "true";
})();
