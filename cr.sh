#!/bin/bash

# ================= CONFIG =================
SD_PATH="$HOME/printer_data/gcodes"
OUTFILE="$SD_PATH/cr.gcode"
TEMPFILE="$SD_PATH/crtmp.gcode"

Z_OFFSET="$1"     # Z físico actual
Z_HEIGHT="$2"     # Altura donde se detuvo la impresión
SRCFILE="$3"
BED_TEMP="$4"
HOT_TEMP="$5"

# Ficheros temporales thumbnail
THUMB_RAW="/tmp/cr_thumb.raw"
THUMB_B64="/tmp/cr_thumb.b64"
THUMB_PNG="/tmp/cr_thumb.png"
THUMB_OUT="/tmp/cr_thumb_resume.png"

# =========================================

cp "$SD_PATH/$SRCFILE" "$TEMPFILE" || exit 1

# =========================================================
# 1. EXTRAER THUMBNAIL ORIGINAL (si existe)
# =========================================================
HAS_THUMBNAIL=false
sed -n '/^; thumbnail begin/,/^; thumbnail end/p' "$TEMPFILE" > "$THUMB_RAW"

if grep -q '^; thumbnail begin' "$THUMB_RAW"; then
  HAS_THUMBNAIL=true
  sed 's/^; //' "$THUMB_RAW" | sed '1d;$d' > "$THUMB_B64"
fi

# =========================================================
# 2. PROCESAR THUMBNAIL (añadir texto RESUME)
# =========================================================
PROCESSED_THUMBNAIL=""

if $HAS_THUMBNAIL && command -v convert >/dev/null 2>&1; then
  base64 -d "$THUMB_B64" > "$THUMB_PNG" 2>/dev/null

  if [ -s "$THUMB_PNG" ]; then
    # Texto grande, centrado, semitransparente
    convert "$THUMB_PNG" \
      -resize 150x150! \
      \( -size 150x150 xc:none \
        -gravity center \
        -font DejaVu-Sans-Bold \
        -fill "rgba(255,0,0,0.55)" \
        -pointsize 24 \
        -annotate 0 "RESUME" \
      \) \
      -composite \
      "$THUMB_OUT"

    if [ -s "$THUMB_OUT" ]; then
      SIZE=$(base64 -w 0 "$THUMB_OUT" | wc -c)
      B64=$(base64 "$THUMB_OUT" | sed 's/^/; /')

      PROCESSED_THUMBNAIL="; thumbnail begin 150x150 $SIZE
$B64
; thumbnail end"
    fi
  fi
fi

# =========================================================
# 3. BUSCAR LÍNEA REAL DE REANUDACIÓN (Orca-safe)
# =========================================================
RESUME_LINE=$(awk -v zh="$Z_HEIGHT" '
{
  if ($0 ~ /[[:space:]]Z/) {
    line = $0
    sub(/.*[[:space:]]Z/, "", line)
    sub(/[[:space:]].*/, "", line)
    last_z = line + 0
  }

  if ($0 ~ /[[:space:]]E[-+]?[0-9]/) {
    if (last_z >= zh) {
      print NR
      exit
    }
  }
}
' "$TEMPFILE")

if [ -z "$RESUME_LINE" ]; then
  echo "ERROR: No se encontró punto válido de reanudación"
  exit 1
fi

# =========================================================
# 4. OBTENER Z REAL Y EXTRUSIÓN
# =========================================================
REAL_Z=$(awk -v stop="$RESUME_LINE" '
NR <= stop {
  if ($0 ~ /[[:space:]]Z/) {
    line = $0
    sub(/.*[[:space:]]Z/, "", line)
    sub(/[[:space:]].*/, "", line)
    z = line
  }
}
END { print z }
' "$TEMPFILE")

BG_EX=$(sed -n "1,${RESUME_LINE}p" "$TEMPFILE" \
  | grep ' E' \
  | tail -n 1 \
  | sed -n 's/.* E\([^ ]*\)/G92 E\1/p')

# =========================================================
# 5. GENERAR cr.gcode
# =========================================================
{
  # --- THUMBNAIL ---
  if [ -n "$PROCESSED_THUMBNAIL" ]; then
    echo "$PROCESSED_THUMBNAIL"
  elif $HAS_THUMBNAIL; then
    cat "$THUMB_RAW"
  fi

  # --- INFO ---
  echo "; === RESUMED PRINT ==="
  echo "; ORIGINAL FILE: $SRCFILE"
  echo "; RESUME FROM Z=$Z_HEIGHT"
  echo "; ⚠ MODEL MAY BE INCOMPLETE"
  echo

  # --- TEMPERATURAS (KLIPPER NATIVO) ---
  [ -n "$BED_TEMP" ] && {
    echo "SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=$BED_TEMP"
  }
  [ -n "$HOT_TEMP" ] && {
    echo "SET_HEATER_TEMPERATURE HEATER=extruder TARGET=$HOT_TEMP"
  }
  [ -n "$BED_TEMP" ] && {
    echo "TEMPERATURE_WAIT SENSOR=heater_bed MINIMUM=$BED_TEMP"
  }
  [ -n "$HOT_TEMP" ] && {
    echo "TEMPERATURE_WAIT SENSOR=extruder MINIMUM=$HOT_TEMP"
  }

  # --- SEGURIDAD DE MOVIMIENTO ---
  echo "SET_VELOCITY_LIMIT VELOCITY=50 ACCEL=500"
  echo "G28 X Y"
  echo "SET_KINEMATIC_POSITION Z=$Z_OFFSET"
  [ -n "$BG_EX" ] && echo "$BG_EX"
  echo "G91"
  echo "G1 Z-$Z_OFFSET F300"
  echo "G90"
  echo "SET_KINEMATIC_POSITION Z=$REAL_Z"
  echo "G1 F1200"

} > "$OUTFILE"

# =========================================================
# 6. AÑADIR GCODE RESTANTE
# =========================================================
sed -n "${RESUME_LINE},\$p" "$TEMPFILE" >> "$OUTFILE"

echo "cr.gcode generado correctamente en: $OUTFILE"
rm "$TEMPFILE"