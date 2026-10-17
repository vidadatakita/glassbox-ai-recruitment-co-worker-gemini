// Loading overlay for a form that waits on the AI (17 Oct 2026). A form marked data-ai-overlay shows a
// full-page overlay once it is submitted: the title (the attribute's value), the steps in
// data-ai-overlay-steps (separated by "|", shown in turn) and the seconds elapsed. Display only.
//
// It never disables a button and never stops the submit (house hard rule: a disabled control is not
// serialised, so the pressed button's name and value would be lost). submit_guard.js still blocks a
// second submit; this script only shows the overlay, which stays until the next page loads.
const STEP_MS = 4000

function overlayFor(form) {
  const title = form.dataset.aiOverlay || "Gemini is working"
  const steps = (form.dataset.aiOverlaySteps || "Reading the brief|Writing|Checking the result").split("|")
  const root = document.createElement("div")
  root.className = "ai-overlay"
  root.setAttribute("role", "status")
  root.setAttribute("aria-live", "polite")
  root.innerHTML = `
    <div class="ai-overlay__card">
      <div class="ai-overlay__orb" aria-hidden="true"><span class="ai-overlay__ring"></span><span class="ai-overlay__spark">&#10022;</span></div>
      <p class="ai-overlay__eyebrow">Gemini on Google Cloud</p>
      <h2 class="ai-overlay__title"></h2>
      <ol class="ai-overlay__steps"></ol>
      <div class="ai-overlay__bar" aria-hidden="true"><span></span></div>
      <p class="ai-overlay__time"><span data-ai-seconds>0</span> s · this can take up to a minute; please keep this page open</p>
    </div>`
  root.querySelector(".ai-overlay__title").textContent = title
  const list = root.querySelector(".ai-overlay__steps")
  steps.forEach((text, i) => {
    const li = document.createElement("li")
    li.textContent = text
    if (i === 0) li.className = "is-active"
    list.appendChild(li)
  })
  return root
}

document.addEventListener("submit", (event) => {
  const form = event.target
  if (!(form instanceof HTMLFormElement) || !form.matches("[data-ai-overlay]")) return
  // Runs after submit_guard (capture phase there); a guarded second submit was already prevented.
  if (event.defaultPrevented || document.querySelector(".ai-overlay")) return
  const root = overlayFor(form)
  document.body.appendChild(root)
  requestAnimationFrame(() => root.classList.add("is-open"))
  const items = [...root.querySelectorAll(".ai-overlay__steps li")]
  const seconds = root.querySelector("[data-ai-seconds]")
  const started = Date.now()
  let step = 0
  root._timers = [
    setInterval(() => { seconds.textContent = Math.floor((Date.now() - started) / 1000) }, 1000),
    setInterval(() => {
      if (step >= items.length - 1) return
      items[step].className = "is-done"
      step += 1
      items[step].className = "is-active"
    }, STEP_MS)
  ]
})

// Back/forward cache: a restored page must not keep a stale overlay.
window.addEventListener("pageshow", () => {
  document.querySelectorAll(".ai-overlay").forEach((root) => { (root._timers || []).forEach(clearInterval); root.remove() })
})
