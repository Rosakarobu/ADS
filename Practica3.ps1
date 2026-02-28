# ============================================
# Script de configuracion DNS - Windows Server
# Practica 3 - Administracion de Sistemas
# Rosa Karina Rosas Burgueno
# ============================================

# Colores
function ok   { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function err  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Yellow }

$global:IP_SERVIDOR = ""

# ============================================
# BLOQUE 1: Verificar Administrador
# ============================================
function Verificar-Admin {
    $admin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        err "Este script debe ejecutarse como Administrador."
        exit 1
    }
    ok "Ejecutando como Administrador."
}

# ============================================
# BLOQUE 2: Detectar IP del servidor
# ============================================
function Detectar-IP {
    Write-Host ""
    info "Interfaces de red disponibles:"
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" } | `
        Format-Table InterfaceAlias, IPAddress -AutoSize
    Write-Host ""

    $interfaz = Read-Host "Ingresa el nombre de la interfaz (ej: Ethernet 2)"
    $ip = (Get-NetIPAddress -InterfaceAlias $interfaz -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue).IPAddress

    if (-not $ip) {
        err "No se encontro IP en la interfaz '$interfaz'."
        $ip = Read-Host "Ingresa la IP manualmente"
    }

    $global:IP_SERVIDOR = $ip
    ok "IP del servidor DNS: $global:IP_SERVIDOR en $interfaz"
}

# ============================================
# BLOQUE 3: Instalar rol DNS
# ============================================
function Instalar-DNS {
    Write-Host ""
    Write-Host "=== Instalando rol DNS ==="

    $rol = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
    if ($rol.Installed) {
        ok "El rol DNS ya esta instalado."
    } else {
        info "Instalando rol DNS..."
        Install-WindowsFeature -Name DNS -IncludeManagementTools
        if ($?) {
            ok "Rol DNS instalado correctamente."
        } else {
            err "Fallo la instalacion del rol DNS."
            return
        }
    }


    if (-not $global:IP_SERVIDOR) { Detectar-IP }


    Configurar-IP


    Configurar-Firewall


    Iniciar-DNS
}

# ============================================
# BLOQUE 4: Configurar IP estatica
# ============================================
function Configurar-IP {
    Write-Host ""
    info "Interfaces de red disponibles:"
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" } | `
        Format-Table InterfaceAlias, IPAddress -AutoSize

    $interfaz = Read-Host "Interfaz de red interna (ej: Ethernet 2)"

    $ipActual = (Get-NetIPAddress -InterfaceAlias $interfaz `
        -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress

    if ($ipActual -and $ipActual -notlike "169.254.*") {
        ok "La interfaz '$interfaz' ya tiene IP: $ipActual"
        $global:IP_SERVIDOR = $ipActual
    } else {
        $nuevaIP = Read-Host "Ingresa la IP para el servidor (ej: 192.168.100.20)"
        $mascara  = Read-Host "Ingresa la mascara en prefijo (ej: 24)"


        Remove-NetIPAddress -InterfaceAlias $interfaz -Confirm:$false `
            -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceAlias $interfaz `
            -IPAddress $nuevaIP -PrefixLength $mascara | Out-Null


        Set-DnsClientServerAddress -InterfaceAlias $interfaz `
            -ServerAddresses $nuevaIP

        $global:IP_SERVIDOR = $nuevaIP
        ok "IP $nuevaIP configurada en '$interfaz'."
    }
}

# ============================================
# BLOQUE 5: Configurar firewall
# ============================================
function Configurar-Firewall {
    info "Abriendo puerto 53 en firewall..."

    $reglaUDP = Get-NetFirewallRule -DisplayName "DNS Puerto 53 UDP" `
        -ErrorAction SilentlyContinue
    if (-not $reglaUDP) {
        New-NetFirewallRule -DisplayName "DNS Puerto 53 UDP" `
            -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow | Out-Null
    }

    $reglaTCP = Get-NetFirewallRule -DisplayName "DNS Puerto 53 TCP" `
        -ErrorAction SilentlyContinue
    if (-not $reglaTCP) {
        New-NetFirewallRule -DisplayName "DNS Puerto 53 TCP" `
            -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow | Out-Null
    }

    ok "Puerto 53 abierto en firewall."
}

# ============================================
# BLOQUE 6: Iniciar servicio DNS
# ============================================
function Iniciar-DNS {
    Stop-Service -Name DNS -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Service -Name DNS

    $estado = (Get-Service -Name DNS).Status
    if ($estado -eq "Running") {
        ok "Servicio DNS activo y corriendo."
        Set-Service -Name DNS -StartupType Automatic
    } else {
        err "El servicio DNS no pudo iniciarse."
    }
}

# ============================================
# OPCION 1: Instalar y configurar DNS
# ============================================
function Menu-Instalar {
    Instalar-DNS
}

# ============================================
# OPCION 2: Reconfigurar DNS con IP actual
# ============================================
function Menu-Reconfigurar {
    Write-Host ""
    Write-Host "=== Reconfigurando DNS ==="

    Detectar-IP
    Configurar-Firewall
    Iniciar-DNS
}

# ============================================
# OPCION 3: Agregar dominio
# ============================================
function Menu-AgregarDominio {
    Write-Host ""
    Write-Host "=== Agregar dominio ==="


    if ((Get-Service -Name DNS -ErrorAction SilentlyContinue).Status -ne "Running") {
        info "Servicio DNS no esta corriendo. Iniciando..."
        Iniciar-DNS
    }

    if (-not $global:IP_SERVIDOR) { Detectar-IP }

    $zona     = Read-Host "Nombre del dominio (ej: reprobados.com)"
    $ipCliente = Read-Host "IP del cliente (ej: 192.168.100.101)"

    if (-not $zona -or -not $ipCliente) {
        err "El dominio y la IP son obligatorios."
        return
    }


    $zonaExiste = Get-DnsServerZone -Name $zona -ErrorAction SilentlyContinue
    if ($zonaExiste) {
        info "El dominio $zona ya existe."
        return
    }

    Add-DnsServerPrimaryZone -Name $zona -ZoneFile "$zona.dns" -DynamicUpdate None
    ok "Zona $zona creada."

    Add-DnsServerResourceRecordA -ZoneName $zona `
        -Name "@" -IPv4Address $ipCliente
    ok "Registro A: $zona → $ipCliente"


    Add-DnsServerResourceRecordA -ZoneName $zona `
        -Name "ns1" -IPv4Address $global:IP_SERVIDOR
    ok "Registro A: ns1.$zona → $global:IP_SERVIDOR"


    Add-DnsServerResourceRecordCName -ZoneName $zona `
        -Name "www" -HostNameAlias "$zona."
    ok "Registro CNAME: www.$zona → $zona"

    ok "Dominio $zona configurado correctamente apuntando a $ipCliente"
}

# ============================================
# OPCION 4: Ver dominios configurados
# ============================================
function Menu-VerDominios {
    Write-Host ""
    Write-Host "=== Dominios configurados ==="

    $zonas = Get-DnsServerZone -ErrorAction SilentlyContinue | `
        Where-Object { $_.ZoneType -eq "Primary" -and `
        $_.ZoneName -notmatch "arpa|localhost|TrustAnchors" }

    if (-not $zonas) {
        info "No hay dominios configurados."
        return
    }

    Write-Host ""
    $contador = 1
    foreach ($zona in $zonas) {
        $registroA = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName `
            -RRType A -ErrorAction SilentlyContinue | `
            Where-Object { $_.HostName -eq "@" }
        $ip = $registroA.RecordData.IPv4Address
        Write-Host "  $contador. $($zona.ZoneName) → $ip"
        $contador++
    }
}

# ============================================
# OPCION 5: Eliminar dominio
# ============================================
function Menu-EliminarDominio {
    Write-Host ""
    Write-Host "=== Eliminar dominio ==="

    Menu-VerDominios
    Write-Host ""

    $zonaEliminar = Read-Host "Dominio a eliminar"
    if (-not $zonaEliminar) {
        err "El dominio no puede estar vacio."
        return
    }

    $zonaExiste = Get-DnsServerZone -Name $zonaEliminar -ErrorAction SilentlyContinue
    if (-not $zonaExiste) {
        err "El dominio $zonaEliminar no existe."
        return
    }

    Remove-DnsServerZone -Name $zonaEliminar -Force
    ok "Dominio $zonaEliminar eliminado."
}

# ============================================
# OPCION 6: Ver estado del servicio
# ============================================
function Menu-VerEstado {
    Write-Host ""
    Write-Host "=== Estado del servicio DNS ==="

    $servicio = Get-Service -Name DNS -ErrorAction SilentlyContinue
    if ($servicio.Status -eq "Running") {
        ok "Servicio DNS: ACTIVO"
    } else {
        err "Servicio DNS: INACTIVO"
    }

    $rolInstalado = (Get-WindowsFeature -Name DNS).Installed
    if ($rolInstalado) {
        ok "Rol DNS: INSTALADO"
    } else {
        err "Rol DNS: NO INSTALADO"
    }

    Write-Host ""
    info "Zonas configuradas:"
    Menu-VerDominios

    Write-Host ""
    $dominio = Read-Host "Dominio a consultar (ej: reprobados.com)"
    if ($dominio) {
        Write-Host ""
        Resolve-DnsName -Name $dominio -Server $global:IP_SERVIDOR `
            -ErrorAction SilentlyContinue
    }
}

# ============================================
# MENU PRINCIPAL
# ============================================
function Mostrar-Menu {
    Write-Host ""
    Write-Host "----------------------------------"
    Write-Host "   Configuracion DNS - Windows"
    Write-Host "----------------------------------"
    Write-Host " 1. Instalar y configurar DNS"
    Write-Host " 2. Reconfigurar DNS con IP actual"
    Write-Host " 3. Agregar dominio"
    Write-Host " 4. Ver dominios configurados"
    Write-Host " 5. Eliminar dominio"
    Write-Host " 6. Ver estado del servicio"
    Write-Host " 0. Salir"
    Write-Host "----------------------------------"
    return Read-Host " Elige una opcion"
}

# ============================================
# INICIO
# ============================================
Verificar-Admin

while ($true) {
    $opcion = Mostrar-Menu
    switch ($opcion) {
        "1" { Menu-Instalar }
        "2" { Menu-Reconfigurar }
        "3" { Menu-AgregarDominio }
        "4" { Menu-VerDominios }
        "5" { Menu-EliminarDominio }
        "6" { Menu-VerEstado }
        "0" { Write-Host "Saliendo..."; exit 0 }
        default { err "Opcion invalida." }
    }
}
