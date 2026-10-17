// Saves the competency-test answers as they are typed (three-step application, 17 Oct 2026). The
// server keeps the deadline and refuses a late answer whatever this does; this only spares the
// applicant a lost answer when the tab closes. At zero on the countdown the form is sent with the
// answers given ("time up submits what is answered"). Does nothing on pages without the test form.
const form = document.querySelector("form[data-autosave-url]")
if (form && form.dataset.locked !== "true") {
  const status = form.querySelector("[data-autosave-status]")
  let timer = null
  const save = () => {
    const body = new FormData(form)
    fetch(form.dataset.autosaveUrl, { method: "POST", body, headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" } })
      .then((r) => r.json().then((data) => ({ ok: r.ok, data })))
      .then(({ ok, data }) => { if (status) status.textContent = ok ? "All answers saved." : (data.error || "Not saved; use Save answers.") })
      .catch(() => { if (status) status.textContent = "Not saved: no connection. Your answers stay on this page; use Save answers when back online." })
  }
  form.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(save, 800) })
  form.addEventListener("change", () => { clearTimeout(timer); timer = setTimeout(save, 200) })
  const clock = document.querySelector("[data-due-at]")
  if (clock) {
    const due = Date.parse(clock.dataset.dueAt)
    const offset = Date.parse(clock.dataset.now) - Date.now()
    const wait = Math.max(0, due - (Date.now() + offset))
    // requestSubmit runs the form's submit handlers (the double-submit guard) and sends the button value.
    setTimeout(() => form.requestSubmit(form.querySelector("button[type=submit]")), wait + 500)
  }
}
