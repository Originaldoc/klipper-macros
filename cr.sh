#!/bin/bash

SD_PATH="$HOME/printer_data/gcodes"
OUTFILE="$SD_PATH/cr.gcode"
TEMPFILE="$SD_PATH/crtmp.gcode"

Z_OFFSET="$1"
Z_HEIGHT="$2"
SRCFILE="$3"
BED_TEMP="$4"
HOT_TEMP="$5"

cp "$SD_PATH/$SRCFILE" "$TEMPFILE"

############################################
# 1. BUSCAR LÍNEA REAL DE REANUDACIÓN
############################################
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
  echo "ERROR: No se encontró punto válido de reanudación (Z >= $Z_HEIGHT con extrusión)"
  exit 1
fi

############################################
# 2. Z REAL
############################################
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

echo "DEBUG: RESUME_LINE=$RESUME_LINE  REAL_Z=$REAL_Z"

############################################
# 3. EXTRUSIÓN
############################################
BG_EX=$(sed -n "1,${RESUME_LINE}p" "$TEMPFILE" \
  | grep ' E' \
  | tail -n 1 \
  | sed -n 's/.* E\([^ ]*\)/G92 E\1/p')

############################################
# 4. CABECERA SEGURA
############################################
# === EXTRAER THUMBNAIL ===
THUMBNAIL=$(sed -n '/^; thumbnail begin/,/^; thumbnail end/p' "$TEMPFILE")

{
  [ -n "$THUMBNAIL" ] && echo "$THUMBNAIL"
  echo "; RESUMED PRINT - ORIGINAL FILE: $SRCFILE"
  echo "; ⚠ MODEL MAY BE INCOMPLETE"
} >> "$OUTFILE"

{
echo "; === SAFE RESUME (Orca Slicer) ==="

# --- TEMPERATURAS (PRIMERO SIEMPRE) ---
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

# --- LIMITES DE SEGURIDAD ---
echo "SET_VELOCITY_LIMIT VELOCITY=50 ACCEL=500"

# --- CINEMÁTICA ---
echo "G28 X Y"
echo "SET_KINEMATIC_POSITION Z=$Z_OFFSET"
[ -n "$BG_EX" ] && echo "$BG_EX"
echo "G91"
echo "G1 Z-$Z_OFFSET F300"
echo "G90"
echo "SET_KINEMATIC_POSITION Z=$REAL_Z"
echo "G1 F1200"

} >> "$OUTFILE"

############################################
# 5. TEMPERATURAS
############################################
[ -n "$BED_TEMP" ] && {
  echo "M140 S$BED_TEMP"
  echo "M190 S$BED_TEMP"
} >> "$OUTFILE"

[ -n "$HOT_TEMP" ] && {
  echo "M104 S$HOT_TEMP"
  echo "M109 S$HOT_TEMP"
} >> "$OUTFILE"

############################################
# 6. CONTINUAR GCODE
############################################
sed -n "${RESUME_LINE},\$p" "$TEMPFILE" >> "$OUTFILE"

echo "Resume GCODE listo: $OUTFILE"
rm "$TEMPFILE"
