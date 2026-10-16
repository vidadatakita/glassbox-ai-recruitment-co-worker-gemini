// Shows the chosen file's name beside the "Choose file" button (Lamar). Display only:
// the file input itself is untouched, so what the browser submits does not change.
document.addEventListener("change", (event) => {
  const input = event.target
  if (!(input instanceof HTMLInputElement) || input.type !== "file") return
  const name = input.closest(".file-pick")?.querySelector(".file-pick__name")
  if (name) name.textContent = input.files[0]?.name || name.dataset.empty
})
