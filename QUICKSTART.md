# Quickstart - Headscale + Headplane

Guía de inicio rápido para tener Headscale + Headplane funcionando en menos de 5 minutos.

## 🚀 Instalación en 3 Pasos

### 1. Ejecutar el Instalador

```bash
./install.sh
```

### 2. Responder las Preguntas

El instalador te preguntará:

- **Dominio o IP**: `vpn.midominio.com` o `192.168.1.100`
- **¿SSL?**: `s` (sí) o `n` (no)
  - Si sí: ¿Let's Encrypt o autofirmado?
  - Email para Let's Encrypt
- **Puertos**: Presiona Enter para usar los defaults
- **Nombre del Tailnet**: `myorg` (o el nombre de tu empresa)
- **¿OIDC?**: `n` (no, a menos que tengas Keycloak/Authentik)

### 3. ¡Listo!

Al finalizar verás:

```
✓ Headscale + Headplane están corriendo

URL de acceso: https://vpn.midominio.com

Próximos pasos:
1. Crear un usuario administrador...
```

---

## 📝 Primeros Pasos

### 1. Entrar en la UI Web

El instalador ya ha creado el usuario administrador y una **API key**, que
muestra por pantalla al terminar. Ábre la UI y pega esa key en el login:

```
https://vpn.midominio.com/admin          # con proxy (SSL)
http://vpn.midominio.com:3000/admin      # sin proxy
```

> Headplane sirve la interfaz bajo la ruta `/admin`. La raíz (`/`) devuelve 404.
> Sin OIDC, la API key es la única credencial: no hay usuario/contraseña.

### 2. Generar Clave de Conexión

```bash
./scripts/utils.sh preauth:create admin
```

O directamente, teniendo en cuenta que desde Headscale 0.29 `--user` espera el
**ID numérico** del usuario, no su nombre:

```bash
docker exec headscale headscale users list     # busca el ID de 'admin'
docker exec headscale headscale preauthkeys create \
  --user 1 \
  --reusable \
  --expiration 24h
```

Copia la clave que se muestra (empieza por `hskey-auth-`).

### 3. Conectar un Dispositivo

En tu ordenador/móvil con [Tailscale instalado](https://tailscale.com/download):

```bash
# Con proxy (SSL): el control plane vive en la raíz del dominio
tailscale up --login-server=https://vpn.midominio.com --authkey=<tu-clave>

# Sin proxy: hay que indicar el puerto de Headscale
tailscale up --login-server=http://vpn.midominio.com:8080 --authkey=<tu-clave>
```

> La URL exacta la muestra el instalador al terminar, y está en `.env` como
> `HEADSCALE_PUBLIC_URL`. **No es la misma** que la de la interfaz web.

---

## 🔧 Comandos Útiles

### Ver Estado

```bash
docker compose ps
```

### Ver Logs

```bash
# Todos los servicios
docker compose logs -f

# Solo Headscale
docker compose logs -f headscale
```

### Listar Dispositivos Conectados

```bash
docker exec headscale headscale nodes list
```

### Reiniciar Servicios

```bash
docker compose restart
```

### Detener Todo

```bash
docker compose down
```

### Iniciar de Nuevo

```bash
docker compose up -d
# O si tienes SSL habilitado:
docker compose --profile ssl up -d
```

---

## 🛠️ Script de Utilidades

Incluye un script con comandos útiles:

```bash
./scripts/utils.sh help

# Ejemplos:
./scripts/utils.sh status
./scripts/utils.sh users:create admin
./scripts/utils.sh preauth:create admin
./scripts/utils.sh backup
```

---

## ❓ Problemas Comunes

### "Connection refused" al acceder a la UI

**Solución**: Espera 30 segundos para que los servicios terminen de iniciar:

```bash
docker compose ps  # Verifica que estén "healthy"
```

### Let's Encrypt falla

**Causa**: DNS no apunta correctamente o puertos 80/443 bloqueados.

**Solución rápida**: Usa certificado autofirmado temporalmente:

```bash
./install.sh  # Re-ejecutar y elegir "autofirmado"
```

### Error 500 `auth ID has invalid length: expected 38, got 101`

**Causa**: has pegado la **API key** (la del login, `hskey-api-…`, 87 caracteres)
en el diálogo *Register Machine Key* de Headplane. Ese campo sólo acepta el
**Auth ID** de 38 caracteres.

**Solución**: lanza `tailscale up` **sin** `--authkey` en el dispositivo:

```bash
tailscale up --login-server=https://vpn.midominio.com
# -> To authenticate, visit: .../register/hskey-authreq-XXXXXXXXXXXXXXXXXXXXXXXX
```

Pega en Headplane sólo el `hskey-authreq-…`. O sáltate la UI por completo usando
una pre-auth key con `--authkey` (paso 2 de arriba).

### Los dispositivos no se conectan entre sí

**Solución**: Verifica que el puerto UDP 3478 esté abierto:

```bash
sudo ufw allow 3478/udp
```

---

## 📚 Más Información

- Documentación completa: Ver [README.md](README.md)
- Troubleshooting detallado: [README.md#troubleshooting](README.md#troubleshooting)
- Reconfigurar: Re-ejecuta `./install.sh`
- Backup: `./scripts/utils.sh backup`

---

## 🗑️ Desinstalar

```bash
./uninstall.sh         # Mantiene datos
./uninstall.sh --purge # Elimina todo
```

---

**¡Eso es todo! Tu red privada VPN está lista para usar.**
