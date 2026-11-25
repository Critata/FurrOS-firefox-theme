// FurrOS theme for Firefox — preferences needed to load userChrome.css
// and to avoid white flashes / wallpapers covering the new tab page.

user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Dark theme consistent with the site
user_pref("browser.theme.content-theme", 0);
user_pref("browser.theme.toolbar-theme", 0);
user_pref("layout.css.prefers-color-scheme.content-override", 0);
user_pref("browser.display.use_system_colors", false);
user_pref("browser.display.background_color", "#150B11");
user_pref("browser.display.background_color.dark", "#150B11");
user_pref("browser.startup.blankWindow", false);

// The new tab "Customize" pencil shows wallpapers.
// The selected wallpaper is translated by userContent.css into a FurrOS
// background behind the wordmark; the page background stays #150B11.
user_pref("browser.newtabpage.activity-stream.newtabWallpapers.enabled", true);
user_pref("browser.newtabpage.activity-stream.newtabWallpapers.user.enabled", true);

// No shortcuts, stories, weather or widgets on the new tab page
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

// Background behind the FurrOS wordmark: set to true to enable (off by default)
user_pref("furr.newtab.wordmark.background", false);
