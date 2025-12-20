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

  // Parse disconnected players from server
  let disconnectedPlayers = [];
  try {
    disconnectedPlayers = JSON.parse(elmGameContainer.dataset.disconnectedPlayers || "[]");
  } catch (e) {
    console.error("Failed to parse disconnected players:", e);
  }

  const gameApp = Elm.Main.init({
    node: elmGameContainer,
    flags: {
      gameId: gameId,
      playerId: playerId,
      disconnectedPlayers: disconnectedPlayers
    }
  });

  // Setup Phoenix Socket for game with reconnection
  const gameSocket = new Socket("/socket", {
    reconnectAfterMs: (tries) => {
      // Exponential backoff: 1s, 2s, 4s, 8s, max 10s
      return Math.min(1000 * Math.pow(2, tries - 1), 10000);
    }
  });

  // Track connection status
  gameSocket.onOpen(() => {
    console.log("Socket connected");
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "connection_status",
        status: "connected"
      });
    }
  });

  gameSocket.onClose(() => {
    console.log("Socket disconnected");
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "connection_status",
        status: "disconnected"
      });
    }
  });

  gameSocket.onError(() => {
    console.log("Socket error");
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "connection_status",
        status: "disconnected"
      });
    }
  });

  gameSocket.connect();

  // Join the game channel
  let gameChannel = gameSocket.channel(`game:${gameId}`, {
    player_id: playerId
  });

  // Function to handle successful channel join
  function handleChannelJoin(resp) {
    console.log("Joined game channel successfully", resp);
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "initial_state",
        game_state: resp.game_state,
        connections: resp.connections || []
      });
    }
  }

  // Function to rejoin channel (used after reconnection)
  function rejoinChannel() {
    if (gameChannel.state === "joined") {
      return; // Already joined
    }

    gameChannel.join()
      .receive("ok", handleChannelJoin)
      .receive("error", resp => {
        console.error("Unable to rejoin game channel", resp);
        if (gameApp.ports.receiveFromChannel) {
          gameApp.ports.receiveFromChannel.send({
            type: "error",
            message: resp.reason || "Failed to rejoin game"
          });
        }
      });
  }

  gameChannel.join()
    .receive("ok", handleChannelJoin)
    .receive("error", resp => {
      console.error("Unable to join game channel", resp);
      if (gameApp.ports.receiveFromChannel) {
        gameApp.ports.receiveFromChannel.send({
          type: "error",
          message: resp.reason || "Failed to join game"
        });
      }
    });

  // Handle channel close - attempt to rejoin
  gameChannel.onClose(() => {
    console.log("Channel closed, will attempt to rejoin when socket reconnects");
  });

  // Handle channel errors
  gameChannel.onError(() => {
    console.log("Channel error");
  });

  // Listen for game state updates from server
  gameChannel.on("game_state_updated", (payload) => {
    console.log("Game state updated:", payload);
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "game_state_updated",
        game_state: payload.game_state,
        connections: payload.connections || []
      });
    }
  });

  // Listen for rematch ready event
  gameChannel.on("rematch_ready", (payload) => {
    console.log("Rematch ready:", payload);
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "rematch_ready",
        game_id: payload.game_id
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

      // Handle reconnect_as specially - it returns the new player state
      if (action === "reconnect_as") {
        gameChannel.push(action, payload)
          .receive("ok", (resp) => {
            console.log("Reconnect success:", resp);
            if (gameApp.ports.receiveFromChannel) {
              gameApp.ports.receiveFromChannel.send({
                type: "reconnected",
                player_id: resp.player_id,
                game_state: resp.game_state,
                connections: resp.connections || []
              });
            }
          })
          .receive("error", (msg) => {
            console.error("Reconnect error:", msg);
            if (gameApp.ports.receiveFromChannel) {
              gameApp.ports.receiveFromChannel.send({
                type: "error",
                message: msg.reason || "Failed to reconnect"
              });
            }
          });
      } else {
        // Normal action handling
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
      }
    });
  }

  // Handle navigation from Elm
  if (gameApp.ports.navigateToUrl) {
    gameApp.ports.navigateToUrl.subscribe((url) => {
      console.log("Navigating to:", url);
      window.location.href = url;
    });
  }

  // Handle browser online/offline events
  window.addEventListener("online", () => {
    console.log("Browser online - socket should auto-reconnect");
  });

  window.addEventListener("offline", () => {
    console.log("Browser offline");
    if (gameApp.ports.receiveFromChannel) {
      gameApp.ports.receiveFromChannel.send({
        type: "connection_status",
        status: "disconnected"
      });
    }
  });

  // Expose for debugging
  window.gameApp = gameApp;
  window.gameChannel = gameChannel;
  window.gameSocket = gameSocket;
}

