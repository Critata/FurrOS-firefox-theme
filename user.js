// Tema FurrOS per Firefox — preferenze necessarie al caricamento di userChrome.css
// e per evitare lampi bianchi / wallpaper che coprano la nuova scheda.

user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Tema scuro coerente con il sito
user_pref("browser.theme.content-theme", 0);
user_pref("browser.theme.toolbar-theme", 0);
user_pref("layout.css.prefers-color-scheme.content-override", 0);
user_pref("browser.display.use_system_colors", false);
user_pref("browser.display.background_color", "#150B11");
user_pref("browser.display.background_color.dark", "#150B11");
user_pref("browser.startup.blankWindow", false);

// La matita "Personalizza" della nuova scheda mostra gli sfondi.
// Il wallpaper scelto viene tradotto da userContent.css in uno sfondo FurrOS
// dietro il wordmark; lo sfondo della pagina resta sempre #150B11.
user_pref("browser.newtabpage.activity-stream.newtabWallpapers.enabled", true);
user_pref("browser.newtabpage.activity-stream.newtabWallpapers.user.enabled", true);

// Niente scorciatoie, storie, meteo e widget nella nuova scheda
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
user_pref("browser.newtabpage.activity-stream.feeds.section.highlights", false);
user_pref("browser.newtabpage.activity-stream.feeds.weatherfeed", false);
user_pref("browser.newtabpage.activity-stream.showWeather", false);
user_pref("browser.newtabpage.activity-stream.widgets.enabled", false);
user_pref("browser.newtabpage.activity-stream.widgets.system.enabled", false);
user_pref("browser.newtabpage.activity-stream.spaces.widgetsOptOut", true);
user_pref("browser.newtabpage.activity-stream.spaces.storiesOptOut", true);
user_pref("browser.newtabpage.activity-stream.spaces.activityOptOut", true);

// Sfondo dietro il wordmark FurrOS: passa a true per attivarlo (di default spento)
user_pref("furr.newtab.wordmark.background", false);
