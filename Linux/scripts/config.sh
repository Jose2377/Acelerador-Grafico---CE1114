# Variables comunes a todos los scripts. Todas las rutas se calculan a partir
# de la ubicacion de este archivo dentro del repositorio clonado, de modo que
# funcionan en cualquier carpeta (sin rutas de Windows).
#
#   <repositorio>/Linux/scripts/config.sh   <- este archivo
#   <repositorio>/FPGA                       proyecto de Quartus
#   <repositorio>/Linux/br2-external         arbol externo de Buildroot
#
# Lo unico que vive fuera del repositorio es la carpeta de compilacion BASE
# (Buildroot, descargas y resultados, ~15 GB). Se puede cambiar con:
#   BASE=/otra/ruta bash scripts/03-compilar.sh
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$SCRIPTS/.." && pwd)"                   # <repositorio>/Linux
REPO="$(cd "$PKG/.." && pwd)"                      # <repositorio>
EXT="$PKG/br2-external"
RBF="$EXT/board/de1soc/fpga/soc_system.rbf"

BASE="${BASE:-$HOME/de1soc}"                       # disco local de Linux, NO la particion de Windows
BR_VERSION="${BR_VERSION:-2026.02.3}"              # Buildroot LTS
BR_DIR="$BASE/buildroot"
OUT="$BASE/output"

# Buildroot no admite espacios en las rutas
case "$PKG$BASE" in *" "*)
    echo "ERROR: la ruta contiene espacios: $PKG o $BASE"
    echo "Clona el repositorio en una carpeta sin espacios (por ejemplo ~/Acelerador-Grafico---CE1114)."
    exit 1;;
esac

# Buildroot ejecuta post-image.sh directamente: necesita permiso de ejecucion
# y finales de linea LF (git en Windows puede dejar CRLF y quitar el +x).
preparar_permisos() {
    local f
    for f in "$SCRIPTS"/*.sh "$EXT"/board/de1soc/post-image.sh \
             "$EXT"/board/de1soc/rootfs-overlay/etc/init.d/S90gpu2d.sh; do
        [ -f "$f" ] || continue
        sed -i 's/\r$//' "$f"
        chmod +x "$f"
    done
}

# Detiene el script si todavia no se corrio 01-preparar-buildroot.sh
requiere_buildroot() {
    if [ ! -f "$OUT/.config" ]; then
        echo "ERROR: no existe $OUT/.config. Corre primero: bash scripts/01-preparar-buildroot.sh"
        exit 1
    fi
}
