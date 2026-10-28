// HelloChat website. A scripted demonstration of the app's two phrases: no microphone, audio,
// speech recognition or network. Status, hint and event strings are the app's own
// (HelloChatApp.swift MainView and GateModel.swift); timings are illustrative.
(() => {
  "use strict";

  const demo = document.getElementById("demo");
  if (demo) initDemo(demo);
  initCopy();

  function initDemo(root) {
    const byId = (id) => document.getElementById(id);
    const heard = byId("heard");
    const note = byId("heard-note");
    const meter = byId("meter");
    const bars = Array.from(meter.querySelectorAll("span"));
    const cue = byId("cue");
    const statusText = byId("voice-status");
    const hint = byId("voice-hint");
    const eventLine = byId("voice-event");
    const announcer = byId("announcer");
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

    const WAKE = "Hello Chat";
    const END = "Bye Chat";
    const STATUS = { off: "Off", opening: "Opening…", on: "On" };
    const HINT = {
      off: `Say ${WAKE} to start Voice. No need to turn it on first.`,
      opening: "Opening Voice in Codex.",
      on: `Say ${END} to end Voice.`,
    };
    // from: index of the first word inside the matched phrase.
    const SPEECH = {
      hello: { words: ["Hello", "Chat"], from: 0, kind: "wake" },
      bye: { words: ["Bye", "Chat"], from: 0, kind: "end" },
      alias: {
        words: ["Harlow", "Chat"], from: 0, kind: "alias",
        note: "Harlow Chat counts as Hello Chat while Allow small spelling differences is on.",
      },
      mention: {
        words: ["I", "said", "Hello", "Chat"], from: 2, kind: "mention",
        note: "Clear mentions of the phrase are ignored.",
      },
    };
    const WORD_MS = 190;    // words arriving from the streaming model
    const SETTLE_MS = 450;  // the app waits about this long for stable text
    const OPEN_MS = 1400;   // illustrative; real timing depends on Codex
    const END_MS = 600;
    const KEEP = 2;         // utterances kept in the bubble

    let voice = "off";
    let busy = false;
    let session = 0;
    let current = null;
    let speakTimer = 0;
    let openTimer = 0;
    let cueTimer = 0;
    let levelTimer = 0;

    // Timers die with a reset, so a stale step can never change the new state.
    function later(ms, run) {
      const owner = session;
      return window.setTimeout(() => { if (owner === session) run(); }, ms);
    }

    function setVoice(next) {
      voice = next;
      root.dataset.voice = next;
      statusText.textContent = STATUS[next];
      hint.textContent = HINT[next];
    }

    function setEvent(text) { eventLine.textContent = text; }

    function announce(text) {
      announcer.textContent = "";
      window.setTimeout(() => { announcer.textContent = text; }, 40);
    }

    function emptyState() {
      const empty = document.createElement("span");
      empty.className = "heard-empty";
      empty.textContent = "Nothing heard yet";
      return empty;
    }

    function buildUtterance(speech) {
      const line = document.createElement("span");
      line.className = "utt";
      const mark = document.createElement("mark");
      mark.className = `match match-${speech.kind}`;
      const words = speech.words.map((text, index) => {
        const word = document.createElement("span");
        word.className = "word pending";
        word.textContent = text;
        if (index === speech.from) {
          if (index > 0) line.append(" ");
          line.append(mark);
          mark.append(word);
        } else {
          const host = index > speech.from ? mark : line;
          if (index > 0) host.append(" ");
          host.append(word);
        }
        return word;
      });
      return { line, mark, words };
    }

    function trim() {
      const lines = Array.from(heard.querySelectorAll(".utt"));
      lines.slice(0, Math.max(0, lines.length - KEEP)).forEach((line) => line.remove());
      const kept = lines.slice(-KEEP);
      kept.forEach((line, index) => line.classList.toggle("old", index < kept.length - 1));
    }

    function startLevels() {
      stopLevels();
      const tick = () => {
        bars.forEach((bar) => {
          bar.style.transform = `scaleY(${(0.25 + Math.random() * 0.75).toFixed(2)})`;
        });
        levelTimer = window.setTimeout(tick, 90);
      };
      tick();
    }

    function stopLevels() {
      window.clearTimeout(levelTimer);
      levelTimer = 0;
      bars.forEach((bar) => { bar.style.transform = ""; });
    }

    // The Wake sound rises and the End sound falls; the bars trace that shape silently.
    function playCue(kind) {
      cue.textContent = kind === "wake" ? "Wake sound" : "End sound";
      cue.classList.add("show");
      meter.classList.remove("cue-wake", "cue-end");
      void meter.offsetWidth;
      meter.classList.add(`cue-${kind}`);
      window.clearTimeout(cueTimer);
      cueTimer = later(1600, () => {
        cue.classList.remove("show");
        meter.classList.remove("cue-wake", "cue-end");
      });
    }

    function speak(key) {
      const speech = SPEECH[key];
      if (!speech) return;
      if (current) settle();
      heard.querySelector(".heard-empty")?.remove();
      const built = buildUtterance(speech);
      heard.append(built.line);
      trim();
      note.textContent = "";
      current = { speech, ...built, index: 0 };
      if (reduced.matches) {
        built.words.forEach((word) => word.classList.remove("pending"));
        speakTimer = later(SETTLE_MS, settle);
        return;
      }
      startLevels();
      step();
    }

    function step() {
      const c = current;
      if (!c) return;
      if (c.index > 0) c.words[c.index - 1].classList.remove("tentative");
      if (c.index < c.words.length) {
        c.words[c.index].classList.remove("pending");
        c.words[c.index].classList.add("tentative");
        c.index += 1;
        speakTimer = later(WORD_MS, step);
      } else {
        stopLevels();
        speakTimer = later(SETTLE_MS, settle);
      }
    }

    function settle() {
      const c = current;
      if (!c) return;
      current = null;
      window.clearTimeout(speakTimer);
      stopLevels();
      c.words.forEach((word) => word.classList.remove("pending", "tentative"));
      c.mark.classList.add("is-set");
      outcome(c.speech);
    }

    function outcome(speech) {
      const said = speech.words.join(" ");
      if (speech.note) note.textContent = speech.note;
      if (speech.kind === "mention") {
        announce(`Heard ${said}. ${speech.note}`);
      } else if (speech.kind === "end") {
        end();
      } else {
        wake(said);
      }
    }

    function wake(said) {
      if (busy) {
        setEvent(`Heard ${WAKE} · finishing the current Voice action`);
        announce(`Heard ${said}. Finishing the current Voice action.`);
        return;
      }
      setEvent(`Heard ${WAKE}`);
      if (voice === "on") {
        announce(`Heard ${said}. Codex Voice is on.`);
        return;
      }
      busy = true;
      setVoice("opening");
      announce(`Heard ${said}. Opening Voice in Codex.`);
      openTimer = later(OPEN_MS, () => {
        openTimer = 0;
        busy = false;
        setVoice("on");
        playCue("wake");
        announce("Codex Voice is on.");
      });
    }

    function end() {
      playCue("end");
      if (voice === "opening") {
        window.clearTimeout(openTimer);
        openTimer = 0;
        busy = false;
        setVoice("off");
        setEvent("Voice connection cancelled");
        announce(`Heard ${END}. Voice connection cancelled.`);
        return;
      }
      if (busy) return;
      if (voice === "off") {
        setEvent(`Heard ${END} · Codex Voice is already off`);
        announce(`Heard ${END}. Codex Voice is already off.`);
        return;
      }
      busy = true;
      later(END_MS, () => {
        busy = false;
        setVoice("off");
        setEvent(`Heard ${END}`);
        announce(`Heard ${END}. Codex Voice is off.`);
      });
    }

    function reset() {
      session += 1;
      [speakTimer, openTimer, cueTimer].forEach((timer) => window.clearTimeout(timer));
      stopLevels();
      current = null;
      busy = false;
      heard.replaceChildren(emptyState());
      note.textContent = "";
      cue.classList.remove("show");
      meter.classList.remove("cue-wake", "cue-end");
      setVoice("off");
      setEvent("");
      announce("Demonstration reset.");
    }

    function press(key) {
      const button = root.querySelector(`[data-say="${key}"]`);
      if (!button) return;
      button.classList.add("pressed");
      window.setTimeout(() => button.classList.remove("pressed"), 140);
    }

    root.querySelectorAll("[data-say]").forEach((button) => {
      button.addEventListener("click", () => speak(button.dataset.say));
    });
    byId("reset").addEventListener("click", reset);

    // Single-key shortcuts only while focus is inside the demonstration.
    root.addEventListener("keydown", (event) => {
      if (event.defaultPrevented || event.repeat || event.metaKey || event.ctrlKey || event.altKey) return;
      const key = event.key.toLowerCase();
      const target = key === "h" ? "hello" : key === "b" ? "bye" : null;
      if (!target) return;
      event.preventDefault();
      press(target);
      speak(target);
    });

    setVoice("off");
  }

  function initCopy() {
    if (!navigator.clipboard || !window.isSecureContext) return;
    const status = document.getElementById("copy-status");
    document.querySelectorAll("[data-copy]").forEach((button) => {
      const source = document.getElementById(button.dataset.copy);
      if (!source) return;
      button.hidden = false;
      let timer = 0;
      button.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(`${source.textContent.trim()}\n`);
          button.textContent = "Copied";
        } catch {
          button.textContent = "Failed to copy";
        }
        if (status) status.textContent = button.textContent;
        window.clearTimeout(timer);
        timer = window.setTimeout(() => {
          button.textContent = "Copy";
          if (status) status.textContent = "";
        }, 2000);
      });
    });
  }
})();
