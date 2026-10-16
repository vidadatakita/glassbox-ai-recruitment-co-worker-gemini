// "Ask AI" chat window (staff/shared/_data_chat). Questions go by fetch to /staff/ask (JSON);
// answers are built with textContent, never innerHTML, so nothing in an answer can run as markup.
// While a question is on its way a second one is not sent (a busy flag; the button is never
// disabled, house rule).
function chat() { return document.querySelector("[data-data-chat]") }

// "To the latest message" shows while the log is scrolled up from its end.
function syncToEnd(log) {
  const button = chat()?.querySelector("[data-chat-to-end]")
  if (button) button.hidden = log.scrollHeight - log.scrollTop - log.clientHeight < 60
}
document.addEventListener("scroll", (event) => {
  if (event.target.matches?.("[data-chat-log]")) syncToEnd(event.target)
}, true)

const pause = (ms) => new Promise((r) => setTimeout(r, ms))

// Text as paragraphs, and lines starting with "- " as a list; returns [element, text] pairs so the
// text can be typed in afterwards. textContent only: nothing in an answer can run as markup.
function layout(div, text) {
  const parts = []
  let list = null
  String(text).split("\n").forEach((line) => {
    const item = line.match(/^\s*[-•*]\s+(.*)/)
    if (item) {
      if (!list) { list = document.createElement("ul"); div.appendChild(list) }
      const li = document.createElement("li")
      list.appendChild(li)
      parts.push([li, item[1]])
    } else if (line.trim()) {
      list = null
      const p = document.createElement("p")
      div.appendChild(p)
      parts.push([p, line])
    }
  })
  return parts
}

function bubble(log, who, text) {
  const div = document.createElement("div")
  div.className = `data-chat__msg data-chat__msg--${who}`
  layout(div, text).forEach(([el, t]) => { el.textContent = t })
  log.appendChild(div)
  log.scrollTop = log.scrollHeight
  return div
}

function typingDots(log) {
  const div = document.createElement("div")
  div.className = "data-chat__msg data-chat__msg--bot data-chat__typing"
  div.setAttribute("aria-label", "Typing")
  div.innerHTML = "<span></span><span></span><span></span>"
  log.appendChild(div)
  log.scrollTop = log.scrollHeight
  return div
}

// The answer appears like a chat message: word by word, then the table and links. Text appearing
// is not movement, so it runs with "reduce motion" too (only the sliding animations are off there).
async function typeIn(log, div, text, typing = true) {
  const parts = layout(div, text)
  log.appendChild(div)
  if (!typing) { parts.forEach(([el, t]) => { el.textContent = t }); return }
  // Each paragraph or list item shows only when its typing starts, never as an empty line first.
  parts.forEach(([el]) => { el.hidden = true })
  for (const [el, t] of parts) {
    el.hidden = false
    const words = t.split(/(\s+)/)
    for (let i = 0; i < words.length; i += 2) {
      el.textContent += words[i] + (words[i + 1] || "")
      if (i % 6 === 0) { log.scrollTop = log.scrollHeight; await pause(28) }
    }
  }
}

// typing: false for the history after a reload (shown at once, with its table and links).
async function answer(log, reply, typing = true) {
  const div = document.createElement("div")
  div.className = `data-chat__msg data-chat__msg--${reply.status === "answered" ? "bot" : "warn"}`
  await typeIn(log, div, reply.answer, typing)
  // A list answer as a table built by the server: { columns, rows: [{ cells, path }] }; the first
  // cell links to the row's page.
  if (reply.table?.rows?.length) {
    const table = document.createElement("table")
    table.className = "data-chat__table data-chat__appear"
    const head = table.createTHead().insertRow()
    reply.table.columns.forEach((h) => { const th = document.createElement("th"); th.textContent = h; head.appendChild(th) })
    const body = table.createTBody()
    reply.table.rows.forEach(({ cells, path }) => {
      const tr = body.insertRow()
      cells.forEach((value, i) => {
        const td = tr.insertCell()
        if (i === 0 && path) {
          const a = document.createElement("a")
          a.href = path
          a.textContent = value
          td.appendChild(a)
        } else td.textContent = value
      })
    })
    div.appendChild(table)
  }
  if (reply.links?.length) {
    const links = document.createElement("div")
    links.className = "data-chat__links data-chat__appear"
    reply.links.forEach(({ label, path }) => {
      const a = document.createElement("a")
      a.href = path
      a.textContent = label
      links.appendChild(a)
    })
    div.appendChild(links)
  }
  // The AI's offers as buttons, like the starter questions: a click asks that question.
  if (reply.choices?.length) {
    const chips = document.createElement("div")
    chips.className = "data-chat__chips data-chat__appear"
    reply.choices.forEach((q) => {
      const b = document.createElement("button")
      b.type = "button"
      b.className = "data-chat__chip"
      b.setAttribute("data-chat-example", "")
      b.textContent = q
      chips.appendChild(b)
    })
    div.appendChild(chips)
  }
  // Land on the start of the answer, so its summary is read before a long table.
  log.scrollTop = Math.max(0, div.offsetTop - log.offsetTop - 8)
  syncToEnd(log)
}

async function loadHistory(root) {
  if (root.dataset.loaded) return
  root.dataset.loaded = "true"
  const log = root.querySelector("[data-chat-log]")
  const res = await fetch(root.dataset.url, { headers: { Accept: "application/json" } })
  if (!res.ok) return
  const history = await res.json()
  for (const q of history) {
    bubble(log, "me", q.question)
    await answer(log, q, false)
  }
  log.scrollTop = log.scrollHeight
}

async function ask(root, question) {
  const log = root.querySelector("[data-chat-log]")
  if (root.dataset.busy === "true" || !question.trim()) return
  root.dataset.busy = "true"
  bubble(log, "me", question)
  const waiting = typingDots(log)
  try {
    const res = await fetch(root.dataset.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json",
                 "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content },
      body: JSON.stringify({ question })
    })
    const reply = await res.json()
    waiting.remove()
    await answer(log, reply)
  } catch {
    waiting.remove()
    bubble(log, "warn", "Connection lost. Try again.")
  } finally {
    delete root.dataset.busy
  }
}

function toggle(root, open) {
  const panel = root.querySelector(".data-chat__panel")
  const button = root.querySelector(".data-chat__fab")
  panel.hidden = !open
  button.setAttribute("aria-expanded", String(open))
  if (open) { loadHistory(root); root.querySelector("textarea").focus() }
}

document.addEventListener("click", (event) => {
  const root = chat()
  if (!root) return
  if (event.target.closest("[data-chat-toggle]")) toggle(root, root.querySelector(".data-chat__panel").hidden)
  if (event.target.closest("[data-chat-close]")) toggle(root, false)
  if (event.target.closest("[data-chat-to-end]")) {
    const log = root.querySelector("[data-chat-log]")
    log.scrollTo({ top: log.scrollHeight, behavior: "smooth" })
  }
  const example = event.target.closest("[data-chat-example]")
  if (example) ask(root, example.textContent)
})

document.addEventListener("submit", (event) => {
  if (!event.target.matches("[data-chat-form]")) return
  event.preventDefault()
  const textarea = event.target.querySelector("textarea")
  ask(chat(), textarea.value)
  textarea.value = ""
  fit(textarea)
})

// The question box grows with its text (CSS field-sizing); where a browser lacks that, its height
// follows the text here, up to the CSS max-height.
function fit(textarea) {
  if (CSS.supports("field-sizing", "content")) return
  textarea.style.height = "auto"
  textarea.style.height = `${textarea.scrollHeight + 2}px`
}
document.addEventListener("input", (event) => {
  if (event.target.matches("[data-chat-form] textarea")) fit(event.target)
})

// A link to /staff/ask lands on a staff page with #tanya-data: open the window there once, then
// drop the hash, so a reload shows the page with the window closed (its default).
function openFromHash() {
  const root = chat()
  if (!root || location.hash !== "#tanya-data") return
  history.replaceState(null, "", location.pathname + location.search)
  toggle(root, true)
}
document.addEventListener("turbo:load", openFromHash)
document.addEventListener("DOMContentLoaded", openFromHash)

document.addEventListener("keydown", (event) => {
  const root = chat()
  if (!root) return
  if (event.key === "Escape" && !root.querySelector(".data-chat__panel").hidden) toggle(root, false)
  if (event.key === "Enter" && !event.shiftKey && event.target.matches("[data-chat-form] textarea")) {
    event.preventDefault()
    event.target.form.requestSubmit()
  }
})
