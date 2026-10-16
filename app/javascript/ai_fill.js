// "Tulis dengan AI" without a page reload: a form marked data-ai-fill, sent with its AI button,
// goes by fetch (JSON); the answer's fields fill the inputs of the same name in place (the form, or
// the surrounding [data-ai-scope] when the AI button has its own form). The skeleton shows while
// the AI writes (submit_guard sets data-submitted/data-submitter first; staff.css). Without this
// script the form submits normally and the page reloads with the result.
function scopeOf(form) { return form.closest("[data-ai-scope]") || form }

function say(scope, text, ok) {
  let line = scope.querySelector("[data-ai-message]")
  if (!line) {
    line = document.createElement("div")
    line.setAttribute("data-ai-message", "")
    line.setAttribute("role", "status")
    scope.prepend(line)
  }
  line.className = `alert ${ok ? "alert-primary" : "alert-warning"} mb-3`
  line.textContent = text
}

document.addEventListener("submit", async (event) => {
  const form = event.target
  if (!form.matches("[data-ai-fill]") || !event.submitter?.classList.contains("ai-btn")) return
  event.preventDefault()
  const scope = scopeOf(form)
  try {
    const res = await fetch(form.action, { method: "POST", body: new FormData(form, event.submitter),
                                           headers: { Accept: "application/json" } })
    const reply = await res.json()
    if (reply.ok) {
      Object.entries(reply.fields || {}).forEach(([name, value]) => {
        const field = scope.querySelector(`[name="${name}"]`)
        if (field) { field.value = value; field.dispatchEvent(new Event("input", { bubbles: true })) }
      })
    }
    say(scope, reply.message || "The AI could not write. Try again.", reply.ok)
  } catch {
    say(scope, "Koneksi terputus. Coba lagi.", false)
  } finally {
    delete form.dataset.submitted
    delete form.dataset.submitter
  }
})

// Every other AI button (brief steps, stage and salary recommendations, scoring a test with AI):
// a form marked data-ai-swap is sent by fetch, the server answers as usual (a redirect to the page
// with the AI's result), and only the page content is swapped in: no blank reload, the header,
// menu and chat stay, the scroll stays unless the result has #hasil-ai to land on. Scripts that
// set up on load hear "turbo:load" again. Anything unexpected falls back to a normal page load.
document.addEventListener("submit", async (event) => {
  const form = event.target
  if (!form.matches("[data-ai-swap]") || !event.submitter?.classList.contains("ai-btn")) return
  event.preventDefault()
  const body = new FormData(form, event.submitter)
  try {
    const res = await fetch(form.action, { method: (form.getAttribute("method") || "post").toUpperCase(), body,
                                           headers: { Accept: "text/html" } })
    const html = await res.text()
    const next = new DOMParser().parseFromString(html, "text/html")
    const from = next.querySelector(".main-content .container-fluid")
    const into = document.querySelector(".main-content .container-fluid")
    if (!res.ok || !from || !into) throw new Error("unexpected answer")
    into.replaceChildren(...from.childNodes)
    document.title = next.title
    history.replaceState(null, "", res.url)
    document.getElementById("hasil-ai")?.scrollIntoView({ block: "start" })
    document.dispatchEvent(new Event("turbo:load"))
  } catch {
    window.location.reload()
  } finally {
    delete form.dataset.submitted
    delete form.dataset.submitter
  }
})
