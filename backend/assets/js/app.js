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
 * 클립보드 복사.
 *
 * 초대·공유 링크는 토큰이 길어서 손으로 옮겨 적으면 한 글자만 틀려도 열리지 않고,
 * 어디서 틀렸는지 알 방법이 없다.
 *
 * `navigator.clipboard` 는 보안 컨텍스트(https 또는 localhost)에서만 동작한다.
 * 막힌 환경에서는 입력을 선택해 주기만 하고 — 사용자가 Ctrl+C 로 끝낼 수 있다.
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
        this.flash(trigger, "복사됨")
      } catch {
        // 클립보드가 막혔다. 선택은 해 뒀으니 그대로 복사할 수 있다.
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



// ── 테마 ──────────────────────────────────────────────────
// LiveView 에서 테마를 바꾸면 여기서 받아 즉시 적용하고 캐시를 갱신한다.
// 연필·게임은 CSS 가 번들에 없어 그때 내려받는다.
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
    // CSS 를 못 받으면 테마를 바꾸지 않는다. 반쯤 적용된 화면보다 낫다.
    link.onerror = () => root.removeAttribute("data-theme-loading");
    document.head.appendChild(link);
  } else {
    apply();
  }
});
