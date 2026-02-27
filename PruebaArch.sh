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
        echo "OK: enp0s8 ya tiene IP: $IP_ACTUAL"
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

# --- Instalar y configurar BIND9 ---
instalar_bind9() {
    echo ""
    echo "=== Instalando y configurando BIND9 ==="

    if systemctl is-active --quiet named; then
        echo "OK: BIND9 ya esta instalado y corriendo. Se omite instalacion."
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

# --- Agregar dominio ---
agregar_dominio() {
    echo ""
    echo "=== Agregar nuevo dominio ==="

    read -p "Ingresa el nombre del dominio (ej: reprobados.com): " ZONA
    read -p "Ingresa la IP a la que apuntara el dominio (ej: 192.168.100.30): " IP_CLIENTE

    if [ -z "$ZONA" ] || [ -z "$IP_CLIENTE" ]; then
        echo "ERROR: El dominio y la IP no pueden estar vacios."
        return
    fi

    ARCHIVO_ZONA="/var/named/$ZONA.zone"

    if grep -q "zone \"$ZONA\"" /etc/named.conf 2>/dev/null; then
        echo "AVISO: El dominio $ZONA ya existe. Use la opcion 4 para eliminarlo primero."
        return
    fi

    cat >> /etc/named.conf << EOF

zone "$ZONA" IN {
    type master;
    file "$ARCHIVO_ZONA";
    allow-update { none; };
};
EOF
    echo "OK: Zona $ZONA agregada a named.conf"

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
    systemctl restart named
    echo "OK: Dominio $ZONA agregado correctamente apuntando a $IP_CLIENTE"
}

# --- Ver dominios configurados ---
ver_dominios() {
    echo ""
    echo "=== Dominios configurados ==="

    # Buscar solo las zonas del usuario (ignorar las de BIND9 por defecto)
    ZONAS=$(grep "^zone" /etc/named.conf | awk '{print $2}' | tr -d '"' | grep -v "arpa\|localhost\|example")

    if [ -z "$ZONAS" ]; then
        echo "AVISO: No hay dominios configurados todavia."
    else
        echo "Dominios encontrados:"
        echo ""
        CONTADOR=1
        for ZONA in $ZONAS; do
            ARCHIVO="/var/named/$ZONA.zone"
            if [ -f "$ARCHIVO" ]; then
                IP=$(grep "^@" "$ARCHIVO" | grep " A " | awk '{print $4}')
                echo "  $CONTADOR. $ZONA → $IP"
            else
                echo "  $CONTADOR. $ZONA → (archivo de zona no encontrado)"
            fi
            CONTADOR=$((CONTADOR + 1))
        done
    fi
}

# --- Eliminar dominio ---
eliminar_dominio() {
    echo ""
    echo "=== Eliminar dominio ==="

    ver_dominios

    echo ""
    read -p "Ingresa el dominio que deseas eliminar: " ZONA_ELIMINAR

    if [ -z "$ZONA_ELIMINAR" ]; then
        echo "ERROR: El dominio no puede estar vacio."
        return
    fi

    if ! grep -q "zone \"$ZONA_ELIMINAR\"" /etc/named.conf 2>/dev/null; then
        echo "ERROR: El dominio $ZONA_ELIMINAR no existe."
        return
    fi

    ARCHIVO_ZONA="/var/named/$ZONA_ELIMINAR.zone"

    if [ -f "$ARCHIVO_ZONA" ]; then
        rm -f "$ARCHIVO_ZONA"
        echo "OK: Archivo de zona eliminado."
    fi

    sed -i "/zone \"$ZONA_ELIMINAR\"/,/};/d" /etc/named.conf
    echo "OK: Zona $ZONA_ELIMINAR eliminada de named.conf"

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
        echo "Intenta iniciarlo con: systemctl start named"
    fi

    echo ""
    read -p "Ingresa el dominio a consultar (ej: reprobados.com): " DOMINIO_TEST

    if [ -z "$DOMINIO_TEST" ]; then
        echo "ERROR: El dominio no puede estar vacio."
        return
    fi

    echo ""
    echo "--- nslookup $DOMINIO_TEST ---"
    nslookup $DOMINIO_TEST 127.0.0.1
}

mostrar_menu() {
    echo ""
    echo "----------------------------------"
    echo "   Configuracion DNS"
    echo "----------------------------------"
    echo " 1. Instalar y configurar BIND9"
    echo " 2. Agregar dominio"
    echo " 3. Ver dominios configurados"
    echo " 4. Eliminar dominio"
    echo " 5. Ver estado del servicio"
    echo " 6. Salir"
    echo "----------------------------------"
    read -p " Elige una opcion: " OPCION
}

verificar_root
verificar_ip_estatica

while true; do
    mostrar_menu
    case $OPCION in
        1)
            instalar_bind9
            ;;
        2)
            agregar_dominio
            ;;
        3)
            ver_dominios
            ;;
        4)
            eliminar_dominio
            ;;
        5)
            ver_estado
            ;;
        6)
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "ERROR: Opcion invalida. Elige entre 1 y 6."
            ;;
    esac
done
