// AI interview chat: every answer is sent with fetch and the next question appears in the same page,
// like a chat. Without JavaScript the forms still post and the page reloads (progressive enhancement).
// The server decides everything (turn, time, checks, retries); this file only draws what it answers.
// All text is put in with textContent, never innerHTML.
const root = document.querySelector("[data-interview-chat]")
if (root) init(root)

function init(root) {
  const $ = (selector) => root.querySelector(selector)
  const intro = $("[data-iv-intro]")
  const chat = $("[data-iv-chat]")
  const thread = $("[data-iv-thread]")
  const composer = $("[data-iv-form]")
  const startForm = $("[data-iv-start-form]")
  const finishForm = $("[data-iv-finish-form]")
  const nextForm = $("[data-iv-next-form]")
  const retryBox = $("[data-iv-retry]")
  const meta = $("[data-iv-meta]")
  const error = $("[data-iv-error]")
  const textarea = composer.querySelector("textarea")
  const positionInput = composer.querySelector("input[name=position]")
  const max = Number(root.dataset.max)
  let busy = false

  const csrf = () => document.querySelector("meta[name=csrf-token]")?.content || ""

  async function post(url, body) {
    const response = await fetch(url, {
      method: "POST", credentials: "same-origin",
      headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrf() },
      body: JSON.stringify(body || {})
    })
    if (!(response.headers.get("content-type") || "").includes("json")) throw new Error("unexpected answer")
    return response.json()
  }

  const scrollDown = () => { thread.scrollTop = thread.scrollHeight }

  function bubble(kind, text) {
    const wrap = document.createElement("div")
    wrap.className = `iv-msg ${kind === "q" ? "iv-q" : "iv-a"}`
    const who = document.createElement("span")
    who.className = "iv-who"
    who.textContent = kind === "q" ? "Interviewer" : "You"
    const p = document.createElement("p")
    p.textContent = text
    wrap.append(who, p)
    thread.append(wrap)
    scrollDown()
    return wrap
  }

  function typing() {
    const wrap = document.createElement("div")
    wrap.className = "iv-msg iv-q iv-typing"
    wrap.setAttribute("aria-label", "The interviewer is typing")
    for (let i = 0; i < 3; i++) { const dot = document.createElement("span"); dot.className = "iv-dot"; wrap.append(dot) }
    thread.append(wrap)
    scrollDown()
    return wrap
  }

  const showError = (message) => { error.textContent = message || ""; error.hidden = !message }

  function growTextarea() {
    textarea.style.height = "auto"
    textarea.style.height = `${Math.min(textarea.scrollHeight, 160)}px`
  }

  // The AI was busy: the answer stays saved, the composer gives way to a "Try again" button.
  function waitForRetry(message) {
    composer.hidden = true
    retryBox.hidden = false
    showError("")
    if (message) retryBox.querySelector("p").textContent = message
  }

  function showQuestion(next, dueLabel) {
    thread.querySelectorAll(".iv-current").forEach((el) => el.classList.remove("iv-current"))
    bubble("q", next.question).classList.add("iv-current")
    positionInput.value = next.position
    root.querySelectorAll(".iv-seg").forEach((seg, i) => seg.classList.toggle("on", i < next.position))
    meta.replaceChildren(document.createTextNode(`Question ${next.position} of ${max}` + (dueLabel ? ` · answer before ${dueLabel}` : "")))
    retryBox.hidden = true
    composer.hidden = false
    textarea.focus({ preventScroll: true })
  }

  function done(redirect) {
    bubble("q", "Thank you. Your interview is complete.")
    composer.hidden = true
    retryBox.hidden = true
    setTimeout(() => window.location.assign(redirect), 1600)
  }

  async function run(action) {
    if (busy) return
    busy = true
    showError("")
    try { await action() } catch (_) { showError("We could not reach the server. Please try again.") } finally { busy = false }
  }

  startForm?.addEventListener("submit", (event) => {
    event.preventDefault()
    run(async () => {
      intro.hidden = true
      chat.hidden = false
      const wait = typing()
      let data
      try { data = await post(startForm.action) } catch (err) { wait.remove(); intro.hidden = false; chat.hidden = true; throw err }
      wait.remove()
      if (data.status === "finished") return done(data.redirect)
      if (data.status === "retry") { intro.hidden = false; chat.hidden = true; showError(data.message); return }
      showQuestion(data.next, data.due_label)
    })
  })

  composer.addEventListener("submit", (event) => {
    event.preventDefault()
    const text = textarea.value.trim()
    if (!text) { showError("Please type your answer first."); return }
    run(async () => {
      const mine = bubble("a", text)
      textarea.value = ""
      growTextarea()
      const wait = typing()
      let data
      try { data = await post(composer.action, { answer: text, position: positionInput.value }) }
      catch (err) { wait.remove(); mine.remove(); textarea.value = text; growTextarea(); throw err }
      wait.remove()
      if (data.status === "refused") { mine.remove(); textarea.value = text; growTextarea(); showError(data.message); return }
      if (data.status === "finished") return done(data.redirect)
      if (data.status === "retry") return waitForRetry(data.message)
      showQuestion(data.next, data.due_label)
    })
  })

  nextForm?.addEventListener("submit", (event) => {
    event.preventDefault()
    run(async () => {
      const wait = typing()
      let data
      try { data = await post(nextForm.action) } catch (err) { wait.remove(); throw err }
      wait.remove()
      if (data.status === "finished") return done(data.redirect)
      if (data.status === "retry") return waitForRetry(data.message)
      showQuestion(data.next, data.due_label)
    })
  })

  finishForm.addEventListener("submit", (event) => {
    event.preventDefault()
    run(async () => { done((await post(finishForm.action)).redirect) })
  })

  // Enter sends, Shift+Enter makes a new line (like a chat); never while an input method is composing.
  textarea.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      composer.requestSubmit()
    }
  })
  textarea.addEventListener("input", growTextarea)

  scrollDown()
}
