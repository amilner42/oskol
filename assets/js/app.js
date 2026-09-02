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
  hooks: {},  // Empty hooks for now
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

// Elm game client. One client for every game: it speaks the gamekit protocol
// and picks a renderer by game slug.
import { Elm } from "../src/Main.elm";

const elmGameContainer = document.getElementById("elm-game-app");
if (elmGameContainer) {
  const gameId = elmGameContainer.dataset.gameId;
  const gameSlug = elmGameContainer.dataset.gameSlug;
  const playerId = elmGameContainer.dataset.playerId || null;

  const gameApp = Elm.Main.init({
    node: elmGameContainer,
    flags: { gameId, gameSlug, playerId }
  });

  const send = (message) => {
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send(message);
    }
  };

  const gameSocket = new Socket("/socket", {});
  gameSocket.connect();

  const gameChannel = gameSocket.channel(`game:${gameId}`, { player_id: playerId });

  gameChannel.join()
    .receive("ok", (resp) => send({ type: "payload", payload: resp.payload }))
    .receive("error", (resp) => send({ type: "error", message: resp.reason || "Failed to join game" }));

  gameChannel.on("update", (msg) => send({ type: "payload", payload: msg.payload }));
  gameChannel.on("error", (msg) => send({ type: "error", message: msg.message || "Action failed" }));
  gameChannel.on("rematch_ready", (msg) => send({ type: "rematch_ready", game_id: msg.game_id }));

  gameSocket.onOpen(() => send({ type: "connection_status", status: "connected" }));
  gameSocket.onClose(() => send({ type: "connection_status", status: "disconnected" }));

  if (gameApp.ports.sendToChannel) {
    gameApp.ports.sendToChannel.subscribe((data) => {
      if (data.type === "action") {
        gameChannel.push("action", { action: { name: data.name, params: data.params } })
          .receive("error", (msg) => send({ type: "error", message: msg.reason || "Action failed" }));
      } else if (data.type === "rematch") {
        gameChannel.push("rematch", {})
          .receive("error", (msg) => send({ type: "error", message: msg.reason || "Rematch failed" }));
      }
    });
  }

  if (gameApp.ports.navigateToUrl) {
    gameApp.ports.navigateToUrl.subscribe((url) => {
      window.location.href = url;
    });
  }

  window.elmApp = gameApp;
  window.gameChannel = gameChannel;
}
