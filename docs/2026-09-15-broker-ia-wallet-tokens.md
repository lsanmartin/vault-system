# Arquitectura de Broker de IA: Capa de Conocimiento, Harness, Billetera de Tokens y Operaciones Críticas

> 🗓️ **Fecha:** 2026-09-15 (Revisión técnica consolidada: 2026-09-16)  
> 🏷️ **Contexto:** cddev/vault-system · docs · Infraestructura de Agentes y Broker de Cómputo  
> 📌 **Estado:** Especificación Arquitectónica Aprobada y Consolidada  

---

## 1. Resumen Ejecutivo

La arquitectura del **Broker de Cómputo Local-First** consolida la gestión de inferencia y herramientas como un **recurso finito, medible, reservado y auditado**. El diseño separa estrictamente la **autoridad contable** (Ledger) del **consumo de cómputo** (Broker/Modelos).

El sistema está diseñado técnicamente para operar bajo un **circuito cerrado** (*closed-loop*, intransferible e inconvertible a dinero fiat). La aplicabilidad final de exenciones regulatorias (financieras y de protección de datos como la Ley 21.719 en Chile) deberá ser validada jurídicamente antes de despliegues comerciales.

---

## 2. Esquema Arquitectónico General

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                    Servicio Online / Cloud (Fase 2)                     │
│   • Motor Transaccional Servidor: TigerBeetle (Cluster consenso VSR)    │
│   • Ingesta de Event Sourcing: Procesamiento secuencial de audit_log    │
│   • Asignación de Capacidad: Emisión de Offline Compute Leases          │
│   • Catálogo y Políticas: CreditPolicy y ResourceCost maestros          │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ Sync Engine (Event Stream / ACK)
┌────────────────────────────────────▼────────────────────────────────────┐
│              Dispositivo Local (Mac / PC) — Soberano (Fase 1)           │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │               Bolsa de Cómputo (Ledger Local) [AUTORIDAD]       │   │
│   │   • SQLite Partida Doble + audit_log append-only criptográfico  │   │
│   │   • Gestión de Offline Compute Lease (Cupo delegado)            │   │
│   │   • Invariantes estrictos: Hold >= Capture, Release delta       │   │
│   └────────────────────────────────┬────────────────────────────────┘   │
│                                    │ Autorizaciones (Hold / Capture)
│   ┌────────────────────────────────▼────────────────────────────────┐   │
│   │              Broker Local de Inferencia [CONSUMIDOR]            │   │
│   │   • Gate F0: Caché en memoria de autorización (Cero lag)        │   │
│   │   • Privacy Interceptor (Censura PII en gateway)                │   │
│   │   • Model Context Router (Catálogo vivo y BYOK)                 │   │
│   └───────────────┬─────────────────────────────────┬───────────────┘   │
│                   │                                 │                   │
│   ┌───────────────▼───────────────┐ ┌───────────────▼───────────────┐   │
│   │      APIs Nativas del OS      │ │     MCP-Billing-Adapter       │   │
│   │ • AppleScript / Swift APIs    │ │ • Blender MCP (GPU/segundos)  │   │
│   │ • Windows Accessibility / CLI │ │ • ComfyUI (Créditos/imagen)   │   │
│   │ • Shell Sandboxed             │ │ • Tools de Código / Terminal  │   │
│   └───────────────────────────────┘ └───────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Principios y Resoluciones Arquitectónicas

### 3.1 Separación Estricta: Ledger (Autoridad) vs. Broker (Consumidor)
- **El Broker no es dueño del saldo.** El Broker es un mero orquestador que solicita reservas contables.
- **El Ledger es la única autoridad:** Valida disponibilidad, emite bloqueos (`Hold`), registra consumos (`Capture`) y restituye remanentes (`Release`).

### 3.2 Gate F0: Caché de Autorización (No Frontera de Seguridad)
- **Rol de F0:** Actúa como optimización de lectura de bajísima latencia para streaming de inferencia.
- **Límite de confianza:** F0 **nunca** crea créditos, no modifica saldos ni otorga validez transaccional retroactiva. Solo certifica en RAM que existe un `Hold` vigente emitido por el Ledger.

### 3.3 Prevención de Overspend Offline: Offline Compute Lease
- Se descarta el concepto de "flotante arbitrario" que permita doble gasto en escenarios multi-dispositivo.
- **Modelo de Lease:** El Cloud Ledger delega una **cuota finita de cómputo** (*Offline Compute Lease*) a cada dispositivo registrado:
  ```text
  Cloud Balance: 10.000 créditos
       ├── Lease Dispositivo A (MacBook): 2.000 créditos
       └── Lease Dispositivo B (Desktop): 3.000 créditos
  ```
- Al agotarse el lease offline, el dispositivo bloquea nuevas inferencias hasta sincronizar y renovar asignación.

### 3.4 Anti-Replay y Cadena Criptográfica Verificable
- La firma por hardware (**Secure Enclave / TPM**) autentica el origen pero no previene por sí sola la restauración de copias de seguridad (rollback de base de datos local).
- **Mecanismo Anti-Replay obligatorio:**
  - Contador monótono incremental ligado a hardware (`sequence`).
  - Encadenamiento criptográfico estricto de eventos:
    $$E_n = \text{Hash}(E_{n-1} + \text{Payload}_n + \text{Sequence}_n)$$
  - Registro de `device_id`, `ledger_epoch`, `previous_hash`, `tx_hash` y firma hardware.

### 3.5 audit_log Append-Only y Event Sourcing
- `audit_log` no es solo una tabla relacional; es una **secuencia inmutable de eventos sincronizables**.
- La unidad mínima de réplica hacia el coordinador central (TigerBeetle) es el **evento contable individual**, no el estado consolidado de la base de datos.

```sql
CREATE TABLE audit_log (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    event_hash TEXT NOT NULL UNIQUE,
    previous_event_hash TEXT NOT NULL,
    device_id TEXT NOT NULL,
    device_signature TEXT NOT NULL,
    ledger_epoch INTEGER NOT NULL,
    idempotency_key TEXT NOT NULL,
    payload JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    synced BOOLEAN DEFAULT FALSE
);
```

### 3.6 Hold por Turno (Bordes Financieros vs. Loop Caliente)
- La contabilidad no interrumpe el streaming de tokens.
- Ocurre exclusivamente en los bordes del turno:
  $$\text{AUTH (Hold)} \longrightarrow \text{STREAM (Inferencia / Tool)} \longrightarrow \text{CAPTURE (Real)} \longrightarrow \text{RELEASE (Delta)}$$

### 3.7 Compute Resource Broker: Normalización Heterogénea
- `MCP-Billing-Adapter` unifica consumo dispar (tokens LLM, tiempo GPU, generación imágenes) bajo la abstracción **Compute Credit**:
  - Tokens texto entrada/salida (LLMs).
  - Segundos GPU de cómputo (Blender MCP).
  - Pasos de inferencia / imágenes (ComfyUI MCP).

### 3.8 Desacoplamiento Económico: Costo de Proveedor vs. Precio al Usuario
- Se divide la entidad tarifaria en dos capas independientes:
  - **ResourceCost:** Costo técnico facturado por el proveedor externo (ej. USD por 1M tokens OpenAI/Anthropic).
  - **CreditPolicy:** Factor de conversión a créditos internos del sistema para el usuario final.
- Permite sustituir proveedores o absorber fluctuaciones cambiarias sin alterar la unidad económica del usuario.

---

## 4. Esquema de Entidades Contables y Reglas de Invarianza

```text
┌──────────────────────────┐             ┌──────────────────────────┐
│          Device          │             │          Lease           │
├──────────────────────────┤             ├──────────────────────────┤
│ • id (UUID / Hardware)   │             │ • id (UUID)              │
│ • public_key (PEM)       │             │ • device_id -> Device.id │
│ • monotonic_seq (INT)    │             │ • allocated_credits (DEC)│
│ • enrolled_at (TS)       │             │ • expires_at (TS)        │
└────────────┬─────────────┘             └────────────┬─────────────┘
             │ 1                                      │ 1
             │ asigna                                 │ limita
             │ 0..*                                   │ 0..*
┌────────────▼────────────────────────────────────────▼─────────────┐
│                             Account                               │
├───────────────────────────────────────────────────────────────────┤
│ • id (UUID)                                                       │
│ • owner_id (TEXT)                                                 │
│ • transferable (BOOL = FALSE)                                     │
│ • redeemable_for_cash (BOOL = FALSE)                              │
└────────────────────────────────┬──────────────────────────────────┘
                                 │ 1
                                 │ registra
                                 │ 0..*
┌────────────────────────────────▼──────────────────────────────────┐
│                           Transaction                             │
├───────────────────────────────────────────────────────────────────┤
│ • id (UUID)                                                       │
│ • idempotency_key (TEXT UNIQUE)                                   │
│ • status (PENDING / POSTED / VOIDED)                              │
│ • initiated_at (TS)                                               │
│ • posted_at (TS)                                                  │
└────────────────────────────────┬──────────────────────────────────┘
                                 │ 1 contiene
                                 │ 2..*
┌────────────────────────────────▼──────────────────────────────────┐
│                              Entry                                │
├───────────────────────────────────────────────────────────────────┤
│ • id (UUID)                                                       │
│ • transaction_id (UUID) -> Transaction.id                         │
│ • account_id (UUID)     -> Account.id                             │
│ • entry_type (HOLD / CAPTURE / RELEASE / DEPOSIT)                 │
│ • debit (DECIMAL)                                                 │
│ • credit (DECIMAL)                                                │
│ • resource_usage_id (UUID nullable) -> ResourceUsage.id           │
└───────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────┐     ┌──────────────────────────┐
│          ResourceCost            │     │       CreditPolicy       │
├──────────────────────────────────┤     ├──────────────────────────┤
│ • provider (OpenAI, Anthropic)   │     │ • resource_type (LLM/GPU)│
│ • resource_id (gpt-4o, claude)   │     │ • credit_factor (DECIMAL)│
│ • unit_cost (USD / unidad)       │     │ • effective_from (TS)    │
│ • effective_from / to (TS)       │     │ • effective_to (TS)      │
└──────────────────────────────────┘     └──────────────────────────┘
```

### Invariantes Contables Estrictos
1. **Conservación de masa:** $\sum \text{debit} = \sum \text{credit}$ en toda transacción.
2. **Cardinalidad mínima:** Cada transacción contiene $\ge 2$ entradas (`Entry`).
3. **Consistencia de ciclo:**
   - $\text{HOLD} \ge \text{CAPTURE}$
   - $\text{RELEASE} = \text{HOLD} - \text{CAPTURE}$
   - $\text{CAPTURE} \le \text{HOLD}$
4. **Inmutabilidad de eventos:** `CAPTURE` nunca sobreescribe a `HOLD`. `RELEASE` nunca modifica a `CAPTURE`. Cada transición constituye un evento separado e inmutable.
5. **Idempotencia:** Cada `idempotency_key` procesa estrictamente una única operación lógica.

---

## 5. Ciclo de Vida de Inferencia

```text
[ Inicio Turno Agente ]
       │
       ▼
 1. AUTH (Hold) ──────► Estimar techo (input + max_output / recursos MCP).
       │                Ledger reserva créditos en estado PENDING.
       │                Gate F0 almacena bandera en memoria para lectura rápida.
       ▼
 2. STREAM / TOOL ────► Ejecutar inferencia o tarea MCP (cero lag contable).
       │
       ▼
 3. CAPTURE ──────────► Medir métricas reales (ResourceUsage: tokens, GPU secs).
       │                Ledger asienta consumo exacto en estado POSTED.
       ▼
 4. RELEASE ──────────► Ledger libera delta remanente (Hold - Capture).
                        Actualiza saldo disponible y registro en audit_log.
```

---

## 6. Hoja de Ruta de Implementación Acotada

Para garantizar viabilidad y control de deuda técnica, la Fase 1 se reduce estrictamente al núcleo operativo.

```text
┌──────────────────────────────────────┐        ┌──────────────────────────────────────┐
│       Fase 1: Núcleo MVP Local       │        │     Fase 2: Coordinación Cloud       │
├──────────────────────────────────────┤        ├──────────────────────────────────────┤
│ • SQLite Partida Doble + Invariantes │───►───►│ • Cluster TigerBeetle central        │
│ • Ciclo Auth -> Capture -> Release   │        │ • Sync Engine basado en audit_log    │
│ • F0 como caché de autorización      │        │ • Asignación de Leases remotos       │
│ • 1 LLM Gateway + 1 MCP Adapter      │        │ • Portal de Marcas / Vouchers B2B    │
│ • audit_log con hash-chaining        │        │ • Radar dinámico SCD-2 tarifario     │
│ • Test de estrés: 10.000 turnos      │        │ • Validación jurídica closed-loop    │
└──────────────────────────────────────┘        └──────────────────────────────────────┘
```

---

## 7. Referencias y Documentos Relacionados

- [2026-06-17-mcp-broker-macos.md](2026-06-17-mcp-broker-macos.md)
- [2026-07-21-arquitectura-detallada-vault-system.md](2026-07-21-arquitectura-detallada-vault-system.md)
- [ADR-001-local-inference-engine.md](ADR-001-local-inference-engine.md)
- [_specs.md](../_specs.md)
- [_memory.md](../_memory.md)
- [_lore.md](../_lore.md)
