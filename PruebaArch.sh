#!/bin/bash

# --- Verificar permisos de root ---
verificar_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Este script debe ejecutarse como root."
        echo "Usa: sudo bash dns_setup.sh"
        exit 1
    else
        echo "OK: Ejecutando como root."
    fi
}

# --- Verificar o configurar IP estatica ---
verificar_ip_estatica() {
    echo ""
    echo "=== Verificando IP estatica en enp0s8 ==="

    IP_ACTUAL=$(ip addr show enp0s8 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

    if [ -n "$IP_ACTUAL" ]; then
        echo "OK: La interfaz enp0s8 ya tiene IP: $IP_ACTUAL"
        IP_SERVIDOR=$IP_ACTUAL
    else
        echo "AVISO: No se encontro IP estatica en enp0s8."
        read -p "Ingresa la IP que deseas asignar (ej: 192.168.100.10): " IP_INPUT
        read -p "Ingresa la mascara en formato CIDR (ej: 24): " MASCARA_INPUT

        if [ -z "$IP_INPUT" ] || [ -z "$MASCARA_INPUT" ]; then
            echo "ERROR: La IP o mascara no pueden estar vacias."
            exit 1
        fi

        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/20-static.network << EOF
[Match]
Name=enp0s8

[Network]
Address=${IP_INPUT}/${MASCARA_INPUT}
EOF

        systemctl enable systemd-networkd
        systemctl restart systemd-networkd
        sleep 2

        IP_SERVIDOR=$IP_INPUT
        echo "OK: IP estatica $IP_SERVIDOR configurada correctamente."
    fi
}

# --- Instalar BIND9 ---
instalar_bind9() {
    echo ""
    echo "=== Instalando BIND9 ==="

    if systemctl is-active --quiet named; then
        echo "OK: BIND9 ya esta corriendo. Se omite instalacion."
    else
        echo "Instalando paquetes necesarios..."
        pacman -Sy --noconfirm bind

        if [ $? -ne 0 ]; then
            echo "ERROR: Fallo la instalacion de BIND9."
            exit 1
        fi

        systemctl enable named
        systemctl start named
        echo "OK: BIND9 instalado y servicio iniciado."
    fi
}

# --- Configurar zona DNS ---
configurar_zona_dns() {
    echo ""
    echo "=== Configurando zona DNS ==="

    # Preguntar el dominio y la IP del cliente
    read -p "Ingresa el nombre del dominio (ej: reprobados.com): " ZONA
    read -p "Ingresa la IP a la que apuntara el dominio (ej: 192.168.100.30): " IP_CLIENTE

    if [ -z "$ZONA" ] || [ -z "$IP_CLIENTE" ]; then
        echo "ERROR: El dominio y la IP no pueden estar vacios."
        exit 1
    fi

    ARCHIVO_ZONA="/var/named/$ZONA.zone"
    CONF_LOCAL="/etc/named.conf"

    # Verificar si la zona ya existe
    if grep -q "$ZONA" "$CONF_LOCAL" 2>/dev/null; then
        echo "OK: La zona $ZONA ya existe. Se omite."
    else
        cat >> /etc/named.conf << EOF

zone "$ZONA" IN {
    type master;
    file "$ARCHIVO_ZONA";
    allow-update { none; };
};
EOF
        echo "OK: Zona $ZONA agregada a named.conf"
    fi

    # Crear archivo de zona si no existe
    if [ -f "$ARCHIVO_ZONA" ]; then
        echo "OK: Archivo de zona ya existe. Se omite."
    else
        cat > "$ARCHIVO_ZONA" << EOF
\$TTL 86400
@   IN  SOA     ns1.$ZONA. admin.$ZONA. (
                2024010101  ; Serial
                3600        ; Refresh
                1800        ; Retry
                604800      ; Expire
                86400 )     ; Minimum TTL

; Servidor de nombres
@   IN  NS      ns1.$ZONA.

; Registros A
ns1 IN  A       $IP_SERVIDOR
@   IN  A       $IP_CLIENTE

; Registro CNAME para www
www IN  CNAME   $ZONA.
EOF
        chown named:named "$ARCHIVO_ZONA"
        echo "OK: Archivo de zona creado para $ZONA"
    fi

    systemctl restart named
}

# --- Eliminar dominio ---
eliminar_zona_dns() {
    echo ""
    echo "=== Eliminar dominio ==="

    read -p "Ingresa el dominio que deseas eliminar: " ZONA_ELIMINAR

    if [ -z "$ZONA_ELIMINAR" ]; then
        echo "ERROR: El dominio no puede estar vacio."
        return
    fi

    ARCHIVO_ZONA="/var/named/$ZONA_ELIMINAR.zone"

    # Eliminar el archivo de zona
    if [ -f "$ARCHIVO_ZONA" ]; then
        rm -f "$ARCHIVO_ZONA"
        echo "OK: Archivo de zona $ARCHIVO_ZONA eliminado."
    else
        echo "AVISO: No se encontro el archivo de zona para $ZONA_ELIMINAR."
    fi

    # Eliminar la entrada en named.conf
    if grep -q "$ZONA_ELIMINAR" /etc/named.conf; then
        # Borrar el bloque completo de la zona en named.conf
        sed -i "/zone \"$ZONA_ELIMINAR\"/,/};/d" /etc/named.conf
        echo "OK: Zona $ZONA_ELIMINAR eliminada de named.conf"
    else
        echo "AVISO: No se encontro $ZONA_ELIMINAR en named.conf"
    fi

    systemctl restart named
    echo "OK: Servicio reiniciado."
}

# --- Ver estado del servicio ---
ver_estado() {
    echo ""
    echo "=== Estado del servicio DNS ==="

    if systemctl is-active --quiet named; then
        echo "OK: BIND9 esta corriendo."
    else
        echo "AVISO: BIND9 no esta corriendo."
    fi

    echo ""
    echo "--- Prueba de resolucion ---"
    read -p "Ingresa el dominio a consultar (ej: reprobados.com): " DOMINIO_TEST
    nslookup $DOMINIO_TEST 127.0.0.1
}

# --- Cambiar dominio ---
cambiar_dominio() {
    echo ""
    echo "=== Cambiar dominio ==="
    echo "Primero eliminaremos el dominio anterior."
    eliminar_zona_dns
    echo ""
    echo "Ahora configuraremos el nuevo dominio."
    configurar_zona_dns
}

mostrar_menu() {
    echo ""
    echo "============================================"
    echo "   Configuracion DNS"
    echo "============================================"
    echo " 1. Instalar y configurar DNS"
    echo " 2. Cambiar dominio"
    echo " 3. Eliminar dominio"
    echo " 4. Ver estado del servicio"
    echo " 5. Salir"
    echo "============================================"
    read -p " Elige una opcion: " OPCION
}

verificar_root
verificar_ip_estatica

while true; do
    mostrar_menu
    case $OPCION in
        1)
            instalar_bind9
            configurar_zona_dns
            ;;
        2)
            cambiar_dominio
            ;;
        3)
            eliminar_zona_dns
            ;;
        4)
            ver_estado
            ;;
        5)
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "ERROR: Opcion invalida. Elige entre 1 y 5."
            ;;
    esac
done
