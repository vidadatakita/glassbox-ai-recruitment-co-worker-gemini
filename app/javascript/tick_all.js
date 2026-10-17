// "Tick all" with a live count (17 Oct 2026). Inside a form marked data-tick-scope: a checkbox marked
// data-tick-all ticks or clears every checkbox marked data-tick-item; each [data-tick-count] shows
// "N of M ticked"; each [data-tick-n] shows N (used in the button label). Display only: the ticked
// boxes are what the form sends, exactly as without this script.
function refresh(scope) {
  const items = [...scope.querySelectorAll("[data-tick-item]")]
  const n = items.filter((box) => box.checked).length
  scope.querySelectorAll("[data-tick-count]").forEach((el) => { el.textContent = `${n} of ${items.length} ticked` })
  scope.querySelectorAll("[data-tick-n]").forEach((el) => { el.textContent = n })
  scope.querySelectorAll("[data-tick-all]").forEach((all) => {
    all.checked = n === items.length && n > 0
    all.indeterminate = n > 0 && n < items.length
  })
}

document.addEventListener("change", (event) => {
  const box = event.target
  const scope = box.closest?.("[data-tick-scope]")
  if (!scope) return
  if (box.matches("[data-tick-all]")) scope.querySelectorAll("[data-tick-item]").forEach((item) => { item.checked = box.checked })
  if (box.matches("[data-tick-all], [data-tick-item]")) refresh(scope)
})

document.addEventListener("DOMContentLoaded", () => document.querySelectorAll("[data-tick-scope]").forEach(refresh))
