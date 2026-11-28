import en from "../locales/en.js";
import zhCN from "../locales/zh-CN.js";

const locales = { en, "zh-CN": zhCN };
const storageKey = "h2t-download-language";
const releaseApi = "https://api.github.com/repos/MuGdxy/Hades2Together/releases?per_page=1";
const installerName = "Hades2Together-Setup.exe";
const assetPath = "/MuGdxy/Hades2Together/releases/download/";

const copyElements = document.querySelectorAll("[data-copy]");
const languageButtons = document.querySelectorAll("[data-language]");
const releaseTitle = document.querySelector("#release-title");
const releaseDetail = document.querySelector("#release-detail");
const installerLink = document.querySelector("#installer-link");

let language = initialLanguage();
let release = { status: "loading" };

function initialLanguage() {
  try {
    const saved = localStorage.getItem(storageKey);
    if (Object.hasOwn(locales, saved)) return saved;
  } catch {
    // Storage may be disabled. Browser language detection still works.
  }

  return /^zh(?:-|$)/i.test(navigator.language) ? "zh-CN" : "en";
}

function renderLanguage() {
  const copy = locales[language];
  document.documentElement.lang = language;

  for (const element of copyElements) {
    const value = copy[element.dataset.copy];
    const attribute = element.dataset.attribute;
    if (attribute) {
      element.setAttribute(attribute, value);
    } else {
      element.textContent = value;
    }
  }

  for (const button of languageButtons) {
    button.setAttribute("aria-pressed", String(button.dataset.language === language));
  }

  renderRelease();
}

function renderRelease() {
  const copy = locales[language];
  const releaseType = copy[release.prerelease ? "prerelease" : "release"];
  const values = { tag: release.tag, releaseType };
  const format = (template) => template.replace(/\{(tag|releaseType)\}/g, (_, key) => values[key]);

  releaseTitle.textContent = format(copy[`${release.status}Title`]);
  releaseDetail.textContent = format(copy[`${release.status}Detail`]);

  if (release.url) {
    installerLink.href = release.url;
  } else {
    installerLink.removeAttribute("href");
  }
  installerLink.hidden = !release.url;
}

function findInstaller(assets) {
  for (const asset of assets) {
    if (asset?.name !== installerName || asset.state !== "uploaded") continue;

    try {
      const url = new URL(asset.browser_download_url);
      if (url.origin === "https://github.com" && url.pathname.startsWith(assetPath)
          && url.pathname.endsWith(`/${installerName}`)) {
        return url.href;
      }
    } catch {
      // Skip malformed download URLs.
    }
  }
}

async function fetchRelease() {
  try {
    const response = await fetch(releaseApi, {
      headers: { Accept: "application/vnd.github+json" },
      signal: AbortSignal.timeout(8000),
    });

    if (response.status === 429) return { status: "limited" };
    if (response.status === 403) {
      const body = await response.json().catch(() => null);
      if (response.headers.get("x-ratelimit-remaining") === "0"
          || response.headers.has("retry-after")
          || /rate limit/i.test(body?.message ?? "")) {
        return { status: "limited" };
      }
    }
    if (!response.ok) return { status: "error" };

    const releases = await response.json();
    if (!Array.isArray(releases)) return { status: "error" };
    if (!releases.length) return { status: "empty" };
    const [latest] = releases;
    if (latest?.draft !== false || !latest.tag_name) return { status: "error" };

    const url = findInstaller(latest.assets ?? []);
    return { status: url ? "ready" : "missing", tag: latest.tag_name, prerelease: latest.prerelease, url };
  } catch {
    return { status: "error" };
  }
}

for (const button of languageButtons) {
  button.addEventListener("click", () => {
    language = button.dataset.language;
    try {
      localStorage.setItem(storageKey, language);
    } catch {
      // The current page can still be translated.
    }
    renderLanguage();
  });
}

renderLanguage();
release = await fetchRelease();
renderRelease();
