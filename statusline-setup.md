# Replicar configuracion de Claude Code

Pasos para que otro Claude Code quede igual: statusline (path | git branch | modelo | % contexto | limites 5h/7d con barra y countdown reset) mas resto de settings.json.

## 1. Crear script

Guardar como `~/.claude/statusline-command.sh` (en Windows: `C:\Users\<usuario>\.claude\statusline-command.sh`):

```bash
#!/usr/bin/env bash
# Claude Code status line: full directory | git branch | model | context % | 5h/7d limits (progress bar, with reset countdown)
input=$(cat)

if command -v jq >/dev/null 2>&1; then
  cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
  model=$(echo "$input" | jq -r '.model.display_name // empty')
  used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
  five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
  five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
  week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
else
  # Fallback without jq (best effort). Flatten to one line first.
  flat=$(echo "$input" | tr -d '\r\n')
  cwd=$(echo "$flat" | sed -n 's/.*"current_dir" *: *"\([^"]*\)".*/\1/p' | head -n1 | sed 's/\\\\/\//g')
  model=$(echo "$flat" | sed -n 's/.*"display_name" *: *"\([^"]*\)".*/\1/p' | head -n1)
  # Value of a field inside a given top-level-ish block (empty if null/absent).
  # $1 = block key (context_window, five_hour, seven_day), $2 = field name
  # Handles both quoted (ISO string) and bare numeric (epoch seconds) values.
  _field() {
    local block val
    block=$(echo "$flat" | grep -o "\"$1\" *: *{[^}]*}" | head -n1)
    val=$(echo "$block" | sed -n "s/.*\"$2\" *: *\"\([^\"]*\)\".*/\1/p" | head -n1)
    if [ -z "$val" ]; then
      val=$(echo "$block" | sed -n "s/.*\"$2\" *: *\([0-9][0-9.]*\).*/\1/p" | head -n1)
    fi
    echo "$val"
  }
  # Strip the (flat) rate-limit objects so the only used_percentage left is the context one
  used=$(echo "$flat" \
    | sed 's/"five_hour" *: *{[^}]*}//g; s/"seven_day" *: *{[^}]*}//g; s/"spend_limit" *: *{[^}]*}//g' \
    | grep -o '"used_percentage" *: *[0-9][0-9.]*' | head -n1 | sed 's/.*: *//')
  five=$(_field five_hour used_percentage)
  five_reset=$(_field five_hour resets_at)
  week=$(_field seven_day used_percentage)
  week_reset=$(_field seven_day resets_at)
fi

# Normalize Windows path (C:\a\b -> C:/a/b) and show the full path
cwd=${cwd//\\//}
[ -z "$cwd" ] && cwd=$(pwd)

# Git branch (skip optional locks)
branch=""
if [ -d "$cwd" ]; then
  branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null \
    || GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# Colors (dimmed by the terminal, so keep them simple)
CYAN='\033[36m'; GREEN='\033[32m'; MAGENTA='\033[35m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

out="${CYAN}${cwd}${RESET}"
[ -n "$branch" ] && out="${out} ${GREEN}(${branch})${RESET}"
[ -n "$model" ] && out="${out} | ${MAGENTA}${model}${RESET}"

# Color a percentage by threshold: <50 green, 50-79 yellow, >=80 red
# Usage: pct_colored <value> ; prints "<color><N>%<reset>"
pct_colored() {
  local p c
  p=$(printf '%.0f' "$1" 2>/dev/null) || return 1
  c=$GREEN
  [ "$p" -ge 50 ] && c=$YELLOW
  [ "$p" -ge 80 ] && c=$RED
  printf '%s' "${c}${p}%${RESET}"
}

if [ -n "$used" ]; then
  s=$(pct_colored "$used") && out="${out} | ctx ${s}"
fi

# Render a 10-char text progress bar for a percentage, colored by the same
# threshold rule as pct_colored: <50 green, 50-79 yellow, >=80 red.
# Usage: bar_colored <value> ; prints "<color>[bar] N%<reset>"
bar_colored() {
  local p c width filled empty bar i
  p=$(printf '%.0f' "$1" 2>/dev/null) || return 1
  c=$GREEN
  [ "$p" -ge 50 ] && c=$YELLOW
  [ "$p" -ge 80 ] && c=$RED
  width=10
  filled=$(((p + 5) / 10))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  empty=$((width - filled))
  bar=""
  for ((i = 0; i < filled; i++)); do bar="${bar}█"; done
  for ((i = 0; i < empty; i++)); do bar="${bar}░"; done
  printf '%s' "${c}[${bar}] ${p}%${RESET}"
}

# Time remaining until a resets_at timestamp (epoch seconds or ISO string).
# Prints e.g. "2h10m" or "3d4h"; empty (and non-zero exit) when unavailable.
time_until() {
  local resets="$1" now diff d h m
  [ -z "$resets" ] && return 1
  case "$resets" in
    ''|*[!0-9]*) resets=$(date -d "$resets" +%s 2>/dev/null) ;;
  esac
  [ -z "$resets" ] && return 1
  now=$(date +%s)
  diff=$((resets - now))
  [ "$diff" -lt 0 ] && diff=0
  d=$((diff / 86400)); h=$(((diff % 86400) / 3600)); m=$(((diff % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# Usage limits (hidden when absent), each with its own reset countdown when known
limits=""
if [ -n "$five" ]; then
  s=$(bar_colored "$five") && limits="5h ${s}"
  r=$(time_until "$five_reset") && [ -n "$r" ] && limits="${limits} resets ${r}"
fi
if [ -n "$week" ]; then
  s=$(bar_colored "$week") && limits="${limits:+$limits }7d ${s}"
  r=$(time_until "$week_reset") && [ -n "$r" ] && limits="${limits} resets ${r}"
fi
[ -n "$limits" ] && out="${out} | ${limits}"

printf '%b' "$out"
```

## 2. Dar permiso de ejecucion (Linux/Mac)

```bash
chmod +x ~/.claude/statusline-command.sh
```

En Windows no hace falta (se ejecuta via bash/Git Bash).

## 3. Apuntar settings.json al script

Editar `~/.claude/settings.json` (crear si no existe), agregar/mergear:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

## 4. Requisitos

- `jq` instalado (recomendado, path rapido). Sin `jq` usa fallback con `sed`/`grep` (mas lento, mismo resultado).
- `git` en PATH para mostrar branch.
- `bash` disponible (Git Bash en Windows).

## 5. Resto de settings.json

Agregar junto al bloque `statusLine` (mismo archivo `~/.claude/settings.json`), mergear sin pisar lo que ya tengas:

```json
{
  "model": "sonnet",
  "theme": "dark",
  "autoUpdatesChannel": "latest",
  "skipDangerousModePermissionPrompt": true,
  "attribution": {
    "commit": "",
    "pr": "",
    "sessionUrl": false
  },
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  },
  "enabledPlugins": {
    "claude-mem@thedotmack": true,
    "caveman@caveman": true,
    "agent-browser@agent-browser": true,
    "superpowers@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "thedotmack": {
      "source": { "source": "github", "repo": "thedotmack/claude-mem" }
    },
    "caveman": {
      "source": { "source": "github", "repo": "JuliusBrussee/caveman" }
    },
    "agent-browser": {
      "source": { "source": "github", "repo": "vercel-labs/agent-browser" }
    }
  }
}
```

Notas:
- `skipDangerousModePermissionPrompt: true` salta confirmacion extra en modo dangerous. Usar solo si ya confias en ese equipo/flujo.
- `attribution` vacio = no agrega firma de Claude en commits/PRs.
- Plugins requieren instalar marketplace primero (`extraKnownMarketplaces`) y despues habilitar plugin — Claude Code los descarga solo al reiniciar sesion.
- Sin `skillOverrides`: todas las skills de los plugins quedan activas (nada desactivado).

## 6. MCP servers (opcional)

Esta config tiene conectores MCP activos (Claude Docs, Gmail, Google Calendar, Google Drive, claude-mem mcp-search). Son opcionales y se agregan via `/mcp` o editando `~/.claude.json` — no van en `settings.json`. Solo replicar si el otro equipo necesita esos conectores especificos.

## 7. Auto Mode (opcional)

Si querés mismo comportamiento de "aprobar rutinario sin preguntar": usar `defaultMode: "auto"` en `permissions` dentro de `settings.json`, o dejar que Auto Mode se configure solo la primera vez que se activa (pregunta contexto org/repo).

## Que muestra

`ruta_completa (branch) | modelo | ctx N% | 5h [barra] N% resets Xh Ym | 7d [barra] N% resets Xd Yh`

Colores: cyan=ruta, verde=branch, magenta=modelo. Porcentajes/barras: verde <50%, amarillo 50-79%, rojo >=80%.
