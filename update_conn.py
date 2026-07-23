import re

with open('core/src/lib.rs', 'r') as f:
    content = f.read()

# Replace DbConnectionGuard
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

new_guard = """pub struct DbConnectionGuard<'a> {
    pub conn_guard: std::sync::MutexGuard<'a, Option<Connection>>,
    _query_guard: std::sync::MutexGuard<'a, ()>,
}

impl<'a> std::ops::Deref for DbConnectionGuard<'a> {
    type Target = Connection;
    fn deref(&self) -> &Self::Target {
        self.conn_guard.as_ref().unwrap()
    }
}

impl<'a> std::ops::DerefMut for DbConnectionGuard<'a> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.conn_guard.as_mut().unwrap()
    }
}"""

# Actually, the problem is lifetimes with 'static. 
