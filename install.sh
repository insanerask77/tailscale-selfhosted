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

# Este instalador tiene UN solo modo de despliegue: Caddy delante de Headscale
# y Headplane, enrutando un único dominio (/ -> control plane, /admin -> UI).
# La única bifurcación es quién pone el HTTPS, y eso es lo que decide SSL_MODE:
#
#   letsencrypt  Caddy pide el certificado a Let's Encrypt.
#   selfsigned   Caddy firma con su CA interna.
#   front        Lo pone otro proxy por delante (NPM, nginx, Traefik u otro
#                Caddy). Este Caddy sirve HTTP y el instalador escupe el
#                snippet de configuración para ese proxy.
#   none         No hay HTTPS. Para localhost, LAN de confianza o un acceso
#                que ya viaja por otra VPN.
configure_network() {
    print_header "CONFIGURACIÓN DE RED Y ACCESO"

    print_info "Dominio o IP con el que se accede al stack. Caddy enruta ese"
    print_info "único nombre: / -> Headscale, /admin -> Headplane."
    print_info "Ejemplos: vpn.midominio.com, 192.168.1.100, localhost"
    DOMAIN=$(ask_input "Dominio o IP" "${DOMAIN:-vpn.example.com}" "validate_domain_or_ip")

    # Let's Encrypt no emite para IPs ni para localhost: en esos casos ni se
    # ofrece, en vez de dejar que el reto ACME falle a mitad de instalación.
    local tls_options=()
    if [[ "$DOMAIN" =~ ^[0-9.]+$ ]] || [[ "$DOMAIN" == "localhost" ]]; then
        print_warning "Has indicado una IP o localhost: Let's Encrypt no emite certificados para eso"
    else
        tls_options+=("letsencrypt|Caddy, con Let's Encrypt|Certificado público y de confianza para ${DOMAIN}. Requiere que su DNS ya apunte aquí y que los puertos 80 y 443 lleguen desde internet.")
    fi
    tls_options+=("selfsigned|Caddy, con certificado autofirmado|HTTPS sin dependencias externas. Hay que instalar la CA de Caddy en cada cliente Tailscale o no conectarán.")
    tls_options+=("front|Un proxy que ya tienes por delante|NPM, nginx, Traefik u otro Caddy terminan el TLS y reenvían aquí. Se genera el snippet listo para ese proxy.")
    tls_options+=("none|Nadie: sólo HTTP|Caddy enruta igual, pero sin cifrar: http://${DOMAIN}. Para localhost, LAN de confianza o un acceso que ya va por VPN.")

    SSL_MODE=$(ask_choice "¿Quién pone el HTTPS?" "${SSL_MODE:-letsencrypt}" "${tls_options[@]}")

    case "$SSL_MODE" in
        letsencrypt)
            URL_SCHEME="https"
            FRONT_PROXY=""
            print_info "Let's Encrypt necesita un email para los avisos de renovación"
            ACME_EMAIL=$(ask_input "Email para Let's Encrypt" "${ACME_EMAIL:-admin@${DOMAIN}}" "validate_email")
            ;;
        selfsigned)
            URL_SCHEME="https"
            FRONT_PROXY=""
            print_info "Se usará un certificado autofirmado"
            print_warning "Tendrás que instalar la CA en cada cliente Tailscale (se exporta al final)"
            ;;
        front)
            # El proxy de delante habla HTTPS con el mundo aunque aquí el salto
            # sea HTTP: SERVER_URL y la cookie de sesión se deciden por lo que
            # ve el cliente, no por lo que escucha Caddy.
            URL_SCHEME="https"
            FRONT_PROXY=$(ask_choice "¿Qué proxy tienes delante?" "${FRONT_PROXY:-npm}" \
                "npm|Nginx Proxy Manager|Guía de los campos del Proxy Host más el bloque para la caja Advanced." \
                "nginx|Nginx que gestionas tú|Un server{} completo listo para /etc/nginx/conf.d/." \
                "traefik|Traefik|Configuración dinámica en YAML para el file provider." \
                "caddy|Otro Caddy|El Caddyfile del proxy de borde.")

            echo ""
            print_info "Dirección de ESTA máquina tal y como la ve el proxy: es a donde reenvía."
            local guess
            guess=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
            BACKEND_HOST=$(ask_input "IP o hostname de esta máquina" \
                                     "${BACKEND_HOST:-${guess:-127.0.0.1}}")
            ;;
        none)
            URL_SCHEME="http"
            FRONT_PROXY=""
            print_info "Caddy escuchará en HTTP y enrutará / y /admin sin certificado"
            ;;
    esac

    if [[ "$URL_SCHEME" == "http" ]]; then
        print_warning "ADVERTENCIA: el plano de control viajará sin cifrar"
        print_warning "No expongas esto a internet"
    fi

    print_success "Configuración de red completada"
}

configure_ports() {
    print_header "CONFIGURACIÓN DE PUERTOS"

    print_info "Enter para aceptar los valores por defecto."

    if [[ "$SSL_MODE" == "letsencrypt" || "$SSL_MODE" == "selfsigned" ]]; then
        HTTP_PORT=$(ask_input "Puerto HTTP de Caddy (reto ACME y redirección a HTTPS)" \
                              "${HTTP_PORT:-80}" "validate_port")
        HTTPS_PORT=$(ask_input "Puerto HTTPS de Caddy" "${HTTPS_PORT:-443}" "validate_port")
    else
        # Sin certificado Caddy no escucha en 443: preguntar por ese puerto
        # sería ofrecer uno que nadie va a abrir.
        [[ "$SSL_MODE" == "front" ]] && \
            print_info "Es el puerto donde el proxy de delante encontrará a Caddy"
        HTTP_PORT=$(ask_input "Puerto HTTP de Caddy" "${HTTP_PORT:-80}" "validate_port")
        HTTPS_PORT="443"
    fi

    # Headplane y la API de Headscale NO se publican en el host: sólo los
    # alcanza Caddy por la red interna de Docker.
    HEADPLANE_PORT="3000"

    HEADSCALE_GRPC_PORT=$(ask_input "Puerto gRPC de Headscale (interno)" "${HEADSCALE_GRPC_PORT:-50443}" "validate_port")
    HEADSCALE_HTTP_PORT=$(ask_input "Puerto HTTP API de Headscale (interno)" "${HEADSCALE_HTTP_PORT:-8080}" "validate_port")
    HEADSCALE_DERP_PORT=$(ask_input "Puerto DERP/STUN de Headscale (UDP, debe ser accesible)" "${HEADSCALE_DERP_PORT:-3478}" "validate_port")
    HEADSCALE_METRICS_PORT=$(ask_input "Puerto Metrics de Headscale (interno)" "${HEADSCALE_METRICS_PORT:-9090}" "validate_port")

    print_success "Configuración de puertos completada"
}

# Las URLs públicas dependen del dominio Y de los puertos, así que sólo pueden
# calcularse después de configure_ports.
#
# Importante: son las URLs que ve el MUNDO, no las internas. Headscale y
# Headplane siguen hablando HTTP por la red de Docker, pero anuncian https://
# cuando es eso lo que resuelve el cliente.
compute_public_urls() {
    local suffix=""

    case "$SSL_MODE" in
        letsencrypt|selfsigned)
            [[ "$HTTPS_PORT" != "443" ]] && suffix=":${HTTPS_PORT}"
            HEADSCALE_PUBLIC_URL="https://${DOMAIN}${suffix}"
            ;;
        front)
            # El proxy de delante escucha en el 443 estándar. Su puerto no tiene
            # por qué coincidir con HTTP_PORT, que es sólo el de esta máquina.
            HEADSCALE_PUBLIC_URL="https://${DOMAIN}"
            ;;
        none)
            [[ "$HTTP_PORT" != "80" ]] && suffix=":${HTTP_PORT}"
            HEADSCALE_PUBLIC_URL="http://${DOMAIN}${suffix}"
            ;;
    esac

    # Un solo dominio: la UI vive en /admin de ese mismo host.
    HEADPLANE_PUBLIC_URL="$HEADSCALE_PUBLIC_URL"

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
    # que incluye SSL_MODE=front: ahí el TLS lo pone el proxy de delante y Caddy
    # sirve HTTP, pero el cliente ve https. Por eso se decide sobre URL_SCHEME.
    SESSION_SECURE=$([[ "$URL_SCHEME" == "https" ]] && echo "true" || echo "false")

    cat > "$ENV_FILE" <<EOF
# =============================================================================
# CONFIGURACIÓN HEADSCALE + HEADPLANE
# =============================================================================
# Generado por install.sh el $(date)
# Para reconfigurar: ejecuta ./install.sh

# -----------------------------------------------------------------------------
# RED Y ACCESO
# -----------------------------------------------------------------------------
# Un solo dominio. Caddy lo enruta: / -> Headscale, /admin -> Headplane.
DOMAIN=${DOMAIN}
URL_SCHEME=${URL_SCHEME}

# URL del control plane: la que usan los clientes con --login-server
SERVER_URL=${SERVER_URL}
HEADSCALE_PUBLIC_URL=${HEADSCALE_PUBLIC_URL}

# URL pública de la interfaz web (la UI se sirve bajo /admin)
HEADPLANE_PUBLIC_URL=${HEADPLANE_PUBLIC_URL}

# Quién pone el HTTPS. Caddy arranca siempre y enruta en los cuatro casos.
#   letsencrypt -> Caddy pide el certificado a Let's Encrypt
#   selfsigned  -> Caddy firma con su CA interna
#   front       -> lo pone un proxy por delante; aquí Caddy sirve HTTP
#   none        -> no hay HTTPS en ninguna capa
SSL_MODE=${SSL_MODE}
ACME_EMAIL=${ACME_EMAIL:-}

# Proxy de delante (sólo con SSL_MODE=front): npm, nginx, traefik o caddy.
# Determina qué snippet se genera en reverse-proxy/.
FRONT_PROXY=${FRONT_PROXY:-}

# Dirección de esta máquina vista desde ese proxy (destino del reverse proxy)
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

    # Headscale siempre está detrás de Caddy, así que sin trusted_proxies vería
    # la IP de Caddy en todas las peticiones y todos los nodos aparecerían con
    # la misma en los logs. Se confía en el rango privado de las redes bridge de
    # Docker (172.17-172.31, que cae dentro de 172.16.0.0/12): el puerto de
    # Headscale no se publica en el host, así que nadie más puede llegar ahí.
    # Headscale rechaza el prefijo /0, por eso no vale poner 0.0.0.0/0.
    TRUSTED_PROXIES_CONFIG=$(cat <<'EOFP'
trusted_proxies:
  - 172.16.0.0/12
EOFP
    )

    # Con un proxy por delante la cadena X-Forwarded-For llega con dos saltos
    # (cliente, proxy) y Headscale sólo salta los que tiene en la lista, así que
    # se añade también el proxy para que la IP real sea la del cliente.
    if [[ "$SSL_MODE" == "front" && -n "${BACKEND_HOST:-}" ]]; then
        TRUSTED_PROXIES_CONFIG+=$'\n'"  # Descomenta y pon el CIDR de tu proxy para ver la IP real del cliente:"
        TRUSTED_PROXIES_CONFIG+=$'\n'"  # - 192.168.1.50/32"
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
    print_header "GENERANDO CADDYFILE"

    case "$SSL_MODE" in
        letsencrypt)
            CADDY_DOMAIN="$DOMAIN"
            CADDY_TLS="tls ${ACME_EMAIL}"
            CADDY_HSTS="Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\""
            ;;
        selfsigned)
            CADDY_DOMAIN="$DOMAIN"
            CADDY_TLS="tls internal"
            CADDY_HSTS="# HSTS deshabilitado (certificado autofirmado)"
            ;;
        *)
            # 'front' y 'none': Caddy sólo enruta, por HTTP.
            #
            # ":80" en vez de "http://${DOMAIN}" a propósito: sin certificado el
            # sitio se alcanza por varios nombres (localhost, la IP de la LAN, el
            # hostname con el que lo llame el proxy de delante) y un site address
            # con dominio devolvería 404 a todos los demás.
            #
            # Caddy no intenta emitir certificados para una dirección sin esquema
            # ni host, así que no hace falta "auto_https off".
            CADDY_DOMAIN=":80"
            CADDY_TLS="# Sin TLS aquí: Caddy sólo hace de reverse proxy por HTTP"
            if [[ "$SSL_MODE" == "front" ]]; then
                CADDY_HSTS="# HSTS: lo emite el proxy de delante, que es quien habla HTTPS"
            else
                CADDY_HSTS="# HSTS deshabilitado (sin TLS)"
            fi
            ;;
    esac

    # Redirección HTTP -> HTTPS sólo cuando Caddy es quien tiene el certificado.
    # Sin él el sitio YA es el de HTTP y el bloque sería un bucle; con un proxy
    # delante, redirigir aquí mandaría al cliente de vuelta al proxy.
    if [[ "$SSL_MODE" == "letsencrypt" || "$SSL_MODE" == "selfsigned" ]]; then
        HTTP_REDIRECT=$(cat <<EOF
http://${DOMAIN} {
    redir https://{host}{uri} permanent
}
EOF
        )
    else
        HTTP_REDIRECT=""
    fi

    export CADDY_DOMAIN CADDY_TLS CADDY_HSTS HEADSCALE_HTTP_PORT HTTP_REDIRECT

    envsubst < "$TEMPLATES_DIR/Caddyfile.tmpl" > "$SCRIPT_DIR/Caddyfile"

    print_success "Caddyfile generado: Caddyfile"
}

generate_compose_override() {
    print_header "GENERANDO DOCKER COMPOSE OVERRIDE"

    local ports_block
    if [[ "$SSL_MODE" == "letsencrypt" || "$SSL_MODE" == "selfsigned" ]]; then
        print_info "Publicando los puertos HTTP y HTTPS de Caddy..."
        ports_block=$(cat <<'EOFP'
      # HTTP: reto ACME de Let's Encrypt y redirección a HTTPS
      - "${HTTP_PORT:-80}:80"
      - "${HTTPS_PORT:-443}:443"
      # HTTP/3 (QUIC)
      - "${HTTPS_PORT:-443}:443/udp"
EOFP
        )
    else
        print_info "Publicando sólo el puerto HTTP de Caddy (aquí no hay TLS)..."
        ports_block=$(cat <<'EOFP'
      # Sin TLS en esta máquina: sólo HTTP. No se publica 443 porque nada
      # escucharía ahí.
      - "${HTTP_PORT:-80}:80"
EOFP
        )
    fi

    # El heredoc no va entrecomillado, pero ports_block ya viene expandido y
    # bash no vuelve a escanear el resultado de una expansión: los ${HTTP_PORT}
    # de dentro llegan literales al fichero, que es lo que queremos (los
    # resuelve Compose leyendo .env).
    cat > "$SCRIPT_DIR/docker-compose.override.yml" <<EOF
# Docker Compose Override - Generado automáticamente por install.sh
# Publica los puertos de Caddy, que dependen de quién ponga el TLS.
#
# Compose FUSIONA las listas de 'ports' añadiendo, nunca quitando, así que los
# puertos variables no pueden estar en docker-compose.yml: si estuvieran, este
# fichero no podría retirarlos.
#
# NO editar a mano: install.sh lo regenera en cada ejecución.

services:
  caddy:
    ports:
${ports_block}
EOF

    print_success "docker-compose.override.yml generado"
}

# Con Caddy delante de todo, el proxy externo tiene un ÚNICO destino y no
# necesita saber nada de /admin ni de CORS: le basta con reenviar el dominio
# entero a Caddy, que ya enruta por ruta. Por eso el snippet es tan corto.
generate_front_proxy_snippet() {
    [[ "$SSL_MODE" == "front" ]] || return 0

    print_header "GENERANDO CONFIGURACIÓN DEL PROXY DE DELANTE"

    local tmpl out
    case "$FRONT_PROXY" in
        npm)     tmpl="front-npm.md.tmpl";      out="NGINX-PROXY-MANAGER.md" ;;
        nginx)   tmpl="front-nginx.conf.tmpl";  out="nginx-${DOMAIN}.conf"   ;;
        traefik) tmpl="front-traefik.yml.tmpl"; out="traefik-${DOMAIN}.yml"  ;;
        caddy)   tmpl="front-caddy.tmpl";       out="Caddyfile"              ;;
        *)
            print_warning "Proxy '${FRONT_PROXY}' desconocido, no se genera snippet"
            return 0
            ;;
    esac

    mkdir -p "$SCRIPT_DIR/reverse-proxy"

    export DOMAIN BACKEND_HOST HTTP_PORT HEADSCALE_DERP_PORT HEADSCALE_PUBLIC_URL

    # Lista explícita de variables: las plantillas de nginx y Traefik están
    # llenas de $host, $http_upgrade, $remote_addr... y un envsubst sin lista se
    # los comería todos dejando la configuración rota.
    envsubst '${DOMAIN} ${BACKEND_HOST} ${HTTP_PORT} ${HEADSCALE_DERP_PORT} ${HEADSCALE_PUBLIC_URL}' \
        < "$TEMPLATES_DIR/$tmpl" > "$SCRIPT_DIR/reverse-proxy/$out"

    print_success "Generado: reverse-proxy/${out}"
    print_info "Cópialo a la máquina del proxy y aplícalo allí"
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
    docker compose pull

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

    # Caddy forma parte del stack siempre: es quien enruta / y /admin, con
    # certificado o sin él. Por eso ya no hay profiles que activar.
    print_info "Levantando servicios..."
    docker compose up -d

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
    echo -e "${CYAN}HTTPS:${NC} ${BOLD}${SSL_MODE}${NC}"
    echo ""

    # URLs de acceso
    echo -e "${CYAN}Interfaz web (Headplane):${NC} ${BOLD}${HEADPLANE_PUBLIC_URL}/admin${NC}"
    echo -e "${CYAN}Control plane (Headscale):${NC} ${BOLD}${HEADSCALE_PUBLIC_URL}${NC}"
    echo ""

    # Con un proxy delante el stack NO es alcanzable todavía: falta configurar
    # la otra máquina. Decirlo antes que nada evita el desconcierto.
    if [[ "$SSL_MODE" == "front" ]]; then
        echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}${BOLD}│  FALTA UN PASO: CONFIGURAR EL PROXY DE DELANTE                          │${NC}"
        echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "   La URL de arriba todavía no responde. Aquí, Caddy escucha en:"
        echo -e "     ${BOLD}${BACKEND_HOST}:${HTTP_PORT}${NC}  (HTTP, ya enruta / y /admin)"
        echo ""
        echo -e "   Snippet listo para copiar en la máquina del proxy:"
        echo -e "     ${BOLD}$(ls -1 "$SCRIPT_DIR"/reverse-proxy/ 2>/dev/null | sed 's|^|reverse-proxy/|' | tr '\n' ' ')${NC}"
        echo ""
        print_warning "Apunta ${DOMAIN} al proxy, no a esta máquina."
        print_warning "Abre UDP ${HEADSCALE_DERP_PORT} hacia ${BACKEND_HOST}: el relay DERP no pasa por el proxy."
        echo ""
    fi

    # El aviso depende de URL_SCHEME y no de SSL_MODE: con un proxy delante hay
    # HTTPS aunque aquí no corra ningún terminador TLS.
    if [[ "$URL_SCHEME" == "http" ]]; then
        print_warning "El plano de control viaja sin cifrar (HTTP)"
        echo -e "   No expongas esto fuera de una red de confianza."
        echo ""
    fi

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
    echo "• Caddyfile: Caddyfile"
    echo "• Override de puertos: docker-compose.override.yml"
    [[ "$SSL_MODE" == "front" ]] && echo "• Snippet del proxy de delante: reverse-proxy/"
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
    configure_network
    configure_ports
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
    generate_front_proxy_snippet

    # 6. Desplegar
    echo ""
    if ask_yes_no "¿Deseas desplegar el stack ahora?" "y"; then
        # Fase 1: sólo Headscale, para poder emitir la API key
        start_headscale_first
        bootstrap_headscale

        # Regenerar la config de Headplane ya con la API key inyectada
        generate_headplane_config

        # Fase 2: resto del stack (Headplane y Caddy)
        deploy_stack
        show_access_info
    else
        print_info "Configuración completada pero no desplegada"
        print_info "Para desplegar manualmente, ejecuta:"
        echo -e "  ${YELLOW}docker compose up -d${NC}"
    fi

    echo ""
}

# Ejecutar main
main "$@"
