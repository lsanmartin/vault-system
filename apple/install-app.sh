#!/bin/bash
echo "Esperando a que termine el build..."
while pgrep xcodebuild > /dev/null; do sleep 2; done
echo "Buscando VaultSystem.app en DerivedData..."
APP_PATH=$(find /Users/lsanmartin/Library/Developer/Xcode/DerivedData/VaultSystem-*/Build/Products/Release -name "VaultSystem.app" -type d | head -n 1)
if [ -n "$APP_PATH" ]; then
    echo "Copiando $APP_PATH a /Applications/"
    rm -rf /Applications/VaultSystem.app
    cp -R "$APP_PATH" /Applications/VaultSystem.app
    echo "¡Instalación completada!"
else
    echo "Error: No se encontró VaultSystem.app"
fi
