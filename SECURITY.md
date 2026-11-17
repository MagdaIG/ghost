# Seguridad

## Qué hace Ghost en tu Mac

- **Sin red:** la app no abre conexiones, no tiene telemetría ni actualizaciones automáticas.
- **Sin permisos especiales:** no pide Accesibilidad, Monitorización de entrada, Grabación
  de pantalla ni ningún otro permiso de privacidad. El atajo global usa la API
  `RegisterEventHotKey`, que no puede leer otras teclas.
- **Sin privilegios de administrador:** se ejecuta como tu usuario. Solo usa
  `/usr/bin/pmset displaysleepnow` y `/usr/bin/caffeinate -u`, que no requieren `sudo`.
- **Energía reversible:** crea una aserción `PreventUserIdleSystemSleep`, que macOS libera
  automáticamente si Ghost se cierra o falla.
- **Datos locales:** preferencias en `~/Library/Preferences/dev.ghost.Ghost.plist` y un
  archivo de estado en `~/Library/Application Support/Ghost/status` (lo lee el comando `ghost`).

## Instalación

`install.sh` compila desde el código fuente con las herramientas de Apple y firma la app
de forma **ad-hoc** (local, sin cuenta de desarrollador). No descarga binarios ni scripts
de terceros, no usa `curl | bash` y no pide contraseña. Revisa el script antes de
ejecutarlo si lo deseas: es corto y está comentado.

## Reportar una vulnerabilidad

Abre un aviso privado en
[GitHub Security Advisories](https://github.com/MagdaIG/ghost/security/advisories/new)
en lugar de un issue público.
