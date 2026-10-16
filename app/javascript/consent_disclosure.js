// "Full details" disclosure on Lamar (D39). Progressive enhancement: the server renders the
// details expanded and the button hidden, so without JavaScript nothing is collapsed. With it,
// the details are collapsed VISUALLY (class consent-details--collapsed clips them) and stay in the
// accessibility tree, so a screen reader reads the full text. Never aria-hidden, never disabled.
document.addEventListener("DOMContentLoaded", () => {
  const toggle = document.querySelector("[data-consent-toggle]")
  const details = document.querySelector("[data-consent-details]")
  if (!toggle || !details) return
  const set = (open) => {
    details.classList.toggle("consent-details--collapsed", !open)
    toggle.setAttribute("aria-expanded", String(open))
    toggle.textContent = open ? "Hide details" : "Full details"
  }
  toggle.hidden = false
  set(false)
  toggle.addEventListener("click", () => set(toggle.getAttribute("aria-expanded") !== "true"))
})
