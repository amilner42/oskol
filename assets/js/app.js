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

// Elm App Integration
import { Elm } from "../src/Main.elm";

// Mount Elm app if the container exists
const elmContainer = document.getElementById("elm-app");
if (elmContainer) {
  const app = Elm.Main.init({
    node: elmContainer,
    flags: {}
  });

  // Setup Phoenix Socket for Elm counter demo
  const socket = new Socket("/socket", {});
  socket.connect();

  // Join the counter channel (using "demo" as the counter ID)
  const channel = socket.channel("counter:demo", {});

  channel.join()
    .receive("ok", resp => {
      console.log("Joined counter channel successfully", resp);
      // Send initial count to Elm
      if (app.ports.receiveFromChannel) {
        app.ports.receiveFromChannel.send({
          type: "counter_updated",
          count: resp.count
        });
      }
    })
    .receive("error", resp => {
      console.error("Unable to join counter channel", resp);
    });

  // Receive counter updates from server
  channel.on("counter_updated", (payload) => {
    console.log("Counter updated:", payload);
    if (app.ports.receiveFromChannel) {
      app.ports.receiveFromChannel.send({
        type: "counter_updated",
        count: payload.count
      });
    }
  });

  // Send increment/decrement actions from Elm -> server
  if (app.ports.sendToChannel) {
    app.ports.sendToChannel.subscribe((data) => {
      console.log("Sending to channel:", data);
      const action = data.action; // "increment" or "decrement"

      channel.push(action, {})
        .receive("ok", (msg) => console.log("Action success:", msg))
        .receive("error", (msg) => console.error("Action error:", msg));
    });
  }

  // Expose for debugging
  window.elmApp = app;
  window.counterChannel = channel;
}

// Elm Game Integration
const elmGameContainer = document.getElementById("elm-game-app");
if (elmGameContainer) {
  const gameId = elmGameContainer.dataset.gameId;
  const playerId = elmGameContainer.dataset.playerId || null;

  const gameApp = Elm.Main.init({
    node: elmGameContainer,
    flags: {
      gameId: gameId,
      playerId: playerId
    }
  });

  // Setup Phoenix Socket for game
  const gameSocket = new Socket("/socket", {});
  gameSocket.connect();

  // Join the game channel
  const gameChannel = gameSocket.channel(`game:${gameId}`, {
    player_id: playerId
  });

  gameChannel.join()
    .receive("ok", resp => {
      console.log("Joined game channel successfully", resp);
      // Send initial game state to Elm
      if (gameApp.ports.receiveFromChannel) {
        gameApp.ports.receiveFromChannel.send({
          type: "initial_state",
          game_state: resp.game_state
        });
      }
    })
    .receive("error", resp => {
      console.error("Unable to join game channel", resp);
      if (gameApp.ports.receiveFromChannel) {
        gameApp.ports.receiveFromChannel.send({
          type: "error",
          message: resp.reason || "Failed to join game"
        });
      }
    });

  // Listen for game state updates from server
  gameChannel.on("game_state_updated", (payload) => {
    console.log("Game state updated:", payload);
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "game_state_updated",
        game_state: payload.game_state
      });
    }
  });

  // Send actions from Elm -> server
  if (gameApp.ports.sendToChannel) {
    gameApp.ports.sendToChannel.subscribe((data) => {
      console.log("Sending to game channel:", data);
      const action = data.action;

      // Remove 'action' from payload, send only the params
      const {action: _, ...payload} = data;

      // Send the action to the channel
      gameChannel.push(action, payload)
        .receive("ok", (msg) => console.log("Action success:", msg))
        .receive("error", (msg) => {
          console.error("Action error:", msg);
          if (gameApp.ports.receiveFromChannel) {
            gameApp.ports.receiveFromChannel.send({
              type: "error",
              message: msg.reason || "Action failed"
            });
          }
        });
    });
  }

  // Expose for debugging
  window.gameApp = gameApp;
  window.gameChannel = gameChannel;
  window.gameSocket = gameSocket;
}

