#!/usr/bin/env bash
# patch-ebrou.sh — Parchea la APK de eBROU para fixear el bug de la
# Llave Digital que se invalida cada ~24 h en dispositivos modernos
# (Android 14+ con KeyMint 3 y/o re-enrolment biométrico agresivo).
#
# Verificado contra uy.brou 3.34.0 (versionCode 33400, 2026-05).
# Probablemente funciona en versiones futuras mientras se siga usando
# el plugin cordova-plugin-secure-storage-echo-brou con la misma
# estructura.
#
# Lo que hace:
#   Patch A — cambia DEFAULT_AUTHENTICATION_VALIDITY_TIME de 86400 s
#             (24 h) a 31_536_000 s (365 días) en SecureStorage.smali.
#   Patch B — agrega setInvalidatedByBiometricEnrollment(false) al
#             KeyGenParameterSpec.Builder en RSA.smali, antes del
#             build(). Default Android es true → cualquier re-enrol
#             biométrico que haga el OS invalida la key permanentemente.
#
# Importante: NO toca recursos. apktool corre con `-r` para preservar
# resources.arsc binario al byte; tocarlo hace que el SDK de VU
# Fraud Analysis rechace la app en runtime.
#
# Uso:
#   ./patch-ebrou.sh uy.brou-3.34.0.apk
#
# Requiere: apktool 2.9+, JDK 11+, build-tools de Android SDK
# (zipalign, apksigner). NO requiere adb.

set -euo pipefail

# ─── defaults ────────────────────────────────────────────────────────
KEYSTORE="${KEYSTORE:-./brou-patch.keystore}"
KS_PASS="${KS_PASS:-brou123}"
KS_ALIAS="${KS_ALIAS:-brou}"
APK_IN=""
APK_OUT=""
KEEP_WORK=0
WORK="$(mktemp -d -t brou-patch-XXXXXX)"

cleanup() {
  if [[ "$KEEP_WORK" == "1" ]]; then
    echo "→ Workdir preservado en: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

log() { printf '\033[1;36m→\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
patch-ebrou.sh — fixea el bug de la Llave Digital de eBROU

USO:
  $0 [opciones] <apk-de-entrada>

El APK de entrada debe sacarlo el usuario previamente — por ej. con una
app tipo "APK Extractor" del Play Store, o con \`adb pull\` si ya tiene
configurado ADB. Este script no toca el teléfono.

OPCIONES:
  -o, --output FILE   APK de salida (default: <input>-patched.apk)
  -k, --keystore F    Keystore para firmar (default: ./brou-patch.keystore)
                      Se crea automáticamente si no existe.
  -p, --password P    Contraseña del keystore (default: brou123)
      --keep-work     Conservar el directorio temporal (debug)
  -h, --help          Esta ayuda

VARIABLES DE ENTORNO:
  APKTOOL_JAR    Path al jar de apktool (autodetectado si no se pasa)
  ANDROID_HOME   Path al SDK de Android (para hallar zipalign/apksigner)

DEPENDENCIAS:
  apktool >= 2.9, JDK >= 11, build-tools (zipalign + apksigner),
  keytool (viene con el JDK), python3.
EOF
}

# ─── parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)   APK_OUT="$2"; shift 2;;
    -k|--keystore) KEYSTORE="$2"; shift 2;;
    -p|--password) KS_PASS="$2"; shift 2;;
    --keep-work)   KEEP_WORK=1; shift;;
    -h|--help)     usage; exit 0;;
    -*)            err "opción desconocida: $1"; usage; exit 1;;
    *)             APK_IN="$1"; shift;;
  esac
done

if [[ -z "$APK_IN" ]]; then
  err "Falta APK de entrada. Pasá el path como argumento."
  usage; exit 1
fi
[[ -f "$APK_IN" ]] || { err "no existe: $APK_IN"; exit 3; }

# default output name
if [[ -z "$APK_OUT" ]]; then
  base="$(basename "$APK_IN" .apk)"
  APK_OUT="${base}-patched.apk"
fi

# ─── localizar tooling ───────────────────────────────────────────────
find_apktool() {
  if [[ -n "${APKTOOL_JAR:-}" && -f "$APKTOOL_JAR" ]]; then echo "$APKTOOL_JAR"; return; fi
  shopt -s nullglob
  local candidates=(
    "$HOME"/apktool*.jar
    "$HOME"/.local/share/apktool*.jar
    "$HOME"/.cache/apk-mitm/apktool-*.jar
    /opt/apktool/apktool*.jar
    /usr/local/share/apktool*.jar
    /usr/share/java/apktool*.jar
  )
  shopt -u nullglob
  for c in "${candidates[@]}"; do
    [[ -f "$c" ]] && { echo "$c"; return; }
  done
  return 1
}

find_buildtool() {
  local name="$1"
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    local cand
    cand=$(ls -1d "$ANDROID_HOME"/build-tools/*/"$name" 2>/dev/null | sort -V | tail -1 || true)
    [[ -n "$cand" && -x "$cand" ]] && { echo "$cand"; return; }
  fi
  command -v "$name" 2>/dev/null && return
  return 1
}

APKTOOL_JAR=$(find_apktool || true)
ZIPALIGN=$(find_buildtool zipalign || true)
APKSIGNER=$(find_buildtool apksigner || true)

MISSING=()
[[ -z "$APKTOOL_JAR" ]] && MISSING+=("apktool.jar (setea APKTOOL_JAR=...)")
[[ -z "$ZIPALIGN"    ]] && MISSING+=("zipalign (setea ANDROID_HOME=...)")
[[ -z "$APKSIGNER"   ]] && MISSING+=("apksigner (setea ANDROID_HOME=...)")
command -v java >/dev/null     || MISSING+=("java (JDK 11+)")
command -v keytool >/dev/null  || MISSING+=("keytool (viene con el JDK)")
command -v python3 >/dev/null  || MISSING+=("python3")
if (( ${#MISSING[@]} > 0 )); then
  err "faltan dependencias:"
  for m in "${MISSING[@]}"; do printf '   • %s\n' "$m" >&2; done
  exit 2
fi

# ─── decompilar ──────────────────────────────────────────────────────
DECOMP="$WORK/decoded"
log "Decompilando con apktool (modo -r, sin tocar recursos)…"
java -jar "$APKTOOL_JAR" d -r -f "$APK_IN" -o "$DECOMP" >/dev/null
ok "decompile OK ($DECOMP)"

# localizar smali targets (pueden caer en classes/classes2/classes3 según versión)
SS=$(find "$DECOMP" -path '*com/crypho/plugins/SecureStorage.smali' -print -quit)
RSA=$(find "$DECOMP" -path '*com/crypho/plugins/RSA.smali' -print -quit)
[[ -n "$SS"  ]] || { err "no encontré SecureStorage.smali — ¿plugin removido o renombrado?"; exit 4; }
[[ -n "$RSA" ]] || { err "no encontré RSA.smali — ¿plugin removido o renombrado?"; exit 4; }
log "SecureStorage: ${SS#$DECOMP/}"
log "RSA:           ${RSA#$DECOMP/}"

# ─── Patch A: timer 24h → 365d ───────────────────────────────────────
log "Aplicando Patch A — DEFAULT_AUTHENTICATION_VALIDITY_TIME 86400 → 31_536_000"
if grep -q 'const v0, 0x1e13380' "$SS"; then
  ok "Patch A ya aplicado (idempotente)"
elif grep -q 'const v0, 0x15180' "$SS"; then
  sed -i 's/const v0, 0x15180\b/const v0, 0x1e13380/' "$SS"
  grep -q 'const v0, 0x1e13380' "$SS" || { err "Patch A falló al escribir"; exit 5; }
  ok "Patch A aplicado"
else
  err "Patch A: anchor 'const v0, 0x15180' no encontrado en SecureStorage.smali."
  err "Esta versión de eBROU puede haber cambiado el plugin. Revisar a mano."
  exit 5
fi

# ─── Patch B: setInvalidatedByBiometricEnrollment(false) ─────────────
log "Aplicando Patch B — setInvalidatedByBiometricEnrollment(false) en RSA.getInitParams"
if grep -q 'setInvalidatedByBiometricEnrollment' "$RSA"; then
  ok "Patch B ya aplicado (idempotente)"
else
  python3 - "$RSA" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
# Anchor: el último setBlockModes(...) + move-result-object p0
# justo antes del build(). Tolera variación en whitespace.
anchor = re.compile(
    r'(invoke-virtual \{p0,\s*p1\}, '
    r'Landroid/security/keystore/KeyGenParameterSpec\$Builder;'
    r'->setBlockModes\(\[Ljava/lang/String;\)'
    r'Landroid/security/keystore/KeyGenParameterSpec\$Builder;\s*\n'
    r'\s*move-result-object p0\s*\n)'
)
patch = (
    "\n"
    "    const/4 v0, 0x0\n"
    "\n"
    "    invoke-virtual {p0, v0}, "
    "Landroid/security/keystore/KeyGenParameterSpec$Builder;"
    "->setInvalidatedByBiometricEnrollment(Z)"
    "Landroid/security/keystore/KeyGenParameterSpec$Builder;\n"
    "\n"
    "    move-result-object p0\n"
)
out, n = anchor.subn(r'\1' + patch, src, count=1)
if n != 1:
    print("Patch B: anchor no encontrado en RSA.smali (versión nueva del plugin?)",
          file=sys.stderr)
    sys.exit(1)
p.write_text(out)
PY
  grep -q 'setInvalidatedByBiometricEnrollment' "$RSA" || \
    { err "Patch B falló al escribir el smali"; exit 5; }
  ok "Patch B aplicado"
fi

# ─── rebuild ─────────────────────────────────────────────────────────
UNSIGNED="$WORK/unsigned.apk"
ALIGNED="$WORK/aligned.apk"
log "Recompilando APK…"
java -jar "$APKTOOL_JAR" b "$DECOMP" -o "$UNSIGNED" >/dev/null
ok "rebuild OK"

# ─── keystore ────────────────────────────────────────────────────────
if [[ ! -f "$KEYSTORE" ]]; then
  log "Generando keystore propio en $KEYSTORE…"
  keytool -genkeypair -keystore "$KEYSTORE" -alias "$KS_ALIAS" \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$KS_PASS" -keypass "$KS_PASS" \
      -dname "CN=BROU Patch, O=Self, C=UY" 2>/dev/null
  ok "keystore generado"
fi

# ─── zipalign + sign ─────────────────────────────────────────────────
log "zipalign + firmar…"
"$ZIPALIGN" -p -f 4 "$UNSIGNED" "$ALIGNED"
"$APKSIGNER" sign \
    --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
    --out "$APK_OUT" "$ALIGNED" 2>/dev/null
"$APKSIGNER" verify "$APK_OUT" >/dev/null 2>&1 \
  && ok "firma verificada" \
  || { err "fallo de verificación de firma"; exit 6; }

# ─── sanity check: APK firmada existe y no quedó vacía ───────────────
[[ -s "$APK_OUT" ]] || { err "el APK firmado quedó vacío"; exit 7; }

ok "APK parcheada lista: $APK_OUT  ($(du -h "$APK_OUT" | cut -f1))"
log "Próximo paso: pasá $APK_OUT al teléfono e instalala manualmente."
log "Antes vas a tener que desinstalar la versión oficial (Play Store) y"
log "pedir baja-alta de la Llave Digital en sucursal."
