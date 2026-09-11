// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
// import {hooks as colocatedHooks} from "phoenix-colocated/oskol"  // Package doesn't exist
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    // Invite links: native share on phones, clipboard elsewhere.
    Share: {
      mounted() {
        this.el.addEventListener("click", async () => {
          const url = this.el.dataset.url;
          const label = this.el.querySelector("[data-label]");
          const original = label ? label.textContent : null;
          const flash = (text) => {
            if (!label) return;
            label.textContent = text;
            setTimeout(() => (label.textContent = original), 1500);
          };
          const mobile = window.matchMedia("(max-width: 640px)").matches;
          if (mobile && navigator.share) {
            try { await navigator.share({ url }); } catch (_) {}
            return;
          }
          try {
            await navigator.clipboard.writeText(url);
            flash("Copied!");
          } catch (_) {
            flash("Copy failed");
          }
        });
      },
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

// Drag sources (src/Drag.elm marks them with data-drag-capture): route every
// pointer event of a gesture to the element it started on, so Elm's
// pointermove/pointerup handlers keep firing after the pointer leaves it.
// Capture phase, so no handler on the way down can swallow it. This is the
// one thing Elm cannot do itself; all drag logic stays in Elm.
document.addEventListener("pointerdown", (e) => {
  const source = e.target.closest && e.target.closest("[data-drag-capture]");
  if (source && source.setPointerCapture) {
    try { source.setPointerCapture(e.pointerId); } catch (_) {}
  }
}, true);

// The Elm app: the whole front end. It owns routing (/, /:slug, /:slug/:id),
// the landing pages, and the one game client that speaks the gamekit
// protocol and picks a renderer by game slug.
//
// Everything below this line is what Elm cannot do itself: the Phoenix
// channel, and the platform's share sheet / clipboard.
import { Elm } from "../src/Main.elm";

const meta = (name) => document.querySelector(`meta[name='${name}']`)?.getAttribute("content") || null;

const app = Elm.Main.init({
  flags: {
    csrf: meta("csrf-token") || "",
    // The name this browser last played under, remembered against the
    // silent guest cookie and rendered into the page that served the app.
    guestName: meta("guest-name"),
  },
});

window.elmApp = app;

// ---- The game channel ----
//
// A page load is no longer what opens a game: the Play page asks for its
// room by port, so joining a game the client navigated to and joining one it
// was served both take the same path. A second request (a rematch, or
// another table) leaves the first channel before opening the next.
let gameSocket = null;
let gameChannel = null;

// Who this browser tab is, for the life of the tab: the seat uses it to tell
// this client coming back (a reload, a route change, a socket the phone
// brought back from sleep) from another tab taking the seat over, which is
// the only case anyone should be told about. It authenticates nothing --
// the seat token is still the only way in.
const clientId = (() => {
  const key = "oskol:client";
  try {
    const existing = sessionStorage.getItem(key);
    if (existing) return existing;
    const minted = (crypto.randomUUID && crypto.randomUUID()) || String(Math.random()).slice(2);
    sessionStorage.setItem(key, minted);
    return minted;
  } catch (_) {
    // Private modes without storage: this tab is simply anonymous, and the
    // server falls back to the socket itself.
    return null;
  }
})();

const send = (message) => app.ports.receiveFromChannel?.send(message);

app.ports.joinGameChannel?.subscribe(({ gameId, seatToken }) => {
  if (gameChannel) {
    // Unbind before leaving: leaving is asynchronous, and a channel still
    // on its way out must not keep talking to Elm on behalf of a table this
    // client has moved on from.
    gameChannel.off("update");
    gameChannel.off("error");
    gameChannel.off("rematch_ready");
    gameChannel.leave();
    gameChannel = null;
  }

  if (!gameSocket) {
    gameSocket = new Socket("/socket", { params: { client: clientId } });
    gameSocket.connect();
    gameSocket.onOpen(() => send({ type: "connection_status", status: "connected" }));
    gameSocket.onClose(() => send({ type: "connection_status", status: "disconnected" }));
  }

  const channel = gameSocket.channel(`game:${gameId}`, { token: seatToken });
  gameChannel = channel;

  channel.join()
    .receive("ok", (resp) => send({ type: "payload", payload: resp.payload }))
    .receive("error", (resp) => {
      // A room that is gone stays gone: report it instead of rejoining forever.
      send({ type: "error", message: resp.reason || "Failed to join game" });
      channel.leave();
    });

  channel.on("update", (msg) => send({ type: "payload", payload: msg.payload }));
  channel.on("error", (msg) => send({ type: "error", message: msg.message || "Action failed" }));
  channel.on("rematch_ready", (msg) => send({ type: "rematch_ready", game_id: msg.game_id }));

  window.gameChannel = channel;
});

app.ports.sendToChannel?.subscribe((data) => {
  if (!gameChannel) return;
  if (data.type === "action") {
    gameChannel.push("action", { action: { name: data.name, params: data.params } })
      .receive("error", (msg) => send({ type: "error", message: msg.reason || "Action failed" }));
  } else if (data.type === "rematch") {
    gameChannel.push("rematch", {})
      .receive("error", (msg) => send({ type: "error", message: msg.reason || "Rematch failed" }));
  }
});

// ---- Invite links: native share on phones, clipboard elsewhere ----
app.ports.shareInvite?.subscribe(async (url) => {
  const reply = (result) => app.ports.shareResult?.send(result);
  const mobile = window.matchMedia("(max-width: 640px)").matches;
  if (mobile && navigator.share) {
    try { await navigator.share({ url }); } catch (_) {}
    reply("shared");
    return;
  }
  try {
    await navigator.clipboard.writeText(url);
    reply("copied");
  } catch (_) {
    reply("failed");
  }
});
