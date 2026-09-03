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
import {hooks as colocatedHooks} from "phoenix-colocated/vr"
import topbar from "../vendor/topbar"

/**
 * Clipboard copy.
 *
 * Invite/share link tokens are long: copy one by hand and a single wrong
 * character makes it fail to open, with no way to tell where the typo is.
 *
 * `navigator.clipboard` only works in a secure context (https or localhost).
 * Where it is blocked, we just select the input — the user can finish with Ctrl+C.
 */
const CopyToClipboard = {
  mounted() {
    this.handle = async (event) => {
      const trigger = event.target.closest("[data-copy-trigger]")
      if (!trigger) return

      const source = this.el.querySelector("[data-copy-source]")
      if (!source) return

      source.select()

      try {
        await navigator.clipboard.writeText(source.value)
        this.flash(trigger, "Copied")
      } catch {
        // Clipboard is blocked. The text is already selected, so it can be copied as-is.
        this.flash(trigger, "Ctrl+C")
      }
    }

    this.el.addEventListener("click", this.handle)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handle)
  },

  flash(trigger, message) {
    const original = trigger.dataset.originalLabel || trigger.textContent
    trigger.dataset.originalLabel = original
    trigger.textContent = message

    clearTimeout(this.timer)
    this.timer = setTimeout(() => { trigger.textContent = original }, 1500)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CopyToClipboard},
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



// ── Theme ─────────────────────────────────────────────────
// When the theme changes in LiveView, we receive it here, apply it immediately,
// and refresh the cache. Pencil and game themes are not in the bundle, so their
// CSS is fetched on demand.
window.addEventListener("phx:vr:theme", (event) => {
  const theme = event.detail?.theme;
  if (!theme) return;

  const root = document.documentElement;
  const LAZY = { "pencil-warm": "/themes/pencil.css", game: "/themes/game.css" };
  const href = LAZY[theme];

  const apply = () => {
    root.setAttribute("data-theme", theme);
    localStorage.setItem("vr:theme", theme);
    root.removeAttribute("data-theme-loading");
  };

  if (href && !document.querySelector(`link[data-vr-theme="${href}"]`)) {
    root.setAttribute("data-theme-loading", "true");
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    link.dataset.vrTheme = href;
    link.onload = apply;
    // If the CSS fails to load, don't switch themes. Better than a half-applied screen.
    link.onerror = () => root.removeAttribute("data-theme-loading");
    document.head.appendChild(link);
  } else {
    apply();
  }
});
