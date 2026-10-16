// Running totals on the job-brief wizard (feature 03): activity shares, "sebaiknya" weights and
// stage weights, each against its target of 100%. Display only: the server recomputes every total
// (Briefs::BriefCheck), so a page without JavaScript shows the saved total and still works.
// Never touches a submit button (house hard rule: no disabling).
function refresh(group) {
  const output = document.querySelector(`[data-sum-output="${group}"]`)
  if (!output) return
  let total = 0
  document.querySelectorAll(`[data-sum="${group}"]`).forEach((input) => {
    const value = input.value.trim()
    if (/^\d+$/.test(value)) total += parseInt(value, 10)
  })
  output.querySelector("strong").textContent = `${total}%`
  output.classList.toggle("job-brief-total--ok", total === 100)
  output.classList.toggle("job-brief-total--off", total !== 100)
}

document.addEventListener("input", (event) => {
  const group = event.target?.dataset?.sum
  if (group) refresh(group)
})
