# Replicar configuración de Claude Code (skills, plugins, MCPs, statusline)

> **Instrucciones para Claude:** este archivo describe la configuración de Claude Code de otro equipo. Tu tarea es dejar este equipo configurado igual. Seguí los pasos en orden. Antes de escribir un archivo, leelo si ya existe y **mergeá** (no pises claves que el usuario ya tenga). Al terminar, reportá qué quedó hecho y qué requiere acción manual del usuario (logins, API keys, extensión de Chrome).

Equipo origen: Windows 11, Git Bash, Node v26, Bun instalado. Funciona también en Mac/Linux ajustando rutas (`~` = `C:\Users\<usuario>` en Windows).

## 0. Requisitos previos

Verificar y, si faltan, instalar:

- `node` (v20+) y `npm`
- `git` y `bash` (en Windows: Git for Windows / Git Bash)
- `bun` (lo usa el plugin claude-mem): `npm i -g bun` o `powershell -c "irm bun.sh/install.ps1 | iex"`
- `jq` (opcional, acelera la statusline): `winget install jqlang.jq`
- El usuario tiene que estar logueado en Claude Code con **la misma cuenta de claude.ai** que el equipo origen (ver sección 4: de eso dependen varios MCPs y skills).

## 1. settings.json

Archivo: `~/.claude/settings.json`. Mergear este contenido:

```json
{
  "model": "opus",
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
- `attribution` vacío: Claude no firma commits ni PRs.
- `skipDangerousModePermissionPrompt: true`: no pide confirmación extra al entrar en modo bypass. Confirmar con el usuario si lo quiere en este equipo.
- **No copiar** el bloque `autoMode.environment` del equipo origen: es específico de esa máquina. Auto Mode lo genera solo la primera vez que se activa.
- El origen tiene además un plugin local `claudeTalk` (deshabilitado, apunta a una carpeta local). Se omite a propósito.

## 2. Plugins

Con los marketplaces declarados en `settings.json`, Claude Code los descarga al reiniciar. Si no aparecen, instalarlos a mano dentro de Claude Code:

```
/plugin marketplace add thedotmack/claude-mem
/plugin marketplace add JuliusBrussee/caveman
/plugin marketplace add vercel-labs/agent-browser
/plugin install claude-mem@thedotmack
/plugin install caveman@caveman
/plugin install agent-browser@agent-browser
/plugin install superpowers@claude-plugins-official
```

Versiones en el origen: claude-mem 13.25.1, caveman 2.7.0, agent-browser aff6125c023b, superpowers 7.0.0.

Qué aporta cada uno:
- **claude-mem**: memoria persistente entre sesiones (hooks + MCP `mcp-search` + skills `mem-search`, `make-plan`, `do`, etc.). Levanta un worker local con Bun; su base queda en `~/.claude-mem/`.
- **caveman**: modo de respuesta comprimido, activo por defecto (nivel `full`) vía hook SessionStart. Skills `caveman`, `caveman-commit`, `caveman-review`, etc.
- **agent-browser**: skill de automatización de navegador. Si la skill pide el CLI: `npm i -g agent-browser && agent-browser install`.
- **superpowers**: skills de proceso (brainstorming, writing-plans, systematic-debugging, TDD, code review, etc.).

## 3. MCP servers

En el origen **no hay MCP servers definidos a mano** (`mcpServers` está vacío en `~/.claude.json`). Todos los MCP vienen de otras fuentes, así que no hay que copiar JSON:

| MCP | De dónde sale | Qué hacer en este equipo |
|---|---|---|
| Claude Docs, Gmail, Google Calendar, Google Drive | Conectores de la cuenta claude.ai | Loguearse con la misma cuenta (`/login`). Gmail y Calendar pueden pedir autenticar de nuevo: correr `/mcp` y autenticar. |
| claude-in-chrome | Extensión "Claude in Chrome" | Instalar la extensión en Chrome, loguearse con la misma cuenta. En `/config` habilitar Chrome por defecto (en el origen `claudeInChromeDefaultEnabled: true`), o arrancar con `claude --chrome`. |
| claude-mem `mcp-search` | Plugin claude-mem | Se instala solo con el plugin (sección 2). |

Verificar con `/mcp` que todos aparezcan conectados.

## 4. Skills

Dos orígenes:

1. **Skills de plugins**: vienen con la sección 2.
2. **Skills sincronizadas de claude.ai** (`~/.claude/skills/synced/...`: docs, docx, pdf, pptx, xlsx, deep-research, skill-creator, google-workspace, morning, import-memory, chrome-browser, built-in-browser, computer-use): se sincronizan solas al loguearse con la misma cuenta. No copiar a mano.

## 5. Statusline

Muestra: `ruta (branch) | modelo | ctx N% | 5h [barra] N% resets XhYm | 7d [barra] N% resets XdYh`. Colores: verde <50 %, amarillo 50-79 %, rojo >=80 %.

Crear `~/.claude/statusline-command.sh` con este contenido (en Linux/Mac, después `chmod +x ~/.claude/statusline-command.sh`):

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

## 6. Verificación final

1. Reiniciar Claude Code.
2. `/plugin`: los 4 plugins instalados y habilitados.
3. `/mcp`: Claude Docs, Gmail, Google Calendar, Google Drive, claude-in-chrome y claude-mem conectados.
4. Lista de skills: aparecen `caveman:*`, `claude-mem:*`, `superpowers:*`, `agent-browser:*` y las de claude.ai.
5. Al iniciar sesión aparece el aviso de caveman activo y el contexto de claude-mem.
6. La statusline se ve abajo.

Reportar al usuario lo que falte (login, API key, extensión de Chrome).
