// A link or redirect to #some-id that points at or inside a folded <details> opens it, so returning to a
// stage card after an action (the #stage-N anchor) always shows that card (17 Oct 2026).
//
// A stepper step marked data-open-section does the same on click, then briefly highlights the section,
// so the user sees which part of the page belongs to that step. The browser's own fragment navigation
// still does the scroll and the address bar; this only opens and highlights. Display only.
function reveal(id, { scroll } = { scroll: true }) {
  const el = id && document.getElementById(id)
  if (!el) return
  const details = el.closest("details")
  if (details && !details.open) details.open = true
  if (scroll) el.scrollIntoView({ block: "start" })
  el.classList.remove("is-flash")
  void el.offsetWidth // restart the animation when the same step is clicked twice
  el.classList.add("is-flash")
}

document.addEventListener("click", (event) => {
  const link = event.target.closest?.("a[data-open-section]")
  if (!link) return
  const id = decodeURIComponent(link.getAttribute("href").slice(1))
  // Open before the browser scrolls, so the scroll lands on the opened section; the same hash clicked
  // twice fires no hashchange, so this does not wait for one.
  reveal(id, { scroll: location.hash === `#${id}` })
})

// The step links carry data-turbo="false": Turbo Drive otherwise turns the in-page link into a page
// visit, redraws the body, and the card this opened is replaced by a fresh folded one.
function openTarget() { reveal(decodeURIComponent(location.hash.slice(1))) }
window.addEventListener("hashchange", openTarget)
document.addEventListener("DOMContentLoaded", openTarget)
// A redirect back to #stage-N rendered by Turbo fires turbo:load, not DOMContentLoaded.
document.addEventListener("turbo:load", openTarget)
