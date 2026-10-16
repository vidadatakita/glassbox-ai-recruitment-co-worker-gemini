// Countdown for the running technical test (D60 slice 3). DISPLAY ONLY: the server stores due_at
// and refuses an answer after due_at + grace whatever this shows. The offset between the server's
// "now" (printed on the page) and the device clock is measured once, so a phone whose clock is
// wrong still counts down to the server's due_at. Does nothing on pages without [data-due-at].
const el = document.querySelector("[data-due-at]")
if (el) {
  const due = Date.parse(el.dataset.dueAt)
  const offset = Date.parse(el.dataset.now) - Date.now()
  const text = el.querySelector("[data-countdown-text]")
  const tick = () => {
    const left = Math.max(0, Math.floor((due - (Date.now() + offset)) / 1000))
    if (left === 0) {
      text.textContent = "Time is up"
      return
    }
    // Words, not "34:37": with a colon that reads as a clock time.
    text.textContent = `${Math.floor(left / 60)} min ${left % 60} sec`
    el.classList.toggle("is-low", left <= 300)
    setTimeout(tick, 1000)
  }
  tick()
}
