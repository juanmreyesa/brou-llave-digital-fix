# Parche para eBROU — Llave Digital y huella digital se rompen cada 24 h en Android moderno y SoC Qualcomm

Este repo contiene un parche para la app eBROU (`uy.brou`) que arregla dos bugs relacionados:
1. La Llave Digital se invalida cada 24 h y obliga a volver a la sucursal del banco para que te bajen la llave digital y luego volver a registrarse.
2. La huella digital deja de funcionar dentro de la app (al confirmar operaciones, al loguearse), forzando a usar PIN o reactivarla a diario.

Ambos síntomas tienen la misma raíz: el plugin de almacenamiento seguro de eBROU usa una key del Android Keystore con dos defaults inseguros que en celulares modernos rompen la key con cualquier re-entrenamiento biométrico del sistema operativo o tras un timer de 24h. El parche cambia esos dos defaults, recompila y vuelve a firmar la APK con una keystore propia.

Probado en OnePlus 12 con OxygenOS 16; funciona estable desde hace más de una semana en uso diario.

Aviso legal: este parche se distribuye con fines educativos y de uso personal. Modificar y reinstalar una app del propio teléfono está dentro del uso defensivo legítimo. Distribuir la APK ya parcheada a otros, o intentar revender el procedimiento, queda bajo responsabilidad de quien lo haga. Yo no soy responsable de lo que decida hacer un tercero con esto.

---

Síntomas que arregla

**Bug de la Llave Digital:**
- Activás la Llave Digital en sucursal (o por el banco te la habilitan de nuevo).
- Funciona bien por unas horas.
- Al día siguiente, al intentar firmar una operación web te llega la notificación push, la abrís y la app te dice que la Llave **no está configurada** y te pide rehacerla desde cero.
- No la podés rehacer solo: tenés que volver físicamente a la sucursal del banco.
- Se repite cada 24-48 h.

**Bug de la huella digital:**
- Activás la huella para entrar a la app o confirmar operaciones.
- Funciona unas horas o un día.
- De pronto la app deja de aceptar la huella y te pide PIN. Si vas a reactivarla, te dice que "hay que volver a configurarla".
- Se reactiva, vuelve a fallar al rato.

Afecta principalmente a celulares con **Android 14 o superior** y SoC moderno (Snapdragon 8 Gen 2 o más nuevo, Tensor G3+, Dimensity 9200+, etc.). No afecta a teléfonos viejos: típicamente OnePlus 8 / Pixel 5 / Galaxy S20 y anteriores en Android 13 no exhiben los bugs.

---

## Causa de los bugs (resumen técnico)

El plugin de almacenamiento seguro de eBROU (`cordova-plugin-secure-storage-echo-brou`, un fork del plugin upstream de Crypho) tiene dos defaults problemáticos al crear la key RSA del Keystore Android:

1. **`DEFAULT_AUTHENTICATION_VALIDITY_TIME = 86400`** (segundos = 24 h). Es el tiempo que la key queda "autorizada" tras un evento de autenticación biométrica. En versiones viejas de Android (Keymaster 4) el contador se renovaba con cualquier desbloqueo del teléfono y nunca caducaba en uso normal. En Android 14+ con **KeyMint 3** la semántica cambió: el contador no se renueva con desbloqueos genéricos, así que a las 24 h exactas la key muere.

2. **`setInvalidatedByBiometricEnrollment(true)`** (default de Android, el plugin nunca lo cambia). Quiere decir: "si el usuario o el sistema reentrenan/agregan biometría, invalidá la key permanentemente". En OxygenOS post-fusión con ColorOS, en One UI moderno y en Pixel reciente, el sistema **reentrena el modelo de huella y de cara en background** sin avisar al usuario. Cada reentrenamiento invalida la key.

Como la **misma key** se usa tanto para la Llave Digital como para validar la huella dentro de la app, los dos bugs comparten causa. El parche resuelve ambos:

| Patch | Cambio | Efecto |
|---|---|---|
| **A** | `0x15180` (86400 s) → `0x1e13380` (31_536_000 s = 365 d) | La key vive hasta 1 año en lugar de 24 h |
| **B** | Agrega `setInvalidatedByBiometricEnrollment(false)` al `KeyGenParameterSpec.Builder` | El reentrenamiento biométrico (huella o cara) ya no mata la key |

Los detalles del análisis de bytecode están en el documento del reclamo (no se incluye acá por contener datos personales).

---

## Cómo usarlo

### Pre-requisitos

| Herramienta | Cómo obtenerla |
|---|---|
| **apktool** ≥ 2.9 | https://apktool.org · descargar el .jar |
| **JDK** 11+ | `apt install openjdk-21-jdk-headless` / equivalente |
| **build-tools** de Android SDK | con Android Studio o `cmdline-tools` standalone — para `zipalign` y `apksigner` |
| **python3** | viene preinstalado en casi cualquier Linux moderno |

Apuntá las variables de entorno si las herramientas no están en el PATH:

```bash
export APKTOOL_JAR=/ruta/a/apktool.jar
export ANDROID_HOME=/ruta/al/sdk            # ej. ~/Android/Sdk
```

### Paso 1 — obtener la APK actual de tu teléfono

El script trabaja sobre la APK oficial que ya tenés instalada en tu celular. **Tenés que sacarla vos** antes de correr el parche. Algunas formas:

- **Más fácil**: instalá una app tipo "APK Extractor" (hay varias gratis en Play Store), abrila, buscá "eBROU" en la lista, exportá el APK a la memoria del teléfono. Después pasalo a tu PC por cable, Bluetooth, Telegram, lo que sea.
- **Si ya tenés ADB configurado**:
  ```bash
  adb shell pm path uy.brou
  # devuelve algo como: package:/data/app/.../base.apk
  adb pull /data/app/.../base.apk uy.brou.apk
  ```

El archivo va a pesar ~150 MB.

### Paso 2 — parchear

```bash
./patch-ebrou.sh uy.brou.apk
```

Eso genera `uy.brou-patched.apk` en el directorio actual. El proceso:
1. Decompila la APK preservando recursos sin tocar.
2. Aplica el Patch A (timer 365 d) sobre `SecureStorage.smali`.
3. Aplica el Patch B (`setInvalidatedByBiometricEnrollment(false)`) sobre `RSA.smali`.
4. Recompila, firma con una keystore propia (la genera la primera vez en `./brou-patch.keystore`).
5. Verifica que ambos parches estén realmente presentes en el bytecode final.

### Paso 3 — instalar en el teléfono

Pasá el archivo `uy.brou-patched.apk` al celular y abrilo desde el explorador de archivos. Antes vas a tener que:

1. **Desinstalar la versión oficial** de eBROU (Configuración → Apps → eBROU → Desinstalar). Si la dejás, Android va a rechazar la instalación de la parcheada porque la firma no coincide.
2. **Permitir instalación de APKs de origen desconocido** desde el explorador de archivos que estés usando.
3. **Ir a sucursal a pedir baja-alta de la Llave Digital**: tu Llave actual está rota a nivel servidor, no se puede "rescatar". Sale del banco con la APK parcheada ya instalada y la activás desde cero.

### Opciones del script

```
$ ./patch-ebrou.sh --help

USO:
  ./patch-ebrou.sh [opciones] <apk-de-entrada>

El APK de entrada debe sacarlo el usuario previamente — por ej. con una
app tipo "APK Extractor" del Play Store, o con `adb pull` si ya tiene
configurado ADB. Este script no toca el teléfono.

OPCIONES:
  -o, --output FILE   APK de salida (default: <input>-patched.apk)
  -k, --keystore F    Keystore para firmar (default: ./brou-patch.keystore)
                      Se crea automáticamente si no existe.
  -p, --password P    Contraseña del keystore (default: brou123)
      --keep-work     Conservar el directorio temporal (debug)
  -h, --help          Esta ayuda
```

---

## Advertencias importantes

1. **No se va a actualizar más por Play Store.** La firma cambió, Play la trata como app distinta. Cada vez que BROU saque actualización vas a tener que repetir el procedimiento sobre la APK nueva (o reinstalar la oficial y aceptar que vuelvan los bugs).

2. **Desinstalar borra los datos de la app.** El uninstall limpia todo. Eso incluye el "fingerprint" del dispositivo que la app registra contra el backend. Probablemente al volver a entrar te exija revalidar identidad (selfie + foto de cédula). Eso es **normal**, no es señal de que algo salió mal.

3. **Vas a necesitar una baja-alta de la Llave en sucursal.** Tu Llave actual está rota a nivel servidor, no se puede "rescatar". Lo más simple es pedir en sucursal que te la den de baja, salís del banco con la APK parcheada ya instalada, y la activás desde cero.

4. **No tocar los recursos de la APK es crítico.** El script usa `apktool d -r` que preserva `resources.arsc` al byte. Si en algún momento intentás "decorar" la app (cambiar el ícono, el nombre, etc.) el SDK antifraude de la app la rechaza al arrancar.

5. **Riesgo bancario: cero pero no nulo.** El parche no toca nada de la lógica de transacciones ni la comunicación con el banco; solo arregla dos parámetros locales del Keystore Android. En el peor caso imaginable, el banco detecta que firma no oficial y te invalida la clave server-side → terminás como ya estás. No hay vector adicional de riesgo.

---

## ¿Qué pasa si BROU saca actualización del plugin?

Mientras los nombres de clase y método del plugin sigan iguales (`com.crypho.plugins.SecureStorage`, `com.crypho.plugins.RSA.getInitParams`), el script encuentra las anclas en el smali y aplica los parches sin problema. El parche es idempotente: si lo corrés sobre una APK ya parcheada, no la rompe.

Si BROU cambia el plugin upstream (reescribe a Kotlin, cambia el nombre del paquete, etc.) el script va a fallar con un mensaje claro y habría que revisitar las anclas. Lo ideal sería que lo arreglen en serio — el reclamo formal va por ese carril.

---

## Estructura de este repo

```
patch-publico/
├── README.md          ← este archivo
└── patch-ebrou.sh     ← script automatizado
```

El keystore se genera al primer uso (`brou-patch.keystore`). Conviene guardarlo: si lo perdés y BROU saca una actualización, vas a tener que desinstalar otra vez (porque la firma de la nueva tanda no va a coincidir con la vieja). Si lo guardás, podés instalar parches consecutivos como "actualización" sobre la misma firma.

---

## Créditos / contacto

Análisis hecho por reverse engineering del cliente Android de eBROU 3.34.0. Si encontrás bugs en el script o mejoras, mandá un PR. Si BROU finalmente arregla esto en serio, este repo queda como referencia histórica.

