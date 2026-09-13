---
name: directriz-apple-silicon-prevalece
type: decision
confidence: high
source: lsm
created: 2026-09-13
review_by: 2027-03-13
---

# Directriz #1 — Apple Silicon prevalece

> **El diseño que prevalece es siempre el de Apple Silicon.**
> Las demás plataformas (Intel Mac, Linux, iPad, iPhone, Android) **se adaptan como puedan**,
> siguiendo al diseño de Apple Silicon, nunca al revés.

## Implicaciones operativas

- `arm64` / Apple Silicon es el caso de referencia y define la arquitectura.
- El binario universal se mantiene como artefacto "oficial" (`make build-universal`).
- El build Intel (`make build-intel`) es un **atajo de iteración**, nunca reemplaza ni condiciona el universal.
- Ningún ajuste para otra plataforma puede degradar el build de arm64.
