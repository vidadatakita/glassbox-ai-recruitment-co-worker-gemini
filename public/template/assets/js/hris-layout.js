/*
 * Fixed presentation settings for HRIS.
 *
 * Zynix stores the demo switcher's choices in localStorage. This application
 * intentionally has one approved presentation: light mode, a white horizontal
 * menu, and the HRIS blue primary colour. Remove demo preferences before the
 * theme boots so a previous visitor cannot change the application shell.
 */
(function () {
  "use strict";

  var settingKeys = [
    "zynixdarktheme",
    "zynixrtl",
    "zynixlayout",
    "zynixverticalstyles",
    "zynixnavstyles",
    "zynixMenu",
    "zynixHeader",
    "zynixboxed",
    "zynixdefaultwidth",
    "zynixfullwidth",
    "zynixregular",
    "zynixclassic",
    "zynixmodern",
    "zynixheaderfixed",
    "zynixheaderscrollable",
    "zynixmenufixed",
    "zynixmenuscrollable",
    "primaryRGB",
    "bodyBgRGB",
    "bodylightRGB",
    "bgimg"
  ];

  function lockTheme() {
    var html = document.documentElement;
    var i;

    try {
      for (i = 0; i < settingKeys.length; i += 1) {
        localStorage.removeItem(settingKeys[i]);
      }
    } catch (error) {
      // Browsers can block storage in private or embedded contexts. The
      // attributes below still provide the correct visual default.
    }

    html.setAttribute("lang", "en");
    html.setAttribute("dir", "ltr");
    html.setAttribute("data-nav-layout", "horizontal");
    html.setAttribute("data-nav-style", "menu-click");
    html.setAttribute("data-theme-mode", "light");
    html.setAttribute("data-header-styles", "light");
    html.setAttribute("data-menu-styles", "light");
    html.setAttribute("data-width", "fullwidth");
    // Zynix uses this attribute to keep the horizontal menu closed behind the
    // mobile menu button. Desktop dropdown menus must not have it, though.
    if (window.innerWidth < 992) {
      html.setAttribute("data-toggled", "close");
    } else {
      html.removeAttribute("data-toggled");
    }
    html.removeAttribute("data-vertical-style");
    html.removeAttribute("data-page-style");
    html.removeAttribute("data-bg-img");
    html.style.removeProperty("--body-bg-rgb");
    html.style.removeProperty("--body-bg-rgb2");
    html.style.removeProperty("--light-rgb");
    html.style.removeProperty("--form-control-bg");
    html.style.removeProperty("--input-border");
    html.style.setProperty("--primary-rgb", "37, 99, 235");
  }

  function setYear() {
    var year = document.getElementById("year");
    if (year) {
      year.textContent = new Date().getFullYear();
    }
  }

  function initialiseBootstrapComponents() {
    var selector;
    var elements;
    var i;

    if (!window.bootstrap) {
      return;
    }

    selector = '[data-bs-toggle="tooltip"]';
    elements = document.querySelectorAll(selector);
    for (i = 0; i < elements.length; i += 1) {
      if (!window.bootstrap.Tooltip.getInstance(elements[i])) {
        new window.bootstrap.Tooltip(elements[i]);
      }
    }
  }

  function normaliseText(value) {
    return (value || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "");
  }

  function menuLinkIsUsable(link) {
    var href = link.getAttribute("href");
    return href && href.indexOf("javascript:") !== 0 && href !== "#";
  }

  function initialiseNavigationDirectory() {
    var groups = document.getElementById("application-navigation-groups");
    var search = document.getElementById("application-navigation-search");
    var empty = document.getElementById("application-navigation-empty");
    var modal = document.getElementById("application-navigation");
    var menu = document.querySelector(".app-sidebar .main-menu");
    var groupItems;
    var index;

    if (!groups || !search || !empty || !modal || !menu) {
      return;
    }

    groups.innerHTML = "";
    for (index = 0; index < menu.children.length; index += 1) {
      var slide = menu.children[index];
      var childIndex;
      var topLink = null;
      var topLabel = "";
      var iconClass = "ri-layout-grid-line";
      var seen = {};
      var links = [];
      var group;
      var title;
      var linkList;
      var menuLinks;
      var linkIndex;

      if (!slide.classList.contains("slide")) {
        continue;
      }

      for (childIndex = 0; childIndex < slide.children.length; childIndex += 1) {
        if (slide.children[childIndex].tagName === "A") {
          topLink = slide.children[childIndex];
          break;
        }
      }

      if (!topLink) {
        continue;
      }

      topLabel = normaliseText(topLink.textContent);
      if (!topLabel) {
        continue;
      }

      if (topLink.querySelector(".side-menu__icon")) {
        iconClass = topLink.querySelector(".side-menu__icon").className;
      }

      menuLinks = slide.querySelectorAll("a.side-menu__item[href]");
      for (linkIndex = 0; linkIndex < menuLinks.length; linkIndex += 1) {
        var menuLink = menuLinks[linkIndex];
        var label;
        var key;

        if (!menuLinkIsUsable(menuLink)) {
          continue;
        }

        label = normaliseText(menuLink.textContent);
        key = menuLink.href + "|" + label;
        if (!label || seen[key]) {
          continue;
        }

        seen[key] = true;
        links.push({ href: menuLink.href, label: label });
      }

      if (!links.length) {
        continue;
      }

      group = document.createElement("section");
      group.className = "application-navigation-group";
      group.setAttribute("data-navigation-group", "");

      title = document.createElement("h3");
      title.className = "application-navigation-group__title";
      title.innerHTML = '<i class="' + iconClass + '" aria-hidden="true"></i><span></span>';
      title.querySelector("span").textContent = topLabel;
      group.appendChild(title);

      linkList = document.createElement("div");
      linkList.className = "application-navigation-links";
      for (linkIndex = 0; linkIndex < links.length; linkIndex += 1) {
        var directoryLink = document.createElement("a");
        directoryLink.className = "application-navigation-link";
        directoryLink.href = links[linkIndex].href;
        directoryLink.textContent = links[linkIndex].label;
        directoryLink.title = links[linkIndex].label;
        directoryLink.setAttribute("data-navigation-link", "");
        linkList.appendChild(directoryLink);
      }
      group.appendChild(linkList);
      groups.appendChild(group);
    }

    function filterDirectory() {
      var term = normaliseText(search.value).toLowerCase();
      var visibleGroups = 0;
      var groupIndex;

      groupItems = groups.querySelectorAll("[data-navigation-group]");
      for (groupIndex = 0; groupIndex < groupItems.length; groupIndex += 1) {
        var directoryLinks = groupItems[groupIndex].querySelectorAll("[data-navigation-link]");
        var groupTitle = normaliseText(groupItems[groupIndex].querySelector("h3").textContent).toLowerCase();
        var visibleLinks = 0;
        var directoryIndex;

        for (directoryIndex = 0; directoryIndex < directoryLinks.length; directoryIndex += 1) {
          var matches = !term || groupTitle.indexOf(term) !== -1 || normaliseText(directoryLinks[directoryIndex].textContent).toLowerCase().indexOf(term) !== -1;
          directoryLinks[directoryIndex].classList.toggle("d-none", !matches);
          if (matches) {
            visibleLinks += 1;
          }
        }

        groupItems[groupIndex].classList.toggle("d-none", visibleLinks === 0);
        if (visibleLinks) {
          visibleGroups += 1;
        }
      }
      empty.classList.toggle("d-none", visibleGroups !== 0);
    }

    if (!search.getAttribute("data-navigation-bound")) {
      search.setAttribute("data-navigation-bound", "true");
      search.addEventListener("input", filterDirectory);
      modal.addEventListener("shown.bs.modal", function () {
        search.focus();
      });
      modal.addEventListener("hidden.bs.modal", function () {
        search.value = "";
        filterDirectory();
      });
    }

    filterDirectory();
  }

  function initialiseHorizontalForms() {
    var forms = document.querySelectorAll("form");
    var index;

    for (index = 0; index < forms.length; index += 1) {
      var form = forms[index];
      var hasDirectFormLabels = form.querySelector(".form-group > label");

      if (!hasDirectFormLabels || form.classList.contains("auth-form") || form.classList.contains("row") || form.closest(".form-horizontal")) {
        continue;
      }

      form.classList.add("hris-horizontal-form");
    }
  }

  function initialiseActionButtons() {
    var buttons = document.querySelectorAll(".btn, form button, form input[type='submit'], form input[type='button']");
    var semanticButtonClasses = [
      "btn-primary", "btn-secondary", "btn-success", "btn-danger",
      "btn-warning", "btn-info", "btn-light", "btn-dark", "btn-default",
      "btn-theme", "btn-primary-light"
    ];
    var index;

    for (index = 0; index < buttons.length; index += 1) {
      var button = buttons[index];

      if (button.classList.contains("btn-close") || button.classList.contains("btn-box-tool") || button.classList.contains("btn-app")) {
        continue;
      }

      var hasSemanticStyle = semanticButtonClasses.some(function (className) {
        return button.classList.contains(className);
      });

      button.classList.add("btn", "me-2");
      button.classList.add("btn-wave", "waves-effect", "waves-light");

      if (!hasSemanticStyle) {
        button.classList.add("btn-primary-light");
      }
    }
  }

  function initialiseZynixForms() {
    var forms = document.querySelectorAll("form");
    var index;

    for (index = 0; index < forms.length; index += 1) {
      var form = forms[index];
      var hasFields = form.querySelector(".form-control, select, textarea, input:not([type='hidden'])");
      var hasAction = form.querySelector("button[type='submit'], input[type='submit']");

      if (!hasFields || !hasAction || form.classList.contains("auth-form") || form.classList.contains("zynix-form-opt-out")) {
        continue;
      }

      form.classList.add("zynix-system-form");

      var shell = form.closest(".box, .form-panel, .card");
      if (shell) {
        shell.classList.add("zynix-form-shell");
      }

      var actionContainers = form.querySelectorAll(".box-footer, .actions");
      var actionIndex;
      for (actionIndex = 0; actionIndex < actionContainers.length; actionIndex += 1) {
        actionContainers[actionIndex].classList.add("zynix-form-actions");
      }

      var hints = form.querySelectorAll(".form-group i:not(.fa), .form-group small, .help-block");
      var hintIndex;
      for (hintIndex = 0; hintIndex < hints.length; hintIndex += 1) {
        hints[hintIndex].classList.add("zynix-field-hint");
      }

      var headings = form.querySelectorAll("h3, h4");
      var headingIndex;
      for (headingIndex = 0; headingIndex < headings.length; headingIndex += 1) {
        if (!headings[headingIndex].closest(".modal, .salary-schema-card, .hris-form-card")) {
          headings[headingIndex].classList.add("zynix-form-section-title");
        }
      }

      var checkboxes = form.querySelectorAll(".form-group input[type='checkbox']");
      var checkboxIndex;
      for (checkboxIndex = 0; checkboxIndex < checkboxes.length; checkboxIndex += 1) {
        var checkbox = checkboxes[checkboxIndex];
        var checkboxName = checkbox.getAttribute("name") || "";

        if (!checkbox.closest("table") && checkboxName.slice(-2) !== "[]" && !checkbox.classList.contains("salary-switch-input") && !checkbox.classList.contains("hris-switch-input") && !checkbox.classList.contains("standard-checkbox")) {
          checkbox.classList.add("zynix-toggle-input");
        }
      }

      var errorBox = form.querySelector("#error_explanation");
      if (errorBox) {
        errorBox.classList.add("zynix-form-errors");
        errorBox.setAttribute("role", "alert");
      }
    }
  }

  function initialiseDynamicLayoutObserver() {
    var refreshPending = false;

    if (!window.MutationObserver || !document.body || document.body.getAttribute("data-hris-layout-observer")) {
      return;
    }

    document.body.setAttribute("data-hris-layout-observer", "true");
    new MutationObserver(function (mutations) {
      var hasAddedElement = false;
      var mutationIndex;
      var nodeIndex;

      for (mutationIndex = 0; mutationIndex < mutations.length && !hasAddedElement; mutationIndex += 1) {
        for (nodeIndex = 0; nodeIndex < mutations[mutationIndex].addedNodes.length; nodeIndex += 1) {
          if (mutations[mutationIndex].addedNodes[nodeIndex].nodeType === 1) {
            hasAddedElement = true;
            break;
          }
        }
      }

      if (!hasAddedElement || refreshPending) {
        return;
      }

      refreshPending = true;
      window.setTimeout(function () {
        refreshPending = false;
        initialiseHorizontalForms();
        initialiseActionButtons();
        initialiseZynixForms();
      }, 0);
    }).observe(document.body, { childList: true, subtree: true });
  }

  window.openFullscreen = function () {
    var element = document.documentElement;
    var openIcon = document.querySelector(".full-screen-open");
    var closeIcon = document.querySelector(".full-screen-close");

    if (!document.fullscreenElement) {
      if (element.requestFullscreen) {
        element.requestFullscreen();
      }
      if (openIcon) { openIcon.classList.add("d-none"); }
      if (closeIcon) { closeIcon.classList.remove("d-none"); }
    } else {
      if (document.exitFullscreen) {
        document.exitFullscreen();
      }
      if (openIcon) { openIcon.classList.remove("d-none"); }
      if (closeIcon) { closeIcon.classList.add("d-none"); }
    }
  };

  lockTheme();

  document.addEventListener("DOMContentLoaded", function () {
    lockTheme();
    setYear();
    initialiseBootstrapComponents();
    initialiseNavigationDirectory();
    initialiseHorizontalForms();
    initialiseActionButtons();
    initialiseZynixForms();
    initialiseDynamicLayoutObserver();
  });

  // GlassBox vendor edit (docs/decisions/0002): this app runs Turbo (Rails 8), whose
  // navigation event is "turbo:load"; padma's copy listens only for "turbolinks:load", so
  // without this line the decoration stops after the first in-app link click.
  document.addEventListener("turbo:load", function () {
    lockTheme();
    setYear();
    initialiseBootstrapComponents();
    initialiseNavigationDirectory();
    initialiseHorizontalForms();
    initialiseActionButtons();
    initialiseZynixForms();
    initialiseDynamicLayoutObserver();
  });

  document.addEventListener("turbolinks:load", function () {
    lockTheme();
    setYear();
    initialiseBootstrapComponents();
    initialiseNavigationDirectory();
    initialiseHorizontalForms();
    initialiseActionButtons();
    initialiseZynixForms();
    initialiseDynamicLayoutObserver();
  });

  window.addEventListener("load", function () {
    var loader = document.getElementById("loader");
    if (loader) {
      loader.classList.add("d-none");
    }
  });
}());
