// Remembers the language picked in the menu and closes the menu on outside clicks.
document.addEventListener("click", function (event) {
  var link = event.target.closest("[data-lang]");
  if (link) {
    try { localStorage.setItem("vime.lang", link.getAttribute("data-lang")); } catch (error) {}
  }
  document.querySelectorAll("details.language[open]").forEach(function (menu) {
    if (!menu.contains(event.target)) menu.removeAttribute("open");
  });
});

document.addEventListener("keydown", function (event) {
  if (event.key !== "Escape") return;
  document.querySelectorAll("details.language[open]").forEach(function (menu) {
    menu.removeAttribute("open");
    menu.querySelector("summary").focus();
  });
});
