# FurrOS Firefox Theme

Tema Firefox ispirato a [FurrOS](https://furros.xyz/): chrome scuro, chips con bordo ink, ombre sticker, wordmark zampa + FurrOS nella nuova scheda.

## Contenuto

- `userChrome.css` — interfaccia Firefox: barra URL ovale, tendina unita, menu e pannelli.
- `userContent.css` — nuova scheda: wordmark, sfondi FurrOS incorporati, stili del chatbot AI.
- `user.js` — preferenze necessarie (`toolkit.legacyUserProfileCustomizations.stylesheets`, tema scuro, sfondi, disattivazione shortcut/storie/widget).
- `install.sh` — installer automatico con backup dei file esistenti.

## Installazione

```bash
git clone https://github.com/TUO-USERNAME/FurrOS-firefox-theme.git
cd FurrOS-firefox-theme
chmod +x install.sh
./install.sh
```

Se hai più profili o vuoi scegliere manualmente:

```bash
./install.sh --profile /home/tuonome/.config/mozilla/firefox/xxxx.default-release
```

L'installer:

1. rileva il profilo Firefox predefinito;
2. crea la cartella `chrome` se manca;
3. salva i vecchi `userChrome.css`, `userContent.css` e `user.js` con suffisso `.bak-DATA-ORA`;
4. copia i file del tema;
5. chiede di riavviare Firefox.

## Disinstallazione

```bash
./install.sh --uninstall
```

Rimuove i tre file del tema. I backup restano nel profilo.

## Note importanti

- Il file `user.js` viene riletto a ogni avvio e **sovrascrive** le preferenze in esso contenute. Se modifichi una di quelle preferenze da `about:config`, Firefox la ripristinerà al prossimo avvio.
- La nuova scheda usa come sfondo `#150B11`. Le immagini dei tile della matita vengono tradotte in tre sfondi FurrOS incorporati dietro il wordmark.
- Il caricamento di immagini personali non viene applicato: il wordmark resta senza sfondo aggiuntivo.
- Testato su Firefox 161, Linux/Wayland. Per altre versioni potrebbero servire piccoli adattamenti.

## Release

La release `v1.0.0` contiene il sorgente del tema pronto da scaricare e installare.
