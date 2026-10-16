// A note that is required only in some cases, enforced by the browser's own validation (the
// server refuses as well): the form cannot be sent and the field turns red (staff.css).
//   <textarea data-note-required-unless="usulan_ai">  required while the checked radio named
//     "label" in the same form differs from that value (Label Analisa: departing from the AI).
//   <button data-requires-note="true|false">  pressing it sets whether the form's note is
//     required (Lanjut / Rekomendasi AI / Tidak Lanjut, step 06).
function syncLabelNote(form) {
  const note = form.querySelector("textarea[data-note-required-unless]")
  if (!note) return
  const checked = form.querySelector("input[name=label]:checked")
  note.required = !!checked && checked.value !== note.dataset.noteRequiredUnless
}

document.addEventListener("change", (event) => {
  if (event.target.matches("input[name=label]") && event.target.form) syncLabelNote(event.target.form)
})

document.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-requires-note]")
  const note = button?.form?.querySelector("textarea[name=note]")
  if (note) note.required = button.dataset.requiresNote === "true"
}, true)

document.addEventListener("turbo:load", () => document.querySelectorAll("form").forEach(syncLabelNote))
document.addEventListener("DOMContentLoaded", () => document.querySelectorAll("form").forEach(syncLabelNote))

// The browser's own "Please fill out this field" follows the browser's language; say it in Indonesian.
document.addEventListener("invalid", (event) => {
  const note = event.target
  if (note.matches("textarea[name=note]") && note.validity.valueMissing) {
    note.setCustomValidity("A note is required for this choice: write the reason.")
  }
}, true)
document.addEventListener("input", (event) => {
  if (event.target.matches("textarea[name=note]")) event.target.setCustomValidity("")
})

// Salary (step 08): the note is required when the amount is outside the band or differs from the
// AI's amount on screen.
function syncSalaryNote(form) {
  const note = form.querySelector("textarea[data-band-min]")
  const amount = form.querySelector("input[name=amount]")
  if (!note || !amount) return
  const value = parseInt(amount.value.replace(/\D/g, ""), 10)
  const { salaryAi, bandMin, bandMax } = note.dataset
  const outside = bandMin && bandMax && (value < +bandMin || value > +bandMax)
  const differs = salaryAi && value !== +salaryAi
  note.required = !!(value && (outside || differs))
}
document.addEventListener("input", (event) => {
  if (event.target.matches("input[name=amount]") && event.target.form) syncSalaryNote(event.target.form)
})
document.addEventListener("turbo:load", () => document.querySelectorAll("form").forEach(syncSalaryNote))
document.addEventListener("DOMContentLoaded", () => document.querySelectorAll("form").forEach(syncSalaryNote))

// The Indonesian message above is a custom validity, which would stick until the next "input"
// event (a value filled without typing would stay "invalid"); clear it on every submit press, so the
// browser re-checks the real value and sets it again only if still empty.
document.addEventListener("click", (event) => {
  const button = event.target.closest("button[type=submit], input[type=submit]")
  button?.form?.querySelectorAll("textarea[name=note]").forEach((note) => note.setCustomValidity(""))
}, true)
