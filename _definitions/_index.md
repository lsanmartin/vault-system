# _definitions — vault-system

Corpus de la voz del usuario. Formato: `00-Sistema/protocolo-definiciones.md`.

## objective
- Por definir.

## constraint
- Por definir.

## important
- [[rc1-mutex-raiz-latencia]] — Medido (2026-09-02): queries 15-27ms, refresh 69-97ms, cero contención de mutex. La latencia de 3000ms era misdiagnóstico.

## decision
- [[sidebar-lazy-cache]] — Sidebar lazy vía `childrenByParent` on-demand; `allFolders`/`allNotes` completos.
