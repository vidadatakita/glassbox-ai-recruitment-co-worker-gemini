// Sign-in page in demo mode: "Use" fills the email and password fields; the visitor still
// presses Sign in. Display help only (no submit, nothing is sent from here).
document.addEventListener("click", (event) => {
  const button = event.target.closest?.("[data-demo-email]")
  if (!button) return
  const email = document.querySelector("input[name='email_address']")
  const password = document.querySelector("input[name='password']")
  if (!email || !password) return
  email.value = button.dataset.demoEmail
  password.value = button.dataset.demoPassword
  document.querySelector("form button[type=submit]")?.focus()
})
