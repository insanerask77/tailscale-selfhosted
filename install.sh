#!/usr/bin/env bash

# =============================================================================
# HEADSCALE + HEADPLANE - INSTALADOR INTERACTIVO
# =============================================================================
# Instalador todo-en-uno para Headscale (control plane) + Headplane (Web UI)
# Uso: ./install.sh
#
# Características:
# - Detección y validación de dependencias
# - Configuración interactiva con valores por defecto sensatos
# - Generación automática de secretos
# - Soporte para SSL (Let's Encrypt o certificado autofirmado)
# - Integración OIDC opcional
# - Idempotente: puede ejecutarse múltiples veces para reconfigurar
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIABLES GLOBALES
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
DATA_DIR="${SCRIPT_DIR}/data"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# -----------------------------------------------------------------------------
# FUNCIONES DE UTILIDAD
# -----------------------------------------------------------------------------

# Imprimir mensajes con color
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Preguntar sí/no con valor por defecto
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [S/n]"
    else
        prompt="$prompt [s/N]"
    fi

    while true; do
        read -p "$(echo -e "${CYAN}?${NC} $prompt: ")" response
        response="${response:-$default}"
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        case "$response" in
            y|s|yes|si|sí)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                print_warning "Por favor responde 's' (sí) o 'n' (no)"
                ;;
        esac
    done
}

# Preguntar input con valor por defecto y validación opcional
ask_input() {
    local prompt="$1"
    local default="$2"
    local validate_func="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        prompt="$prompt [${default}]"
    fi

    while true; do
        read -p "$(echo -e "${CYAN}?${NC} $prompt: ")" value
        value="${value:-$default}"

        # Si hay función de validación, usarla
        if [[ -n "$validate_func" ]] && type "$validate_func" &>/dev/null; then
            if $validate_func "$value"; then
                echo "$value"
                return 0
            else
                print_warning "Valor inválido, intenta de nuevo"
                continue
            fi
        fi

        # Si no está vacío, aceptar
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        else
            print_warning "Este campo no puede estar vacío"
        fi
    done
}

# Menú numerado. Imprime en stderr para no contaminar la captura por $(...)
# y devuelve por stdout la clave elegida. Uso:
#   ask_choice "Pregunta" "actual" "clave1|Título|Descripción" "clave2|..."
ask_choice() {
    local prompt="$1"
    local current="$2"
    shift 2
    local options=("$@")
    local n=${#options[@]}
    local default_idx=1
    local i key title desc choice

    for i in "${!options[@]}"; do
        IFS='|' read -r key title desc <<< "${options[$i]}"
        [[ "$key" == "$current" ]] && default_idx=$((i + 1))
    done

    {
        echo ""
        echo -e "${CYAN}${BOLD}${prompt}${NC}"
        echo ""
        for i in "${!options[@]}"; do
            IFS='|' read -r key title desc <<< "${options[$i]}"
            echo -e "  ${BOLD}$((i + 1))${NC}) ${BOLD}${title}${NC}"
            echo -e "     ${desc}"
        done
        echo ""
    } >&2

    while true; do
        read -r -p "$(echo -e "${CYAN}?${NC} Elige una opción [1-${n}] [${default_idx}]: ")" choice >&2
        choice="${choice:-$default_idx}"

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            IFS='|' read -r key title desc <<< "${options[$((choice - 1))]}"
            echo "$key"
            return 0
        fi
        print_warning "Opción inválida, elige un número entre 1 y ${n}" >&2
    done
}

# Validar un CIDR IPv4/IPv6. Headscale rechaza los prefijos /0 en
# trusted_proxies, así que aquí se rechazan también para fallar antes.
validate_cidr() {
    local input="$1"

    if [[ ! "$input" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]]; then
        print_error "Formato inválido: se espera un CIDR, por ejemplo 192.168.1.10/32"
        return 1
    fi

    local bits="${input##*/}"
    if [[ "$bits" == "0" ]]; then
        print_error "Headscale no admite el prefijo /0 en trusted_proxies"
        return 1
    fi

    return 0
}

# Validar dominio o IP
validate_domain_or_ip() {
    local input="$1"

    # Validar IP (simplificado)
    if [[ "$input" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi

    # Validar dominio (simplificado)
    if [[ "$input" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi

    # Validar localhost
    if [[ "$input" == "localhost" ]]; then
        return 0
    fi

    return 1
}

# Validar puerto
validate_port() {
    local port="$1"

    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi

    return 1
}

# Validar email
validate_email() {
    local email="$1"

    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi

    return 1
}

# Validar nombre alfanumérico
validate_alphanumeric() {
    local name="$1"

    if [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi

    return 1
}

# Validar URL
validate_url() {
    local url="$1"

    if [[ "$url" =~ ^https?:// ]]; then
        return 0
    fi

    return 1
}

# Generar secreto aleatorio
generate_secret() {
    local length="${1:-64}"
    openssl rand -hex "$length" 2>/dev/null || \
        head -c "$length" /dev/urandom | xxd -p | tr -d '\n'
}

# -----------------------------------------------------------------------------
# FUNCIONES DE VERIFICACIÓN DE DEPENDENCIAS
# -----------------------------------------------------------------------------

check_command() {
    command -v "$1" &>/dev/null
}

install_docker() {
    print_info "Intentando instalar Docker..."

    # Detectar distribución
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "No se pudo detectar la distribución del sistema"
        return 1
    fi

    case "$OS" in
        ubuntu|debian)
            print_info "Instalando Docker en Debian/Ubuntu..."
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gnupg
            sudo install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        fedora|rhel|centos)
            print_info "Instalando Docker en Fedora/RHEL/CentOS..."
            sudo dnf -y install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        arch)
            print_info "Instalando Docker en Arch Linux..."
            sudo pacman -Sy --noconfirm docker docker-compose
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        *)
            print_error "Distribución no soportada para instalación automática: $OS"
            print_info "Por favor instala Docker manualmente: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac

    # Agregar usuario actual al grupo docker
    if ! groups | grep -q docker; then
        print_info "Agregando usuario actual al grupo docker..."
        sudo usermod -aG docker "$USER"
        print_warning "Debes cerrar sesión y volver a entrar para que el cambio de grupo surta efecto"
        print_warning "O ejecuta: newgrp docker"
    fi

    print_success "Docker instalado correctamente"
    return 0
}

check_dependencies() {
    print_header "VERIFICACIÓN DE DEPENDENCIAS"

    local missing_deps=()

    # Verificar Docker
    if ! check_command docker; then
        print_warning "Docker no está instalado"
        if ask_yes_no "¿Deseas instalar Docker automáticamente?" "y"; then
            if ! install_docker; then
                missing_deps+=("docker")
            fi
        else
            missing_deps+=("docker")
        fi
    else
        print_success "Docker está instalado"

        # Verificar que Docker daemon esté corriendo
        if ! docker info &>/dev/null; then
            print_warning "Docker daemon no está corriendo"
            print_info "Intentando iniciar Docker..."
            sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || {
                print_error "No se pudo iniciar Docker daemon. Inícialo manualmente."
                missing_deps+=("docker-daemon")
            }
        fi
    fi

    # Verificar Docker Compose (plugin)
    if ! docker compose version &>/dev/null; then
        print_warning "Docker Compose plugin no está instalado"
        missing_deps+=("docker-compose")
    else
        print_success "Docker Compose plugin está instalado"
    fi

    # Verificar openssl (para generar secretos)
    if ! check_command openssl; then
        print_warning "OpenSSL no está instalado (necesario para generar secretos)"
        missing_deps+=("openssl")
    fi

    # Si hay dependencias faltantes, salir
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "Faltan las siguientes dependencias: ${missing_deps[*]}"
        print_info "Por favor instálalas manualmente y vuelve a ejecutar el instalador"
        exit 1
    fi

    print_success "Todas las dependencias están instaladas"
}

# -----------------------------------------------------------------------------
# FUNCIONES DE CONFIGURACIÓN
# -----------------------------------------------------------------------------

load_existing_config() {
    if [ -f "$ENV_FILE" ]; then
        print_info "Encontrado archivo de configuración existente"
        if ask_yes_no "¿Deseas cargar la configuración existente?" "y"; then
            # Cargar variables existentes
            set -a
            source "$ENV_FILE"
            set +a
            return 0
        fi
    fi
    return 1
}

# El modo de despliegue determina tres cosas que antes iban mezcladas en
# ENABLE_SSL: quién termina TLS, si arranca Caddy, y si hay uno o dos dominios.
#
#   standalone   Caddy embebido enruta / y /admin. Con TLS o sin él.
#   proxy-single Proxy externo termina TLS. Un dominio, UI en /admin.
#   proxy-split  Proxy externo termina TLS. Dominios separados (requiere CORS).
#   plain        Sin Caddy y sin TLS. Puertos crudos. Sólo LAN/desarrollo.
configure_deployment_mode() {
    print_header "MODO DE DESPLIEGUE"

    DEPLOY_MODE=$(ask_choice "¿Cómo se va a exponer este stack?" "${DEPLOY_MODE:-standalone}" \
        "standalone|Todo-en-uno con Caddy incluido|Caddy enruta un solo dominio: / -> Headscale, /admin -> Headplane. El certificado se elige después y puede ser ninguno (http://)." \
        "proxy-single|Detrás de un proxy externo, un dominio|Nginx Proxy Manager/Traefik termina TLS. Un dominio: / -> Headscale, /admin -> Headplane. Sin CORS." \
        "proxy-split|Detrás de un proxy externo, dominios separados|Un dominio para el control plane y otro para la UI. Necesita cabeceras CORS en el proxy." \
        "plain|Sin Caddy: puertos crudos|Headscale y Headplane publicados en puertos distintos, sin cifrar y sin enrutado por ruta. Sólo depuración y LAN de confianza.")

    case "$DEPLOY_MODE" in
        standalone)
            # URL_SCHEME queda pendiente: depende del certificado, que se
            # elige en configure_network.
            RUN_CADDY="true";  URL_SCHEME="https"; SPLIT_DOMAINS="false" ;;
        proxy-single)
            RUN_CADDY="false"; URL_SCHEME="https"; SPLIT_DOMAINS="false"; SSL_MODE="external" ;;
        proxy-split)
            RUN_CADDY="false"; URL_SCHEME="https"; SPLIT_DOMAINS="true";  SSL_MODE="external" ;;
        plain)
            RUN_CADDY="false"; URL_SCHEME="http";  SPLIT_DOMAINS="false"; SSL_MODE="none" ;;
    esac

    # ENABLE_SSL se conserva porque docker-compose lo usa para el profile y
    # varios sitios lo consultan, pero ahora significa "arranca Caddy", no
    # "hay HTTPS": con proxy externo hay HTTPS y Caddy NO debe arrancar.
    ENABLE_SSL="$RUN_CADDY"

    print_success "Modo de despliegue: ${DEPLOY_MODE}"
}

configure_network() {
    print_header "CONFIGURACIÓN DE RED Y ACCESO"

    if [[ "$SPLIT_DOMAINS" == "true" ]]; then
        print_info "Dominio del control plane: el que usarán los clientes en --login-server"
        print_info "Ejemplo: ts.midominio.com"
        HEADSCALE_DOMAIN=$(ask_input "Dominio de Headscale" \
            "${HEADSCALE_DOMAIN:-${DOMAIN:-ts.example.com}}" "validate_domain_or_ip")

        print_info "Dominio de la interfaz web (distinto del anterior)"
        print_info "Ejemplo: admin.ts.midominio.com"
        HEADPLANE_DOMAIN=$(ask_input "Dominio de Headplane" \
            "${HEADPLANE_DOMAIN:-admin.${HEADSCALE_DOMAIN}}" "validate_domain_or_ip")

        if [[ "$HEADPLANE_DOMAIN" == "$HEADSCALE_DOMAIN" ]]; then
            print_error "Los dos dominios no pueden ser iguales en modo proxy-split"
            print_info "Usa el modo 'proxy-single' si quieres compartir dominio"
            exit 1
        fi

        # DOMAIN se mantiene por compatibilidad con el resto del script
        DOMAIN="$HEADSCALE_DOMAIN"
    else
        print_info "Dominio o IP para acceder al servicio"
        print_info "Ejemplos: vpn.midominio.com, 192.168.1.100"
        DOMAIN=$(ask_input "Dominio o IP" "${DOMAIN:-vpn.example.com}" "validate_domain_or_ip")
        HEADSCALE_DOMAIN="$DOMAIN"
        HEADPLANE_DOMAIN="$DOMAIN"
    fi

    # El tipo de certificado sólo se pregunta cuando Caddy es quien lo emite.
    # "none" no desactiva Caddy: sigue enrutando / y /admin, sólo que por HTTP.
    if [[ "$RUN_CADDY" == "true" ]]; then
        # Let's Encrypt no emite para IPs ni para localhost, así que en esos
        # casos ni se ofrece en vez de dejar que falle el reto ACME.
        local cert_options=()
        if [[ "$DOMAIN" =~ ^[0-9.]+$ ]] || [[ "$DOMAIN" == "localhost" ]]; then
            print_warning "Has indicado una IP o localhost: Let's Encrypt no emite certificados para eso"
        else
            cert_options+=("letsencrypt|Let's Encrypt|Certificado público y de confianza para ${DOMAIN}. Requiere que su DNS ya apunte aquí y que los puertos 80 y 443 sean accesibles desde internet.")
        fi
        cert_options+=("selfsigned|Autofirmado (CA interna de Caddy)|HTTPS sin dependencias externas. Hay que instalar la CA en cada cliente Tailscale o no conectarán.")
        cert_options+=("none|Ninguno: sólo HTTP|Caddy sigue enrutando / y /admin, pero sin cifrar: http://${DOMAIN}. Para acceso local o por VPN ya existente.")

        SSL_MODE=$(ask_choice "¿Qué certificado debe usar Caddy?" \
            "${SSL_MODE:-letsencrypt}" "${cert_options[@]}")

        case "$SSL_MODE" in
            letsencrypt)
                URL_SCHEME="https"
                print_info "Let's Encrypt necesita un email para avisos de renovación"
                ACME_EMAIL=$(ask_input "Email para Let's Encrypt" "${ACME_EMAIL:-admin@${DOMAIN}}" "validate_email")
                ;;
            selfsigned)
                URL_SCHEME="https"
                print_info "Se usará un certificado autofirmado"
                print_warning "Tendrás que instalar la CA en cada cliente Tailscale (se exporta al final)"
                ;;
            none)
                URL_SCHEME="http"
                print_info "Caddy escuchará en HTTP y enrutará / y /admin sin certificado"
                ;;
        esac
    fi

    if [[ "$URL_SCHEME" == "http" ]]; then
        print_warning "ADVERTENCIA: el plano de control viajará sin cifrar"
        print_warning "No expongas esto a internet"
    fi

    print_success "Configuración de red completada"
}

# En los modos con proxy externo, Headscale ve todas las peticiones con la IP
# del proxy. trusted_proxies (Headscale 0.29+) activa el middleware de IP real
# para que los logs y las ACL vean la IP del cliente.
# Además hay que decidir a qué interfaz se publican los puertos: dejarlos en
# 0.0.0.0 los expone a toda la red, no sólo al proxy.
configure_proxy_access() {
    [[ "$RUN_CADDY" == "true" ]] && return 0

    print_header "ACCESO DESDE EL PROXY / RED"

    if [[ "$DEPLOY_MODE" == "plain" ]]; then
        BIND_ADDRESS=$(ask_input "Interfaz donde publicar los puertos (0.0.0.0 = todas)" \
            "${BIND_ADDRESS:-0.0.0.0}")
        PROXY_CIDR=""
        return 0
    fi

    print_info "El proxy corre en otra máquina y debe poder alcanzar estos puertos."
    print_info "Publicarlos en 0.0.0.0 los deja accesibles a toda la red;"
    print_info "indica la IP de esta máquina en la red del proxy para limitarlo."
    BIND_ADDRESS=$(ask_input "Interfaz donde publicar los puertos" "${BIND_ADDRESS:-0.0.0.0}")

    if [[ "$BIND_ADDRESS" == "0.0.0.0" ]]; then
        print_warning "Los puertos ${HEADSCALE_HTTP_PORT:-8080} y ${HEADPLANE_PORT:-3000} quedarán"
        print_warning "accesibles sin cifrar desde cualquier host que llegue a esta máquina."
        print_warning "Protégelos con firewall si la red no es de confianza."
    fi

    echo ""
    print_info "IP o rango del proxy, en notación CIDR. Headscale confiará en sus"
    print_info "cabeceras X-Forwarded-For para registrar la IP real del cliente."
    print_info "Ejemplos: 192.168.1.50/32 (una IP), 192.168.1.0/24 (una red)"
    PROXY_CIDR=$(ask_input "CIDR del proxy" "${PROXY_CIDR:-192.168.1.0/24}" "validate_cidr")

    # El proxy está en otra máquina y necesita una dirección con la que llegar
    # aquí. No se puede deducir; se ofrece la IP local como pista.
    echo ""
    local guess
    guess=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
    print_info "Dirección de ESTA máquina tal como la ve el proxy (destino del reverse proxy)"
    BACKEND_HOST=$(ask_input "IP o hostname de esta máquina" \
                             "${BACKEND_HOST:-${guess:-192.168.1.10}}")

    print_success "Acceso configurado"
}

configure_ports() {
    print_header "CONFIGURACIÓN DE PUERTOS"

    print_info "Puertos por defecto recomendados. Presiona Enter para usar los valores por defecto."

    if [[ "$RUN_CADDY" == "true" ]]; then
        if [[ "$SSL_MODE" == "none" ]]; then
            # Sin TLS, Caddy sólo escucha en HTTP: preguntar por el puerto
            # HTTPS sería ofrecer un puerto que nadie va a abrir.
            HTTP_PORT=$(ask_input "Puerto HTTP (donde escuchará Caddy)" "${HTTP_PORT:-80}" "validate_port")
            HTTPS_PORT="443"
        else
            HTTP_PORT=$(ask_input "Puerto HTTP (para redirección a HTTPS)" "${HTTP_PORT:-80}" "validate_port")
            HTTPS_PORT=$(ask_input "Puerto HTTPS" "${HTTPS_PORT:-443}" "validate_port")
        fi
        HEADPLANE_PORT="3000"  # Interno, sólo accesible por Caddy
    else
        # Sin Caddy, estos dos puertos se publican en el host: son los que el
        # proxy externo (o el cliente, en modo plain) tiene que alcanzar.
        print_info "Estos puertos se publicarán en el host para que los alcance el proxy"
        HEADPLANE_PORT=$(ask_input "Puerto web de Headplane" "${HEADPLANE_PORT:-3000}" "validate_port")
        HTTP_PORT="80"
        HTTPS_PORT="443"
    fi

    HEADSCALE_GRPC_PORT=$(ask_input "Puerto gRPC de Headscale (interno)" "${HEADSCALE_GRPC_PORT:-50443}" "validate_port")
    HEADSCALE_HTTP_PORT=$(ask_input "Puerto HTTP API de Headscale (interno)" "${HEADSCALE_HTTP_PORT:-8080}" "validate_port")
    HEADSCALE_DERP_PORT=$(ask_input "Puerto DERP/STUN de Headscale (UDP, debe ser accesible)" "${HEADSCALE_DERP_PORT:-3478}" "validate_port")
    HEADSCALE_METRICS_PORT=$(ask_input "Puerto Metrics de Headscale (interno)" "${HEADSCALE_METRICS_PORT:-9090}" "validate_port")

    print_success "Configuración de puertos completada"
}

# Las URLs públicas dependen del modo, del dominio Y de los puertos, así que
# sólo pueden calcularse después de configure_ports.
#
# Importante: son las URLs que ve el MUNDO, no las internas. En los modos con
# proxy, Headscale y Headplane siguen hablando HTTP por la red de Docker, pero
# anuncian https://... porque es lo que el cliente resuelve.
compute_public_urls() {
    case "$DEPLOY_MODE" in
        standalone)
            # Caddy sirve ambos en el mismo dominio y enruta por ruta. Sin
            # certificado escucha en HTTP_PORT; con él, en HTTPS_PORT.
            local suffix=""
            if [[ "$SSL_MODE" == "none" ]]; then
                [[ "$HTTP_PORT" != "80" ]] && suffix=":${HTTP_PORT}"
                HEADSCALE_PUBLIC_URL="http://${DOMAIN}${suffix}"
            else
                [[ "$HTTPS_PORT" != "443" ]] && suffix=":${HTTPS_PORT}"
                HEADSCALE_PUBLIC_URL="https://${DOMAIN}${suffix}"
            fi
            HEADPLANE_PUBLIC_URL="$HEADSCALE_PUBLIC_URL"
            ;;
        proxy-single)
            # El proxy externo escucha en 443 estándar; sin puerto en la URL.
            HEADSCALE_PUBLIC_URL="https://${HEADSCALE_DOMAIN}"
            HEADPLANE_PUBLIC_URL="https://${HEADSCALE_DOMAIN}"
            ;;
        proxy-split)
            HEADSCALE_PUBLIC_URL="https://${HEADSCALE_DOMAIN}"
            HEADPLANE_PUBLIC_URL="https://${HEADPLANE_DOMAIN}"
            ;;
        plain)
            # Cada servicio en su propio puerto del host: las URLs lo llevan.
            HEADSCALE_PUBLIC_URL="http://${DOMAIN}:${HEADSCALE_HTTP_PORT}"
            HEADPLANE_PUBLIC_URL="http://${DOMAIN}:${HEADPLANE_PORT}"
            ;;
    esac

    # SERVER_URL = URL del control plane; es la que usan los clientes Tailscale
    SERVER_URL="$HEADSCALE_PUBLIC_URL"

    echo ""
    print_info "URL del control plane (Headscale): ${HEADSCALE_PUBLIC_URL}"
    print_info "URL de la interfaz web (Headplane): ${HEADPLANE_PUBLIC_URL}/admin"
}

configure_tailnet() {
    print_header "CONFIGURACIÓN DE LA RED TAILNET"

    print_info "Configura los parámetros de tu red privada virtual (Tailnet)"

    TAILNET_NAME=$(ask_input "Nombre de la organización/tailnet (alfanumérico, sin espacios)" \
                             "${TAILNET_NAME:-myorg}" "validate_alphanumeric")

    ADMIN_USER=$(ask_input "Nombre del usuario administrador inicial" \
                           "${ADMIN_USER:-admin}" "validate_alphanumeric")

    IP_PREFIXES_V4=$(ask_input "Rango IPv4 para clientes (CIDR)" "${IP_PREFIXES_V4:-100.64.0.0/10}")
    IP_PREFIXES_V6=$(ask_input "Rango IPv6 para clientes (CIDR)" "${IP_PREFIXES_V6:-fd7a:115c:a1e0::/48}")

    DATA_DIR=$(ask_input "Ruta de persistencia de datos" "${DATA_DIR:-./data}")

    LOG_LEVEL=$(ask_input "Nivel de log (trace/debug/info/warn/error)" "${LOG_LEVEL:-info}")

    print_success "Configuración de Tailnet completada"
}

configure_oidc() {
    print_header "CONFIGURACIÓN DE AUTENTICACIÓN OIDC (OPCIONAL)"

    print_info "Puedes integrar un proveedor OIDC (Keycloak, Authentik, etc.)"
    print_info "Si no lo configuras, Headplane usará autenticación local (usuario/contraseña)"

    if ask_yes_no "¿Deseas configurar autenticación OIDC?" "${ENABLE_OIDC:-n}"; then
        ENABLE_OIDC="true"

        print_info "Ejemplos de Issuer URL:"
        print_info "  - Keycloak: https://auth.example.com/realms/master"
        print_info "  - Authentik: https://auth.example.com/application/o/headplane/"

        OIDC_ISSUER_URL=$(ask_input "Issuer URL del proveedor OIDC" "${OIDC_ISSUER_URL:-}" "validate_url")
        OIDC_CLIENT_ID=$(ask_input "Client ID" "${OIDC_CLIENT_ID:-headplane}")
        OIDC_CLIENT_SECRET=$(ask_input "Client Secret" "${OIDC_CLIENT_SECRET:-}")
        OIDC_SCOPE=$(ask_input "Scopes OIDC (separados por espacios)" "${OIDC_SCOPE:-openid profile email}")
        OIDC_EMAIL_CLAIM=$(ask_input "Claim del email" "${OIDC_EMAIL_CLAIM:-email}")
    else
        ENABLE_OIDC="false"
        OIDC_ISSUER_URL=""
        OIDC_CLIENT_ID=""
        OIDC_CLIENT_SECRET=""
        OIDC_SCOPE="openid profile email"
        OIDC_EMAIL_CLAIM="email"
    fi

    print_success "Configuración de OIDC completada"
}

generate_secrets() {
    print_header "GENERACIÓN DE SECRETOS"

    # Generar COOKIE_SECRET si no existe (exactamente 32 caracteres)
    if [ -z "${COOKIE_SECRET:-}" ]; then
        print_info "Generando COOKIE_SECRET..."
        COOKIE_SECRET=$(generate_secret 16)  # 16 bytes = 32 caracteres hex
        print_success "COOKIE_SECRET generado"
    else
        print_info "COOKIE_SECRET existente detectado, reutilizando"
    fi
}

# -----------------------------------------------------------------------------
# FUNCIONES DE GENERACIÓN DE ARCHIVOS
# -----------------------------------------------------------------------------

generate_env_file() {
    print_header "GENERANDO ARCHIVO .env"

    # Variables derivadas: deben existir como variables de shell (no solo en el
    # heredoc) porque las plantillas se rellenan con envsubst más adelante.
    AUTH_TYPE=$([[ "$ENABLE_OIDC" == "true" ]] && echo "oidc" || echo "local")
    # La cookie debe marcarse Secure siempre que el navegador hable HTTPS, lo
    # que incluye los modos con proxy externo donde Caddy NO arranca. Por eso
    # se decide sobre URL_SCHEME y no sobre ENABLE_SSL.
    SESSION_SECURE=$([[ "$URL_SCHEME" == "https" ]] && echo "true" || echo "false")

    cat > "$ENV_FILE" <<EOF
# =============================================================================
# CONFIGURACIÓN HEADSCALE + HEADPLANE
# =============================================================================
# Generado por install.sh el $(date)
# Para reconfigurar: ejecuta ./install.sh

# -----------------------------------------------------------------------------
# MODO DE DESPLIEGUE
# -----------------------------------------------------------------------------
# standalone   -> Caddy embebido termina TLS (un dominio, UI en /admin)
# proxy-single -> proxy externo, un dominio (/ -> Headscale, /admin -> UI)
# proxy-split  -> proxy externo, dominios separados (requiere CORS)
# plain        -> HTTP sin cifrar, puertos publicados directamente
DEPLOY_MODE=${DEPLOY_MODE}

# -----------------------------------------------------------------------------
# RED Y ACCESO
# -----------------------------------------------------------------------------
DOMAIN=${DOMAIN}
HEADSCALE_DOMAIN=${HEADSCALE_DOMAIN}
HEADPLANE_DOMAIN=${HEADPLANE_DOMAIN}
URL_SCHEME=${URL_SCHEME}

# URL del control plane: la que usan los clientes con --login-server
SERVER_URL=${SERVER_URL}
HEADSCALE_PUBLIC_URL=${HEADSCALE_PUBLIC_URL}

# URL pública de la interfaz web (la UI se sirve bajo /admin)
HEADPLANE_PUBLIC_URL=${HEADPLANE_PUBLIC_URL}

# ENABLE_SSL significa "arrancar Caddy", no "hay HTTPS": en los modos
# proxy-* hay HTTPS pero lo termina el proxy externo y Caddy no debe arrancar.
ENABLE_SSL=${ENABLE_SSL}
SSL_MODE=${SSL_MODE}
ACME_EMAIL=${ACME_EMAIL:-}

# Interfaz del host donde se publican los puertos cuando no hay Caddy
BIND_ADDRESS=${BIND_ADDRESS:-0.0.0.0}

# CIDR del reverse proxy externo. Headscale confía en su X-Forwarded-For
# para registrar la IP real del cliente (trusted_proxies).
PROXY_CIDR=${PROXY_CIDR:-}

# Dirección de esta máquina vista desde el proxy (destino del reverse proxy)
BACKEND_HOST=${BACKEND_HOST:-}

# -----------------------------------------------------------------------------
# PUERTOS
# -----------------------------------------------------------------------------
HTTP_PORT=${HTTP_PORT}
HTTPS_PORT=${HTTPS_PORT}
HEADPLANE_PORT=${HEADPLANE_PORT}
HEADSCALE_GRPC_PORT=${HEADSCALE_GRPC_PORT}
HEADSCALE_HTTP_PORT=${HEADSCALE_HTTP_PORT}
HEADSCALE_DERP_PORT=${HEADSCALE_DERP_PORT}
HEADSCALE_METRICS_PORT=${HEADSCALE_METRICS_PORT}

# -----------------------------------------------------------------------------
# TAILNET
# -----------------------------------------------------------------------------
TAILNET_NAME=${TAILNET_NAME}

# Usuario administrador creado automáticamente al desplegar
ADMIN_USER=${ADMIN_USER}

# Caducidad de la API key generada automáticamente (ej: 90d, 365d)
APIKEY_EXPIRATION=${APIKEY_EXPIRATION:-90d}

# API key de Headscale: credencial de acceso a Headplane. La rellena el
# instalador tras arrancar Headscale. NO compartir ni versionar.
HEADSCALE_API_KEY=${HEADSCALE_API_KEY:-}

IP_PREFIXES_V4=${IP_PREFIXES_V4}
IP_PREFIXES_V6=${IP_PREFIXES_V6}
DATA_DIR=${DATA_DIR}
LOG_LEVEL=${LOG_LEVEL}

# -----------------------------------------------------------------------------
# HEADPLANE
# -----------------------------------------------------------------------------
COOKIE_SECRET=${COOKIE_SECRET}
INTEGRATION_MODE=integrated

# -----------------------------------------------------------------------------
# OIDC
# -----------------------------------------------------------------------------
ENABLE_OIDC=${ENABLE_OIDC}
OIDC_ISSUER_URL="${OIDC_ISSUER_URL}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET}"
OIDC_SCOPE="${OIDC_SCOPE}"
OIDC_EMAIL_CLAIM="${OIDC_EMAIL_CLAIM}"

# Auth type (generado automáticamente)
AUTH_TYPE=${AUTH_TYPE}

# Session secure (generado automáticamente)
SESSION_SECURE=${SESSION_SECURE}

# -----------------------------------------------------------------------------
# AVANZADO
# -----------------------------------------------------------------------------
TZ=${TZ:-UTC}
NETWORK_NAME=headscale-net
HEADSCALE_IMAGE_TAG=latest
HEADPLANE_IMAGE_TAG=latest
CADDY_IMAGE_TAG=2-alpine
EOF

    print_success "Archivo .env generado: $ENV_FILE"
}

generate_headscale_config() {
    print_header "GENERANDO CONFIGURACIÓN DE HEADSCALE"

    # Configurar OIDC si está habilitado
    if [[ "$ENABLE_OIDC" == "true" ]]; then
        # OIDC_SCOPE es una lista separada por espacios ("openid profile email");
        # Headscale la espera como lista YAML, un elemento por scope.
        local scope_list=""
        local s
        for s in $OIDC_SCOPE; do
            scope_list+="    - ${s}"$'\n'
        done

        # Heredoc SIN comillas: las variables deben expandirse aquí. envsubst
        # hace una sola pasada y no volvería a sustituir el texto insertado.
        OIDC_CONFIG=$(cat <<EOFC
oidc:
  only_start_if_oidc_is_available: true
  issuer: "${OIDC_ISSUER_URL}"
  client_id: "${OIDC_CLIENT_ID}"
  client_secret: "${OIDC_CLIENT_SECRET}"
  scope:
${scope_list%$'\n'}
  strip_email_domain: true
EOFC
        )
    else
        OIDC_CONFIG="# OIDC deshabilitado"
    fi

    # Detrás de un proxy externo, Headscale ve la IP del proxy en todas las
    # peticiones. trusted_proxies activa el middleware de IP real para que los
    # logs y las ACL vean la del cliente. Headscale rechaza el prefijo /0.
    if [[ -n "${PROXY_CIDR:-}" ]]; then
        TRUSTED_PROXIES_CONFIG=$(cat <<EOFP
trusted_proxies:
  - ${PROXY_CIDR}
EOFP
        )
    else
        TRUSTED_PROXIES_CONFIG="# trusted_proxies: sin proxy externo configurado"
    fi

    # Cargar plantilla y sustituir variables
    export SERVER_URL HEADSCALE_HTTP_PORT HEADSCALE_METRICS_PORT HEADSCALE_GRPC_PORT \
           IP_PREFIXES_V4 IP_PREFIXES_V6 TAILNET_NAME HEADSCALE_DERP_PORT LOG_LEVEL \
           OIDC_CONFIG OIDC_ISSUER_URL OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_SCOPE \
           TRUSTED_PROXIES_CONFIG

    envsubst < "$TEMPLATES_DIR/headscale-config.yaml.tmpl" > "$SCRIPT_DIR/headscale-config.yaml"

    print_success "Configuración de Headscale generada: headscale-config.yaml"
}

generate_headplane_config() {
    print_header "GENERANDO CONFIGURACIÓN DE HEADPLANE"

    # Generar bloque OIDC si está habilitado
    if [[ "$ENABLE_OIDC" == "true" ]]; then
        OIDC_CONFIG_BLOCK=$(cat <<EOFC
oidc:
  enabled: true
  issuer: "${OIDC_ISSUER_URL}"
  client_id: "${OIDC_CLIENT_ID}"
  client_secret: "${OIDC_CLIENT_SECRET}"
  scope: "${OIDC_SCOPE}"
  use_pkce: true
  disable_api_key_login: false
  profile_picture_source: "gravatar"
  default_role: "member"
EOFC
        )
    else
        OIDC_CONFIG_BLOCK="# OIDC disabled"
    fi

    # Headplane exige un booleano estricto; nunca dejar el valor vacío.
    # Depende del esquema que ve el NAVEGADOR, no de si Caddy arranca: con
    # proxy externo hay HTTPS aunque Headplane reciba HTTP por dentro.
    SESSION_SECURE=$([[ "$URL_SCHEME" == "https" ]] && echo "true" || echo "false")

    # La API key sólo existe tras arrancar Headscale. En la primera pasada se
    # omite la clave; bootstrap_headscale regenera este fichero con ella.
    if [[ -n "${HEADSCALE_API_KEY:-}" ]]; then
        HEADSCALE_API_KEY_LINE="api_key: \"${HEADSCALE_API_KEY}\""
    else
        HEADSCALE_API_KEY_LINE="# api_key: pendiente de generar"
    fi

    # Cargar plantilla y sustituir variables
    # Exportar todas las variables necesarias
    export COOKIE_SECRET
    export SESSION_SECURE
    export HEADPLANE_PUBLIC_URL
    export HEADSCALE_PUBLIC_URL
    export HEADSCALE_HTTP_PORT
    export HEADSCALE_API_KEY_LINE
    export OIDC_CONFIG_BLOCK

    # Usar envsubst sin lista de variables para que sustituya todas
    envsubst < "$TEMPLATES_DIR/headplane-config.yaml.tmpl" > "$SCRIPT_DIR/headplane-config.yaml"

    # Verificar que no ha quedado ningún campo obligatorio sin sustituir
    if grep -qE '^\s*(cookie_secure|cookie_secret|base_url|public_url|url):\s*("")?\s*$' "$SCRIPT_DIR/headplane-config.yaml"; then
        print_error "headplane-config.yaml tiene campos obligatorios vacíos tras la sustitución"
        grep -nE '^\s*(cookie_secure|cookie_secret|base_url|public_url|url):\s*("")?\s*$' "$SCRIPT_DIR/headplane-config.yaml"
        exit 1
    fi

    print_success "Configuración de Headplane generada: headplane-config.yaml"
}

generate_caddyfile() {
    if [[ "$RUN_CADDY" != "true" ]]; then
        print_info "Caddy no se usa en este modo, no se genera Caddyfile"
        return 0
    fi

    print_header "GENERANDO CADDYFILE"

    # Configurar dominio y TLS según el modo
    case "$SSL_MODE" in
        letsencrypt)
            CADDY_DOMAIN="$DOMAIN"
            CADDY_TLS="tls ${ACME_EMAIL}"
            CADDY_HSTS="Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\""
            ;;
        none)
            # ":80" en vez de "http://${DOMAIN}" a propósito: sin certificado
            # el sitio suele alcanzarse por varios nombres (localhost, la IP
            # de la LAN, un hostname interno) y un site address con dominio
            # devolvería 404 a todos los demás. Escuchar en el puerto sin
            # filtrar por Host es lo que hace útil este modo.
            #
            # Caddy no intenta emitir ningún certificado para una dirección
            # sin esquema ni host, así que no hace falta "auto_https off".
            CADDY_DOMAIN=":80"
            CADDY_TLS="# Sin TLS: Caddy sólo actúa de reverse proxy por HTTP"
            CADDY_HSTS="# HSTS deshabilitado (sin TLS)"
            ;;
        *)
            CADDY_DOMAIN="$DOMAIN"
            CADDY_TLS="tls internal"
            CADDY_HSTS="# HSTS deshabilitado (certificado autofirmado)"
            ;;
    esac

    # Redirección HTTP a HTTPS. Sin TLS no hay a dónde redirigir: el propio
    # sitio ya es el de HTTP y añadir este bloque daría un bucle.
    if [[ "$SSL_MODE" == "none" ]]; then
        HTTP_REDIRECT=""
    else
        HTTP_REDIRECT=$(cat <<EOF
http://${DOMAIN} {
    redir https://{host}{uri} permanent
}
EOF
        )
    fi

    # Cargar plantilla y sustituir variables
    export CADDY_DOMAIN CADDY_TLS CADDY_HSTS HEADSCALE_HTTP_PORT HTTP_REDIRECT

    envsubst < "$TEMPLATES_DIR/Caddyfile.tmpl" > "$SCRIPT_DIR/Caddyfile"

    print_success "Caddyfile generado: Caddyfile"
}

generate_compose_override() {
    print_header "GENERANDO DOCKER COMPOSE OVERRIDE"

    local header
    header=$(cat <<'EOF'
# Docker Compose Override - Generado automáticamente por install.sh
# Publica los puertos que dependen del modo de despliegue.
#
# Compose FUSIONA las listas de 'ports' añadiendo, nunca quitando, así que
# los puertos variables no pueden estar en docker-compose.yml: si estuvieran,
# este fichero no podría retirarlos.
#
# NO editar a mano: install.sh lo regenera en cada ejecución.
EOF
    )

    # BIND_ADDRESS se interpola ahora (heredoc sin comillas) porque Compose no
    # admite variables en la parte de la IP de un mapeo de puertos.
    if [[ "$RUN_CADDY" == "true" ]]; then
        # Con Caddy embebido nadie más necesita alcanzar a Headscale ni a
        # Headplane: Caddy los resuelve por la red de Docker.
        if [[ "$SSL_MODE" == "none" ]]; then
            print_info "Publicando sólo el puerto HTTP de Caddy (sin TLS)..."
            cat > "$SCRIPT_DIR/docker-compose.override.yml" <<EOF
${header}

services:
  caddy:
    ports:
      # Sin TLS: sólo HTTP. No se publica 443 porque nada escucharía ahí.
      - "\${HTTP_PORT:-80}:80"
EOF
        else
            print_info "Publicando los puertos HTTP y HTTPS de Caddy..."
            cat > "$SCRIPT_DIR/docker-compose.override.yml" <<EOF
${header}

services:
  caddy:
    ports:
      # HTTP: reto ACME de Let's Encrypt y redirección a HTTPS
      - "\${HTTP_PORT:-80}:80"
      - "\${HTTPS_PORT:-443}:443"
      # HTTP/3 (QUIC)
      - "\${HTTPS_PORT:-443}:443/udp"
EOF
        fi
    else
        print_info "Publicando puertos en ${BIND_ADDRESS:-0.0.0.0} para el acceso externo..."
        cat > "$SCRIPT_DIR/docker-compose.override.yml" <<EOF
${header}

services:
  headscale:
    ports:
      # API HTTP del control plane -> destino del proxy para el dominio principal
      - "${BIND_ADDRESS:-0.0.0.0}:\${HEADSCALE_HTTP_PORT:-8080}:8080"

  headplane:
    ports:
      # Interfaz web -> destino del proxy para /admin o el dominio de la UI
      - "${BIND_ADDRESS:-0.0.0.0}:\${HEADPLANE_PORT:-3000}:3000"
EOF
    fi

    print_success "docker-compose.override.yml generado"
}

# Genera la configuración para el reverse proxy externo. No se aplica sola:
# son ficheros para que el usuario los lleve a la máquina del proxy.
generate_reverse_proxy_configs() {
    if [[ "$DEPLOY_MODE" != "proxy-single" && "$DEPLOY_MODE" != "proxy-split" ]]; then
        return 0
    fi

    print_header "GENERANDO CONFIGURACIÓN DEL PROXY EXTERNO"

    local out_dir="${SCRIPT_DIR}/reverse-proxy"
    mkdir -p "$out_dir"

    # Con dominios separados, el navegador carga la UI desde un origen y la API
    # vive en otro: sin estas cabeceras el navegador bloquea las llamadas.
    if [[ "$DEPLOY_MODE" == "proxy-split" ]]; then
        CORS_BLOCK=$(cat <<EOFC

    # CORS: la UI (${HEADPLANE_PUBLIC_URL}) y la API están en orígenes
    # distintos. 'always' es necesario para que las cabeceras salgan también
    # en las respuestas de error.
    add_header Access-Control-Allow-Origin      "${HEADPLANE_PUBLIC_URL}" always;
    add_header Access-Control-Allow-Credentials "true" always;
    add_header Access-Control-Allow-Headers     "Authorization, Content-Type" always;
    add_header Access-Control-Allow-Methods     "GET, POST, PUT, DELETE, OPTIONS" always;
    if (\$request_method = OPTIONS) { return 204; }
EOFC
        )
    else
        CORS_BLOCK="    # CORS innecesario: un solo dominio, mismo origen."
    fi

    # Con dominio único no hay un segundo server block: la UI tiene que ser un
    # location MÁS del mismo server, o /admin acabaría en Headscale (404).
    # Nginx resuelve los prefijos por longitud, así que el orden da igual.
    if [[ "$DEPLOY_MODE" == "proxy-single" ]]; then
        HEADPLANE_LOCATION=$(cat <<EOFH

    # Interfaz web. El prefijo /admin está compilado en la imagen de
    # Headplane: no lo reescribas, la UI cargaría en blanco.
    location /admin {
        proxy_pass http://${BACKEND_HOST}:${HEADPLANE_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect http:// https://;

        # /admin/events/live es SSE: sin esto la UI no se actualiza sola
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
EOFH
        )
        # Misma idea para NPM, pero con \$http_connection: \$connection_upgrade
        # se declara en el 'map' del contexto http {}, que NPM no expone.
        HEADPLANE_LOCATION_NPM=$(cat <<EOFN

# Interfaz web en el MISMO dominio. Sin esto, /admin iría a Headscale.
location /admin {
    proxy_pass http://${BACKEND_HOST}:${HEADPLANE_PORT};
    proxy_http_version 1.1;

    proxy_set_header Upgrade    \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_buffering off;
    proxy_read_timeout 3600s;
}
EOFN
        )
        PROXY_HOST_2=$(cat <<EOFP2
### Proxy Host 2 — no hace falta

En modo \`proxy-single\` todo vive en \`${HEADSCALE_DOMAIN}\`: la UI es el
\`location /admin\` que ya va incluido en el bloque *Advanced* de arriba.
**No crees un segundo Proxy Host**: NPM no admite dos hosts con el mismo
dominio y el segundo no se aplicaría.
EOFP2
        )
    else
        # En proxy-split la UI tiene su propio server block / Proxy Host.
        HEADPLANE_LOCATION=""
        HEADPLANE_LOCATION_NPM=""
        PROXY_HOST_2=$(cat <<EOFP2
### Proxy Host 2 — interfaz web

**Details**

| Campo | Valor |
|---|---|
| Domain Names | \`${HEADPLANE_DOMAIN}\` |
| Scheme | \`http\` |
| Forward Hostname / IP | \`${BACKEND_HOST}\` |
| Forward Port | \`${HEADPLANE_PORT}\` |
| **Websockets Support** | ✅ **activado** |

**SSL**: Let's Encrypt, \`Force SSL\` ✅.

**Advanced**:

\`\`\`nginx
# La raíz no sirve nada: Headplane vive bajo /admin
location = / {
    return 301 https://\$host/admin;
}

location /admin {
    proxy_pass http://${BACKEND_HOST}:${HEADPLANE_PORT};
    proxy_http_version 1.1;

    proxy_set_header Upgrade    \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # /admin/events/live es SSE: sin esto la UI no se actualiza sola
    proxy_buffering off;
    proxy_read_timeout 3600s;
}
\`\`\`
EOFP2
        )
    fi

    export DEPLOY_MODE BACKEND_HOST CORS_BLOCK PROXY_CIDR \
           HEADSCALE_DOMAIN HEADPLANE_DOMAIN \
           HEADSCALE_PUBLIC_URL HEADPLANE_PUBLIC_URL \
           HEADSCALE_HTTP_PORT HEADPLANE_PORT HEADSCALE_DERP_PORT \
           HEADPLANE_LOCATION HEADPLANE_LOCATION_NPM PROXY_HOST_2

    # envsubst con lista explícita: las plantillas nginx están llenas de
    # $host, $http_upgrade, $remote_addr... que envsubst borraría si se le
    # dejara sustituir todo.
    local vars='${DEPLOY_MODE} ${BACKEND_HOST} ${CORS_BLOCK} ${PROXY_CIDR}'
    vars+=' ${HEADSCALE_DOMAIN} ${HEADPLANE_DOMAIN}'
    vars+=' ${HEADSCALE_PUBLIC_URL} ${HEADPLANE_PUBLIC_URL}'
    vars+=' ${HEADSCALE_HTTP_PORT} ${HEADPLANE_PORT} ${HEADSCALE_DERP_PORT}'
    vars+=' ${HEADPLANE_LOCATION} ${HEADPLANE_LOCATION_NPM} ${PROXY_HOST_2}'

    envsubst "$vars" < "$TEMPLATES_DIR/nginx-headscale.conf.tmpl" > "$out_dir/nginx-headscale.conf"
    envsubst "$vars" < "$TEMPLATES_DIR/REVERSE-PROXY.md.tmpl"     > "$out_dir/REVERSE-PROXY.md"

    if [[ "$DEPLOY_MODE" == "proxy-split" ]]; then
        envsubst "$vars" < "$TEMPLATES_DIR/nginx-headplane.conf.tmpl" > "$out_dir/nginx-headplane.conf"
    else
        # En dominio único la UI es un location del mismo server block, no un
        # server aparte: un fichero separado sólo induciría a error.
        rm -f "$out_dir/nginx-headplane.conf"
    fi

    # Comprobar que no quedaron marcadores sin sustituir
    if grep -rlqE '\$\{[A-Z_]+\}' "$out_dir" 2>/dev/null; then
        print_error "Quedaron variables sin sustituir en la configuración del proxy:"
        grep -rnoE '\$\{[A-Z_]+\}' "$out_dir" | head -5
        exit 1
    fi

    print_success "Configuración del proxy generada en: reverse-proxy/"
    print_info "Lee reverse-proxy/REVERSE-PROXY.md y aplícala en la máquina del proxy"
}

create_data_dirs() {
    print_header "CREANDO DIRECTORIOS DE DATOS"

    mkdir -p "$DATA_DIR"
    mkdir -p "$DATA_DIR/caddy-logs"

    print_success "Directorios de datos creados en: $DATA_DIR"
}

# -----------------------------------------------------------------------------
# FUNCIONES DE DESPLIEGUE
# -----------------------------------------------------------------------------

start_headscale_first() {
    # Headscale debe estar arriba ANTES que Headplane: la API key que Headplane
    # necesita sólo puede emitirla un Headscale en marcha.
    print_header "ARRANCANDO HEADSCALE"

    print_info "Descargando imágenes de Docker..."
    local compose_args=""
    [[ "$RUN_CADDY" == "true" ]] && compose_args="--profile ssl"
    docker compose $compose_args pull

    print_info "Levantando Headscale..."
    docker compose up -d headscale

    print_info "Esperando a que Headscale esté saludable..."
    local waited=0
    while [ $waited -lt 90 ]; do
        local state
        state=$(docker inspect -f '{{.State.Health.Status}}' headscale 2>/dev/null || echo "starting")
        if [[ "$state" == "healthy" ]]; then
            echo ""
            print_success "Headscale está listo"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done

    echo ""
    print_error "Headscale no llegó a estado saludable tras 90s"
    print_info "Revisa los logs con: docker compose logs headscale"
    exit 1
}

bootstrap_headscale() {
    print_header "CREANDO USUARIO ADMINISTRADOR Y API KEY"

    # --- Usuario administrador (idempotente) ---
    # 'users create' falla con UNIQUE constraint si ya existe, así que se
    # comprueba antes para que reejecutar el instalador no aborte.
    if docker exec headscale headscale users list --output json 2>/dev/null \
        | grep -q "\"name\": *\"${ADMIN_USER}\""; then
        print_info "El usuario '${ADMIN_USER}' ya existe, se conserva"
    else
        if docker exec headscale headscale users create "${ADMIN_USER}" >/dev/null 2>&1; then
            print_success "Usuario administrador creado: ${ADMIN_USER}"
        else
            print_error "No se pudo crear el usuario '${ADMIN_USER}'"
            docker exec headscale headscale users create "${ADMIN_USER}" || true
            exit 1
        fi
    fi

    # Headscale 0.29 exige el ID numérico en 'preauthkeys create --user',
    # no el nombre, así que hay que resolverlo para poder mostrar el comando.
    ADMIN_USER_ID=$(docker exec headscale headscale users list --output json 2>/dev/null \
                    | tr -d ' \t\n' \
                    | grep -oE "\"id\":[0-9]+,\"name\":\"${ADMIN_USER}\"" \
                    | grep -oE '[0-9]+' | head -1)
    [[ -z "$ADMIN_USER_ID" ]] && ADMIN_USER_ID="<id>"

    # --- API key ---
    # Headscale sólo devuelve el valor completo al crearla; después almacena
    # únicamente el prefijo. Si conservamos una en .env y sigue vigente, se
    # reutiliza para que reconfigurar no acumule claves huérfanas.
    if [[ -n "${HEADSCALE_API_KEY:-}" ]]; then
        local prefix expires now
        prefix=$(printf '%s' "$HEADSCALE_API_KEY" | cut -d- -f1-3)

        # Headscale lista el prefijo enmascarado ("hskey-api-XXXX-***"), por lo
        # que hay que buscar el prefijo como subcadena, no como valor exacto.
        expires=$(docker exec headscale headscale apikeys list --output json 2>/dev/null \
                  | tr -d ' \t\n' \
                  | grep -oE "\"prefix\":\"${prefix}[^\"]*\",\"expiration\":\{\"seconds\":[0-9]+" \
                  | grep -oE '[0-9]+$' || true)
        now=$(date +%s)

        if [[ -n "$expires" ]] && [[ "$expires" -gt "$now" ]]; then
            print_info "Reutilizando la API key existente de .env"
            return 0
        elif [[ -n "$expires" ]]; then
            print_warning "La API key guardada en .env ha caducado, se generará otra"
        else
            print_warning "La API key guardada en .env ya no existe, se generará otra"
        fi
    fi

    HEADSCALE_API_KEY=$(docker exec headscale headscale apikeys create \
                        --expiration "${APIKEY_EXPIRATION:-90d}" 2>/dev/null | tr -d '\r\n')

    if [[ ! "$HEADSCALE_API_KEY" =~ ^hskey- ]]; then
        print_error "La API key generada no tiene el formato esperado"
        print_info "Genérala manualmente con: docker exec headscale headscale apikeys create"
        HEADSCALE_API_KEY=""
        return 0
    fi

    # Persistir en .env (único fichero con secretos, ya excluido por .gitignore)
    if grep -q '^HEADSCALE_API_KEY=' "$ENV_FILE"; then
        sed -i "s|^HEADSCALE_API_KEY=.*|HEADSCALE_API_KEY=${HEADSCALE_API_KEY}|" "$ENV_FILE"
    else
        printf '\n# API key de Headscale (generada automáticamente, NO compartir)\nHEADSCALE_API_KEY=%s\n' \
            "$HEADSCALE_API_KEY" >> "$ENV_FILE"
    fi

    print_success "API key generada (válida ${APIKEY_EXPIRATION:-90d}) y guardada en .env"
}

deploy_stack() {
    print_header "DESPLEGANDO STACK CON DOCKER COMPOSE"

    # Determinar profile a usar
    local compose_args=""
    if [[ "$RUN_CADDY" == "true" ]]; then
        compose_args="--profile ssl"
        print_info "Activando profile SSL..."
    elif docker ps --filter "name=^caddy$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
        # Al reconfigurar de 'standalone' a un modo con proxy externo, Caddy
        # sigue vivo de la instalación anterior: 'up -d' sin el profile no lo
        # para, y seguiría ocupando los puertos 80/443.
        print_info "Parando Caddy: este modo no lo usa..."
        docker compose --profile ssl stop caddy >/dev/null 2>&1 || true
        docker compose --profile ssl rm -f caddy >/dev/null 2>&1 || true
    fi

    # Levantar servicios
    print_info "Levantando servicios..."
    docker compose $compose_args up -d

    # Esperar a que los servicios estén saludables
    print_info "Esperando a que los servicios estén listos..."
    local max_wait=60
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if docker compose ps | grep -q "healthy"; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done
    echo ""

    if [ $waited -ge $max_wait ]; then
        print_warning "Los servicios están tardando más de lo esperado en iniciar"
        print_info "Verifica el estado con: docker compose ps"
        print_info "Verifica los logs con: docker compose logs -f"
    else
        print_success "Servicios desplegados correctamente"
    fi

    export_root_ca
}

# Con SSL_MODE=selfsigned, Caddy firma con su propia CA interna. Los clientes
# Tailscale rechazan ese certificado ("x509: certificate signed by unknown
# authority") y ni siquiera llegan a /key, así que la VPN no funciona hasta que
# la CA se instala en cada dispositivo. Se exporta aquí para poder distribuirla.
export_root_ca() {
    [[ "${SSL_MODE:-none}" == "selfsigned" ]] || return 0

    local ca_src="/data/caddy/pki/authorities/local/root.crt"
    local ca_dst="${SCRIPT_DIR}/caddy-root-ca.crt"
    local waited=0

    while [ $waited -lt 30 ]; do
        if docker exec caddy test -f "$ca_src" 2>/dev/null; then
            if docker exec caddy cat "$ca_src" > "$ca_dst" 2>/dev/null \
               && [[ -s "$ca_dst" ]]; then
                chmod 644 "$ca_dst"
                print_success "CA raíz exportada a: ${ca_dst}"
                return 0
            fi
        fi
        sleep 2
        waited=$((waited + 2))
    done

    rm -f "$ca_dst"
    print_warning "No se pudo exportar la CA raíz de Caddy"
    print_info "Extráela manualmente con:"
    print_info "  docker exec caddy cat ${ca_src} > caddy-root-ca.crt"
    return 0
}

show_access_info() {
    print_header "¡INSTALACIÓN COMPLETADA!"

    echo ""
    echo -e "${GREEN}${BOLD}✓ Headscale + Headplane están corriendo${NC}"
    echo -e "${CYAN}Modo de despliegue:${NC} ${BOLD}${DEPLOY_MODE}${NC}"
    if [[ "$RUN_CADDY" == "true" ]]; then
        echo -e "${CYAN}Certificado:${NC} ${BOLD}${SSL_MODE}${NC}"
    fi
    echo ""

    # URLs de acceso
    echo -e "${CYAN}Interfaz web (Headplane):${NC} ${BOLD}${HEADPLANE_PUBLIC_URL}/admin${NC}"
    echo -e "${CYAN}Control plane (Headscale):${NC} ${BOLD}${HEADSCALE_PUBLIC_URL}${NC}"
    echo ""

    # En los modos con proxy externo el stack NO es alcanzable todavía: falta
    # configurar la otra máquina. Decirlo antes que nada evita el desconcierto.
    if [[ "$DEPLOY_MODE" == "proxy-single" || "$DEPLOY_MODE" == "proxy-split" ]]; then
        echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}${BOLD}│  FALTA UN PASO: CONFIGURAR EL PROXY EXTERNO                             │${NC}"
        echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "   Las URLs de arriba todavía no responden. El stack escucha en:"
        echo -e "     ${BOLD}${BACKEND_HOST}:${HEADSCALE_HTTP_PORT}${NC}  (control plane, HTTP)"
        echo -e "     ${BOLD}${BACKEND_HOST}:${HEADPLANE_PORT}${NC}  (interfaz web, HTTP)"
        echo ""
        echo -e "   Configuración lista para copiar en la máquina del proxy:"
        echo -e "     ${BOLD}reverse-proxy/REVERSE-PROXY.md${NC}   guía paso a paso para NPM"
        echo -e "     ${BOLD}reverse-proxy/nginx-headscale.conf${NC}"
        [[ "$DEPLOY_MODE" == "proxy-split" ]] && \
        echo -e "     ${BOLD}reverse-proxy/nginx-headplane.conf${NC}"
        echo ""
        print_warning "Apunta AMBOS dominios al proxy, no a esta máquina."
        print_warning "Abre UDP ${HEADSCALE_DERP_PORT} hacia ${BACKEND_HOST}: el relay DERP no pasa por el proxy."
        echo ""
    fi

    # El aviso de TLS depende del modo, no de si Caddy arranca: con proxy
    # externo hay HTTPS aunque aquí no corra ningún terminador TLS.
    if [[ "$URL_SCHEME" == "http" ]]; then
        print_warning "El plano de control viaja sin cifrar (HTTP)"
        echo -e "   No expongas esto fuera de una red de confianza."
        echo ""
    fi

    if [[ "$RUN_CADDY" == "true" ]]; then
        if [[ "$SSL_MODE" == "selfsigned" ]]; then
            print_warning "Estás usando un certificado autofirmado (CA interna de Caddy)"
            echo ""
            echo -e "   ${BOLD}Los clientes Tailscale NO se conectarán hasta que instales la CA.${NC}"
            echo -e "   Sin ella fallan con: ${YELLOW}x509: certificate signed by unknown authority${NC}"
            echo ""
            if [[ -s "${SCRIPT_DIR}/caddy-root-ca.crt" ]]; then
                echo -e "   CA raíz exportada en: ${BOLD}${SCRIPT_DIR}/caddy-root-ca.crt${NC}"
                echo -e "   Cópiala a cada dispositivo e instálala en su almacén de confianza:"
                echo ""
                echo -e "   ${YELLOW}# Linux (Debian/Ubuntu)${NC}"
                echo -e "   ${YELLOW}sudo cp caddy-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates${NC}"
                echo -e "   ${YELLOW}# macOS${NC}"
                echo -e "   ${YELLOW}sudo security add-trusted-cert -d -k /Library/Keychains/System.keychain caddy-root-ca.crt${NC}"
                echo -e "   ${YELLOW}# Windows (PowerShell como administrador)${NC}"
                echo -e "   ${YELLOW}Import-Certificate -FilePath caddy-root-ca.crt -CertStoreLocation Cert:\\LocalMachine\\Root${NC}"
                echo ""
                echo -e "   ${BOLD}Android/iOS no admiten CAs propias para Tailscale:${NC} en esos"
                echo -e "   dispositivos necesitas Let's Encrypt (reejecuta el instalador)."
            fi
            echo ""
        fi
    fi

    # --- API key: único método de acceso a la UI sin OIDC ---
    if [[ -n "${HEADSCALE_API_KEY:-}" ]]; then
        echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}${BOLD}│  API KEY PARA INICIAR SESIÓN EN HEADPLANE                               │${NC}"
        echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  ${BOLD}${HEADSCALE_API_KEY}${NC}"
        echo ""
        print_warning "GUÁRDALA AHORA: Headscale sólo la muestra en el momento de crearla."
        print_warning "Da control total sobre tu tailnet. Trátala como una contraseña."
        echo ""
        echo -e "  Si la pierdes, genera otra con:"
        echo -e "  ${YELLOW}docker exec headscale headscale apikeys create --expiration 90d${NC}"
        echo ""
    else
        print_warning "No se generó ninguna API key en esta ejecución"
        echo -e "  Para entrar en Headplane necesitas una:"
        echo -e "  ${YELLOW}docker exec headscale headscale apikeys create --expiration 90d${NC}"
        echo ""
    fi

    echo -e "${CYAN}${BOLD}Próximos pasos:${NC}"
    echo ""
    echo -e "1. Entra en ${BOLD}${HEADPLANE_PUBLIC_URL}/admin${NC} y pega la API key de arriba"
    echo -e "   ${YELLOW}(la UI vive bajo /admin; la raíz / devuelve 404)${NC}"
    echo ""
    echo "2. Generar una clave de pre-autenticación para conectar dispositivos:"
    echo -e "   ${YELLOW}docker exec headscale headscale preauthkeys create --user ${ADMIN_USER_ID} --reusable --expiration 24h${NC}"
    echo -e "   ${YELLOW}(--user espera el ID numérico del usuario, no su nombre)${NC}"
    echo ""
    echo "3. Conectar un dispositivo con Tailscale:"
    echo -e "   ${YELLOW}tailscale up --login-server=${HEADSCALE_PUBLIC_URL} --authkey=<clave-del-paso-2>${NC}"
    echo ""
    print_warning "No confundas las tres claves de este stack:"
    echo -e "   • ${BOLD}API key${NC} (hskey-api-...)      -> iniciar sesión en la UI de Headplane"
    echo -e "   • ${BOLD}Pre-auth key${NC} (hskey-auth-...) -> registrar dispositivos con --authkey"
    echo -e "   • ${BOLD}Auth ID${NC} (hskey-authreq-...)   -> lo imprime 'tailscale up' sin --authkey,"
    echo -e "     y es lo único que acepta el diálogo \"Register Machine Key\" de Headplane"
    echo ""

    echo -e "${CYAN}${BOLD}Comandos útiles:${NC}"
    echo ""
    echo "• Ver estado de los servicios:"
    echo -e "  ${YELLOW}docker compose ps${NC}"
    echo ""
    echo "• Ver logs:"
    echo -e "  ${YELLOW}docker compose logs -f${NC}"
    echo ""
    echo "• Reiniciar servicios:"
    echo -e "  ${YELLOW}docker compose restart${NC}"
    echo ""
    echo "• Detener servicios:"
    echo -e "  ${YELLOW}docker compose down${NC}"
    echo ""
    echo "• Reconfigurar:"
    echo -e "  ${YELLOW}./install.sh${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}Archivos generados:${NC}"
    echo ""
    echo "• Configuración: .env"
    echo "• Config Headscale: headscale-config.yaml"
    echo "• Config Headplane: headplane-config.yaml"
    [[ "$RUN_CADDY" == "true" ]] && echo "• Caddyfile: Caddyfile"
    echo "• Override de puertos: docker-compose.override.yml"
    if [[ "$DEPLOY_MODE" == "proxy-single" || "$DEPLOY_MODE" == "proxy-split" ]]; then
        echo "• Config del proxy externo: reverse-proxy/"
    fi
    echo "• Datos: $DATA_DIR/"
    echo ""

    print_success "¡Disfruta de tu red privada virtual!"
}

# -----------------------------------------------------------------------------
# FUNCIÓN PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    clear

    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║   ██╗  ██╗███████╗ █████╗ ██████╗ ███████╗ ██████╗ █████╗ ██╗     ███████╗║
║   ██║  ██║██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██║     ██╔════╝║
║   ███████║█████╗  ███████║██║  ██║███████╗██║     ███████║██║     █████╗  ║
║   ██╔══██║██╔══╝  ██╔══██║██║  ██║╚════██║██║     ██╔══██║██║     ██╔══╝  ║
║   ██║  ██║███████╗██║  ██║██████╔╝███████║╚██████╗██║  ██║███████╗███████╗║
║   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝║
║                                                                           ║
║                        + HEADPLANE WEB UI                                 ║
║                                                                           ║
║              Instalador Interactivo Todo-en-Uno v1.0                     ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    print_info "Este instalador configurará Headscale + Headplane con un solo comando"
    print_info "Responde las preguntas a continuación (puedes usar valores por defecto)"
    echo ""

    # Verificar si es una reconfiguración
    local is_reconfigure=false
    if [ -f "$ENV_FILE" ]; then
        echo ""
        print_warning "Se detectó una instalación existente"
        if ask_yes_no "¿Deseas reconfigurar la instalación existente?" "n"; then
            is_reconfigure=true
            print_info "Modo reconfiguración activado"
            print_warning "Los datos existentes se mantendrán, solo se actualizará la configuración"
            echo ""
        else
            print_info "Continuando con la instalación existente..."
            exit 0
        fi
    fi

    # 1. Verificar dependencias
    check_dependencies

    # 2. Cargar configuración existente (si existe y no es reconfiguración)
    if ! $is_reconfigure; then
        load_existing_config || true
    else
        # En modo reconfiguración, cargar siempre la config existente como base
        set -a
        source "$ENV_FILE"
        set +a
    fi

    # 3. Configuración interactiva
    configure_deployment_mode
    configure_network
    configure_ports
    configure_proxy_access
    compute_public_urls
    configure_tailnet
    configure_oidc

    # 4. Generar secretos
    generate_secrets

    # 5. Generar archivos de configuración
    generate_env_file
    create_data_dirs
    generate_headscale_config
    generate_headplane_config
    generate_caddyfile
    generate_compose_override
    generate_reverse_proxy_configs

    # 6. Desplegar
    echo ""
    if ask_yes_no "¿Deseas desplegar el stack ahora?" "y"; then
        # Fase 1: sólo Headscale, para poder emitir la API key
        start_headscale_first
        bootstrap_headscale

        # Regenerar la config de Headplane ya con la API key inyectada
        generate_headplane_config

        # Fase 2: resto del stack (Headplane y, si procede, Caddy)
        deploy_stack
        show_access_info
    else
        print_info "Configuración completada pero no desplegada"
        print_info "Para desplegar manualmente, ejecuta:"
        if [[ "$RUN_CADDY" == "true" ]]; then
            echo -e "  ${YELLOW}docker compose --profile ssl up -d${NC}"
        else
            echo -e "  ${YELLOW}docker compose up -d${NC}"
        fi
    fi

    echo ""
}

# Ejecutar main
main "$@"
