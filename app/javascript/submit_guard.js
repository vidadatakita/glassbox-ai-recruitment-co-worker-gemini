// Double-submit guard for forms marked data-submit-guard (house hard rule).
//
// It blocks the SECOND submit event of a form and NEVER disables a button: a disabled control
// is not serialised, so the pressed button's name and value would vanish from the request and
// the controller would match no branch (the hrkita_sai SPKL incident). Do not "improve" this by
// adding `disabled`, `data-disable-with` or `data-turbo-submits-with`.
document.addEventListener("submit", (event) => {
  const form = event.target
  if (!(form instanceof HTMLFormElement) || !form.matches("[data-submit-guard]")) return
  if (form.dataset.submitted === "true") {
    event.preventDefault()
    return
  }
  form.dataset.submitted = "true"
  // Which button sent it, for display only (staff.css: the AI button's busy state shows only when
  // the AI button was pressed, not when "Simpan" in the same form was).
  form.dataset.submitter = event.submitter?.classList.contains("ai-btn") ? "ai" : "other"
}, true)

// A page restored from the back/forward cache keeps the flag; clear it so the form works again.
window.addEventListener("pageshow", () => {
  document.querySelectorAll("form[data-submitted]").forEach((form) => delete form.dataset.submitted)
})
