import re

with open('core/src/lib.rs', 'r') as f:
    content = f.read()

old_guard = """pub struct DbConnectionGuard {
    pub conn: Connection,
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl std::ops::Deref for DbConnectionGuard {
    type Target = Connection;
    fn deref(&self) -> &Self::Target {
        &self.conn
    }
}

impl std::ops::DerefMut for DbConnectionGuard {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.conn
    }
}"""

new_guard = """pub struct DbConnectionGuard {
    conn_guard: std::sync::MutexGuard<'static, Option<Connection>>,
    _query_guard: std::sync::MutexGuard<'static, ()>,
}

impl std::ops::Deref for DbConnectionGuard {
    type Target = Connection;
    fn deref(&self) -> &Self::Target {
        self.conn_guard.as_ref().unwrap()
    }
}

impl std::ops::DerefMut for DbConnectionGuard {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.conn_guard.as_mut().unwrap()
    }
}"""

content = content.replace(old_guard, new_guard)

old_get_db = """    if let Some(c) = conn_guard.as_ref() {
        if let Ok(cloned) = c.try_clone() {
            return Some(DbConnectionGuard {
                conn: cloned,
                _guard: query_guard,
            });
        }
    }
    None"""

new_get_db = """    if conn_guard.is_some() {
        return Some(DbConnectionGuard {
            conn_guard: conn_guard,
            _query_guard: query_guard,
        });
    }
    None"""

content = content.replace(old_get_db, new_get_db)

with open('core/src/lib.rs', 'w') as f:
    f.write(content)
print("Updated lib.rs")
