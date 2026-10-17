// Checkbox dropdowns of a filter (17 Oct 2026). The summary text follows the ticked boxes ("All …",
// the one value, or "N selected"), and an open dropdown closes on a click outside it or on Escape.
// Display only: the ticked boxes are what the form sends, exactly as without this script.
function refresh(box) {
  const ticked = [...box.querySelectorAll("input[type=checkbox]:checked")]
  const text = box.querySelector("[data-multi-select-text]")
  if (!text) return
  text.textContent = ticked.length === 0 ? box.dataset.allLabel
    : ticked.length === 1 ? ticked[0].closest("label").textContent.trim()
    : `${ticked.length} selected`
}

document.addEventListener("change", (event) => {
  const box = event.target.closest?.("[data-multi-select]")
  if (box) refresh(box)
})

document.addEventListener("click", (event) => {
  document.querySelectorAll("[data-multi-select][open]").forEach((box) => {
    if (!box.contains(event.target)) box.open = false
  })
})

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return
  document.querySelectorAll("[data-multi-select][open]").forEach((box) => { box.open = false; box.querySelector("summary")?.focus() })
})

// Only one dropdown open at a time.
document.addEventListener("toggle", (event) => {
  const box = event.target
  if (!(box instanceof HTMLDetailsElement) || !box.matches("[data-multi-select]") || !box.open) return
  document.querySelectorAll("[data-multi-select][open]").forEach((other) => { if (other !== box) other.open = false })
}, true)
