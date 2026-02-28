# Practica 2 - Automatización y Gestión del Servidor DHCP
# Windows Server 2022
# Rosa Karina Rosas Burgueño

$VERDE   = "Green"
$ROJO    = "Red"
$AMARILLO = "Yellow"
$NC      = "White"

function ok   { param($m) Write-Host "[OK] $m"    -ForegroundColor $VERDE }
function err  { param($m) Write-Host "[ERROR] $m" -ForegroundColor $ROJO }
function info { param($m) Write-Host "[INFO] $m"  -ForegroundColor $AMARILLO }

# Verificar
function verificar_instalacion {
    Write-Host ""
    Write-Host "--- Verificando instalacion DHCP ---"

    $rol = Get-WindowsFeature -Name DHCP

    if ($rol.InstallState -eq "Installed") {
        ok "El rol DHCP esta instalado."
        Write-Host ""
        info "Estado del servicio:"
        $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        if ($svc.Status -eq "Running") {
            ok "Servicio DHCPServer: ACTIVO"
        } else {
            err "Servicio DHCPServer: INACTIVO"
        }
    } else {
        err "El rol DHCP NO esta instalado."
    }
    Write-Host ""
}

# instalar
function instalar_dhcp {
    Write-Host ""
    Write-Host "--- Instalacion de DHCP ---"

    $rol = Get-WindowsFeature -Name DHCP

    if ($rol.InstallState -eq "Installed") {
        ok "El rol DHCP ya esta instalado, no se necesita hacer nada."
        Write-Host ""
        return
    }

    info "Instalando rol DHCP..."
    Install-WindowsFeature -Name DHCP -IncludeManagementTools

    $rol = Get-WindowsFeature -Name DHCP
    if ($rol.InstallState -eq "Installed") {
        ok "Rol DHCP instalado correctamente."
    } else {
        err "Fallo la instalacion."
        return
    }
    Write-Host ""
}

# validar IP
function validar_ip {
    param($ip)

    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        err "Formato invalido. Usa el formato: X.X.X.X"
        return $false
    }

    $nums = $ip -split '\.'
    foreach ($n in $nums) {
        if ([int]$n -lt 0 -or [int]$n -gt 255) {
            err "Numero fuera de rango (0-255): $n"
            return $false
        }
    }

    if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255") {
        err "Esa IP no es valida."
        return $false
    }

    return $true
}

# configurar servidor dhcp
function configurar_dhcp {
    Write-Host ""
    Write-Host "--- Configuracion del servidor DHCP ---"
    Write-Host ""

    $SCOPE = Read-Host "Nombre del ambito (scope)"
    if ([string]::IsNullOrEmpty($SCOPE)) { $SCOPE = "MiServidor" }

    do {
        $IP_INICIO = Read-Host "IP de inicio del rango"
    } while (-not (validar_ip $IP_INICIO))

    do {
        $IP_FIN = Read-Host "IP de fin del rango"
        $ipValida = validar_ip $IP_FIN
        if ($ipValida) {
            $oct1 = $IP_INICIO -split '\.'; $oct2 = $IP_FIN -split '\.'
            $N1 = [int]$oct1[0]*16777216 + [int]$oct1[1]*65536 + [int]$oct1[2]*256 + [int]$oct1[3]
            $N2 = [int]$oct2[0]*16777216 + [int]$oct2[1]*65536 + [int]$oct2[2]*256 + [int]$oct2[3]
            if ($N2 -le $N1) {
                err "La IP final debe ser mayor que la IP inicial."
                $ipValida = $false
            }
        }
    } while (-not $ipValida)

    do {
        $LEASE = Read-Host "Tiempo de concesion en segundos"
        $leaseValido = $LEASE -match '^\d+$' -and [int]$LEASE -gt 0
        if (-not $leaseValido) { err "Ingresa un numero valido mayor a 0." }
    } while (-not $leaseValido)

    do {
        $GATEWAY = Read-Host "Gateway/puerta de enlace (Enter para omitir)"
        if ([string]::IsNullOrEmpty($GATEWAY)) {
            info "Sin gateway configurado."
            break
        }
    } while (-not (validar_ip $GATEWAY))

    do {
        $DNS = Read-Host "DNS principal (Enter para omitir)"
        if ([string]::IsNullOrEmpty($DNS)) {
            info "Sin DNS configurado."
            break
        }
    } while (-not (validar_ip $DNS))

    $oct = $IP_INICIO -split '\.'
    $RED       = "$($oct[0]).$($oct[1]).$($oct[2]).0"
    $MASCARA   = "255.255.255.0"
    $IP_SERVIDOR     = $IP_INICIO
    $IP_RANGO_INICIO = "$($oct[0]).$($oct[1]).$($oct[2]).$([int]$oct[3] + 1)"

    Write-Host ""
    Write-Host "-------------------------------"
    Write-Host "   RESUMEN DE CONFIGURACION"
    Write-Host "-------------------------------"
    Write-Host "  Scope     : $SCOPE"
    Write-Host "  Red       : $RED/24"
    Write-Host "  Mascara   : $MASCARA"
    Write-Host "  Rango     : $IP_INICIO - $IP_FIN"
    Write-Host "  Lease     : $LEASE segundos"
    Write-Host "  Gateway   : $(if([string]::IsNullOrEmpty($GATEWAY)){'(sin gateway)'}else{$GATEWAY})"
    Write-Host "  DNS       : $(if([string]::IsNullOrEmpty($DNS)){'(sin DNS)'}else{$DNS})"
    Write-Host "  IP servidor: $IP_SERVIDOR"
    Write-Host "--------------------------------"
    Write-Host ""

    $CONF = Read-Host "¿Aplicar esta configuracion? (s/n)"
    if ($CONF -notmatch '^[Ss]$') {
        info "Cancelado."
        return
    }

    try {
        info "Creando scope DHCP..."
        Add-DhcpServerv4Scope `
            -Name       $SCOPE `
            -StartRange $IP_RANGO_INICIO `
            -EndRange   $IP_FIN `
            -SubnetMask $MASCARA `
            -State      Active
        ok "Scope creado."

        if (-not [string]::IsNullOrEmpty($GATEWAY)) {
            info "Configurando gateway..."
            Set-DhcpServerv4OptionValue -ScopeId $RED -OptionId 3 -Value $GATEWAY
            ok "Gateway configurado."
        }

        if (-not [string]::IsNullOrEmpty($DNS)) {
            info "Configurando DNS..."
            Set-DhcpServerv4OptionValue -ScopeId $RED -OptionId 6 -Value $DNS
            ok "DNS configurado."
        }

        info "Configurando tiempo de concesion..."
        $duracion = New-TimeSpan -Seconds ([int]$LEASE)
        Set-DhcpServerv4Scope -ScopeId $RED -LeaseDuration $duracion
        ok "Lease time configurado."

        info "Asignando IP $IP_SERVIDOR a la interfaz interna..."
        $adaptador = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -like "*Ethernet 2*" }
        if ($adaptador) {
            # Eliminar IPs previas en esa interfaz
            Remove-NetIPAddress -InterfaceAlias $adaptador.Name -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceAlias $adaptador.Name -IPAddress $IP_SERVIDOR -PrefixLength 24 | Out-Null
            ok "IP $IP_SERVIDOR asignada a $($adaptador.Name)."
        } else {
            info "No se encontro 'Ethernet 2'. Asigna la IP manualmente si es necesario."
        }

        info "Iniciando servicio DHCP..."
        Start-Service DHCPServer
        Set-Service  DHCPServer -StartupType Automatic
        Start-Sleep -Seconds 2

        if ((Get-Service DHCPServer).Status -eq "Running") {
            ok "¡Servidor DHCP activo y funcionando!"
        } else {
            err "El servicio no inicio. Revisa el Visor de Eventos."
        }

    } catch {
        err "Error durante la configuracion: $_"
    }
    Write-Host ""
}

# Monitoriar concesiones activas
function monitorear_concesiones {
    Write-Host ""
    Write-Host "--- Concesiones activas ---"
    Write-Host ""

    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if (-not $scopes) {
        err "No hay scopes configurados."
        Write-Host ""
        return
    }

    $total = 0
    foreach ($scope in $scopes) {
        $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
        if ($leases) {
            Write-Host "  IP asignada          MAC                  Hostname"
            Write-Host "  -----------------------------------------------------------"
            foreach ($lease in $leases) {
                Write-Host ("  {0,-20} {1,-20} {2}" -f $lease.IPAddress, $lease.ClientId, $lease.HostName)
                $total++
            }
        }
    }

    Write-Host ""
    Write-Host "  Total de concesiones activas: $total"
    Write-Host ""
}


# Monitorear estado del servidor
function monitorear_estado {
    Write-Host ""
    Write-Host "--- Estado del servidor DHCP ---"
    Write-Host ""

    $rol = Get-WindowsFeature -Name DHCP
    if ($rol.InstallState -eq "Installed") {
        ok "Rol DHCP: INSTALADO"
    } else {
        err "Rol DHCP: NO INSTALADO"
    }

    Write-Host ""
    $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if ($svc.Status -eq "Running") {
        ok "Servicio DHCPServer: ACTIVO"
    } else {
        err "Servicio DHCPServer: INACTIVO"
    }

    if ($svc.StartType -eq "Automatic") {
        ok "Inicio automatico: HABILITADO"
    } else {
        info "Inicio automatico: deshabilitado"
    }

    Write-Host ""
    Write-Host "--- Informacion detallada del servicio ---"
    Get-Service DHCPServer | Format-List Name, Status, StartType
    Write-Host ""
    Write-Host "--- Scopes configurados ---"
    Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Format-Table ScopeId, Name, StartRange, EndRange, State -AutoSize
    Write-Host ""
}

# Apagar el servidor DHCP
function apagar_dhcp {
    Write-Host ""
    Write-Host "--- Apagar servidor DHCP ---"
    Write-Host ""

    $RESP = Read-Host "¿Esta seguro que desea detener el servidor DHCP? (s/n)"
    if ($RESP -notmatch '^[Ss]$') {
        info "Cancelado."
        Write-Host ""
        return
    }

    info "Deteniendo servidor DHCP..."
    Stop-Service DHCPServer -Force

    Start-Sleep -Seconds 2
    if ((Get-Service DHCPServer).Status -ne "Running") {
        ok "Servidor DHCP detenido exitosamente."
    } else {
        err "No se pudo detener el servidor."
    }

    Write-Host ""
    $DESH = Read-Host "¿Deshabilitar el inicio automatico tambien? (s/n)"
    if ($DESH -match '^[Ss]$') {
        Set-Service DHCPServer -StartupType Disabled
        ok "Inicio automatico deshabilitado."
    }
    Write-Host ""
}

# Menu
function menu {
    while ($true) {
        Clear-Host
        Write-Host "------------------------------------"
        Write-Host "      Gestor Servidor DHCP"
        Write-Host "------------------------------------"
        Write-Host ""
        Write-Host "  1. Verificar instalacion"
        Write-Host "  2. Instalar servidor"
        Write-Host "  3. Configurar DHCP"
        Write-Host "  4. Monitorear Concesiones activas"
        Write-Host "  5. Monitorear estado del servidor"
        Write-Host "  6. Apagar servidor DHCP"
        Write-Host "  0. Salir del menu"
        Write-Host ""
        Write-Host "------------------------------------"
        $OPC = Read-Host "Seleccione una opcion"
        Write-Host ""

        switch ($OPC) {
            "1" { verificar_instalacion }
            "2" { instalar_dhcp }
            "3" { configurar_dhcp }
            "4" { monitorear_concesiones }
            "5" { monitorear_estado }
            "6" { apagar_dhcp }
            "0" { Write-Host "Saliendo..."; exit }
            default { err "Opcion invalida." }
        }

        Read-Host "Presiona Enter para continuar"
    }
}

menu
