# Seguridad

## Qué hace Ghost en tu Mac

- **Sin red:** la app no abre conexiones, no tiene telemetría ni actualizaciones automáticas.
- **Sin permisos especiales:** no pide Accesibilidad, Monitorización de entrada, Grabación
  de pantalla ni ningún otro permiso de privacidad. El atajo global usa la API
  `RegisterEventHotKey`, que no puede leer otras teclas.
- **Sin privilegios de administrador por defecto:** se ejecuta como tu usuario. Usa
  `/usr/bin/pmset displaysleepnow` y `/usr/bin/caffeinate -u`, que no requieren `sudo`.
- **Modo tapa cerrada (opcional):** solo si lo activas, macOS te pide la contraseña una
  vez y Ghost instala `/etc/sudoers.d/ghost` (root:wheel, 0440, validado con `visudo -c`).
  La regla permite a tu usuario ejecutar sin contraseña **solo** `/usr/bin/pmset -a
  disablesleep 1` y `/usr/bin/pmset -a disablesleep 0`. Ghost lo desactiva al salir, al
  terminar la sesión y por batería baja, y lo restaura al arrancar si quedó activo.
  `./uninstall.sh` quita la regla (puede pedir `sudo rm -rf /etc/sudoers.d/ghost`).
  Mientras está activo, el Mac no se duerme ni con la tapa cerrada: no lo guardes en una
  mochila o funda.
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
