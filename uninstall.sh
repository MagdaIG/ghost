#!/usr/bin/env bash
# =============================================================================
#  Ghost — desinstalador
#  Cierra Ghost (liberando sus aserciones de energía), quita el inicio automático,
#  borra Ghost.app, el comando `ghost` y la línea de PATH que añadió install.sh.
#
#  Uso:  ./uninstall.sh [--purge]
#        --purge  borra también las preferencias (atajo, triggers, umbrales…)
#
#  No interactivo: si algo requiere sudo y no hay sudo sin contraseña, lo indica
#  con el comando exacto para ejecutarlo a mano.
# =============================================================================
set -euo pipefail

APP_NAME="Ghost"
BUNDLE_ID="dev.ghost.Ghost"
PROC_PATTERN="$APP_NAME.app/Contents/MacOS/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PATH_MARKER_BEGIN="# >>> ghost cli >>>"
PATH_MARKER_END="# <<< ghost cli <<<"
PURGE=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '3,11p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) printf 'Argumento desconocido: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
MANUAL_STEPS=()

remove_path() {
  local target="$1"
  if rm -rf "$target" 2>/dev/null && [ ! -e "$target" ] && [ ! -L "$target" ]; then
    ok "Eliminado $target"
  elif sudo -n true 2>/dev/null && sudo rm -rf "$target"; then
    ok "Eliminado $target (sudo)"
  else
    warn "No se pudo eliminar $target"
    MANUAL_STEPS+=("sudo rm -rf \"$target\"")
  fi
}

printf '\033[1;35m👻 Desinstalando Ghost\033[0m\n'

[ "$(uname -s)" = "Darwin" ] || { echo "Este script es solo para macOS." >&2; exit 10; }

APPS=()
for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  [ -d "$candidate" ] && APPS+=("$candidate")
done

# 1. Quitar inicio automático y cerrar la app. Si no está abierta, se lanza un instante
#    en segundo plano solo para que se dé de baja de Ítems de inicio y se cierre.
if [ "${#APPS[@]}" -gt 0 ] || pgrep -f "$PROC_PATTERN" >/dev/null 2>&1; then
  open -g "ghost://prepare-uninstall" >/dev/null 2>&1 || true
  sleep 1
  for _ in $(seq 1 20); do
    pgrep -f "$PROC_PATTERN" >/dev/null 2>&1 || break
    sleep 0.25
  done
  pkill -f "$PROC_PATTERN" >/dev/null 2>&1 || true
  ok "Ghost cerrado y retirado del inicio de sesión"
fi

# 2. App
if [ "${#APPS[@]}" -eq 0 ]; then
  ok "Ghost.app no estaba instalada"
else
  for app in "${APPS[@]}"; do
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    remove_path "$app"
  done
fi

# 3. CLI (solo enlaces que apuntan a Ghost.app)
for link in /usr/local/bin/ghost "$HOME/.local/bin/ghost"; do
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in
      *"$APP_NAME.app/Contents/Resources/ghost") remove_path "$link" ;;
      *) warn "$link no pertenece a Ghost; se deja intacto" ;;
    esac
  fi
done

# 4. Línea de PATH añadida por install.sh
for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
  if [ -f "$rc" ] && grep -qF "$PATH_MARKER_BEGIN" "$rc"; then
    sed -i '' "/^$PATH_MARKER_BEGIN\$/,/^$PATH_MARKER_END\$/d" "$rc"
    ok "Quitada la línea de PATH de $rc"
  fi
done

# 5. Estado y (opcional) preferencias
rm -rf "$HOME/Library/Application Support/Ghost"
ok "Eliminado el archivo de estado"
if [ "$PURGE" -eq 1 ]; then
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  ok "Preferencias eliminadas"
fi

if [ "${#MANUAL_STEPS[@]}" -gt 0 ]; then
  printf '\n\033[33mPasos pendientes (requieren contraseña de administrador):\033[0m\n'
  for cmd in "${MANUAL_STEPS[@]}"; do
    printf '  %s\n' "$cmd"
  done
  exit 1
fi

printf '\n\033[32m✔ Ghost desinstalado.\033[0m El Mac vuelve a su gestión de energía normal.\n'
