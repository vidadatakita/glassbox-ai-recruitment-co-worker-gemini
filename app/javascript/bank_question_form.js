// Question form of the competency bank (brief step 5): shows only what the chosen type needs (answer
// options for multiple choice, scoring anchors for a written answer) and only the brief rows of the
// chosen section. Display only: hidden fields keep their names and the server checks everything again
// (TestCases::SaveBank). Without JavaScript every field stays visible, as before.
// Bound on every Turbo page load (the staff pages navigate with Turbo Drive); a form is bound once.
const bind = () => document.querySelectorAll("form.question-bank-form:not([data-bank-form-bound])").forEach((form) => {
  form.dataset.bankFormBound = "true"
  const section = form.querySelector("select[name='bank[section]']")
  const kind = form.querySelector("select[name='bank[kind]']")
  const link = form.querySelector("select[name='bank[link_id]']")
  const options = form.querySelector(".question-bank-form__options")
  const anchors = form.querySelector(".question-bank-form__anchors")
  const sync = () => {
    const choice = kind.value === "multiple_choice"
    options.hidden = !choice
    anchors.hidden = choice
    const prefix = section.value === "technical" ? "a:" : "c:"
    link.querySelectorAll("optgroup").forEach((group) => {
      const match = group.querySelector("option")?.value.startsWith(prefix)
      group.hidden = !match
      group.disabled = !match
    })
    if (link.value && !link.value.startsWith(prefix)) link.value = ""
  }
  section.addEventListener("change", sync)
  kind.addEventListener("change", sync)
  sync()
})
document.addEventListener("turbo:load", bind)
bind()
