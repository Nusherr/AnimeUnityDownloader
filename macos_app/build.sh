#!/bin/zsh
# Ricompila l'app nativa dentro il bundle in /Applications e la rifirma.
# La firma ad-hoc del bundle completo è NECESSARIA: senza, macOS rifiuta
# le notifiche dell'app (UNErrorDomain Code=1).
cd "$(dirname "$0")"
swiftc -O -o "/Applications/AnimeUnity Downloader.app/Contents/MacOS/launcher" main.swift || exit 1
codesign --force --deep -s - "/Applications/AnimeUnity Downloader.app"
echo "Fatto: /Applications/AnimeUnity Downloader.app aggiornata e firmata."
